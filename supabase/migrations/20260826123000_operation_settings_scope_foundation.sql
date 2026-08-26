-- Issue #218 phase 1: per-operation settings foundation.
-- Preserve the existing singleton operation_settings contract while adding
-- explicit scoped overrides for SABRINA and BLACKSHEEP.

create table if not exists public.operation_setting_overrides (
  operation_scope text primary key,
  public_name text,
  public_email text,
  public_phone text,
  public_address text,
  public_site_url text,
  timezone text,
  default_currency text,
  checkout_hold_minutes integer,
  payment_hold_minutes integer,
  agency_hold_minutes integer,
  default_confirmation_percentage numeric,
  pix_discount_percent numeric,
  default_slot_interval_minutes integer,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint operation_setting_overrides_scope_ck
    check (operation_scope in ('SABRINA','BLACKSHEEP')),
  constraint operation_setting_overrides_checkout_hold_ck
    check (checkout_hold_minutes is null or checkout_hold_minutes between 1 and 1440),
  constraint operation_setting_overrides_payment_hold_ck
    check (payment_hold_minutes is null or payment_hold_minutes between 1 and 10080),
  constraint operation_setting_overrides_agency_hold_ck
    check (agency_hold_minutes is null or agency_hold_minutes between 1 and 10080),
  constraint operation_setting_overrides_confirmation_ck
    check (default_confirmation_percentage is null or default_confirmation_percentage between 0 and 100),
  constraint operation_setting_overrides_pix_discount_ck
    check (pix_discount_percent is null or pix_discount_percent between 0 and 100),
  constraint operation_setting_overrides_slot_interval_ck
    check (default_slot_interval_minutes is null or default_slot_interval_minutes between 5 and 1440)
);

alter table public.operation_setting_overrides enable row level security;

revoke all on table public.operation_setting_overrides from public, anon, authenticated;
grant select, insert, update, delete on table public.operation_setting_overrides to service_role;

create or replace function public.service_admin_get_operation_settings_v2(
  p_operation_scope text
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with base as (
    select * from public.operation_settings where id = 1
  ), scoped as (
    select * from public.operation_setting_overrides where operation_scope = p_operation_scope
  )
  select jsonb_build_object(
    'operation_scope', p_operation_scope,
    'public_name', coalesce(s.public_name, b.operation_name),
    'public_email', s.public_email,
    'public_phone', s.public_phone,
    'public_address', s.public_address,
    'public_site_url', s.public_site_url,
    'timezone', coalesce(s.timezone, b.timezone),
    'default_currency', coalesce(s.default_currency, b.default_currency),
    'checkout_hold_minutes', coalesce(s.checkout_hold_minutes, b.checkout_hold_minutes),
    'payment_hold_minutes', coalesce(s.payment_hold_minutes, b.payment_hold_minutes),
    'agency_hold_minutes', coalesce(s.agency_hold_minutes, b.agency_hold_minutes),
    'default_confirmation_percentage', coalesce(s.default_confirmation_percentage, b.default_confirmation_percentage),
    'pix_discount_percent', coalesce(s.pix_discount_percent, b.pix_discount_percent),
    'default_slot_interval_minutes', coalesce(s.default_slot_interval_minutes, b.default_slot_interval_minutes),
    'source', jsonb_build_object(
      'base', 'operation_settings:1',
      'override_present', s.operation_scope is not null
    )
  )
  from base b
  left join scoped s on true
  where p_operation_scope in ('SABRINA','BLACKSHEEP');
$$;

revoke all on function public.service_admin_get_operation_settings_v2(text) from public, anon, authenticated;
grant execute on function public.service_admin_get_operation_settings_v2(text) to service_role;

comment on table public.operation_setting_overrides is
  'Per-operation overrides layered over legacy singleton operation_settings. Null means inherit the global value.';
comment on function public.service_admin_get_operation_settings_v2(text) is
  'Resolved settings read model with precedence global operation_settings -> operation scope override.';
