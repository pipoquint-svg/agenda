-- Amelia is a legacy operational source during the transition.
-- BlackSheep Agenda stores Amelia rows only as read-only history.
-- These records MUST NOT become appointments, allocations, payments or managed Google events.

create table public.legacy_amelia_import_batches (
  id uuid primary key default gen_random_uuid(),
  source_filename text,
  source_sha256 text,
  declared_row_count integer check (declared_row_count is null or declared_row_count >= 0),
  imported_row_count integer not null default 0 check (imported_row_count >= 0),
  status text not null default 'OPEN' check (status in ('OPEN','COMPLETED','FAILED')),
  notes text,
  created_by_admin_user_id uuid references public.admin_users(id) on delete set null,
  created_at timestamptz not null default now(),
  completed_at timestamptz,
  check (completed_at is null or completed_at >= created_at)
);

create unique index legacy_amelia_import_batches_sha_uq
  on public.legacy_amelia_import_batches (source_sha256)
  where source_sha256 is not null;

create table public.legacy_amelia_bookings (
  id uuid primary key default gen_random_uuid(),

  -- Immutable domain classification. Amelia remains the operational authority
  -- until its final booking is fulfilled; this table is historical only.
  source_system text not null default 'AMELIA' check (source_system = 'AMELIA'),
  operational_authority text not null default 'AMELIA' check (operational_authority = 'AMELIA'),
  record_mode text not null default 'HISTORY_ONLY' check (record_mode = 'HISTORY_ONLY'),

  amelia_booking_id text not null,
  woocommerce_order_id text,

  customer_name text,
  customer_email text,
  customer_phone text,
  cpf_cnpj text,
  matched_customer_id uuid references public.customers(id) on delete set null,

  service_name text,
  employee_name text,
  start_at timestamptz,
  end_at timestamptz,
  declared_duration_minutes integer check (declared_duration_minutes is null or declared_duration_minutes >= 0),
  status_raw text,

  -- Amelia exports can use a price column with different semantics depending
  -- on the service. Preserve it as source data; never treat it as canonical
  -- contract/payment state in the new system.
  amelia_price_amount numeric(12,2) check (amelia_price_amount is null or amelia_price_amount >= 0),
  payment_status_raw text,
  payment_method_raw text,

  extras_json jsonb not null default '[]'::jsonb,
  custom_fields_json jsonb not null default '{}'::jsonb,
  notes text,
  google_event_reference text,

  first_import_batch_id uuid references public.legacy_amelia_import_batches(id) on delete set null,
  last_import_batch_id uuid references public.legacy_amelia_import_batches(id) on delete set null,
  import_revision integer not null default 1 check (import_revision >= 1),
  first_imported_at timestamptz not null default now(),
  last_imported_at timestamptz not null default now(),

  unique (amelia_booking_id),
  check (end_at is null or start_at is null or end_at >= start_at),
  check (jsonb_typeof(extras_json) = 'array'),
  check (jsonb_typeof(custom_fields_json) = 'object')
);

create index legacy_amelia_bookings_start_idx
  on public.legacy_amelia_bookings (start_at)
  where start_at is not null;

create index legacy_amelia_bookings_customer_phone_idx
  on public.legacy_amelia_bookings (customer_phone)
  where customer_phone is not null;

create index legacy_amelia_bookings_customer_email_idx
  on public.legacy_amelia_bookings (lower(customer_email))
  where customer_email is not null;

create index legacy_amelia_bookings_service_idx
  on public.legacy_amelia_bookings (lower(service_name))
  where service_name is not null;

alter table public.legacy_amelia_import_batches enable row level security;
alter table public.legacy_amelia_bookings enable row level security;

-- Admin UI may read legacy history but never edit it directly.
grant select on public.legacy_amelia_import_batches to authenticated;
grant select on public.legacy_amelia_bookings to authenticated;
revoke insert, update, delete, truncate on public.legacy_amelia_import_batches from anon, authenticated;
revoke insert, update, delete, truncate on public.legacy_amelia_bookings from anon, authenticated;

grant all on public.legacy_amelia_import_batches to service_role;
grant all on public.legacy_amelia_bookings to service_role;

create policy legacy_amelia_import_batches_admin_select
  on public.legacy_amelia_import_batches
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.admin_users au
      where au.auth_user_id = auth.uid()
        and au.is_active
    )
  );

create policy legacy_amelia_bookings_admin_select
  on public.legacy_amelia_bookings
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.admin_users au
      where au.auth_user_id = auth.uid()
        and au.is_active
    )
  );

create or replace function public.create_legacy_amelia_import_batch(
  p_source_filename text default null,
  p_source_sha256 text default null,
  p_declared_row_count integer default null,
  p_notes text default null,
  p_created_by_admin_user_id uuid default null
)
returns uuid
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if p_declared_row_count is not null and p_declared_row_count < 0 then
    raise exception using errcode = 'P0001', message = 'AMELIA_IMPORT_INVALID_ROW_COUNT';
  end if;

  insert into public.legacy_amelia_import_batches (
    source_filename,
    source_sha256,
    declared_row_count,
    notes,
    created_by_admin_user_id
  ) values (
    nullif(btrim(p_source_filename), ''),
    nullif(lower(btrim(p_source_sha256)), ''),
    p_declared_row_count,
    nullif(btrim(p_notes), ''),
    p_created_by_admin_user_id
  )
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.create_legacy_amelia_import_batch(text,text,integer,text,uuid)
  from public, anon, authenticated;
grant execute on function public.create_legacy_amelia_import_batch(text,text,integer,text,uuid)
  to service_role;

create or replace function public.upsert_legacy_amelia_booking(
  p_import_batch_id uuid,
  p_booking jsonb
)
returns uuid
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_amelia_booking_id text;
  v_start_at timestamptz;
  v_end_at timestamptz;
  v_duration integer;
  v_price numeric(12,2);
begin
  if p_booking is null or jsonb_typeof(p_booking) <> 'object' then
    raise exception using errcode = 'P0001', message = 'AMELIA_IMPORT_INVALID_BOOKING';
  end if;

  if not exists (
    select 1
    from public.legacy_amelia_import_batches b
    where b.id = p_import_batch_id
      and b.status = 'OPEN'
  ) then
    raise exception using errcode = 'P0001', message = 'AMELIA_IMPORT_BATCH_NOT_OPEN';
  end if;

  v_amelia_booking_id := nullif(btrim(p_booking->>'amelia_booking_id'), '');
  if v_amelia_booking_id is null then
    raise exception using errcode = 'P0001', message = 'AMELIA_BOOKING_ID_REQUIRED';
  end if;

  begin
    v_start_at := nullif(p_booking->>'start_at', '')::timestamptz;
    v_end_at := nullif(p_booking->>'end_at', '')::timestamptz;
    v_duration := nullif(p_booking->>'declared_duration_minutes', '')::integer;
    v_price := nullif(replace(p_booking->>'amelia_price_amount', ',', '.'), '')::numeric(12,2);
  exception when others then
    raise exception using errcode = 'P0001', message = 'AMELIA_IMPORT_INVALID_TYPED_VALUE';
  end;

  if v_duration is not null and v_duration < 0 then
    raise exception using errcode = 'P0001', message = 'AMELIA_IMPORT_INVALID_DURATION';
  end if;

  if v_price is not null and v_price < 0 then
    raise exception using errcode = 'P0001', message = 'AMELIA_IMPORT_INVALID_PRICE';
  end if;

  if v_start_at is not null and v_end_at is not null and v_end_at < v_start_at then
    raise exception using errcode = 'P0001', message = 'AMELIA_IMPORT_INVALID_RANGE';
  end if;

  insert into public.legacy_amelia_bookings (
    amelia_booking_id,
    woocommerce_order_id,
    customer_name,
    customer_email,
    customer_phone,
    cpf_cnpj,
    service_name,
    employee_name,
    start_at,
    end_at,
    declared_duration_minutes,
    status_raw,
    amelia_price_amount,
    payment_status_raw,
    payment_method_raw,
    extras_json,
    custom_fields_json,
    notes,
    google_event_reference,
    first_import_batch_id,
    last_import_batch_id
  ) values (
    v_amelia_booking_id,
    nullif(btrim(p_booking->>'woocommerce_order_id'), ''),
    nullif(btrim(p_booking->>'customer_name'), ''),
    nullif(lower(btrim(p_booking->>'customer_email')), ''),
    nullif(btrim(p_booking->>'customer_phone'), ''),
    nullif(btrim(p_booking->>'cpf_cnpj'), ''),
    nullif(btrim(p_booking->>'service_name'), ''),
    nullif(btrim(p_booking->>'employee_name'), ''),
    v_start_at,
    v_end_at,
    v_duration,
    nullif(btrim(p_booking->>'status_raw'), ''),
    v_price,
    nullif(btrim(p_booking->>'payment_status_raw'), ''),
    nullif(btrim(p_booking->>'payment_method_raw'), ''),
    case
      when jsonb_typeof(p_booking->'extras') = 'array' then p_booking->'extras'
      else '[]'::jsonb
    end,
    case
      when jsonb_typeof(p_booking->'custom_fields') = 'object' then p_booking->'custom_fields'
      else '{}'::jsonb
    end,
    nullif(btrim(p_booking->>'notes'), ''),
    nullif(btrim(p_booking->>'google_event_reference'), ''),
    p_import_batch_id,
    p_import_batch_id
  )
  on conflict (amelia_booking_id)
  do update set
    woocommerce_order_id = excluded.woocommerce_order_id,
    customer_name = excluded.customer_name,
    customer_email = excluded.customer_email,
    customer_phone = excluded.customer_phone,
    -- CPF remains nullable. Never fabricate a value during legacy import.
    cpf_cnpj = coalesce(excluded.cpf_cnpj, public.legacy_amelia_bookings.cpf_cnpj),
    service_name = excluded.service_name,
    employee_name = excluded.employee_name,
    start_at = excluded.start_at,
    end_at = excluded.end_at,
    declared_duration_minutes = excluded.declared_duration_minutes,
    status_raw = excluded.status_raw,
    amelia_price_amount = excluded.amelia_price_amount,
    payment_status_raw = excluded.payment_status_raw,
    payment_method_raw = excluded.payment_method_raw,
    extras_json = excluded.extras_json,
    custom_fields_json = excluded.custom_fields_json,
    notes = excluded.notes,
    google_event_reference = excluded.google_event_reference,
    last_import_batch_id = excluded.last_import_batch_id,
    import_revision = public.legacy_amelia_bookings.import_revision + 1,
    last_imported_at = now()
  returning id into v_id;

  update public.legacy_amelia_import_batches
  set imported_row_count = imported_row_count + 1
  where id = p_import_batch_id;

  return v_id;
end;
$$;

revoke all on function public.upsert_legacy_amelia_booking(uuid,jsonb)
  from public, anon, authenticated;
grant execute on function public.upsert_legacy_amelia_booking(uuid,jsonb)
  to service_role;

create or replace function public.complete_legacy_amelia_import_batch(p_import_batch_id uuid)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $$
begin
  update public.legacy_amelia_import_batches
  set status = 'COMPLETED',
      completed_at = now()
  where id = p_import_batch_id
    and status = 'OPEN';

  if not found then
    raise exception using errcode = 'P0001', message = 'AMELIA_IMPORT_BATCH_NOT_OPEN';
  end if;
end;
$$;

revoke all on function public.complete_legacy_amelia_import_batch(uuid)
  from public, anon, authenticated;
grant execute on function public.complete_legacy_amelia_import_batch(uuid)
  to service_role;

comment on table public.legacy_amelia_bookings is
  'Read-only historical snapshot of bookings whose operational authority remains Amelia. Rows never become Agenda appointments or Google managed events.';

comment on column public.legacy_amelia_bookings.cpf_cnpj is
  'Nullable by design. Legacy Amelia exports may not contain CPF/CNPJ; request it on the customer next native booking instead of fabricating it.';

comment on column public.legacy_amelia_bookings.amelia_price_amount is
  'Historical source amount only. Do not infer canonical contract paid/balance semantics from this column.';
