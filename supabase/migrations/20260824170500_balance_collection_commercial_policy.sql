-- Approved BlackSheep commercial policy, 2026-08-24.
-- 1. NO_SHOW is financially treated as a performed rental.
-- 2. BlackSheep duration-rental cancellation/reschedule notice is 12 hours for new snapshots.
-- 3. In-person partial payment terminates the old collection so it can be reissued for the reduced balance.
-- 4. At most two ADMIN_REISSUE collections may exist per appointment.

alter table public.appointment_balance_collections
  drop constraint if exists appointment_balance_collections_status_check;
alter table public.appointment_balance_collections
  add constraint appointment_balance_collections_status_check
  check (status in ('PENDING','PAID','EXPIRED','CANCELLED_SETTLED','CANCELLED_NO_SHOW','CANCELLED_PARTIAL_PAYMENT'));

-- Historical CANCELLED_NO_SHOW rows remain valid, but new NO_SHOW transitions must not cancel a balance collection.
drop trigger if exists trg_enqueue_no_show_balance_cancellation on public.appointments;

update public.service_change_policies p
set notice_hours=12, updated_at=now()
from public.services s
where s.id=p.service_id
  and s.operation_scope='BLACKSHEEP'
  and s.duration_mode='BLOCKS'
  and p.notice_hours is distinct from 12;

create or replace function public.create_balance_collection(
  p_appointment_id uuid,p_source text,p_admin_id uuid default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path=public
as $$
declare
  v_now timestamptz:=public.balance_collection_clock();
  v_appointment public.appointments%rowtype;
  v_scope text;
  v_balance numeric(12,2);
  v_sequence integer;
  v_collection public.appointment_balance_collections%rowtype;
  v_previous public.appointment_balance_collections%rowtype;
  v_has_previous boolean:=false;
  v_reissues integer:=0;
begin
  if p_source not in ('AUTO_START','ADMIN_REISSUE') then
    raise exception using errcode='22023',message='BALANCE_COLLECTION_SOURCE_INVALID';
  end if;

  select * into v_appointment from public.appointments where id=p_appointment_id for update;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if;
  select operation_scope into v_scope from public.services where id=v_appointment.service_id;
  if v_scope<>'BLACKSHEEP' then raise exception using errcode='P0001',message='BALANCE_COLLECTION_SCOPE_DENIED'; end if;
  if v_appointment.status not in ('CONFIRMED','COMPLETED','NO_SHOW') then
    raise exception using errcode='P0001',message='BALANCE_COLLECTION_APPOINTMENT_NOT_ELIGIBLE';
  end if;
  if coalesce(v_appointment.billing_mode_snapshot,'CHECKOUT')='INVOICE' then
    raise exception using errcode='P0001',message='BALANCE_COLLECTION_INVOICE_DENIED';
  end if;
  if p_source='AUTO_START' and v_appointment.start_at>v_now then
    raise exception using errcode='P0001',message='BALANCE_COLLECTION_NOT_DUE';
  end if;
  if p_source='ADMIN_REISSUE' and (p_admin_id is null or not public.service_admin_has_permission(p_admin_id,'FINANCE_MANAGE')) then
    raise exception using errcode='42501',message='ADMIN_PERMISSION_DENIED';
  end if;

  perform public.expire_due_balance_collections();
  select * into v_previous
  from public.appointment_balance_collections
  where appointment_id=p_appointment_id
  order by sequence desc limit 1 for update;
  v_has_previous:=found;

  if p_source='AUTO_START' and v_has_previous then
    raise exception using errcode='P0001',message='BALANCE_COLLECTION_ALREADY_CREATED';
  end if;

  if p_source='ADMIN_REISSUE' then
    select count(*)::integer into v_reissues
    from public.appointment_balance_collections
    where appointment_id=p_appointment_id and source='ADMIN_REISSUE';

    if v_reissues>=2 then
      raise exception using errcode='P0001',message='BALANCE_COLLECTION_REISSUE_LIMIT_REACHED';
    end if;
    if not v_has_previous then
      raise exception using errcode='P0001',message='BALANCE_COLLECTION_REISSUE_NOT_ALLOWED';
    end if;
    if v_previous.status='PENDING' then
      raise exception using errcode='P0001',message='BALANCE_COLLECTION_STILL_ACTIVE';
    end if;
    if v_previous.status not in ('EXPIRED','CANCELLED_SETTLED','CANCELLED_NO_SHOW','CANCELLED_PARTIAL_PAYMENT') then
      raise exception using errcode='P0001',message='BALANCE_COLLECTION_REISSUE_NOT_ALLOWED';
    end if;
    if exists(
      select 1 from public.payment_transactions
      where balance_collection_id=v_previous.id
        and provider='MERCADO_PAGO'
        and transaction_type='CHARGE'
        and status='PENDING'
        and provider_payment_id is not null
    ) then
      raise exception using errcode='P0001',message='BALANCE_PROVIDER_CLEANUP_PENDING';
    end if;
  end if;

  v_balance:=round(greatest(coalesce((public.get_appointment_financial_summary(p_appointment_id)->>'contract_balance')::numeric,0),0),2);
  if v_balance<=0.005 then raise exception using errcode='P0001',message='BALANCE_COLLECTION_NOT_DUE'; end if;

  select coalesce(max(sequence),0)+1 into v_sequence
  from public.appointment_balance_collections where appointment_id=p_appointment_id;

  insert into public.appointment_balance_collections(
    appointment_id,sequence,source,status,amount_snapshot,issued_at,expires_at,created_by_admin_id
  ) values(
    p_appointment_id,v_sequence,p_source,'PENDING',v_balance,v_now,v_now+interval '48 hours',p_admin_id
  ) returning * into v_collection;

  insert into public.integration_jobs(job_type,entity_type,entity_id,entity_version,payload_json,idempotency_key)
  values
    ('RENTAL_BALANCE_DUE_EMAIL','BALANCE_COLLECTION',v_collection.id,v_sequence,jsonb_build_object('appointment_id',p_appointment_id,'source',p_source),'rental-balance-email:'||v_collection.id::text),
    ('RENTAL_BALANCE_DUE_KOMMO','BALANCE_COLLECTION',v_collection.id,v_sequence,jsonb_build_object('appointment_id',p_appointment_id,'source',p_source),'rental-balance-kommo:'||v_collection.id::text)
  on conflict(idempotency_key) do nothing;

  insert into public.audit_logs(entity_type,entity_id,action,after_json,origin,admin_user_id)
  values(
    'APPOINTMENT',p_appointment_id,
    case when p_source='AUTO_START' then 'BALANCE_COLLECTION_PENDING' else 'BALANCE_COLLECTION_REISSUED' end,
    jsonb_build_object(
      'collection_id',v_collection.id,'sequence',v_sequence,'amount',v_balance,
      'expires_at',v_collection.expires_at,
      'reissue_count',v_reissues + case when p_source='ADMIN_REISSUE' then 1 else 0 end
    ),
    case when p_source='AUTO_START' then 'SYSTEM' else 'OPERATION' end,
    p_admin_id
  );

  return jsonb_build_object(
    'collection_id',v_collection.id,'appointment_id',p_appointment_id,'sequence',v_sequence,
    'status','PENDING','amount',v_balance,'issued_at',v_collection.issued_at,'expires_at',v_collection.expires_at,
    'reissue_count',v_reissues + case when p_source='ADMIN_REISSUE' then 1 else 0 end,
    'reissues_remaining',greatest(2-(v_reissues + case when p_source='ADMIN_REISSUE' then 1 else 0 end),0)
  );
end;
$$;

create or replace function public.service_admin_reissue_balance_collection(p_appointment_id uuid,p_admin_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path=public
as $$
declare
  v_previous public.appointment_balance_collections%rowtype;
  v_reissues integer:=0;
begin
  if not public.service_admin_has_permission(p_admin_id,'FINANCE_MANAGE') then
    raise exception using errcode='42501',message='ADMIN_PERMISSION_DENIED';
  end if;
  perform public.expire_due_balance_collections();

  select count(*)::integer into v_reissues
  from public.appointment_balance_collections
  where appointment_id=p_appointment_id and source='ADMIN_REISSUE';
  if v_reissues>=2 then
    raise exception using errcode='P0001',message='BALANCE_COLLECTION_REISSUE_LIMIT_REACHED';
  end if;

  select * into v_previous
  from public.appointment_balance_collections
  where appointment_id=p_appointment_id
  order by sequence desc limit 1 for update;
  if not found then raise exception using errcode='P0001',message='BALANCE_COLLECTION_REISSUE_NOT_ALLOWED'; end if;
  if v_previous.status='PENDING' then raise exception using errcode='P0001',message='BALANCE_COLLECTION_STILL_ACTIVE'; end if;
  if v_previous.status not in ('EXPIRED','CANCELLED_SETTLED','CANCELLED_NO_SHOW','CANCELLED_PARTIAL_PAYMENT') then
    raise exception using errcode='P0001',message='BALANCE_COLLECTION_REISSUE_NOT_ALLOWED';
  end if;
  if exists(
    select 1 from public.payment_transactions
    where balance_collection_id=v_previous.id
      and provider='MERCADO_PAGO'
      and transaction_type='CHARGE'
      and status='PENDING'
      and provider_payment_id is not null
  ) then
    raise exception using errcode='P0001',message='BALANCE_PROVIDER_CLEANUP_PENDING';
  end if;
  return public.create_balance_collection(p_appointment_id,'ADMIN_REISSUE',p_admin_id);
end;
$$;

create or replace function public.service_mark_balance_collection_cancelled(
  p_collection_id uuid,p_reason text,p_admin_id uuid default null,p_ip text default null,p_user_agent text default null,p_request_id text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path=public
as $$
declare
  v_now timestamptz:=public.balance_collection_clock();
  v_collection public.appointment_balance_collections%rowtype;
  v_target text;
  v_action text;
  v_request_id uuid;
begin
  if p_reason='SETTLED' then
    v_target:='CANCELLED_SETTLED'; v_action:='BALANCE_COLLECTION_CANCELLED_SETTLED';
  elsif p_reason='PARTIAL' then
    v_target:='CANCELLED_PARTIAL_PAYMENT'; v_action:='BALANCE_COLLECTION_CANCELLED_PARTIAL_PAYMENT';
  else
    raise exception using errcode='22023',message='BALANCE_COLLECTION_CANCEL_REASON_INVALID';
  end if;

  if p_request_id is not null and btrim(p_request_id)<>'' then
    begin v_request_id:=p_request_id::uuid;
    exception when invalid_text_representation then
      raise exception using errcode='22023',message='REQUEST_ID_INVALID';
    end;
  end if;

  select * into v_collection from public.appointment_balance_collections where id=p_collection_id for update;
  if not found then raise exception using errcode='P0001',message='BALANCE_COLLECTION_NOT_FOUND'; end if;
  if v_collection.status<>'PENDING' then
    return jsonb_build_object('collection_id',v_collection.id,'status',v_collection.status,'idempotent',true);
  end if;

  update public.appointment_balance_collections set status=v_target,updated_at=v_now where id=v_collection.id;
  update public.appointment_access_tokens set revoked_at=coalesce(revoked_at,v_now)
  where balance_collection_id=v_collection.id and revoked_at is null;

  insert into public.audit_logs(entity_type,entity_id,action,after_json,origin,admin_user_id,request_id)
  values(
    'APPOINTMENT',v_collection.appointment_id,v_action,
    jsonb_build_object('collection_id',v_collection.id,'ip_address',p_ip,'user_agent',p_user_agent),
    case when p_admin_id is null then 'SYSTEM' else 'OPERATION' end,p_admin_id,v_request_id
  );

  return jsonb_build_object('collection_id',v_collection.id,'appointment_id',v_collection.appointment_id,'status',v_target);
end;
$$;

create or replace function public.service_record_manual_contract_payment(
  p_appointment_id uuid,p_admin_id uuid,p_amount numeric,p_method text,p_ip text,p_user_agent text,p_request_id text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path=public
as $$
declare
  v_before numeric(12,2); v_after numeric(12,2); v_tx uuid; v_collection uuid; v_request_id uuid;
begin
  if not public.service_admin_has_permission(p_admin_id,'FINANCE_MANAGE') then raise exception using errcode='42501',message='ADMIN_PERMISSION_DENIED'; end if;
  if p_amount is null or p_amount<=0 then raise exception using errcode='22023',message='MANUAL_PAYMENT_AMOUNT_INVALID'; end if;
  if upper(coalesce(p_method,'')) not in ('CASH','OTHER') then raise exception using errcode='22023',message='MANUAL_PAYMENT_METHOD_INVALID'; end if;
  if coalesce(btrim(p_ip),'')='' or coalesce(btrim(p_user_agent),'')='' or coalesce(btrim(p_request_id),'')='' then
    raise exception using errcode='22023',message='AUTHORSHIP_ADMIN_EVIDENCE_REQUIRED';
  end if;
  begin v_request_id:=p_request_id::uuid;
  exception when invalid_text_representation then raise exception using errcode='22023',message='REQUEST_ID_INVALID'; end;

  perform 1 from public.appointments where id=p_appointment_id for update;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if;
  v_before:=round(greatest(coalesce((public.get_appointment_financial_summary(p_appointment_id)->>'contract_balance')::numeric,0),0),2);
  if v_before<=0.005 then raise exception using errcode='P0001',message='APPOINTMENT_ALREADY_SETTLED'; end if;
  if p_amount>v_before+0.005 then raise exception using errcode='22023',message='MANUAL_PAYMENT_EXCEEDS_BALANCE'; end if;

  insert into public.payment_transactions(
    appointment_id,transaction_type,method,provider,status,contract_amount_settled,payment_discount_amount,cash_amount,
    paid_at,created_by_admin_id,notes,payment_purpose
  ) values(
    p_appointment_id,'CHARGE',upper(p_method),'MANUAL','APPROVED',round(p_amount,2),0,round(p_amount,2),
    now(),p_admin_id,'Pagamento presencial registrado no painel','CONTRACT'
  ) returning id into v_tx;

  perform public.refresh_appointment_financial_status(p_appointment_id);
  v_after:=round(greatest(coalesce((public.get_appointment_financial_summary(p_appointment_id)->>'contract_balance')::numeric,0),0),2);
  select id into v_collection
  from public.appointment_balance_collections
  where appointment_id=p_appointment_id and status='PENDING'
  order by sequence desc limit 1;

  insert into public.audit_logs(entity_type,entity_id,action,after_json,origin,admin_user_id,request_id)
  values(
    'APPOINTMENT',p_appointment_id,'MANUAL_CONTRACT_PAYMENT_RECORDED',
    jsonb_build_object(
      'payment_transaction_id',v_tx,'method',upper(p_method),'amount',round(p_amount,2),
      'balance_before',v_before,'balance_after',v_after,'ip_address',p_ip,'user_agent',p_user_agent
    ),
    'OPERATION',p_admin_id,v_request_id
  );

  return jsonb_build_object(
    'payment_transaction_id',v_tx,'appointment_id',p_appointment_id,'balance_before',v_before,
    'amount',round(p_amount,2),'balance_after',v_after,'settled',v_after<=0.005,'active_collection_id',v_collection
  );
end;
$$;

create or replace function public.enqueue_due_rental_balance_collections()
returns integer
language plpgsql
volatile
security definer
set search_path=public
as $$
declare v_now timestamptz:=public.balance_collection_clock(); v_row record; v_count integer:=0;
begin
  perform public.expire_due_balance_collections();
  for v_row in
    select a.id
    from public.appointments a
    join public.services s on s.id=a.service_id
    cross join lateral (select public.get_appointment_financial_summary(a.id) as summary) fin
    where s.operation_scope='BLACKSHEEP'
      and a.status in ('CONFIRMED','COMPLETED','NO_SHOW')
      and coalesce(a.billing_mode_snapshot,'CHECKOUT')<>'INVOICE'
      and a.start_at<=v_now
      and a.start_at>v_now-interval '24 hours'
      and coalesce((fin.summary->>'contract_balance')::numeric,0)>0.005
      and not exists(select 1 from public.appointment_balance_collections c where c.appointment_id=a.id)
    order by a.start_at,a.id
    for update of a skip locked
  loop
    begin
      perform public.create_balance_collection(v_row.id,'AUTO_START',null);
      v_count:=v_count+1;
    exception when others then
      if sqlerrm not in ('BALANCE_COLLECTION_ALREADY_CREATED','BALANCE_COLLECTION_NOT_DUE') then raise; end if;
    end;
  end loop;
  return v_count;
end;
$$;

create or replace view public.appointment_open_balances as
select
  a.id appointment_id,a.public_code,a.primary_customer_id customer_id,c.name customer_name,
  a.service_id,a.service_name_snapshot service_name,s.operation_scope,
  a.status appointment_status,a.financial_status,a.billing_mode_snapshot,a.start_at,a.core_end_at,a.commercial_value total_value,
  coalesce((fin.summary->>'contract_settled')::numeric,0)::numeric(12,2) paid_value,
  coalesce((fin.summary->>'contract_balance')::numeric,0)::numeric(12,2) balance_value,
  bc.id active_collection_id,bc.sequence collection_sequence,bc.expires_at collection_expires_at,bc.status collection_status,
  coalesce((select count(*) from public.appointment_balance_collections r where r.appointment_id=a.id and r.source='ADMIN_REISSUE'),0)::integer reissue_count,
  greatest(2-coalesce((select count(*) from public.appointment_balance_collections r where r.appointment_id=a.id and r.source='ADMIN_REISSUE'),0),0)::integer reissues_remaining
from public.appointments a
join public.services s on s.id=a.service_id
left join public.customers c on c.id=a.primary_customer_id
cross join lateral(select public.get_appointment_financial_summary(a.id) summary) fin
left join lateral(
  select x.id,x.sequence,x.expires_at,x.status
  from public.appointment_balance_collections x
  where x.appointment_id=a.id order by x.sequence desc limit 1
) bc on true
where a.status in ('CONFIRMED','COMPLETED','NO_SHOW')
  and coalesce(a.billing_mode_snapshot,'CHECKOUT')<>'INVOICE'
  and coalesce((fin.summary->>'contract_balance')::numeric,0)>0.005;

create or replace view public.appointment_overdue_balances as
select * from public.appointment_open_balances
where core_end_at<=public.balance_collection_clock()
  and collection_status='EXPIRED';

revoke all on public.appointment_open_balances from public,anon,authenticated;
revoke all on public.appointment_overdue_balances from public,anon,authenticated;
grant select on public.appointment_open_balances to service_role;
grant select on public.appointment_overdue_balances to service_role;

revoke all on function public.create_balance_collection(uuid,text,uuid) from public,anon,authenticated;
revoke all on function public.service_admin_reissue_balance_collection(uuid,uuid) from public,anon,authenticated;
revoke all on function public.service_mark_balance_collection_cancelled(uuid,text,uuid,text,text,text) from public,anon,authenticated;
revoke all on function public.service_record_manual_contract_payment(uuid,uuid,numeric,text,text,text,text) from public,anon,authenticated;
revoke all on function public.enqueue_due_rental_balance_collections() from public,anon,authenticated;
grant execute on function public.service_admin_reissue_balance_collection(uuid,uuid) to service_role;
grant execute on function public.service_mark_balance_collection_cancelled(uuid,text,uuid,text,text,text) to service_role;
grant execute on function public.service_record_manual_contract_payment(uuid,uuid,numeric,text,text,text,text) to service_role;
grant execute on function public.enqueue_due_rental_balance_collections() to service_role;
