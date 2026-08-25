-- V1 pre-production data preparation only.
-- No existing behavior is moved behind a feature flag in this phase.

create table if not exists public.feature_flags (
  id uuid primary key default gen_random_uuid(),
  key text not null,
  environment_scope text not null,
  enabled boolean not null default false,
  owner text not null,
  removal_due_at date not null,
  description text null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint feature_flags_key_nonempty check (btrim(key) <> ''),
  constraint feature_flags_owner_nonempty check (btrim(owner) <> ''),
  constraint feature_flags_environment_nonempty check (btrim(environment_scope) <> ''),
  constraint feature_flags_key_environment_unique unique (key, environment_scope)
);

comment on table public.feature_flags is
  'Time-bounded feature flags. Owner and planned removal date are mandatory. V1 pre-production provides read-only consumption only.';

alter table public.feature_flags enable row level security;
revoke all on table public.feature_flags from anon, authenticated;

create or replace function public.read_feature_flag(
  p_key text,
  p_environment_scope text
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((
    select ff.enabled
    from public.feature_flags ff
    where ff.key = p_key
      and ff.environment_scope = p_environment_scope
    limit 1
  ), false);
$$;

revoke all on function public.read_feature_flag(text, text) from public;
grant execute on function public.read_feature_flag(text, text) to service_role;
