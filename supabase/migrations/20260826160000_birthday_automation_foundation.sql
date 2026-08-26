-- Issue #217 — birthday automation foundation.
-- Expand-only. No scheduler, notification provider, coupon generation, or real-customer action is activated here.

alter table public.customers
  add column if not exists birth_date date null;

comment on column public.customers.birth_date is
  'Canonical customer birth date for birthday automation. Service custom fields must reconcile explicitly; never overwrite silently.';

create table if not exists public.birthday_automation_settings (
  id uuid primary key default gen_random_uuid(),
  operation_scope text not null check (operation_scope in ('SABRINA','BLACKSHEEP')),
  is_active boolean not null default false,
  send_message boolean not null default false,
  generate_coupon boolean not null default false,
  send_on_birthday boolean not null default true,
  days_before integer null check (days_before is null or days_before >= 0),
  coupon_prefix text null,
  coupon_discount_type text null check (coupon_discount_type is null or coupon_discount_type in ('PERCENT','FIXED')),
  coupon_discount_value numeric(12,2) null check (coupon_discount_value is null or coupon_discount_value >= 0),
  coupon_validity_days integer null check (coupon_validity_days is null or coupon_validity_days > 0),
  coupon_max_uses integer null check (coupon_max_uses is null or coupon_max_uses > 0),
  coupon_max_uses_per_customer integer null check (coupon_max_uses_per_customer is null or coupon_max_uses_per_customer > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (operation_scope),
  check (is_active = false or send_message or generate_coupon),
  check (
    generate_coupon = false
    or (
      coupon_prefix is not null
      and btrim(coupon_prefix) <> ''
      and coupon_discount_type is not null
      and coupon_discount_value is not null
      and coupon_validity_days is not null
    )
  )
);

create table if not exists public.birthday_automation_cycles (
  id uuid primary key default gen_random_uuid(),
  operation_scope text not null check (operation_scope in ('SABRINA','BLACKSHEEP')),
  customer_id uuid not null references public.customers(id) on delete cascade,
  birthday_year integer not null check (birthday_year between 2000 and 2200),
  trigger_kind text not null check (trigger_kind in ('BEFORE','BIRTHDAY')),
  target_date date not null,
  coupon_id uuid null references public.coupons(id) on delete set null,
  message_status text null check (message_status is null or message_status in ('PENDING','SENT','FAILED','SKIPPED')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (operation_scope, customer_id, birthday_year, trigger_kind)
);

create index if not exists idx_customers_birth_date
  on public.customers (extract(month from birth_date), extract(day from birth_date))
  where birth_date is not null;

create index if not exists idx_birthday_cycles_target_date
  on public.birthday_automation_cycles(target_date, operation_scope);

alter table public.birthday_automation_settings enable row level security;
alter table public.birthday_automation_cycles enable row level security;

revoke all on public.birthday_automation_settings from public, anon, authenticated;
revoke all on public.birthday_automation_cycles from public, anon, authenticated;
grant select, insert, update, delete on public.birthday_automation_settings to service_role;
grant select, insert, update on public.birthday_automation_cycles to service_role;

insert into public.birthday_automation_settings(operation_scope)
values ('SABRINA'), ('BLACKSHEEP')
on conflict (operation_scope) do nothing;

comment on table public.birthday_automation_settings is
  'Configuration foundation only. Rows are seeded disabled and no runtime reads them in this migration.';
comment on table public.birthday_automation_cycles is
  'Idempotency ledger for one birthday cycle per operation/customer/year/trigger kind. No scheduler is enabled by this migration.';
