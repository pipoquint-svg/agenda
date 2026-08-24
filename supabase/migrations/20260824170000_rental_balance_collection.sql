-- Rental balance collection lifecycle.
-- Auto-created at the rental start time for confirmed BlackSheep appointments with a real open balance.
-- Collection links are valid for 48 hours. Admin reissue creates a fresh 48h collection and revokes the prior one.

create table if not exists public.appointment_balance_collections (
  id uuid primary key default gen_random_uuid(),
  appointment_id uuid not null references public.appointments(id) on delete cascade,
  sequence integer not null,
  source text not null check (source in ('AUTO_START','ADMIN_REISSUE')),
  status text not null default 'ACTIVE' check (status in ('ACTIVE','PAID','EXPIRED','REVOKED')),
  amount_snapshot numeric(12,2) not null check (amount_snapshot > 0),
  issued_at timestamptz not null default now(),
  expires_at timestamptz not null,
  created_by_admin_id uuid references public.admin_users(id),
  email_delivered_at timestamptz,
  kommo_delivered_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (appointment_id, sequence),
  check (expires_at > issued_at),
  check ((source = 'ADMIN_REISSUE') = (created_by_admin_id is not null))
);

create index if not exists appointment_balance_collections_active_idx
  on public.appointment_balance_collections(appointment_id, status, expires_at);

alter table public.appointment_access_tokens
  add column if not exists balance_collection_id uuid references public.appointment_balance_collections(id) on delete set null;

create index if not exists appointment_access_tokens_balance_collection_idx
  on public.appointment_access_tokens(balance_collection_id)
  where balance_collection_id is not null;

alter table public.appointment_balance_collections enable row level security;
revoke all on public.appointment_balance_collections from public, anon, authenticated;
grant select, insert, update on public.appointment_balance_collections to service_role;

create or replace function public.balance_collection_clock()
returns timestamptz
language sql
stable
set search_path = public
as $$
  select coalesce(
    nullif(current_setting('agenda.test_now', true), '')::timestamptz,
    now()
  )
$$;

create or replace function public.expire_due_balance_collections()
returns integer
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_now timestamptz := public.balance_collection_clock();
  v_count integer := 0;
begin
  update public.appointment_balance_collections
  set status = 'EXPIRED', updated_at = v_now
  where status = 'ACTIVE' and expires_at <= v_now;
  get diagnostics v_count = row_count;

  update public.appointment_access_tokens t
  set revoked_at = coalesce(t.revoked_at, v_now)
  from public.appointment_balance_collections c
  where t.balance_collection_id = c.id
    and c.status = 'EXPIRED'
    and t.revoked_at is null;

  return v_count;
end;
$$;

create or replace function public.create_balance_collection(
  p_appointment_id uuid,
  p_source text,
  p_admin_id uuid default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_now timestamptz := public.balance_collection_clock();
  v_appointment public.appointments%rowtype;
  v_scope text;
  v_balance numeric(12,2);
  v_sequence integer;
  v_collection public.appointment_balance_collections%rowtype;
begin
  if p_source not in ('AUTO_START','ADMIN_REISSUE') then
    raise exception using errcode='22023', message='BALANCE_COLLECTION_SOURCE_INVALID';
  end if;

  select a.*, s.operation_scope
  into v_appointment, v_scope
  from public.appointments a
  join public.services s on s.id = a.service_id
  where a.id = p_appointment_id
  for update of a;

  if not found then raise exception using errcode='P0001', message='APPOINTMENT_NOT_FOUND'; end if;
  if v_scope <> 'BLACKSHEEP' then raise exception using errcode='P0001', message='BALANCE_COLLECTION_SCOPE_DENIED'; end if;
  if v_appointment.status not in ('CONFIRMED','COMPLETED') then
    raise exception using errcode='P0001', message='BALANCE_COLLECTION_APPOINTMENT_NOT_ELIGIBLE';
  end if;

  if p_source = 'AUTO_START' and v_appointment.start_at > v_now then
    raise exception using errcode='P0001', message='BALANCE_COLLECTION_NOT_DUE';
  end if;

  if p_source = 'ADMIN_REISSUE' then
    if p_admin_id is null or not public.service_admin_has_permission(p_admin_id, 'FINANCE_MANAGE') then
      raise exception using errcode='42501', message='ADMIN_PERMISSION_DENIED';
    end if;
  elsif p_admin_id is not null then
    raise exception using errcode='22023', message='BALANCE_COLLECTION_ADMIN_INVALID';
  end if;

  v_balance := round(greatest(coalesce((public.get_appointment_financial_summary(p_appointment_id)->>'contract_balance')::numeric,0),0),2);
  if v_balance <= 0 then raise exception using errcode='P0001', message='BALANCE_COLLECTION_NOT_DUE'; end if;

  if p_source = 'AUTO_START' and exists (
    select 1 from public.appointment_balance_collections where appointment_id = p_appointment_id
  ) then
    raise exception using errcode='P0001', message='BALANCE_COLLECTION_ALREADY_CREATED';
  end if;

  if p_source = 'ADMIN_REISSUE' then
    update public.appointment_balance_collections
    set status = 'REVOKED', updated_at = v_now
    where appointment_id = p_appointment_id and status = 'ACTIVE';

    update public.appointment_access_tokens
    set revoked_at = coalesce(revoked_at, v_now)
    where appointment_id = p_appointment_id
      and balance_collection_id is not null
      and revoked_at is null;
  end if;

  select coalesce(max(sequence),0) + 1 into v_sequence
  from public.appointment_balance_collections
  where appointment_id = p_appointment_id;

  insert into public.appointment_balance_collections(
    appointment_id, sequence, source, status, amount_snapshot,
    issued_at, expires_at, created_by_admin_id
  ) values (
    p_appointment_id, v_sequence, p_source, 'ACTIVE', v_balance,
    v_now, v_now + interval '48 hours', p_admin_id
  ) returning * into v_collection;

  insert into public.integration_jobs(
    job_type, entity_type, entity_id, entity_version, payload_json, idempotency_key
  ) values (
    'RENTAL_BALANCE_DUE_MESSAGE', 'BALANCE_COLLECTION', v_collection.id, v_sequence,
    jsonb_build_object('appointment_id',p_appointment_id,'source',p_source),
    'rental-balance-due-message:' || v_collection.id::text
  ) on conflict (idempotency_key) do nothing;

  insert into public.audit_logs(entity_type,entity_id,action,before_json,after_json,origin,admin_user_id)
  values(
    'APPOINTMENT', p_appointment_id,
    case when p_source='AUTO_START' then 'BALANCE_COLLECTION_AUTO_CREATED' else 'BALANCE_COLLECTION_REISSUED' end,
    null,
    jsonb_build_object('collection_id',v_collection.id,'sequence',v_sequence,'amount',v_balance,'expires_at',v_collection.expires_at),
    case when p_source='AUTO_START' then 'SYSTEM' else 'OPERATION' end,
    p_admin_id
  );

  return jsonb_build_object(
    'collection_id',v_collection.id,
    'appointment_id',p_appointment_id,
    'sequence',v_sequence,
    'status','ACTIVE',
    'amount',v_balance,
    'issued_at',v_collection.issued_at,
    'expires_at',v_collection.expires_at
  );
end;
$$;

create or replace function public.enqueue_due_rental_balance_collections()
returns integer
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_now timestamptz := public.balance_collection_clock();
  v_row record;
  v_count integer := 0;
begin
  perform public.expire_due_balance_collections();

  for v_row in
    select a.id
    from public.appointments a
    join public.services s on s.id = a.service_id
    cross join lateral public.get_appointment_financial_summary(a.id) f
    where s.operation_scope = 'BLACKSHEEP'
      and a.status = 'CONFIRMED'
      and a.start_at <= v_now
      and a.start_at > v_now - interval '24 hours'
      and coalesce((f->>'contract_balance')::numeric,0) > 0.005
      and not exists (
        select 1 from public.appointment_balance_collections c where c.appointment_id = a.id
      )
    order by a.start_at, a.id
    for update of a skip locked
  loop
    begin
      perform public.create_balance_collection(v_row.id,'AUTO_START',null);
      v_count := v_count + 1;
    exception when others then
      if sqlerrm not in ('BALANCE_COLLECTION_ALREADY_CREATED','BALANCE_COLLECTION_NOT_DUE') then raise; end if;
    end;
  end loop;

  return v_count;
end;
$$;

create or replace function public.service_admin_reissue_balance_collection(
  p_appointment_id uuid,
  p_admin_id uuid
)
returns jsonb
language sql
volatile
security definer
set search_path = public
as $$
  select public.create_balance_collection(p_appointment_id,'ADMIN_REISSUE',p_admin_id)
$$;

create or replace function public.service_verify_balance_collection_email(
  p_collection_id uuid,
  p_email text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_now timestamptz := public.balance_collection_clock();
  v_collection public.appointment_balance_collections%rowtype;
  v_customer_id uuid;
  v_customer_email text;
  v_raw_token text;
  v_hash text;
  v_token_id uuid;
begin
  perform public.expire_due_balance_collections();

  select * into v_collection
  from public.appointment_balance_collections
  where id = p_collection_id
  for update;

  if not found or v_collection.status <> 'ACTIVE' or v_collection.expires_at <= v_now then
    raise exception using errcode='P0001', message='BALANCE_COLLECTION_INVALID_OR_EXPIRED';
  end if;

  select a.primary_customer_id, lower(trim(c.email))
  into v_customer_id, v_customer_email
  from public.appointments a
  join public.customers c on c.id = a.primary_customer_id
  where a.id = v_collection.appointment_id;

  if v_customer_id is null or v_customer_email is null or lower(trim(coalesce(p_email,''))) <> v_customer_email then
    raise exception using errcode='P0001', message='BALANCE_COLLECTION_VERIFICATION_FAILED';
  end if;

  if coalesce((public.get_appointment_financial_summary(v_collection.appointment_id)->>'contract_balance')::numeric,0) <= 0.005 then
    update public.appointment_balance_collections set status='PAID',updated_at=v_now where id=v_collection.id;
    raise exception using errcode='P0001', message='BALANCE_COLLECTION_ALREADY_PAID';
  end if;

  v_raw_token := encode(gen_random_bytes(32),'hex');
  v_hash := encode(digest(v_raw_token,'sha256'),'hex');

  insert into public.appointment_access_tokens(
    appointment_id,token_hash,scope,expires_at,delivery_channel,destination_masked,balance_collection_id
  ) values (
    v_collection.appointment_id,v_hash,'PAY',v_collection.expires_at,'INTERNAL','verified-email',v_collection.id
  ) returning id into v_token_id;

  return jsonb_build_object(
    'access_token',v_raw_token,
    'token_id',v_token_id,
    'appointment_id',v_collection.appointment_id,
    'collection_id',v_collection.id,
    'expires_at',v_collection.expires_at,
    'amount',round(greatest(coalesce((public.get_appointment_financial_summary(v_collection.appointment_id)->>'contract_balance')::numeric,0),0),2)
  );
end;
$$;

create or replace view public.appointment_open_balances as
select
  a.id as appointment_id,
  a.public_code,
  a.primary_customer_id as customer_id,
  c.name as customer_name,
  a.service_id,
  a.service_name_snapshot as service_name,
  s.operation_scope,
  a.status as appointment_status,
  a.financial_status,
  a.start_at,
  a.commercial_value as total_value,
  coalesce((f->>'contract_settled')::numeric,0)::numeric(12,2) as paid_value,
  coalesce((f->>'contract_balance')::numeric,0)::numeric(12,2) as balance_value,
  bc.id as active_collection_id,
  bc.sequence as collection_sequence,
  bc.expires_at as collection_expires_at
from public.appointments a
join public.services s on s.id=a.service_id
left join public.customers c on c.id=a.primary_customer_id
cross join lateral public.get_appointment_financial_summary(a.id) f
left join lateral (
  select x.id,x.sequence,x.expires_at
  from public.appointment_balance_collections x
  where x.appointment_id=a.id and x.status='ACTIVE' and x.expires_at>public.balance_collection_clock()
  order by x.sequence desc
  limit 1
) bc on true
where a.status in ('CONFIRMED','COMPLETED')
  and coalesce((f->>'contract_balance')::numeric,0)>0.005;

revoke all on public.appointment_open_balances from public, anon, authenticated;
grant select on public.appointment_open_balances to service_role;

revoke all on function public.balance_collection_clock() from public, anon, authenticated;
revoke all on function public.expire_due_balance_collections() from public, anon, authenticated;
revoke all on function public.create_balance_collection(uuid,text,uuid) from public, anon, authenticated;
revoke all on function public.enqueue_due_rental_balance_collections() from public, anon, authenticated;
revoke all on function public.service_admin_reissue_balance_collection(uuid,uuid) from public, anon, authenticated;
revoke all on function public.service_verify_balance_collection_email(uuid,text) from public, anon, authenticated;

grant execute on function public.expire_due_balance_collections() to service_role;
grant execute on function public.enqueue_due_rental_balance_collections() to service_role;
grant execute on function public.service_admin_reissue_balance_collection(uuid,uuid) to service_role;
grant execute on function public.service_verify_balance_collection_email(uuid,text) to service_role;
