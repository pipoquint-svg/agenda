-- Private runtime configuration for the InfinitePay adapter.
--
-- This migration intentionally does not seed or activate any production value.
-- The only public surface is a service-role-only SECURITY DEFINER reader used by
-- Edge Functions. Browser roles cannot read the table or execute the reader.

create table if not exists agenda_internal.payment_provider_runtime_configs (
  provider text primary key,
  handle text not null,
  redirect_url text not null,
  live_links_enabled boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint payment_provider_runtime_configs_provider_check
    check (provider = 'INFINITEPAY'),
  constraint payment_provider_runtime_configs_handle_check
    check (handle ~ '^[A-Za-z0-9._-]{2,80}$'),
  constraint payment_provider_runtime_configs_redirect_url_check
    check (redirect_url ~ '^https://[^[:space:]]+$')
);

alter table agenda_internal.payment_provider_runtime_configs owner to postgres;

revoke all on table agenda_internal.payment_provider_runtime_configs
  from public, anon, authenticated, service_role;

create or replace function public.service_get_infinitepay_runtime_config()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_config jsonb;
begin
  select jsonb_build_object(
    'handle', c.handle,
    'redirect_url', c.redirect_url,
    'live_links_enabled', c.live_links_enabled
  )
  into v_config
  from agenda_internal.payment_provider_runtime_configs c
  where c.provider = 'INFINITEPAY';

  if v_config is null then
    raise exception using
      message = 'INFINITEPAY_RUNTIME_CONFIG_MISSING',
      errcode = 'P0001';
  end if;

  return v_config;
end;
$$;

alter function public.service_get_infinitepay_runtime_config() owner to postgres;
revoke all on function public.service_get_infinitepay_runtime_config()
  from public, anon, authenticated;
grant execute on function public.service_get_infinitepay_runtime_config()
  to service_role;

comment on table agenda_internal.payment_provider_runtime_configs is
  'Private provider runtime state. No direct service_role/browser access; InfinitePay activation is controlled separately from booking-page routing.';

comment on function public.service_get_infinitepay_runtime_config() is
  'Service-role-only reader for the private InfinitePay runtime configuration used by Edge Functions.';
