-- PR-05 tenant foundation: additive only. Existing domain ownership and runtime
-- behavior remain unchanged until later tenant ownership/security gates.

create table public.tenants (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  slug text not null,
  status text not null default 'ACTIVE',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint tenants_slug_normalized check (
    slug = lower(btrim(slug))
    and slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'
  ),
  constraint tenants_status_valid check (status in ('ACTIVE', 'SUSPENDED', 'ARCHIVED')),
  constraint tenants_slug_unique unique (slug)
);

create table public.tenant_members (
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null,
  status text not null default 'ACTIVE',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint tenant_members_role_valid check (role in ('OWNER', 'ADMIN')),
  constraint tenant_members_status_valid check (status in ('ACTIVE', 'INACTIVE')),
  constraint tenant_members_tenant_user_unique unique (tenant_id, user_id)
);

create index tenant_members_user_id_idx on public.tenant_members(user_id);

create table public.tenant_settings (
  tenant_id uuid primary key references public.tenants(id) on delete cascade,
  config jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint tenant_settings_config_object check (jsonb_typeof(config) = 'object')
);

create table public.tenant_capabilities (
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  capability_key text not null,
  enabled boolean not null default false,
  config jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint tenant_capabilities_key_normalized check (
    capability_key = lower(btrim(capability_key))
    and capability_key ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'
  ),
  constraint tenant_capabilities_config_object check (jsonb_typeof(config) = 'object'),
  constraint tenant_capabilities_tenant_key_unique unique (tenant_id, capability_key)
);

-- Closed by default: tenant authorization is introduced in PR-07, not by direct
-- table access in this foundation migration. service_role remains the explicit
-- internal/bootstrap boundary.
alter table public.tenants enable row level security;
alter table public.tenant_members enable row level security;
alter table public.tenant_settings enable row level security;
alter table public.tenant_capabilities enable row level security;

revoke all privileges on table public.tenants from public, anon, authenticated;
revoke all privileges on table public.tenant_members from public, anon, authenticated;
revoke all privileges on table public.tenant_settings from public, anon, authenticated;
revoke all privileges on table public.tenant_capabilities from public, anon, authenticated;

grant select, insert, update, delete, truncate, references, trigger, maintain
  on table public.tenants to service_role;
grant select, insert, update, delete, truncate, references, trigger, maintain
  on table public.tenant_members to service_role;
grant select, insert, update, delete, truncate, references, trigger, maintain
  on table public.tenant_settings to service_role;
grant select, insert, update, delete, truncate, references, trigger, maintain
  on table public.tenant_capabilities to service_role;

-- Stable initial organization. This UUID is canonical seed data, not a user or
-- browser-provided tenant selector. operation_scope remains an internal dimension.
insert into public.tenants (id, name, slug, status)
values ('8fba3c57-c0e6-4a37-b7d3-4cf41e5fb65f', 'BlackSheep Studio', 'blacksheep', 'ACTIVE')
on conflict (slug) do nothing;

insert into public.tenant_settings (tenant_id)
select t.id
from public.tenants t
where t.slug = 'blacksheep'
on conflict (tenant_id) do nothing;

-- Bootstrap only current canonical administrative identities. No Auth ID is
-- hardcoded and operational/finance roles receive no tenant membership yet.
insert into public.tenant_members (tenant_id, user_id, role, status)
select
  t.id,
  au.auth_user_id,
  case au.role when 'OWNER' then 'OWNER' else 'ADMIN' end,
  'ACTIVE'
from public.tenants t
join public.admin_users au
  on au.is_active
 and au.role in ('OWNER', 'ADMIN')
where t.slug = 'blacksheep'
on conflict (tenant_id, user_id) do update
set role = excluded.role,
    status = excluded.status,
    updated_at = now();

comment on table public.tenants is
  'PR-05 additive organization root. Existing domain tables remain unscoped until PR-06.';
comment on table public.tenant_members is
  'PR-05 authenticated-user membership root. Bootstrap is derived only from active admin_users OWNER/ADMIN identities.';
comment on table public.tenant_settings is
  'PR-05 empty foundation settings container; operation_settings remains legacy single-tenant compatibility.';
comment on table public.tenant_capabilities is
  'PR-05 capability registry foundation; no plan or runtime behavior is enforced here.';
