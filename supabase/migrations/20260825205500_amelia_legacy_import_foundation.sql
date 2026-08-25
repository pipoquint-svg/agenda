create table if not exists public.legacy_import_batches (
  id uuid primary key default gen_random_uuid(),
  source text not null,
  source_label text,
  customer_rows integer not null default 0 check (customer_rows >= 0),
  appointment_rows integer not null default 0 check (appointment_rows >= 0),
  source_fingerprint text,
  status text not null default 'PREPARED' check (status in ('PREPARED','IMPORTED','PARTIAL','FAILED')),
  notes text,
  created_at timestamptz not null default now(),
  completed_at timestamptz
);

create unique index if not exists legacy_import_batches_source_fingerprint_uidx
  on public.legacy_import_batches(source, source_fingerprint)
  where source_fingerprint is not null;

create table if not exists public.legacy_customer_sources (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references public.legacy_import_batches(id) on delete restrict,
  source text not null,
  source_key text not null,
  source_row_number integer,
  customer_id uuid references public.customers(id) on delete set null,
  match_method text not null default 'UNMATCHED' check (match_method in ('EMAIL','PHONE','EMAIL_PHONE','CREATED','MANUAL','UNMATCHED','CONFLICT')),
  match_confidence text not null default 'NONE' check (match_confidence in ('HIGH','MEDIUM','LOW','NONE')),
  conflict_code text,
  raw_snapshot jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (source, source_key)
);

create index if not exists legacy_customer_sources_customer_idx
  on public.legacy_customer_sources(customer_id);

create table if not exists public.legacy_appointments (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references public.legacy_import_batches(id) on delete restrict,
  source text not null,
  source_appointment_id text not null,
  legacy_customer_source_id uuid references public.legacy_customer_sources(id) on delete set null,
  customer_id uuid references public.customers(id) on delete set null,
  source_order_id text,
  service_name text,
  starts_at timestamptz,
  ends_at timestamptz,
  duration_minutes integer check (duration_minutes is null or duration_minutes >= 0),
  appointment_status text,
  payment_status text,
  payment_method text,
  total_amount numeric(12,2),
  paid_amount numeric(12,2),
  financially_actionable boolean not null default false,
  reviewed_for_collection boolean not null default false,
  review_notes text,
  raw_payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (source, source_appointment_id),
  check (not financially_actionable or reviewed_for_collection)
);

create index if not exists legacy_appointments_customer_idx
  on public.legacy_appointments(customer_id);
create index if not exists legacy_appointments_starts_at_idx
  on public.legacy_appointments(starts_at);
create index if not exists legacy_appointments_order_idx
  on public.legacy_appointments(source_order_id)
  where source_order_id is not null;

alter table public.legacy_import_batches enable row level security;
alter table public.legacy_customer_sources enable row level security;
alter table public.legacy_appointments enable row level security;

revoke all on public.legacy_import_batches from anon, authenticated;
revoke all on public.legacy_customer_sources from anon, authenticated;
revoke all on public.legacy_appointments from anon, authenticated;

grant all on public.legacy_import_batches to service_role;
grant all on public.legacy_customer_sources to service_role;
grant all on public.legacy_appointments to service_role;

comment on table public.legacy_appointments is
  'Read-only historical appointments imported from legacy systems. Financial data is non-actionable unless explicitly reviewed.';
comment on column public.legacy_appointments.financially_actionable is
  'Must remain false for bulk legacy imports. May only become true after explicit operational review.';
