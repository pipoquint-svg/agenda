create or replace function public.expire_due_balance_collections()
returns integer
language plpgsql
volatile
security definer
set search_path=public
as $$
declare v_now timestamptz:=public.balance_collection_clock(); v_count integer:=0; v_row record;
begin
  for v_row in
    update public.appointment_balance_collections
    set status='EXPIRED',updated_at=v_now
    where status='PENDING' and expires_at<=v_now
    returning id,appointment_id,sequence,amount_snapshot,expires_at
  loop
    v_count:=v_count+1;
    update public.appointment_access_tokens set revoked_at=coalesce(revoked_at,v_now)
      where balance_collection_id=v_row.id and revoked_at is null;
    insert into public.integration_jobs(job_type,entity_type,entity_id,entity_version,payload_json,idempotency_key)
    values('RENTAL_BALANCE_CANCEL_EXPIRED','BALANCE_COLLECTION',v_row.id,v_row.sequence,
      jsonb_build_object('appointment_id',v_row.appointment_id),'rental-balance-expired:'||v_row.id::text)
    on conflict(idempotency_key) do nothing;
    insert into public.audit_logs(entity_type,entity_id,action,after_json,origin)
    values('APPOINTMENT',v_row.appointment_id,'BALANCE_COLLECTION_EXPIRED',
      jsonb_build_object('collection_id',v_row.id,'sequence',v_row.sequence,'amount',v_row.amount_snapshot,'expired_at',v_row.expires_at),'SYSTEM');
  end loop;
  return v_count;
end;
$$;

create or replace function public.service_admin_reissue_balance_collection(p_appointment_id uuid,p_admin_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path=public
as $$
declare v_previous public.appointment_balance_collections%rowtype;
begin
  if not public.service_admin_has_permission(p_admin_id,'FINANCE_MANAGE') then raise exception using errcode='42501',message='ADMIN_PERMISSION_DENIED'; end if;
  perform public.expire_due_balance_collections();
  select * into v_previous from public.appointment_balance_collections where appointment_id=p_appointment_id order by sequence desc limit 1 for update;
  if not found then raise exception using errcode='P0001',message='BALANCE_COLLECTION_REISSUE_NOT_ALLOWED'; end if;
  if v_previous.status='PENDING' then raise exception using errcode='P0001',message='BALANCE_COLLECTION_STILL_ACTIVE'; end if;
  if v_previous.status not in ('EXPIRED','CANCELLED_SETTLED','CANCELLED_NO_SHOW') then raise exception using errcode='P0001',message='BALANCE_COLLECTION_REISSUE_NOT_ALLOWED'; end if;
  if exists(
    select 1 from public.payment_transactions
    where balance_collection_id=v_previous.id and provider='MERCADO_PAGO' and transaction_type='CHARGE' and status='PENDING' and provider_payment_id is not null
  ) then raise exception using errcode='P0001',message='BALANCE_PROVIDER_CLEANUP_PENDING'; end if;
  return public.create_balance_collection(p_appointment_id,'ADMIN_REISSUE',p_admin_id);
end;
$$;
