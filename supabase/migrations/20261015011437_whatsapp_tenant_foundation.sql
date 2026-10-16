-- WhatsApp tenant foundation. This stores only provider identifiers and governed
-- state; credentials remain in secret management and no provider call is made.
create table public.whatsapp_tenant_integrations (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete restrict,
  provider text not null default 'META_CLOUD',
  waba_id text null,
  status text not null default 'DISCONNECTED',
  embedded_signup_completed_at timestamptz null,
  last_provider_error_code text null,
  last_provider_error_at timestamptz null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint whatsapp_tenant_integrations_provider_check check (provider = 'META_CLOUD'),
  constraint whatsapp_tenant_integrations_status_check check (status in ('DISCONNECTED', 'PENDING_CONNECTION', 'CONNECTED', 'SUSPENDED')),
  constraint whatsapp_tenant_integrations_waba_id_check check (waba_id is null or btrim(waba_id) <> ''),
  constraint whatsapp_tenant_integrations_id_tenant_unique unique (id, tenant_id)
);

create index whatsapp_tenant_integrations_tenant_id_idx
  on public.whatsapp_tenant_integrations(tenant_id);
create unique index whatsapp_tenant_integrations_waba_id_unique
  on public.whatsapp_tenant_integrations(waba_id) where waba_id is not null;

create table public.whatsapp_tenant_phone_numbers (
  id uuid primary key default gen_random_uuid(),
  integration_id uuid not null references public.whatsapp_tenant_integrations(id) on delete restrict,
  phone_number_id text null,
  display_phone_number text null,
  status text not null default 'PENDING_CONNECTION',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint whatsapp_tenant_phone_numbers_status_check check (status in ('PENDING_CONNECTION', 'CONNECTED', 'SUSPENDED')),
  constraint whatsapp_tenant_phone_numbers_id_check check (phone_number_id is null or btrim(phone_number_id) <> '')
);

create index whatsapp_tenant_phone_numbers_integration_id_idx
  on public.whatsapp_tenant_phone_numbers(integration_id);
create unique index whatsapp_tenant_phone_numbers_id_unique
  on public.whatsapp_tenant_phone_numbers(phone_number_id) where phone_number_id is not null;

create table public.whatsapp_template_submissions (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete restrict,
  integration_id uuid not null,
  notification_template_id uuid not null references public.notification_template_configs(id) on delete restrict,
  provider_template_id text null,
  status text not null default 'DRAFT',
  provider_error_code text null,
  provider_error_message text null,
  submitted_at timestamptz null,
  approved_at timestamptz null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint whatsapp_template_submissions_status_check check (status in ('DRAFT', 'PENDING_SUBMISSION', 'PENDING_REVIEW', 'APPROVED', 'REJECTED', 'FAILED')),
  constraint whatsapp_template_submissions_provider_template_id_check check (provider_template_id is null or btrim(provider_template_id) <> ''),
  constraint whatsapp_template_submissions_tenant_template_unique unique (tenant_id, notification_template_id),
  constraint whatsapp_template_submissions_integration_tenant_fkey
    foreign key (integration_id, tenant_id)
    references public.whatsapp_tenant_integrations(id, tenant_id)
    on delete restrict
);

create index whatsapp_template_submissions_integration_id_idx
  on public.whatsapp_template_submissions(integration_id);

alter table public.whatsapp_tenant_integrations enable row level security;
alter table public.whatsapp_tenant_phone_numbers enable row level security;
alter table public.whatsapp_template_submissions enable row level security;

revoke all on table public.whatsapp_tenant_integrations from public, anon, authenticated;
revoke all on table public.whatsapp_tenant_phone_numbers from public, anon, authenticated;
revoke all on table public.whatsapp_template_submissions from public, anon, authenticated;

grant select, insert, update, delete, truncate, references, trigger, maintain
  on table public.whatsapp_tenant_integrations to service_role;
grant select, insert, update, delete, truncate, references, trigger, maintain
  on table public.whatsapp_tenant_phone_numbers to service_role;
grant select, insert, update, delete, truncate, references, trigger, maintain
  on table public.whatsapp_template_submissions to service_role;

comment on table public.whatsapp_tenant_integrations is
  'Canonical provider-identifier and onboarding-state boundary per tenant. Does not store credentials or invoke Meta.';
comment on table public.whatsapp_tenant_phone_numbers is
  'Tenant-owned WhatsApp phone-number identifiers; provider connection is separate from sending.';
comment on table public.whatsapp_template_submissions is
  'Audit state for future Meta template submission. New rows remain DRAFT until an explicitly authorized adapter is implemented.';
