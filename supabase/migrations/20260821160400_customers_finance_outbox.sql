create table public.customers (
  id uuid primary key default gen_random_uuid(),
  customer_type text not null default 'PERSON' check (customer_type in ('PERSON','BUSINESS')),
  name text not null,
  legal_name text,
  cpf_cnpj text,
  email text,
  phone text,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index customers_name_idx on public.customers (lower(name));
create index customers_phone_idx on public.customers (phone) where phone is not null;
create index customers_email_idx on public.customers (lower(email)) where email is not null;
create index customers_cpf_cnpj_idx on public.customers (cpf_cnpj) where cpf_cnpj is not null;

alter table public.appointments
  add column primary_customer_id uuid references public.customers(id) on delete restrict,
  add column service_name_snapshot text,
  add column service_description_snapshot text,
  add column base_duration_snapshot integer check (base_duration_snapshot is null or base_duration_snapshot > 0),
  add column buffer_before_snapshot integer check (buffer_before_snapshot is null or buffer_before_snapshot >= 0),
  add column buffer_after_snapshot integer check (buffer_after_snapshot is null or buffer_after_snapshot >= 0),
  add column base_price_snapshot numeric(12,2) check (base_price_snapshot is null or base_price_snapshot >= 0),
  add column variable_price_adjustment numeric(12,2) not null default 0,
  add column extras_total numeric(12,2) not null default 0 check (extras_total >= 0),
  add column coupon_discount numeric(12,2) not null default 0 check (coupon_discount >= 0),
  add column commercial_value numeric(12,2) check (commercial_value is null or commercial_value >= 0),
  add column confirmed_at timestamptz,
  add column completed_at timestamptz,
  add column cancelled_at timestamptz,
  add column cancel_reason text,
  add column no_show_at timestamptz,
  add column attendance_status text not null default 'UNKNOWN'
    check (attendance_status in ('UNKNOWN','CONFIRMED')),
  add column attendance_confirmed_at timestamptz;

create index appointments_primary_customer_idx
  on public.appointments (primary_customer_id)
  where primary_customer_id is not null;

create table public.appointment_participants (
  id uuid primary key default gen_random_uuid(),
  appointment_id uuid not null references public.appointments(id) on delete cascade,
  customer_id uuid references public.customers(id) on delete set null,
  role text not null check (role in ('BOOKER','END_CUSTOMER','PAYER','OPERATIONAL_CONTACT')),
  name_snapshot text not null,
  email_snapshot text,
  phone_snapshot text,
  cpf_cnpj_snapshot text,
  created_at timestamptz not null default now()
);

create index appointment_participants_appointment_idx
  on public.appointment_participants (appointment_id);

create table public.appointment_extras (
  id uuid primary key default gen_random_uuid(),
  appointment_id uuid not null references public.appointments(id) on delete cascade,
  extra_id uuid references public.extras(id) on delete set null,
  name_snapshot text not null,
  unit_price_snapshot numeric(12,2) not null check (unit_price_snapshot >= 0),
  duration_delta_snapshot integer not null default 0 check (duration_delta_snapshot >= 0),
  quantity integer not null default 1 check (quantity > 0),
  total_price numeric(12,2) not null check (total_price >= 0),
  total_duration_delta integer not null default 0 check (total_duration_delta >= 0),
  created_at timestamptz not null default now()
);

create index appointment_extras_appointment_idx
  on public.appointment_extras (appointment_id);

create table public.appointment_answers (
  id uuid primary key default gen_random_uuid(),
  appointment_id uuid not null references public.appointments(id) on delete cascade,
  service_field_id uuid references public.service_fields(id) on delete set null,
  field_key_snapshot text not null,
  label_snapshot text not null,
  value_json jsonb,
  created_at timestamptz not null default now()
);

create index appointment_answers_appointment_idx
  on public.appointment_answers (appointment_id);

create table public.coupons (
  id uuid primary key default gen_random_uuid(),
  code text not null,
  discount_type text not null check (discount_type in ('FIXED','PERCENT')),
  discount_value numeric(12,2) not null check (discount_value > 0),
  valid_from timestamptz,
  valid_until timestamptz,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (discount_type <> 'PERCENT' or discount_value <= 100),
  check (valid_from is null or valid_until is null or valid_until >= valid_from)
);

create unique index coupons_code_lower_uq on public.coupons (lower(code));

create table public.coupon_services (
  coupon_id uuid not null references public.coupons(id) on delete cascade,
  service_id uuid not null references public.services(id) on delete cascade,
  primary key (coupon_id, service_id)
);

create table public.appointment_discounts (
  appointment_id uuid primary key references public.appointments(id) on delete cascade,
  coupon_id uuid references public.coupons(id) on delete set null,
  code_snapshot text not null,
  discount_type_snapshot text not null check (discount_type_snapshot in ('FIXED','PERCENT')),
  discount_value_snapshot numeric(12,2) not null check (discount_value_snapshot > 0),
  calculated_discount_amount numeric(12,2) not null check (calculated_discount_amount >= 0),
  created_at timestamptz not null default now()
);

create table public.payment_transactions (
  id uuid primary key default gen_random_uuid(),
  appointment_id uuid not null references public.appointments(id) on delete restrict,
  transaction_type text not null check (transaction_type in ('CHARGE','REFUND')),
  method text not null check (method in ('PIX','CARD','CASH','TRANSFER','CREDIT','COURTESY','OTHER')),
  provider text not null check (provider in ('MERCADO_PAGO','MANUAL')),
  provider_payment_id text,
  status text not null check (status in ('PENDING','APPROVED','REJECTED','EXPIRED','REFUNDED','PARTIALLY_REFUNDED')),
  contract_amount_settled numeric(12,2) not null default 0 check (contract_amount_settled >= 0),
  payment_discount_amount numeric(12,2) not null default 0 check (payment_discount_amount >= 0),
  cash_amount numeric(12,2) not null default 0 check (cash_amount >= 0),
  parent_transaction_id uuid references public.payment_transactions(id) on delete restrict,
  paid_at timestamptz,
  created_by_admin_id uuid,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (payment_discount_amount <= contract_amount_settled),
  check (
    (transaction_type = 'CHARGE' and parent_transaction_id is null)
    or
    (transaction_type = 'REFUND' and parent_transaction_id is not null)
  )
);

create unique index payment_transactions_provider_payment_uq
  on public.payment_transactions (provider, provider_payment_id)
  where provider_payment_id is not null and transaction_type = 'CHARGE';

create index payment_transactions_appointment_idx
  on public.payment_transactions (appointment_id, created_at);

create table public.integration_jobs (
  id uuid primary key default gen_random_uuid(),
  job_type text not null,
  entity_type text not null,
  entity_id uuid not null,
  entity_version integer check (entity_version is null or entity_version >= 1),
  payload_json jsonb not null default '{}'::jsonb,
  status text not null default 'PENDING'
    check (status in ('PENDING','PROCESSING','SUCCEEDED','FAILED','DISCARDED_STALE')),
  attempt_count integer not null default 0 check (attempt_count >= 0),
  run_after timestamptz not null default now(),
  last_error text,
  idempotency_key text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  processed_at timestamptz
);

create unique index integration_jobs_idempotency_uq
  on public.integration_jobs (idempotency_key);

create index integration_jobs_dispatch_idx
  on public.integration_jobs (run_after, created_at)
  where status = 'PENDING';

create table public.audit_logs (
  id uuid primary key default gen_random_uuid(),
  admin_user_id uuid,
  entity_type text not null,
  entity_id uuid not null,
  action text not null,
  before_json jsonb,
  after_json jsonb,
  origin text not null default 'SYSTEM',
  request_id uuid,
  created_at timestamptz not null default now()
);

create index audit_logs_entity_idx
  on public.audit_logs (entity_type, entity_id, created_at);
