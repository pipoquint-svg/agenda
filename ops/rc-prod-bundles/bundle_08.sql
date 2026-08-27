
-- BEGIN RC MIGRATION 20260824170200_balance_collection_hardening.sql
-- Explicit collection lifecycle and overdue criteria.

alter table public.appointment_balance_collections drop constraint if exists appointment_balance_collections_status_check;
update public.appointment_balance_collections set status='PENDING' where status='ACTIVE';
alter table public.appointment_balance_collections
  add constraint appointment_balance_collections_status_check
  check (status in ('PENDING','PAID','EXPIRED','CANCELLED_SETTLED','CANCELLED_NO_SHOW'));

alter table public.payment_transactions
  add column if not exists balance_collection_id uuid references public.appointment_balance_collections(id) on delete set null;
create index if not exists payment_transactions_balance_collection_idx
  on public.payment_transactions(balance_collection_id)
  where balance_collection_id is not null;

create table if not exists public.balance_collection_divergences (
  id uuid primary key default gen_random_uuid(),
  appointment_id uuid not null references public.appointments(id) on delete restrict,
  balance_collection_id uuid references public.appointment_balance_collections(id) on delete set null,
  payment_transaction_id uuid references public.payment_transactions(id) on delete set null,
  divergence_type text not null check (divergence_type in ('PROVIDER_CANCEL_FAILED','DUPLICATE_BALANCE_PAYMENT')),
  provider text,
  provider_reference text,
  details_json jsonb not null default '{}'::jsonb,
  status text not null default 'OPEN' check (status in ('OPEN','RESOLVED','IGNORED_WITH_REASON')),
  detected_at timestamptz not null default now(),
  resolved_at timestamptz,
  resolved_by_admin_id uuid references public.admin_users(id),
  resolution_notes text
);
create index if not exists balance_collection_divergences_open_idx
  on public.balance_collection_divergences(status,detected_at desc);
alter table public.balance_collection_divergences enable row level security;
revoke all on public.balance_collection_divergences from public,anon,authenticated;
grant select,insert,update on public.balance_collection_divergences to service_role;

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
    update public.appointment_access_tokens
      set revoked_at=coalesce(revoked_at,v_now)
      where balance_collection_id=v_row.id and revoked_at is null;
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
  if not public.service_admin_has_permission(p_admin_id,'FINANCE_MANAGE') then
    raise exception using errcode='42501',message='ADMIN_PERMISSION_DENIED';
  end if;
  perform public.expire_due_balance_collections();
  select * into v_previous from public.appointment_balance_collections
  where appointment_id=p_appointment_id order by sequence desc limit 1 for update;
  if found and v_previous.status='PENDING' then
    raise exception using errcode='P0001',message='BALANCE_COLLECTION_STILL_ACTIVE';
  end if;
  if found and v_previous.status not in ('EXPIRED','CANCELLED_SETTLED','CANCELLED_NO_SHOW') then
    raise exception using errcode='P0001',message='BALANCE_COLLECTION_REISSUE_NOT_ALLOWED';
  end if;
  return public.create_balance_collection(p_appointment_id,'ADMIN_REISSUE',p_admin_id);
end;
$$;

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
  v_scope text; v_balance numeric(12,2); v_sequence integer;
  v_collection public.appointment_balance_collections%rowtype;
  v_previous public.appointment_balance_collections%rowtype;
begin
  if p_source not in ('AUTO_START','ADMIN_REISSUE') then raise exception using errcode='22023',message='BALANCE_COLLECTION_SOURCE_INVALID'; end if;
  select * into v_appointment from public.appointments where id=p_appointment_id for update;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if;
  select operation_scope into v_scope from public.services where id=v_appointment.service_id;
  if v_scope<>'BLACKSHEEP' then raise exception using errcode='P0001',message='BALANCE_COLLECTION_SCOPE_DENIED'; end if;
  if v_appointment.status='NO_SHOW' then raise exception using errcode='P0001',message='BALANCE_COLLECTION_NO_SHOW_DENIED'; end if;
  if v_appointment.status not in ('CONFIRMED','COMPLETED') then raise exception using errcode='P0001',message='BALANCE_COLLECTION_APPOINTMENT_NOT_ELIGIBLE'; end if;
  if coalesce(v_appointment.billing_mode_snapshot,'CHECKOUT')='INVOICE' then raise exception using errcode='P0001',message='BALANCE_COLLECTION_INVOICE_DENIED'; end if;
  if p_source='AUTO_START' and v_appointment.start_at>v_now then raise exception using errcode='P0001',message='BALANCE_COLLECTION_NOT_DUE'; end if;
  if p_source='ADMIN_REISSUE' and (p_admin_id is null or not public.service_admin_has_permission(p_admin_id,'FINANCE_MANAGE')) then raise exception using errcode='42501',message='ADMIN_PERMISSION_DENIED'; end if;

  perform public.expire_due_balance_collections();
  select * into v_previous from public.appointment_balance_collections where appointment_id=p_appointment_id order by sequence desc limit 1 for update;
  if p_source='AUTO_START' and found then raise exception using errcode='P0001',message='BALANCE_COLLECTION_ALREADY_CREATED'; end if;
  if p_source='ADMIN_REISSUE' and found and v_previous.status='PENDING' then raise exception using errcode='P0001',message='BALANCE_COLLECTION_STILL_ACTIVE'; end if;
  if p_source='ADMIN_REISSUE' and found and v_previous.status not in ('EXPIRED','CANCELLED_SETTLED','CANCELLED_NO_SHOW') then raise exception using errcode='P0001',message='BALANCE_COLLECTION_REISSUE_NOT_ALLOWED'; end if;

  v_balance:=round(greatest(coalesce((public.get_appointment_financial_summary(p_appointment_id)->>'contract_balance')::numeric,0),0),2);
  if v_balance<=0.005 then raise exception using errcode='P0001',message='BALANCE_COLLECTION_NOT_DUE'; end if;
  select coalesce(max(sequence),0)+1 into v_sequence from public.appointment_balance_collections where appointment_id=p_appointment_id;

  insert into public.appointment_balance_collections(appointment_id,sequence,source,status,amount_snapshot,issued_at,expires_at,created_by_admin_id)
  values(p_appointment_id,v_sequence,p_source,'PENDING',v_balance,v_now,v_now+interval '48 hours',p_admin_id)
  returning * into v_collection;

  insert into public.integration_jobs(job_type,entity_type,entity_id,entity_version,payload_json,idempotency_key)
  values
   ('RENTAL_BALANCE_DUE_EMAIL','BALANCE_COLLECTION',v_collection.id,v_sequence,jsonb_build_object('appointment_id',p_appointment_id,'source',p_source),'rental-balance-email:'||v_collection.id::text),
   ('RENTAL_BALANCE_DUE_KOMMO','BALANCE_COLLECTION',v_collection.id,v_sequence,jsonb_build_object('appointment_id',p_appointment_id,'source',p_source),'rental-balance-kommo:'||v_collection.id::text)
  on conflict(idempotency_key) do nothing;

  insert into public.audit_logs(entity_type,entity_id,action,after_json,origin,admin_user_id)
  values('APPOINTMENT',p_appointment_id,
    case when p_source='AUTO_START' then 'BALANCE_COLLECTION_PENDING' else 'BALANCE_COLLECTION_REISSUED' end,
    jsonb_build_object('collection_id',v_collection.id,'sequence',v_sequence,'amount',v_balance,'expires_at',v_collection.expires_at),
    case when p_source='AUTO_START' then 'SYSTEM' else 'OPERATION' end,p_admin_id);

  return jsonb_build_object('collection_id',v_collection.id,'appointment_id',p_appointment_id,'sequence',v_sequence,'status','PENDING','amount',v_balance,'issued_at',v_collection.issued_at,'expires_at',v_collection.expires_at);
end;
$$;

create or replace function public.service_verify_balance_collection_email(p_collection_id uuid,p_email text)
returns jsonb
language plpgsql
volatile
security definer
set search_path=public,extensions
as $$
declare v_now timestamptz:=public.balance_collection_clock(); v_collection public.appointment_balance_collections%rowtype;
  v_customer_email text; v_raw_token text; v_hash text; v_token_id uuid; v_balance numeric(12,2);
begin
  perform public.expire_due_balance_collections();
  select * into v_collection from public.appointment_balance_collections where id=p_collection_id for update;
  if not found or v_collection.status<>'PENDING' or v_collection.expires_at<=v_now then raise exception using errcode='P0001',message='BALANCE_COLLECTION_INVALID_OR_EXPIRED'; end if;
  select lower(trim(c.email)) into v_customer_email from public.appointments a join public.customers c on c.id=a.primary_customer_id where a.id=v_collection.appointment_id;
  if v_customer_email is null or lower(trim(coalesce(p_email,'')))<>v_customer_email then raise exception using errcode='P0001',message='BALANCE_COLLECTION_VERIFICATION_FAILED'; end if;
  v_balance:=round(greatest(coalesce((public.get_appointment_financial_summary(v_collection.appointment_id)->>'contract_balance')::numeric,0),0),2);
  if v_balance<=0.005 then raise exception using errcode='P0001',message='BALANCE_COLLECTION_ALREADY_PAID'; end if;
  v_raw_token:=encode(gen_random_bytes(32),'hex'); v_hash:=encode(digest(v_raw_token,'sha256'),'hex');
  insert into public.appointment_access_tokens(appointment_id,token_hash,scope,expires_at,delivery_channel,destination_masked,balance_collection_id)
  values(v_collection.appointment_id,v_hash,'PAY',v_collection.expires_at,'INTERNAL','verified-email',v_collection.id)
  returning id into v_token_id;
  return jsonb_build_object('access_token',v_raw_token,'token_id',v_token_id,'appointment_id',v_collection.appointment_id,'collection_id',v_collection.id,'expires_at',v_collection.expires_at,'amount',v_balance);
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
declare v_now timestamptz:=public.balance_collection_clock(); v_collection public.appointment_balance_collections%rowtype; v_target text;
begin
  if p_reason='SETTLED' then v_target:='CANCELLED_SETTLED';
  elsif p_reason='NO_SHOW' then v_target:='CANCELLED_NO_SHOW';
  else raise exception using errcode='22023',message='BALANCE_COLLECTION_CANCEL_REASON_INVALID'; end if;
  select * into v_collection from public.appointment_balance_collections where id=p_collection_id for update;
  if not found then raise exception using errcode='P0001',message='BALANCE_COLLECTION_NOT_FOUND'; end if;
  if v_collection.status<> 'PENDING' then return jsonb_build_object('collection_id',v_collection.id,'status',v_collection.status,'idempotent',true); end if;
  update public.appointment_balance_collections set status=v_target,updated_at=v_now where id=v_collection.id;
  update public.appointment_access_tokens set revoked_at=coalesce(revoked_at,v_now) where balance_collection_id=v_collection.id and revoked_at is null;
  insert into public.audit_logs(entity_type,entity_id,action,after_json,origin,admin_user_id,request_id)
  values('APPOINTMENT',v_collection.appointment_id,
    case when v_target='CANCELLED_SETTLED' then 'BALANCE_COLLECTION_CANCELLED_SETTLED' else 'BALANCE_COLLECTION_CANCELLED_NO_SHOW' end,
    jsonb_build_object('collection_id',v_collection.id,'ip_address',p_ip,'user_agent',p_user_agent),
    case when p_admin_id is null then 'SYSTEM' else 'OPERATION' end,p_admin_id,p_request_id);
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
declare v_before numeric(12,2); v_after numeric(12,2); v_tx uuid; v_collection uuid;
begin
  if not public.service_admin_has_permission(p_admin_id,'FINANCE_MANAGE') then raise exception using errcode='42501',message='ADMIN_PERMISSION_DENIED'; end if;
  if p_amount is null or p_amount<=0 then raise exception using errcode='22023',message='MANUAL_PAYMENT_AMOUNT_INVALID'; end if;
  if upper(coalesce(p_method,'')) not in ('CASH','OTHER') then raise exception using errcode='22023',message='MANUAL_PAYMENT_METHOD_INVALID'; end if;
  if coalesce(btrim(p_ip),'')='' or coalesce(btrim(p_user_agent),'')='' or coalesce(btrim(p_request_id),'')='' then raise exception using errcode='22023',message='AUTHORSHIP_ADMIN_EVIDENCE_REQUIRED'; end if;

  perform 1 from public.appointments where id=p_appointment_id for update;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if;
  v_before:=round(greatest(coalesce((public.get_appointment_financial_summary(p_appointment_id)->>'contract_balance')::numeric,0),0),2);
  if v_before<=0.005 then raise exception using errcode='P0001',message='APPOINTMENT_ALREADY_SETTLED'; end if;
  if p_amount>v_before+0.005 then raise exception using errcode='22023',message='MANUAL_PAYMENT_EXCEEDS_BALANCE'; end if;

  insert into public.payment_transactions(appointment_id,transaction_type,method,provider,status,contract_amount_settled,payment_discount_amount,cash_amount,paid_at,created_by_admin_id,notes,payment_purpose)
  values(p_appointment_id,'CHARGE',upper(p_method),'MANUAL','APPROVED',round(p_amount,2),0,round(p_amount,2),now(),p_admin_id,'Pagamento presencial registrado no painel','CONTRACT')
  returning id into v_tx;
  perform public.refresh_appointment_financial_status(p_appointment_id);
  v_after:=round(greatest(coalesce((public.get_appointment_financial_summary(p_appointment_id)->>'contract_balance')::numeric,0),0),2);
  select id into v_collection from public.appointment_balance_collections where appointment_id=p_appointment_id and status='PENDING' order by sequence desc limit 1;

  insert into public.audit_logs(entity_type,entity_id,action,after_json,origin,admin_user_id,request_id)
  values('APPOINTMENT',p_appointment_id,'MANUAL_CONTRACT_PAYMENT_RECORDED',
    jsonb_build_object('payment_transaction_id',v_tx,'method',upper(p_method),'amount',round(p_amount,2),'balance_before',v_before,'balance_after',v_after,'ip_address',p_ip,'user_agent',p_user_agent),
    'OPERATION',p_admin_id,p_request_id);

  return jsonb_build_object('payment_transaction_id',v_tx,'appointment_id',p_appointment_id,'balance_before',v_before,'amount',round(p_amount,2),'balance_after',v_after,'settled',v_after<=0.005,'active_collection_id',v_collection,'partial_collection_policy_pending',v_after>0.005 and v_collection is not null);
end;
$$;

create or replace function public.service_link_balance_payment_transaction(p_access_token text,p_transaction_id uuid)
returns uuid
language plpgsql
volatile
security definer
set search_path=public,extensions
as $$
declare v_hash text; v_collection uuid; v_appointment uuid;
begin
  v_hash:=encode(digest(p_access_token,'sha256'),'hex');
  select appointment_id,balance_collection_id into v_appointment,v_collection
  from public.appointment_access_tokens
  where token_hash=v_hash and revoked_at is null and consumed_at is null and (expires_at is null or expires_at>now())
  order by created_at desc limit 1;
  if v_collection is null then return null; end if;
  update public.payment_transactions set balance_collection_id=v_collection where id=p_transaction_id and appointment_id=v_appointment;
  return v_collection;
end;
$$;

create or replace view public.appointment_open_balances as
select a.id appointment_id,a.public_code,a.primary_customer_id customer_id,c.name customer_name,a.service_id,a.service_name_snapshot service_name,s.operation_scope,
 a.status appointment_status,a.financial_status,a.billing_mode_snapshot,a.start_at,a.core_end_at,a.commercial_value total_value,
 coalesce((fin.summary->>'contract_settled')::numeric,0)::numeric(12,2) paid_value,
 coalesce((fin.summary->>'contract_balance')::numeric,0)::numeric(12,2) balance_value,
 bc.id active_collection_id,bc.sequence collection_sequence,bc.expires_at collection_expires_at,bc.status collection_status
from public.appointments a join public.services s on s.id=a.service_id left join public.customers c on c.id=a.primary_customer_id
cross join lateral(select public.get_appointment_financial_summary(a.id) summary) fin
left join lateral(select x.id,x.sequence,x.expires_at,x.status from public.appointment_balance_collections x where x.appointment_id=a.id order by x.sequence desc limit 1) bc on true
where a.status in ('CONFIRMED','COMPLETED') and coalesce(a.billing_mode_snapshot,'CHECKOUT')<>'INVOICE'
 and coalesce((fin.summary->>'contract_balance')::numeric,0)>0.005;

create or replace view public.appointment_overdue_balances as
select * from public.appointment_open_balances
where core_end_at<=public.balance_collection_clock() and collection_status='EXPIRED';

revoke all on public.appointment_open_balances from public,anon,authenticated;
revoke all on public.appointment_overdue_balances from public,anon,authenticated;
grant select on public.appointment_open_balances to service_role;
grant select on public.appointment_overdue_balances to service_role;

create or replace function public.enqueue_due_rental_balance_collections()
returns integer language plpgsql volatile security definer set search_path=public as $$
declare v_now timestamptz:=public.balance_collection_clock(); v_row record; v_count integer:=0;
begin
 perform public.expire_due_balance_collections();
 for v_row in
  select a.id from public.appointments a join public.services s on s.id=a.service_id
  cross join lateral(select public.get_appointment_financial_summary(a.id) summary) fin
  where s.operation_scope='BLACKSHEEP' and a.status='CONFIRMED' and coalesce(a.billing_mode_snapshot,'CHECKOUT')<>'INVOICE'
   and a.start_at<=v_now and a.start_at>v_now-interval '24 hours'
   and coalesce((fin.summary->>'contract_balance')::numeric,0)>0.005
   and not exists(select 1 from public.appointment_balance_collections c where c.appointment_id=a.id)
  order by a.start_at,a.id for update of a skip locked
 loop
  begin perform public.create_balance_collection(v_row.id,'AUTO_START',null); v_count:=v_count+1;
  exception when others then if sqlerrm not in ('BALANCE_COLLECTION_ALREADY_CREATED','BALANCE_COLLECTION_NOT_DUE','BALANCE_COLLECTION_NO_SHOW_DENIED') then raise; end if; end;
 end loop;
 return v_count;
end; $$;

create or replace function public.enqueue_no_show_balance_cancellation()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_collection uuid;
begin
 if new.status='NO_SHOW' and old.status is distinct from new.status then
  select id into v_collection from public.appointment_balance_collections where appointment_id=new.id and status='PENDING' order by sequence desc limit 1;
  if v_collection is not null then
   insert into public.integration_jobs(job_type,entity_type,entity_id,entity_version,payload_json,idempotency_key)
   values('RENTAL_BALANCE_CANCEL_NO_SHOW','BALANCE_COLLECTION',v_collection,1,jsonb_build_object('appointment_id',new.id),'rental-balance-no-show:'||v_collection::text)
   on conflict(idempotency_key) do nothing;
  end if;
 end if;
 return new;
end; $$;

drop trigger if exists trg_enqueue_no_show_balance_cancellation on public.appointments;
create trigger trg_enqueue_no_show_balance_cancellation after update of status on public.appointments
for each row execute function public.enqueue_no_show_balance_cancellation();

revoke all on function public.service_mark_balance_collection_cancelled(uuid,text,uuid,text,text,text) from public,anon,authenticated;
revoke all on function public.service_record_manual_contract_payment(uuid,uuid,numeric,text,text,text,text) from public,anon,authenticated;
revoke all on function public.service_link_balance_payment_transaction(text,uuid) from public,anon,authenticated;
grant execute on function public.service_mark_balance_collection_cancelled(uuid,text,uuid,text,text,text) to service_role;
grant execute on function public.service_record_manual_contract_payment(uuid,uuid,numeric,text,text,text,text) to service_role;
grant execute on function public.service_link_balance_payment_transaction(text,uuid) to service_role;
-- END RC MIGRATION 20260824170200_balance_collection_hardening.sql

-- BEGIN RC MIGRATION 20260824170300_balance_payment_protection.sql
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
-- END RC MIGRATION 20260824170300_balance_payment_protection.sql

-- BEGIN RC MIGRATION 20260824170350_balance_payment_completed_appointment.sql
-- A 48h balance collection may still be valid after the appointment transitions
-- from CONFIRMED to COMPLETED. Balance collection payment intents therefore use
-- the collection as the payment authority instead of the checkout status machine.
create or replace function public.service_create_payment_intent_by_token(
  p_access_token text,
  p_payment_kind text,
  p_method text,
  p_request_key text
)
returns jsonb
language plpgsql
security definer
set search_path=public,extensions
as $$
declare
  v_appointment_id uuid;
  v_appointment public.appointments%rowtype;
  v_percentage numeric(5,2);
  v_idempotency_key text;
  v_result jsonb;
  v_transaction_id uuid;
  v_hash text;
  v_collection_id uuid;
  v_collection public.appointment_balance_collections%rowtype;
  v_existing public.payment_transactions%rowtype;
  v_balance numeric(12,2);
  v_discount_percent numeric(5,2);
  v_amounts jsonb;
  v_discount numeric(12,2);
  v_cash_amount numeric(12,2);
begin
  if p_payment_kind not in ('MINIMUM','FULL') then
    raise exception using errcode='P0001',message='INVALID_PAYMENT_KIND';
  end if;
  if p_method not in ('PIX','CARD') then
    raise exception using errcode='P0001',message='PUBLIC_PAYMENT_METHOD_NOT_ALLOWED';
  end if;
  if p_request_key is null or p_request_key !~ '^[A-Za-z0-9_-]{12,100}$' then
    raise exception using errcode='P0001',message='PAYMENT_REQUEST_KEY_INVALID';
  end if;

  v_hash:=encode(digest(p_access_token,'sha256'),'hex');
  select appointment_id,balance_collection_id
    into v_appointment_id,v_collection_id
  from public.appointment_access_tokens
  where token_hash=v_hash
    and revoked_at is null
    and consumed_at is null
    and (expires_at is null or expires_at>now())
  order by created_at desc
  limit 1;

  if v_appointment_id is null then
    v_appointment_id:=public.resolve_appointment_access_token(p_access_token,'PAY');
  else
    perform public.resolve_appointment_access_token(p_access_token,'PAY');
  end if;

  select * into v_appointment from public.appointments where id=v_appointment_id;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if;

  v_idempotency_key:='public:'||v_appointment_id::text||':'||p_request_key;

  if v_collection_id is not null then
    perform public.expire_due_balance_collections();
    select * into v_collection
    from public.appointment_balance_collections
    where id=v_collection_id
    for update;

    if not found or v_collection.status<>'PENDING' or v_collection.expires_at<=public.balance_collection_clock() then
      raise exception using errcode='P0001',message='BALANCE_COLLECTION_INVALID_OR_EXPIRED';
    end if;
    if v_collection.appointment_id<>v_appointment_id then
      raise exception using errcode='P0001',message='BALANCE_COLLECTION_APPOINTMENT_MISMATCH';
    end if;
    if v_appointment.status='NO_SHOW' then
      raise exception using errcode='P0001',message='BALANCE_COLLECTION_NO_SHOW_DENIED';
    end if;
    if v_appointment.status not in ('CONFIRMED','COMPLETED') then
      raise exception using errcode='P0001',message='BALANCE_COLLECTION_APPOINTMENT_NOT_PAYABLE';
    end if;
    if coalesce(v_appointment.billing_mode_snapshot,'CHECKOUT')='INVOICE' then
      raise exception using errcode='P0001',message='BALANCE_COLLECTION_INVOICE_DENIED';
    end if;
    if p_payment_kind<>'FULL' then
      raise exception using errcode='P0001',message='BALANCE_COLLECTION_FULL_PAYMENT_REQUIRED';
    end if;

    select * into v_existing
    from public.payment_transactions
    where idempotency_key=v_idempotency_key;
    if found then
      if v_existing.appointment_id<>v_appointment_id
         or v_existing.method<>p_method
         or v_existing.requested_percentage is distinct from 100::numeric
         or v_existing.balance_collection_id is distinct from v_collection_id then
        raise exception using errcode='P0001',message='IDEMPOTENCY_KEY_CONFLICT';
      end if;
      return jsonb_build_object(
        'transaction_id',v_existing.id,
        'appointment_id',v_existing.appointment_id,
        'status',v_existing.status,
        'payment_kind','FULL_BALANCE',
        'payment_percentage',v_existing.requested_percentage,
        'contract_amount_settled',v_existing.contract_amount_settled,
        'payment_discount_amount',v_existing.payment_discount_amount,
        'cash_amount',v_existing.cash_amount,
        'method',v_existing.method,
        'provider',v_existing.provider,
        'balance_collection_id',v_collection_id,
        'idempotent_replay',true
      );
    end if;

    perform 1 from public.appointments where id=v_appointment_id for update;
    v_balance:=round(greatest(coalesce((public.get_appointment_financial_summary(v_appointment_id)->>'contract_balance')::numeric,0),0),2);
    if v_balance<=0.005 then
      raise exception using errcode='P0001',message='APPOINTMENT_ALREADY_PAID';
    end if;

    select coalesce(os.pix_discount_percent,0)
      into v_discount_percent
    from public.operation_settings os
    where os.id=1;
    if v_discount_percent is null then
      raise exception using errcode='P0001',message='PAYMENT_SETTINGS_LOAD_FAILED';
    end if;

    v_amounts:=public.service_calculate_payment_cash_amount(v_balance,p_method,v_discount_percent);
    v_discount:=(v_amounts->>'payment_discount_amount')::numeric;
    v_cash_amount:=(v_amounts->>'cash_amount')::numeric;

    insert into public.payment_transactions(
      appointment_id,transaction_type,method,provider,status,
      contract_amount_settled,payment_discount_amount,cash_amount,
      idempotency_key,requested_percentage,payment_purpose,balance_collection_id
    ) values(
      v_appointment_id,'CHARGE',p_method,'MERCADO_PAGO','PENDING',
      v_balance,v_discount,v_cash_amount,
      v_idempotency_key,100,'CONTRACT',v_collection_id
    ) returning id into v_transaction_id;

    return jsonb_build_object(
      'transaction_id',v_transaction_id,
      'appointment_id',v_appointment_id,
      'status','PENDING',
      'payment_kind','FULL_BALANCE',
      'payment_percentage',100,
      'contract_balance_before',v_balance,
      'contract_amount_settled',v_balance,
      'payment_discount_amount',v_discount,
      'cash_amount',v_cash_amount,
      'method',p_method,
      'provider','MERCADO_PAGO',
      'balance_collection_id',v_collection_id,
      'idempotent_replay',false
    );
  end if;

  if p_payment_kind='FULL' then
    v_percentage:=100;
  else
    v_percentage:=v_appointment.confirmation_percentage_snapshot;
    if v_percentage is null then
      raise exception using errcode='P0001',message='APPOINTMENT_CONFIRMATION_SNAPSHOT_MISSING';
    end if;
  end if;

  v_result:=public.create_payment_intent(v_appointment_id,v_percentage,p_method,v_idempotency_key);
  return v_result||jsonb_build_object('balance_collection_id',null);
end;
$$;

revoke all on function public.service_create_payment_intent_by_token(text,text,text,text) from public,anon,authenticated;
grant execute on function public.service_create_payment_intent_by_token(text,text,text,text) to service_role;
-- END RC MIGRATION 20260824170350_balance_payment_completed_appointment.sql

-- BEGIN RC MIGRATION 20260824170400_balance_expiry_provider_cleanup.sql
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
-- END RC MIGRATION 20260824170400_balance_expiry_provider_cleanup.sql

-- BEGIN RC MIGRATION 20260824170500_balance_collection_commercial_policy.sql
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
-- END RC MIGRATION 20260824170500_balance_collection_commercial_policy.sql

-- BEGIN RC MIGRATION 20260824170510_no_show_balance_payment.sql
-- NO_SHOW is a performed BlackSheep rental, so a valid 48h balance collection remains payable.
create or replace function public.service_create_payment_intent_by_token(
  p_access_token text,
  p_payment_kind text,
  p_method text,
  p_request_key text
)
returns jsonb
language plpgsql
security definer
set search_path=public,extensions
as $$
declare
  v_appointment_id uuid;
  v_appointment public.appointments%rowtype;
  v_percentage numeric(5,2);
  v_idempotency_key text;
  v_result jsonb;
  v_transaction_id uuid;
  v_hash text;
  v_collection_id uuid;
  v_collection public.appointment_balance_collections%rowtype;
  v_existing public.payment_transactions%rowtype;
  v_balance numeric(12,2);
  v_discount_percent numeric(5,2);
  v_amounts jsonb;
  v_discount numeric(12,2);
  v_cash_amount numeric(12,2);
begin
  if p_payment_kind not in ('MINIMUM','FULL') then
    raise exception using errcode='P0001',message='INVALID_PAYMENT_KIND';
  end if;
  if p_method not in ('PIX','CARD') then
    raise exception using errcode='P0001',message='PUBLIC_PAYMENT_METHOD_NOT_ALLOWED';
  end if;
  if p_request_key is null or p_request_key !~ '^[A-Za-z0-9_-]{12,100}$' then
    raise exception using errcode='P0001',message='PAYMENT_REQUEST_KEY_INVALID';
  end if;

  v_hash:=encode(digest(p_access_token,'sha256'),'hex');
  select appointment_id,balance_collection_id
    into v_appointment_id,v_collection_id
  from public.appointment_access_tokens
  where token_hash=v_hash
    and revoked_at is null
    and consumed_at is null
    and (expires_at is null or expires_at>now())
  order by created_at desc limit 1;

  if v_appointment_id is null then
    v_appointment_id:=public.resolve_appointment_access_token(p_access_token,'PAY');
  else
    perform public.resolve_appointment_access_token(p_access_token,'PAY');
  end if;

  select * into v_appointment from public.appointments where id=v_appointment_id;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if;
  v_idempotency_key:='public:'||v_appointment_id::text||':'||p_request_key;

  if v_collection_id is not null then
    perform public.expire_due_balance_collections();
    select * into v_collection
    from public.appointment_balance_collections
    where id=v_collection_id
    for update;

    if not found or v_collection.status<>'PENDING' or v_collection.expires_at<=public.balance_collection_clock() then
      raise exception using errcode='P0001',message='BALANCE_COLLECTION_INVALID_OR_EXPIRED';
    end if;
    if v_collection.appointment_id<>v_appointment_id then
      raise exception using errcode='P0001',message='BALANCE_COLLECTION_APPOINTMENT_MISMATCH';
    end if;
    if v_appointment.status not in ('CONFIRMED','COMPLETED','NO_SHOW') then
      raise exception using errcode='P0001',message='BALANCE_COLLECTION_APPOINTMENT_NOT_PAYABLE';
    end if;
    if coalesce(v_appointment.billing_mode_snapshot,'CHECKOUT')='INVOICE' then
      raise exception using errcode='P0001',message='BALANCE_COLLECTION_INVOICE_DENIED';
    end if;
    if p_payment_kind<>'FULL' then
      raise exception using errcode='P0001',message='BALANCE_COLLECTION_FULL_PAYMENT_REQUIRED';
    end if;

    select * into v_existing
    from public.payment_transactions
    where idempotency_key=v_idempotency_key;
    if found then
      if v_existing.appointment_id<>v_appointment_id
         or v_existing.method<>p_method
         or v_existing.requested_percentage is distinct from 100::numeric
         or v_existing.balance_collection_id is distinct from v_collection_id then
        raise exception using errcode='P0001',message='IDEMPOTENCY_KEY_CONFLICT';
      end if;
      return jsonb_build_object(
        'transaction_id',v_existing.id,'appointment_id',v_existing.appointment_id,'status',v_existing.status,
        'payment_kind','FULL_BALANCE','payment_percentage',v_existing.requested_percentage,
        'contract_amount_settled',v_existing.contract_amount_settled,
        'payment_discount_amount',v_existing.payment_discount_amount,'cash_amount',v_existing.cash_amount,
        'method',v_existing.method,'provider',v_existing.provider,'balance_collection_id',v_collection_id,'idempotent_replay',true
      );
    end if;

    perform 1 from public.appointments where id=v_appointment_id for update;
    v_balance:=round(greatest(coalesce((public.get_appointment_financial_summary(v_appointment_id)->>'contract_balance')::numeric,0),0),2);
    if v_balance<=0.005 then raise exception using errcode='P0001',message='APPOINTMENT_ALREADY_PAID'; end if;

    select coalesce(os.pix_discount_percent,0) into v_discount_percent
    from public.operation_settings os where os.id=1;
    if v_discount_percent is null then raise exception using errcode='P0001',message='PAYMENT_SETTINGS_LOAD_FAILED'; end if;

    v_amounts:=public.service_calculate_payment_cash_amount(v_balance,p_method,v_discount_percent);
    v_discount:=(v_amounts->>'payment_discount_amount')::numeric;
    v_cash_amount:=(v_amounts->>'cash_amount')::numeric;

    insert into public.payment_transactions(
      appointment_id,transaction_type,method,provider,status,contract_amount_settled,payment_discount_amount,cash_amount,
      idempotency_key,requested_percentage,payment_purpose,balance_collection_id
    ) values(
      v_appointment_id,'CHARGE',p_method,'MERCADO_PAGO','PENDING',v_balance,v_discount,v_cash_amount,
      v_idempotency_key,100,'CONTRACT',v_collection_id
    ) returning id into v_transaction_id;

    return jsonb_build_object(
      'transaction_id',v_transaction_id,'appointment_id',v_appointment_id,'status','PENDING',
      'payment_kind','FULL_BALANCE','payment_percentage',100,'contract_balance_before',v_balance,
      'contract_amount_settled',v_balance,'payment_discount_amount',v_discount,'cash_amount',v_cash_amount,
      'method',p_method,'provider','MERCADO_PAGO','balance_collection_id',v_collection_id,'idempotent_replay',false
    );
  end if;

  if p_payment_kind='FULL' then
    v_percentage:=100;
  else
    v_percentage:=v_appointment.confirmation_percentage_snapshot;
    if v_percentage is null then raise exception using errcode='P0001',message='APPOINTMENT_CONFIRMATION_SNAPSHOT_MISSING'; end if;
  end if;

  v_result:=public.create_payment_intent(v_appointment_id,v_percentage,p_method,v_idempotency_key);
  return v_result||jsonb_build_object('balance_collection_id',null);
end;
$$;

revoke all on function public.service_create_payment_intent_by_token(text,text,text,text) from public,anon,authenticated;
grant execute on function public.service_create_payment_intent_by_token(text,text,text,text) to service_role;
-- END RC MIGRATION 20260824170510_no_show_balance_payment.sql

-- BEGIN RC MIGRATION 20260824171045_hold_capacity_expiry_consistency.sql
-- Keep public availability and authoritative hold creation consistent.
-- Availability intentionally stops hiding expired AWAITING_PAYMENT allocations before
-- periodic cleanup. Hold creation must therefore expire those allocations before the
-- exclusion constraint attempts to protect the newly selected slot.

create or replace function public.public_create_checkout_hold(
  p_booking_page_slug text,
  p_service_id uuid,
  p_service_employee_id uuid,
  p_extra_selections jsonb,
  p_people_count integer,
  p_requested_start_at timestamptz
) returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_page_id uuid;
  v_result jsonb;
  v_hold_id uuid;
begin
  perform public.expire_due_appointment_holds();

  perform public.assert_public_booking_selection(
    p_booking_page_slug,
    p_service_id,
    p_service_employee_id,
    p_extra_selections,
    p_people_count
  );

  select id into v_page_id
  from public.booking_pages
  where slug=lower(btrim(p_booking_page_slug))
    and is_active;

  v_result := public.create_checkout_hold(
    p_service_id,
    p_service_employee_id,
    p_extra_selections,
    p_people_count,
    p_requested_start_at
  );

  v_hold_id := (v_result->>'checkout_hold_id')::uuid;

  update public.checkout_holds
  set booking_page_id=v_page_id,
      updated_at=now()
  where id=v_hold_id;

  return v_result || jsonb_build_object('booking_page_slug',lower(btrim(p_booking_page_slug)));
end;
$$;

create or replace function public.public_create_checkout_hold_duration(
  p_booking_page_slug text,
  p_service_id uuid,
  p_service_employee_id uuid,
  p_duration_blocks integer,
  p_extra_selections jsonb,
  p_people_count integer,
  p_requested_start_at timestamptz
) returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_page_id uuid;
  v_result jsonb;
  v_hold_id uuid;
begin
  perform public.expire_due_appointment_holds();

  perform public.assert_public_booking_duration(
    p_booking_page_slug,
    p_service_id,
    p_service_employee_id,
    p_duration_blocks,
    p_extra_selections,
    p_people_count
  );

  select id into v_page_id
  from public.booking_pages
  where slug=lower(btrim(p_booking_page_slug))
    and is_active;

  if v_page_id is null then
    raise exception using errcode='P0001',message='BOOKING_PAGE_NOT_AVAILABLE';
  end if;

  v_result := public.create_checkout_hold_for_duration(
    p_service_id,
    p_service_employee_id,
    p_duration_blocks,
    p_extra_selections,
    p_people_count,
    p_requested_start_at
  );

  v_hold_id := (v_result->>'checkout_hold_id')::uuid;

  update public.checkout_holds
  set booking_page_id=v_page_id,
      updated_at=now()
  where id=v_hold_id;

  if not found then
    raise exception using errcode='P0001',message='CHECKOUT_HOLD_NOT_FOUND';
  end if;

  return v_result || jsonb_build_object(
    'booking_page_slug',lower(btrim(p_booking_page_slug))
  );
end;
$$;
-- END RC MIGRATION 20260824171045_hold_capacity_expiry_consistency.sql

-- BEGIN RC MIGRATION 20260824171124_hold_capacity_expiry_consistency_verification_marker.sql
do $$ begin if position('expire_due_appointment_holds' in pg_get_functiondef('public.public_create_checkout_hold(text,uuid,uuid,jsonb,integer,timestamptz)'::regprocedure)) = 0 then raise exception 'HOLD_CAPACITY_FIX_NOT_ACTIVE'; end if; end $$;
-- END RC MIGRATION 20260824171124_hold_capacity_expiry_consistency_verification_marker.sql

-- BEGIN RC MIGRATION 20260824180000_customer_access_controls.sql
-- Customer access controls: append-only restrictions/blocking and free-visit policy.

alter table public.services add column if not exists booking_product_type text not null default 'STANDARD';
alter table public.services drop constraint if exists services_booking_product_type_check;
alter table public.services add constraint services_booking_product_type_check check (booking_product_type in ('STANDARD','FREE_VISIT'));

alter table public.appointments add column if not exists free_visit_confirmed_at timestamptz;
alter table public.appointments add column if not exists free_visit_confirmation_deadline timestamptz;

create table if not exists public.customer_access_policy_settings (
  id smallint primary key default 1 check (id=1),
  max_active_free_visits integer not null default 1 check (max_active_free_visits>=1),
  free_visit_confirmation_hours_before integer not null default 24 check (free_visit_confirmation_hours_before between 1 and 168),
  free_visit_no_show_threshold integer not null default 1 check (free_visit_no_show_threshold>=1),
  history_retention_years integer not null default 5 check (history_retention_years between 1 and 20),
  auto_no_free_visits boolean not null default true,
  updated_at timestamptz not null default now()
);
insert into public.customer_access_policy_settings(id) values(1) on conflict(id) do nothing;

create table if not exists public.customer_identity_keys (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customers(id) on delete restrict,
  key_type text not null check (key_type in ('TAX_ID','PHONE','EMAIL')),
  normalized_value text not null,
  first_seen_at timestamptz not null default now(),
  unique(customer_id,key_type,normalized_value)
);
create index if not exists customer_identity_keys_lookup_idx on public.customer_identity_keys(key_type,normalized_value);

create table if not exists public.customer_access_events (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customers(id) on delete restrict,
  event_type text not null check (event_type in ('RESTRICTION_APPLIED','RESTRICTION_REMOVED','RESTRICTION_EXPIRED','BLOCK_APPLIED','BLOCK_REMOVED','BLOCKED_BOOKING_ATTEMPT','IDENTITY_REVIEW_REQUIRED','SECOND_NO_SHOW_ALERT')),
  restriction_type text check (restriction_type is null or restriction_type in ('REQUIRE_FULL_PAYMENT','NO_FREE_VISITS','NO_ONLINE_BOOKING')),
  subject_event_id uuid references public.customer_access_events(id) on delete restrict,
  reason_text text,
  related_appointment_ids uuid[] not null default '{}',
  effective_from timestamptz,
  effective_until timestamptz,
  communicated_at timestamptz,
  actor_admin_id uuid references public.admin_users(id) on delete restrict,
  automated boolean not null default false,
  permission_used text,
  used_key_type text,
  used_key_value text,
  ip_address inet,
  user_agent text,
  request_id uuid,
  created_at timestamptz not null default now(),
  check (event_type not in ('BLOCK_APPLIED','BLOCK_REMOVED') or length(btrim(coalesce(reason_text,'')))>=10),
  check (event_type not like 'RESTRICTION_%' or restriction_type is not null)
);
create index if not exists customer_access_events_customer_idx on public.customer_access_events(customer_id,created_at desc);
create index if not exists customer_access_events_subject_idx on public.customer_access_events(subject_event_id) where subject_event_id is not null;

alter table public.customer_identity_keys enable row level security;
alter table public.customer_access_events enable row level security;
alter table public.customer_access_policy_settings enable row level security;
revoke all on public.customer_identity_keys,public.customer_access_events,public.customer_access_policy_settings from public,anon,authenticated;
grant select,insert on public.customer_identity_keys,public.customer_access_events to service_role;
grant select on public.customer_access_policy_settings to service_role;

create or replace function public.guard_customer_access_append_only() returns trigger language plpgsql set search_path=public as $$
begin raise exception using errcode='42501',message='CUSTOMER_ACCESS_HISTORY_APPEND_ONLY'; end; $$;
drop trigger if exists customer_access_events_append_only on public.customer_access_events;
create trigger customer_access_events_append_only before update or delete on public.customer_access_events for each statement execute function public.guard_customer_access_append_only();
drop trigger if exists customer_identity_keys_append_only on public.customer_identity_keys;
create trigger customer_identity_keys_append_only before update or delete on public.customer_identity_keys for each statement execute function public.guard_customer_access_append_only();
revoke all on function public.guard_customer_access_append_only() from public,anon,authenticated;

create or replace function public.capture_customer_identity_keys(p_customer_id uuid) returns void language plpgsql security definer set search_path=public as $$
declare c public.customers%rowtype;
begin
 select * into c from public.customers where id=p_customer_id;
 if not found then return; end if;
 if nullif(regexp_replace(coalesce(c.cpf_cnpj,''),'\D','','g'),'') is not null then insert into public.customer_identity_keys(customer_id,key_type,normalized_value) values(c.id,'TAX_ID',regexp_replace(c.cpf_cnpj,'\D','','g')) on conflict do nothing; end if;
 if nullif(regexp_replace(coalesce(c.phone,''),'\D','','g'),'') is not null then insert into public.customer_identity_keys(customer_id,key_type,normalized_value) values(c.id,'PHONE',regexp_replace(c.phone,'\D','','g')) on conflict do nothing; end if;
 if nullif(lower(btrim(coalesce(c.email,''))),'') is not null then insert into public.customer_identity_keys(customer_id,key_type,normalized_value) values(c.id,'EMAIL',lower(btrim(c.email))) on conflict do nothing; end if;
end; $$;

create or replace function public.customers_capture_identity_keys_trigger() returns trigger language plpgsql security definer set search_path=public as $$ begin perform public.capture_customer_identity_keys(new.id); return new; end; $$;
drop trigger if exists customers_capture_identity_keys on public.customers;
create trigger customers_capture_identity_keys after insert or update of cpf_cnpj,phone,email on public.customers for each row execute function public.customers_capture_identity_keys_trigger();

insert into public.customer_identity_keys(customer_id,key_type,normalized_value)
select id,'TAX_ID',regexp_replace(cpf_cnpj,'\D','','g') from public.customers where nullif(regexp_replace(coalesce(cpf_cnpj,''),'\D','','g'),'') is not null on conflict do nothing;
insert into public.customer_identity_keys(customer_id,key_type,normalized_value)
select id,'PHONE',regexp_replace(phone,'\D','','g') from public.customers where nullif(regexp_replace(coalesce(phone,''),'\D','','g'),'') is not null on conflict do nothing;
insert into public.customer_identity_keys(customer_id,key_type,normalized_value)
select id,'EMAIL',lower(btrim(email)) from public.customers where nullif(lower(btrim(coalesce(email,''))),'') is not null on conflict do nothing;

create or replace view public.customer_effective_access as
with applies as (
 select e.*,
   exists(select 1 from public.customer_access_events x where x.subject_event_id=e.id and x.event_type in ('RESTRICTION_REMOVED','RESTRICTION_EXPIRED','BLOCK_REMOVED')) as ended
 from public.customer_access_events e
 where e.event_type in ('RESTRICTION_APPLIED','BLOCK_APPLIED')
)
select customer_id,
 bool_or(event_type='BLOCK_APPLIED' and not ended) as online_blocked,
 bool_or(event_type='RESTRICTION_APPLIED' and restriction_type='REQUIRE_FULL_PAYMENT' and not ended and (effective_until is null or effective_until>now())) as require_full_payment,
 bool_or(event_type='RESTRICTION_APPLIED' and restriction_type='NO_FREE_VISITS' and not ended and (effective_until is null or effective_until>now())) as no_free_visits,
 bool_or(event_type='RESTRICTION_APPLIED' and restriction_type='NO_ONLINE_BOOKING' and not ended and (effective_until is null or effective_until>now())) as no_online_booking
from applies group by customer_id;

create or replace view public.customer_behavior_summary as
select c.id as customer_id,
 count(a.id)::integer as total_reservations,
 count(*) filter(where a.status='COMPLETED')::integer as attendances,
 count(*) filter(where a.status='NO_SHOW')::integer as no_shows,
 count(*) filter(where a.status='CANCELLED' and a.cancelled_at is not null and a.cancelled_at<=a.start_at-interval '48 hours')::integer as cancellations_over_48h,
 count(*) filter(where a.status='CANCELLED' and a.cancelled_at is not null and a.cancelled_at>a.start_at-interval '48 hours')::integer as cancellations_under_48h,
 coalesce((select count(*) from public.appointment_policy_actions pa join public.appointments aa on aa.id=pa.appointment_id where aa.primary_customer_id=c.id and pa.action_type='RESCHEDULE'),0)::integer as reschedules_requested,
 count(*) filter(where s.booking_product_type='FREE_VISIT')::integer as free_visits_scheduled,
 count(*) filter(where s.booking_product_type='FREE_VISIT' and a.status='COMPLETED')::integer as free_visits_attended,
 coalesce(sum(a.commercial_value),0)::numeric(14,2) as total_contract_value
from public.customers c
left join public.appointments a on a.primary_customer_id=c.id and a.deleted_at is null
left join public.services s on s.id=a.service_id
group by c.id;

revoke all on public.customer_effective_access,public.customer_behavior_summary from public,anon,authenticated;
grant select on public.customer_effective_access,public.customer_behavior_summary to service_role;

create or replace function public.expire_customer_restrictions() returns integer language plpgsql volatile security definer set search_path=public as $$
declare r record; n integer:=0;
begin
 for r in select e.* from public.customer_access_events e where e.event_type='RESTRICTION_APPLIED' and e.effective_until is not null and e.effective_until<=now() and not exists(select 1 from public.customer_access_events x where x.subject_event_id=e.id and x.event_type in ('RESTRICTION_REMOVED','RESTRICTION_EXPIRED')) loop
  insert into public.customer_access_events(customer_id,event_type,restriction_type,subject_event_id,reason_text,automated,permission_used) values(r.customer_id,'RESTRICTION_EXPIRED',r.restriction_type,r.id,'Restrição expirada conforme prazo configurado.',true,'SYSTEM'); n:=n+1;
 end loop; return n;
end; $$;

create or replace function public.service_apply_customer_restriction(p_customer_id uuid,p_type text,p_reason text,p_admin_id uuid,p_until timestamptz default null,p_related uuid[] default '{}') returns uuid language plpgsql volatile security definer set search_path=public as $$
declare v_id uuid;
begin
 if not public.service_admin_has_permission(p_admin_id,'CUSTOMERS_MANAGE') then raise exception using errcode='42501',message='ADMIN_PERMISSION_DENIED'; end if;
 if p_type not in ('REQUIRE_FULL_PAYMENT','NO_FREE_VISITS','NO_ONLINE_BOOKING') then raise exception using errcode='22023',message='CUSTOMER_RESTRICTION_TYPE_INVALID'; end if;
 if length(btrim(coalesce(p_reason,'')))<10 then raise exception using errcode='22023',message='CUSTOMER_RESTRICTION_REASON_REQUIRED'; end if;
 perform public.capture_customer_identity_keys(p_customer_id);
 insert into public.customer_access_events(customer_id,event_type,restriction_type,reason_text,related_appointment_ids,effective_from,effective_until,actor_admin_id,permission_used) values(p_customer_id,'RESTRICTION_APPLIED',p_type,btrim(p_reason),coalesce(p_related,'{}'),now(),p_until,p_admin_id,'CUSTOMERS_MANAGE') returning id into v_id; return v_id;
end; $$;

create or replace function public.service_remove_customer_restriction(p_event_id uuid,p_reason text,p_admin_id uuid) returns uuid language plpgsql volatile security definer set search_path=public as $$
declare r public.customer_access_events%rowtype; v_id uuid;
begin
 if not public.service_admin_has_permission(p_admin_id,'CUSTOMERS_MANAGE') then raise exception using errcode='42501',message='ADMIN_PERMISSION_DENIED'; end if;
 if length(btrim(coalesce(p_reason,'')))<10 then raise exception using errcode='22023',message='CUSTOMER_RESTRICTION_REASON_REQUIRED'; end if;
 select * into r from public.customer_access_events where id=p_event_id and event_type='RESTRICTION_APPLIED'; if not found then raise exception using errcode='P0001',message='CUSTOMER_RESTRICTION_NOT_FOUND'; end if;
 insert into public.customer_access_events(customer_id,event_type,restriction_type,subject_event_id,reason_text,actor_admin_id,permission_used) values(r.customer_id,'RESTRICTION_REMOVED',r.restriction_type,r.id,btrim(p_reason),p_admin_id,'CUSTOMERS_MANAGE') returning id into v_id; return v_id;
end; $$;

create or replace function public.service_set_customer_block(p_customer_id uuid,p_block boolean,p_reason text,p_admin_id uuid,p_related uuid[] default '{}',p_communicated_at timestamptz default null) returns uuid language plpgsql volatile security definer set search_path=public as $$
declare v_id uuid; r public.customer_access_events%rowtype;
begin
 if not public.service_admin_has_permission(p_admin_id,'CUSTOMERS_MANAGE') then raise exception using errcode='42501',message='ADMIN_PERMISSION_DENIED'; end if;
 if length(btrim(coalesce(p_reason,'')))<10 then raise exception using errcode='22023',message='CUSTOMER_BLOCK_REASON_REQUIRED'; end if;
 perform public.capture_customer_identity_keys(p_customer_id);
 if p_block then
  insert into public.customer_access_events(customer_id,event_type,reason_text,related_appointment_ids,effective_from,communicated_at,actor_admin_id,permission_used) values(p_customer_id,'BLOCK_APPLIED',btrim(p_reason),coalesce(p_related,'{}'),now(),p_communicated_at,p_admin_id,'CUSTOMERS_MANAGE') returning id into v_id;
 else
  select * into r from public.customer_access_events e where e.customer_id=p_customer_id and e.event_type='BLOCK_APPLIED' and not exists(select 1 from public.customer_access_events x where x.subject_event_id=e.id and x.event_type='BLOCK_REMOVED') order by e.created_at desc limit 1;
  if not found then raise exception using errcode='P0001',message='CUSTOMER_BLOCK_NOT_FOUND'; end if;
  insert into public.customer_access_events(customer_id,event_type,subject_event_id,reason_text,actor_admin_id,permission_used) values(p_customer_id,'BLOCK_REMOVED',r.id,btrim(p_reason),p_admin_id,'CUSTOMERS_MANAGE') returning id into v_id;
 end if; return v_id;
end; $$;

create or replace function public.service_public_check_customer_access(p_checkout_hold_token text,p_ip inet,p_user_agent text,p_request_id uuid) returns jsonb language plpgsql volatile security definer set search_path=public,extensions as $$
declare h public.checkout_holds%rowtype; a record; s public.services%rowtype; n integer; other uuid;
begin
 perform public.expire_customer_restrictions();
 select * into h from public.checkout_holds where public_token_hash=encode(digest(p_checkout_hold_token,'sha256'),'hex') and status='ACTIVE' and expires_at>now();
 if not found or h.primary_customer_id is null then raise exception using errcode='P0001',message='CHECKOUT_CUSTOMER_REQUIRED'; end if;
 select * into s from public.services where id=h.service_id;
 select * into a from public.customer_effective_access where customer_id=h.primary_customer_id;
 if coalesce(a.online_blocked,false) or coalesce(a.no_online_booking,false) then
  insert into public.customer_access_events(customer_id,event_type,reason_text,automated,permission_used,ip_address,user_agent,request_id) values(h.primary_customer_id,'BLOCKED_BOOKING_ATTEMPT','Tentativa de reserva online recusada por controle de acesso ativo.',true,'SYSTEM',p_ip,left(p_user_agent,1000),p_request_id);
  raise exception using errcode='P0001',message='ONLINE_BOOKING_NOT_AVAILABLE';
 end if;
 if s.booking_product_type='FREE_VISIT' and coalesce(a.no_free_visits,false) then raise exception using errcode='P0001',message='FREE_VISIT_NOT_AVAILABLE'; end if;
 if s.booking_product_type='FREE_VISIT' then
  select count(*)::integer into n from public.appointments ap join public.services ss on ss.id=ap.service_id where ap.primary_customer_id=h.primary_customer_id and ss.booking_product_type='FREE_VISIT' and ap.status in ('AWAITING_PAYMENT','CONFIRMED') and ap.start_at>=now();
  if n>=1 then raise exception using errcode='P0001',message='FREE_VISIT_ACTIVE_LIMIT_REACHED'; end if;
 end if;
 for other in select distinct k2.customer_id from public.customer_identity_keys k1 join public.customer_identity_keys k2 on k2.key_type=k1.key_type and k2.normalized_value=k1.normalized_value and k2.customer_id<>k1.customer_id join public.customer_effective_access ea on ea.customer_id=k2.customer_id and ea.online_blocked where k1.customer_id=h.primary_customer_id loop
  insert into public.customer_access_events(customer_id,event_type,reason_text,automated,permission_used,ip_address,user_agent,request_id) values(h.primary_customer_id,'IDENTITY_REVIEW_REQUIRED','Chave de identidade coincide com outro cadastro bloqueado; revisão administrativa necessária.',true,'SYSTEM',p_ip,left(p_user_agent,1000),p_request_id);
 end loop;
 return jsonb_build_object('allowed',true,'require_full_payment',coalesce(a.require_full_payment,false),'free_visit',s.booking_product_type='FREE_VISIT');
end; $$;

create or replace function public.customer_access_appointment_before_insert() returns trigger language plpgsql security definer set search_path=public as $$
declare a record; s public.services%rowtype; cfg public.customer_access_policy_settings%rowtype;
begin
 if new.origin<>'PUBLIC' or new.primary_customer_id is null then return new; end if;
 select * into a from public.customer_effective_access where customer_id=new.primary_customer_id;
 if coalesce(a.online_blocked,false) or coalesce(a.no_online_booking,false) then raise exception using errcode='P0001',message='ONLINE_BOOKING_NOT_AVAILABLE'; end if;
 if coalesce(a.require_full_payment,false) then new.confirmation_percentage_snapshot:=100; end if;
 select * into s from public.services where id=new.service_id;
 if s.booking_product_type='FREE_VISIT' then
  if coalesce(a.no_free_visits,false) then raise exception using errcode='P0001',message='FREE_VISIT_NOT_AVAILABLE'; end if;
  select * into cfg from public.customer_access_policy_settings where id=1;
  new.free_visit_confirmation_deadline:=new.start_at-make_interval(hours=>cfg.free_visit_confirmation_hours_before);
 end if;
 return new;
end; $$;
drop trigger if exists customer_access_appointment_before_insert on public.appointments;
create trigger customer_access_appointment_before_insert before insert on public.appointments for each row execute function public.customer_access_appointment_before_insert();

create or replace function public.customer_access_no_show_after_update() returns trigger language plpgsql security definer set search_path=public as $$
declare s public.services%rowtype; cfg public.customer_access_policy_settings%rowtype; n integer;
begin
 if new.status='NO_SHOW' and old.status is distinct from 'NO_SHOW' and new.primary_customer_id is not null then
  select * into s from public.services where id=new.service_id;
  select count(*)::integer into n from public.appointments where primary_customer_id=new.primary_customer_id and status='NO_SHOW';
  if n=2 then insert into public.customer_access_events(customer_id,event_type,reason_text,related_appointment_ids,automated,permission_used) values(new.primary_customer_id,'SECOND_NO_SHOW_ALERT','Cliente atingiu o segundo não comparecimento.',array[new.id],true,'SYSTEM'); end if;
  if s.booking_product_type='FREE_VISIT' then
   select * into cfg from public.customer_access_policy_settings where id=1;
   select count(*)::integer into n from public.appointments ap join public.services ss on ss.id=ap.service_id where ap.primary_customer_id=new.primary_customer_id and ap.status='NO_SHOW' and ss.booking_product_type='FREE_VISIT';
   if cfg.auto_no_free_visits and n>=cfg.free_visit_no_show_threshold and not exists(select 1 from public.customer_effective_access ea where ea.customer_id=new.primary_customer_id and ea.no_free_visits) then
    insert into public.customer_access_events(customer_id,event_type,restriction_type,reason_text,related_appointment_ids,effective_from,automated,permission_used) values(new.primary_customer_id,'RESTRICTION_APPLIED','NO_FREE_VISITS','Restrição automática após não comparecimento em visita gratuita.',array[new.id],now(),true,'SYSTEM');
   end if;
  end if;
 end if; return new;
end; $$;
drop trigger if exists customer_access_no_show_after_update on public.appointments;
create trigger customer_access_no_show_after_update after update of status on public.appointments for each row execute function public.customer_access_no_show_after_update();

create or replace function public.expire_unconfirmed_free_visits() returns integer language plpgsql volatile security definer set search_path=public as $$
declare r record; n integer:=0;
begin
 for r in select a.id from public.appointments a join public.services s on s.id=a.service_id where s.booking_product_type='FREE_VISIT' and a.status='CONFIRMED' and a.free_visit_confirmed_at is null and a.free_visit_confirmation_deadline is not null and a.free_visit_confirmation_deadline<=now() for update of a loop
  update public.appointments set status='CANCELLED',cancelled_at=now(),cancel_reason='FREE_VISIT_CONFIRMATION_MISSING',updated_at=now() where id=r.id;
  update public.resource_allocations set status='CANCELLED',updated_at=now() where appointment_id=r.id and status='ACTIVE'; n:=n+1;
 end loop; return n;
end; $$;

revoke all on function public.capture_customer_identity_keys(uuid),public.expire_customer_restrictions(),public.service_apply_customer_restriction(uuid,text,text,uuid,timestamptz,uuid[]),public.service_remove_customer_restriction(uuid,text,uuid),public.service_set_customer_block(uuid,boolean,text,uuid,uuid[],timestamptz),public.service_public_check_customer_access(text,inet,text,uuid),public.expire_unconfirmed_free_visits() from public,anon,authenticated;
grant execute on function public.capture_customer_identity_keys(uuid),public.expire_customer_restrictions(),public.service_apply_customer_restriction(uuid,text,text,uuid,timestamptz,uuid[]),public.service_remove_customer_restriction(uuid,text,uuid),public.service_set_customer_block(uuid,boolean,text,uuid,uuid[],timestamptz),public.service_public_check_customer_access(text,inet,text,uuid),public.expire_unconfirmed_free_visits() to service_role;
-- END RC MIGRATION 20260824180000_customer_access_controls.sql

-- BEGIN RC MIGRATION 20260824180010_customer_access_rbac.sql
alter table public.admin_user_permissions drop constraint if exists admin_user_permissions_permission_check;
alter table public.admin_user_permissions add constraint admin_user_permissions_permission_check check (permission in (
  'DASHBOARD_VIEW','AGENDA_VIEW','AGENDA_MANAGE','CUSTOMERS_VIEW','CUSTOMERS_MANAGE','CUSTOMER_ACCESS_DETAIL_VIEW',
  'FINANCE_VIEW','FINANCE_MANAGE','PACKAGES_VIEW','PACKAGES_MANAGE','SERVICES_VIEW','SERVICES_MANAGE',
  'INTEGRATIONS_VIEW','INTEGRATIONS_MANAGE','LEADS_VIEW','LEADS_MANAGE','AUDIT_VIEW','TEAM_MANAGE'
));

create or replace function public.service_admin_role_default_permission(p_role text,p_permission text)
returns boolean language sql immutable set search_path=public as $$
 select case upper(p_role)
  when 'OWNER' then true
  when 'ADMIN' then true
  when 'OPERATION' then p_permission in ('DASHBOARD_VIEW','AGENDA_VIEW','AGENDA_MANAGE','CUSTOMERS_VIEW','CUSTOMERS_MANAGE','PACKAGES_VIEW')
  when 'FINANCE' then p_permission in ('DASHBOARD_VIEW','AGENDA_VIEW','CUSTOMERS_VIEW','FINANCE_VIEW','FINANCE_MANAGE','PACKAGES_VIEW')
  else false end;
$$;

create or replace function public.service_admin_get_access_profile(p_admin_id uuid)
returns jsonb language sql stable security definer set search_path=public as $$
 select jsonb_build_object(
  'admin_user_id',a.id,'display_name',a.display_name,'role',a.role,
  'permissions',(select jsonb_object_agg(p.permission,public.service_admin_has_permission(a.id,p.permission)) from (values
   ('DASHBOARD_VIEW'),('AGENDA_VIEW'),('AGENDA_MANAGE'),('CUSTOMERS_VIEW'),('CUSTOMERS_MANAGE'),('CUSTOMER_ACCESS_DETAIL_VIEW'),
   ('FINANCE_VIEW'),('FINANCE_MANAGE'),('PACKAGES_VIEW'),('PACKAGES_MANAGE'),('SERVICES_VIEW'),('SERVICES_MANAGE'),
   ('INTEGRATIONS_VIEW'),('INTEGRATIONS_MANAGE'),('LEADS_VIEW'),('LEADS_MANAGE'),('AUDIT_VIEW'),('TEAM_MANAGE')
  ) p(permission))
 ) from public.admin_users a where a.id=p_admin_id and a.is_active=true;
$$;

create or replace function public.service_admin_set_permission(p_target_admin_id uuid,p_permission text,p_is_granted boolean,p_actor_admin_id uuid)
returns jsonb language plpgsql volatile security definer set search_path=public as $$
declare v_before jsonb; v_after jsonb;
begin
 if not public.service_admin_has_permission(p_actor_admin_id,'TEAM_MANAGE') then raise exception using errcode='P0001',message='ADMIN_PERMISSION_DENIED'; end if;
 if not exists(select 1 from public.admin_users where id=p_target_admin_id) then raise exception using errcode='P0001',message='ADMIN_USER_NOT_FOUND'; end if;
 if p_permission not in ('DASHBOARD_VIEW','AGENDA_VIEW','AGENDA_MANAGE','CUSTOMERS_VIEW','CUSTOMERS_MANAGE','CUSTOMER_ACCESS_DETAIL_VIEW','FINANCE_VIEW','FINANCE_MANAGE','PACKAGES_VIEW','PACKAGES_MANAGE','SERVICES_VIEW','SERVICES_MANAGE','INTEGRATIONS_VIEW','INTEGRATIONS_MANAGE','LEADS_VIEW','LEADS_MANAGE','AUDIT_VIEW','TEAM_MANAGE') then raise exception using errcode='P0001',message='ADMIN_PERMISSION_INVALID'; end if;
 select public.service_admin_get_access_profile(p_target_admin_id) into v_before;
 insert into public.admin_user_permissions(admin_user_id,permission,is_granted,updated_by_admin_id,updated_at) values(p_target_admin_id,p_permission,p_is_granted,p_actor_admin_id,now()) on conflict(admin_user_id,permission) do update set is_granted=excluded.is_granted,updated_by_admin_id=excluded.updated_by_admin_id,updated_at=now();
 select public.service_admin_get_access_profile(p_target_admin_id) into v_after;
 insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin) values(p_actor_admin_id,'ADMIN_USER',p_target_admin_id,'PERMISSION_CHANGED',v_before,v_after,'ADMIN');
 return v_after;
end; $$;

revoke all on function public.service_admin_role_default_permission(text,text),public.service_admin_get_access_profile(uuid),public.service_admin_set_permission(uuid,text,boolean,uuid) from public,anon,authenticated;
grant execute on function public.service_admin_role_default_permission(text,text),public.service_admin_get_access_profile(uuid),public.service_admin_set_permission(uuid,text,boolean,uuid) to service_role;
-- END RC MIGRATION 20260824180010_customer_access_rbac.sql

-- BEGIN RC MIGRATION 20260824180020_free_visit_confirmation.sql
-- Auditable administrative confirmation for free visits.
create or replace function public.service_admin_confirm_free_visit(
  p_appointment_id uuid,
  p_admin_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path=public
as $$
declare
  v_appointment public.appointments%rowtype;
  v_service public.services%rowtype;
begin
  if not public.service_admin_has_permission(p_admin_id,'AGENDA_MANAGE') then
    raise exception using errcode='42501',message='ADMIN_PERMISSION_DENIED';
  end if;

  select * into v_appointment
  from public.appointments
  where id=p_appointment_id
  for update;
  if not found then
    raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND';
  end if;

  select * into v_service from public.services where id=v_appointment.service_id;
  if not found or v_service.booking_product_type<>'FREE_VISIT' then
    raise exception using errcode='P0001',message='FREE_VISIT_REQUIRED';
  end if;
  if v_appointment.status<>'CONFIRMED' then
    raise exception using errcode='P0001',message='FREE_VISIT_NOT_CONFIRMABLE';
  end if;
  if v_appointment.start_at<=now() then
    raise exception using errcode='P0001',message='FREE_VISIT_ALREADY_STARTED';
  end if;
  if v_appointment.free_visit_confirmation_deadline is not null
     and v_appointment.free_visit_confirmation_deadline<=now() then
    raise exception using errcode='P0001',message='FREE_VISIT_CONFIRMATION_DEADLINE_PASSED';
  end if;

  if v_appointment.free_visit_confirmed_at is null then
    update public.appointments
    set free_visit_confirmed_at=now(),updated_at=now()
    where id=p_appointment_id;

    insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
    values(
      p_admin_id,'APPOINTMENT',p_appointment_id,'FREE_VISIT_CONFIRMED',
      jsonb_build_object('free_visit_confirmed_at',null,'confirmation_deadline',v_appointment.free_visit_confirmation_deadline),
      jsonb_build_object('free_visit_confirmed_at',now(),'confirmation_deadline',v_appointment.free_visit_confirmation_deadline),
      'ADMIN'
    );
  end if;

  return jsonb_build_object(
    'appointment_id',p_appointment_id,
    'confirmed',true,
    'free_visit_confirmed_at',(select free_visit_confirmed_at from public.appointments where id=p_appointment_id),
    'confirmation_deadline',v_appointment.free_visit_confirmation_deadline
  );
end;
$$;

revoke all on function public.service_admin_confirm_free_visit(uuid,uuid) from public,anon,authenticated;
grant execute on function public.service_admin_confirm_free_visit(uuid,uuid) to service_role;
-- END RC MIGRATION 20260824180020_free_visit_confirmation.sql

-- BEGIN RC MIGRATION 20260824183000_fix_payment_preview_volatility.sql
-- payment-preview calls the token resolver, which records token usage and takes a row lock.
-- The wrapper therefore cannot be STABLE/read-only.

create or replace function public.service_get_public_payment_method_preview(
  p_access_token text
) returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_context jsonb;
  v_minimum_contract numeric(12,2);
  v_full_contract numeric(12,2);
  v_discount_percent numeric(5,2);
  v_minimum_pix jsonb;
  v_full_pix jsonb;
begin
  v_context := public.service_get_public_payment_context(p_access_token);

  v_minimum_contract := round(coalesce((v_context->>'minimum_due_contract_amount')::numeric, 0), 2);
  v_full_contract := round(coalesce((v_context->>'contract_balance')::numeric, 0), 2);

  select round(coalesce(os.pix_discount_percent, 0), 2)
  into v_discount_percent
  from public.operation_settings os
  where os.id = 1;

  if v_discount_percent is null then
    raise exception using errcode = 'P0001', message = 'PAYMENT_SETTINGS_LOAD_FAILED';
  end if;

  v_minimum_pix := public.service_calculate_payment_cash_amount(v_minimum_contract, 'PIX', v_discount_percent);
  v_full_pix := public.service_calculate_payment_cash_amount(v_full_contract, 'PIX', v_discount_percent);

  return jsonb_build_object(
    'pix_discount_percent', v_discount_percent,
    'confirmation_percentage', (v_context->>'confirmation_percentage')::numeric,
    'minimum_available', coalesce((v_context->>'minimum_available')::boolean, false),
    'full_available', coalesce((v_context->>'full_available')::boolean, false),
    'minimum_due_contract_amount', v_minimum_contract,
    'minimum_due_card_cash_amount', v_minimum_contract,
    'minimum_due_pix_cash_amount', (v_minimum_pix->>'cash_amount')::numeric,
    'full_due_contract_amount', v_full_contract,
    'full_due_card_cash_amount', v_full_contract,
    'full_due_pix_cash_amount', (v_full_pix->>'cash_amount')::numeric
  );
end;
$$;

revoke all on function public.service_get_public_payment_method_preview(text) from public, anon, authenticated;
grant execute on function public.service_get_public_payment_method_preview(text) to service_role;
-- END RC MIGRATION 20260824183000_fix_payment_preview_volatility.sql

-- BEGIN RC MIGRATION 20260824185024_harden_internal_trigger_rpcs.sql
begin;

-- Internal trigger functions execute only through their table triggers.
-- They are not part of the public Data API surface and must not be callable
-- directly by anon/authenticated roles through /rest/v1/rpc/*.
revoke execute on function public.customer_access_appointment_before_insert() from public, anon, authenticated;
revoke execute on function public.customer_access_no_show_after_update() from public, anon, authenticated;
revoke execute on function public.customers_capture_identity_keys_trigger() from public, anon, authenticated;
revoke execute on function public.enqueue_no_show_balance_cancellation() from public, anon, authenticated;

-- The advisor can report this helper on hosted environments even when a clean
-- migration replay does not contain the legacy function. Harden every existing
-- overload when present, but keep a fresh local rebuild deterministic.
do $$
declare
  v_signature text;
begin
  for v_signature in
    select p.oid::regprocedure::text
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'kommo_guard_adjust_due'
      and p.prokind = 'f'
  loop
    execute format('alter function %s set search_path = public', v_signature);
  end loop;
end;
$$;

commit;
-- END RC MIGRATION 20260824185024_harden_internal_trigger_rpcs.sql

-- BEGIN RC MIGRATION 20260824220039_blacksheep_closing_buffer.sql
-- BlackSheep rental commercial hours: client-facing booking may run until 22:00.
-- The post-service buffer remains an internal resource occupation and may extend
-- 30 minutes beyond closing, so the physical studio resource stays available
-- through 22:30 for allocation purposes only.
--
-- Scope is intentionally limited to the staging BlackSheep rental service by
-- stable slug. Environments without this synthetic service are a no-op.

update public.availability_rules ar
set end_local_time = '22:00'::time,
    updated_at = now()
from public.service_employees se
join public.services s on s.id = se.service_id
where ar.service_employee_id = se.id
  and s.slug = 'staging-locacao-blacksheep-duracao'
  and ar.is_active;

update public.resource_availability_rules rar
set end_local_time = '22:30'::time,
    updated_at = now()
where rar.resource_id in (
  select sr.resource_id
  from public.service_resources sr
  join public.services s on s.id = sr.service_id
  where s.slug = 'staging-locacao-blacksheep-duracao'
    and sr.is_required
)
  and rar.is_active;
-- END RC MIGRATION 20260824220039_blacksheep_closing_buffer.sql

-- BEGIN RC MIGRATION 20260825103000_first_owner_bootstrap.sql
CREATE OR REPLACE FUNCTION public.service_bootstrap_first_owner(
  p_auth_user_id uuid,
  p_display_name text,
  p_request_id uuid DEFAULT gen_random_uuid()
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id uuid;
  v_display_name text := btrim(coalesce(p_display_name, ''));
  v_profile jsonb;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended('agenda:first-owner-bootstrap', 0));

  IF EXISTS (SELECT 1 FROM public.admin_users) THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'ADMIN_BOOTSTRAP_CLOSED';
  END IF;

  IF p_auth_user_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM auth.users WHERE id = p_auth_user_id
  ) THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'ADMIN_BOOTSTRAP_AUTH_USER_NOT_FOUND';
  END IF;

  IF length(v_display_name) < 2 OR length(v_display_name) > 120 THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'ADMIN_BOOTSTRAP_DISPLAY_NAME_INVALID';
  END IF;

  INSERT INTO public.admin_users (auth_user_id, display_name, role, is_active)
  VALUES (p_auth_user_id, v_display_name, 'OWNER', true)
  RETURNING id INTO v_admin_id;

  v_profile := public.service_admin_get_access_profile(v_admin_id);

  INSERT INTO public.audit_logs (
    admin_user_id,
    entity_type,
    entity_id,
    action,
    before_json,
    after_json,
    origin,
    request_id
  ) VALUES (
    v_admin_id,
    'ADMIN_USER',
    v_admin_id,
    'FIRST_OWNER_BOOTSTRAPPED',
    NULL,
    jsonb_build_object(
      'admin_user_id', v_admin_id,
      'auth_user_id', p_auth_user_id,
      'display_name', v_display_name,
      'role', 'OWNER',
      'is_active', true,
      'bootstrap', true
    ),
    'SYSTEM',
    p_request_id
  );

  RETURN v_profile;
END;
$$;

REVOKE ALL ON FUNCTION public.service_bootstrap_first_owner(uuid, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.service_bootstrap_first_owner(uuid, text, uuid) FROM anon;
REVOKE ALL ON FUNCTION public.service_bootstrap_first_owner(uuid, text, uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.service_bootstrap_first_owner(uuid, text, uuid) TO service_role;

COMMENT ON FUNCTION public.service_bootstrap_first_owner(uuid, text, uuid) IS
  'One-time, service-role-only bootstrap for the first OWNER. Permanently closes after any admin_users row exists.';
-- END RC MIGRATION 20260825103000_first_owner_bootstrap.sql

-- BEGIN RC MIGRATION 20260825114500_cover_remaining_foreign_keys.sql
CREATE INDEX IF NOT EXISTS appointment_balance_collections_created_by_admin_idx
  ON public.appointment_balance_collections (created_by_admin_id);

CREATE INDEX IF NOT EXISTS balance_collection_divergences_appointment_idx
  ON public.balance_collection_divergences (appointment_id);

CREATE INDEX IF NOT EXISTS balance_collection_divergences_collection_idx
  ON public.balance_collection_divergences (balance_collection_id);

CREATE INDEX IF NOT EXISTS balance_collection_divergences_payment_tx_idx
  ON public.balance_collection_divergences (payment_transaction_id);

CREATE INDEX IF NOT EXISTS balance_collection_divergences_resolved_by_admin_idx
  ON public.balance_collection_divergences (resolved_by_admin_id);

CREATE INDEX IF NOT EXISTS customer_access_events_actor_admin_idx
  ON public.customer_access_events (actor_admin_id);
-- END RC MIGRATION 20260825114500_cover_remaining_foreign_keys.sql

-- BEGIN RC MIGRATION 20260825135109_authenticated_first_owner_bootstrap_bridge.sql
-- Reconcile the authenticated first-OWNER bridge that was applied to the
-- sandbox before it was committed to the authoritative migration history.
--
-- Security contract:
-- - authenticated caller must have a Supabase session (`auth.uid()`);
-- - only the confirmed studio admin address may invoke the one-time bootstrap;
-- - the service-role-only primitive remains the authority for creating OWNER;
-- - no service_role credential is exposed to the browser.

CREATE OR REPLACE FUNCTION public.service_bootstrap_first_owner_authenticated(
  p_display_name text DEFAULT 'BlackSheep Agenda'::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_email text;
  v_confirmed boolean;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'ADMIN_AUTH_REQUIRED';
  END IF;

  SELECT lower(email), email_confirmed_at IS NOT NULL
    INTO v_email, v_confirmed
  FROM auth.users
  WHERE id = v_uid;

  IF v_email IS DISTINCT FROM lower('agenda@blacksheepestudiocriativo.com.br') THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'ADMIN_BOOTSTRAP_EMAIL_DENIED';
  END IF;

  IF coalesce(v_confirmed, false) IS NOT TRUE THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'ADMIN_BOOTSTRAP_EMAIL_UNCONFIRMED';
  END IF;

  RETURN public.service_bootstrap_first_owner(
    v_uid,
    p_display_name,
    gen_random_uuid()
  );
END;
$$;

REVOKE ALL ON FUNCTION public.service_bootstrap_first_owner_authenticated(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.service_bootstrap_first_owner_authenticated(text) FROM anon;
GRANT EXECUTE ON FUNCTION public.service_bootstrap_first_owner_authenticated(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.service_bootstrap_first_owner_authenticated(text) TO service_role;

COMMENT ON FUNCTION public.service_bootstrap_first_owner_authenticated(text) IS
  'One-time authenticated bridge for the first BlackSheep Agenda OWNER. Restricted to the confirmed studio admin email and delegates to the service-role-only bootstrap primitive.';
-- END RC MIGRATION 20260825135109_authenticated_first_owner_bootstrap_bridge.sql
