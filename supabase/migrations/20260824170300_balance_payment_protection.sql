create or replace function public.service_create_payment_intent_by_token(
  p_access_token text,p_payment_kind text,p_method text,p_request_key text
)
returns jsonb
language plpgsql
security definer
set search_path=public,extensions
as $$
declare
  v_appointment_id uuid; v_appointment public.appointments%rowtype; v_percentage numeric(5,2);
  v_idempotency_key text; v_result jsonb; v_transaction_id uuid; v_hash text; v_collection_id uuid;
begin
  if p_payment_kind not in ('MINIMUM','FULL') then raise exception using errcode='P0001',message='INVALID_PAYMENT_KIND'; end if;
  if p_method not in ('PIX','CARD') then raise exception using errcode='P0001',message='PUBLIC_PAYMENT_METHOD_NOT_ALLOWED'; end if;
  if p_request_key is null or p_request_key !~ '^[A-Za-z0-9_-]{12,100}$' then raise exception using errcode='P0001',message='PAYMENT_REQUEST_KEY_INVALID'; end if;

  v_hash:=encode(digest(p_access_token,'sha256'),'hex');
  select appointment_id,balance_collection_id into v_appointment_id,v_collection_id
  from public.appointment_access_tokens
  where token_hash=v_hash and revoked_at is null and consumed_at is null and (expires_at is null or expires_at>now())
  order by created_at desc limit 1;
  if v_appointment_id is null then
    v_appointment_id:=public.resolve_appointment_access_token(p_access_token,'PAY');
  else
    perform public.resolve_appointment_access_token(p_access_token,'PAY');
  end if;

  select * into v_appointment from public.appointments where id=v_appointment_id;
  if v_collection_id is not null then
    perform public.expire_due_balance_collections();
    if not exists(select 1 from public.appointment_balance_collections where id=v_collection_id and status='PENDING' and expires_at>public.balance_collection_clock()) then
      raise exception using errcode='P0001',message='BALANCE_COLLECTION_INVALID_OR_EXPIRED';
    end if;
    if p_payment_kind<>'FULL' then raise exception using errcode='P0001',message='BALANCE_COLLECTION_FULL_PAYMENT_REQUIRED'; end if;
    v_percentage:=100;
  elsif p_payment_kind='FULL' then
    v_percentage:=100;
  else
    v_percentage:=v_appointment.confirmation_percentage_snapshot;
    if v_percentage is null then raise exception using errcode='P0001',message='APPOINTMENT_CONFIRMATION_SNAPSHOT_MISSING'; end if;
  end if;

  v_idempotency_key:='public:'||v_appointment_id::text||':'||p_request_key;
  v_result:=public.create_payment_intent(v_appointment_id,v_percentage,p_method,v_idempotency_key);
  v_transaction_id:=nullif(v_result->>'transaction_id','')::uuid;
  if v_collection_id is not null and v_transaction_id is not null then
    update public.payment_transactions set balance_collection_id=v_collection_id where id=v_transaction_id and appointment_id=v_appointment_id;
  end if;
  return v_result||jsonb_build_object('balance_collection_id',v_collection_id);
end;
$$;

create or replace function public.guard_duplicate_balance_payment()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare v_balance numeric(12,2); v_collection public.appointment_balance_collections%rowtype;
begin
  if new.balance_collection_id is null or new.status<>'APPROVED' or old.status='APPROVED' then return new; end if;
  perform 1 from public.appointments where id=new.appointment_id for update;
  select * into v_collection from public.appointment_balance_collections where id=new.balance_collection_id;
  v_balance:=round(greatest(coalesce((public.get_appointment_financial_summary(new.appointment_id)->>'contract_balance')::numeric,0),0),2);
  if v_balance<=0.005 or v_collection.status in ('PAID','CANCELLED_SETTLED','CANCELLED_NO_SHOW') then
    new.contract_amount_settled:=0;
    new.payment_discount_amount:=0;
    insert into public.balance_collection_divergences(
      appointment_id,balance_collection_id,payment_transaction_id,divergence_type,provider,provider_reference,details_json
    ) values(
      new.appointment_id,new.balance_collection_id,new.id,'DUPLICATE_BALANCE_PAYMENT',new.provider,new.provider_payment_id,
      jsonb_build_object('cash_amount',new.cash_amount,'collection_status',v_collection.status,'contract_balance_before',v_balance)
    ) on conflict do nothing;
    insert into public.audit_logs(entity_type,entity_id,action,after_json,origin)
    values('APPOINTMENT',new.appointment_id,'DUPLICATE_BALANCE_PAYMENT_QUARANTINED',
      jsonb_build_object('payment_transaction_id',new.id,'collection_id',new.balance_collection_id,'cash_amount',new.cash_amount),'MERCADO_PAGO');
  end if;
  return new;
end;
$$;

drop trigger if exists trg_guard_duplicate_balance_payment on public.payment_transactions;
create trigger trg_guard_duplicate_balance_payment
before update of status on public.payment_transactions
for each row execute function public.guard_duplicate_balance_payment();

create or replace function public.mark_balance_collection_paid_after_payment()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare v_balance numeric(12,2); v_now timestamptz:=public.balance_collection_clock(); v_collection public.appointment_balance_collections%rowtype;
begin
  if new.balance_collection_id is null or new.status<>'APPROVED' or old.status='APPROVED' or new.contract_amount_settled<=0 then return new; end if;
  v_balance:=round(greatest(coalesce((public.get_appointment_financial_summary(new.appointment_id)->>'contract_balance')::numeric,0),0),2);
  if v_balance<=0.005 then
    select * into v_collection from public.appointment_balance_collections where id=new.balance_collection_id for update;
    if found and v_collection.status='PENDING' then
      update public.appointment_balance_collections set status='PAID',updated_at=v_now where id=v_collection.id;
      update public.appointment_access_tokens set revoked_at=coalesce(revoked_at,v_now) where balance_collection_id=v_collection.id and revoked_at is null;
      insert into public.audit_logs(entity_type,entity_id,action,after_json,origin)
      values('APPOINTMENT',new.appointment_id,'BALANCE_COLLECTION_PAID',
        jsonb_build_object('collection_id',v_collection.id,'payment_transaction_id',new.id,'cash_amount',new.cash_amount),'MERCADO_PAGO');
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_mark_balance_collection_paid_after_payment on public.payment_transactions;
create trigger trg_mark_balance_collection_paid_after_payment
after update of status on public.payment_transactions
for each row execute function public.mark_balance_collection_paid_after_payment();

revoke all on function public.guard_duplicate_balance_payment() from public,anon,authenticated;
revoke all on function public.mark_balance_collection_paid_after_payment() from public,anon,authenticated;
