
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
