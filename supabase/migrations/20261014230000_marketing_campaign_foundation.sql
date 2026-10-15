-- BlackSheep Rewards S1: inert, tenant-scoped campaign foundation.
-- No campaigns, coupons, jobs, notifications, operational statuses, or existing rows are changed.
-- Versioned configuration is append-only for the only runtime writer (service_role).
-- Later S2-S6 slices must implement audited admin operations, rule evaluation, and checkout wiring.

create table public.marketing_campaigns (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete restrict,
  campaign_key text not null,
  internal_name text not null,
  public_name text,
  description text,
  state text not null default 'DRAFT'
    check (state in ('DRAFT','SCHEDULED','ACTIVE','PAUSED','ENDED','ARCHIVED')),
  starts_at timestamptz,
  ends_at timestamptz,
  created_by_admin_id uuid references public.admin_users(id) on delete set null,
  updated_by_admin_id uuid references public.admin_users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint marketing_campaign_key_format
    check (campaign_key = lower(btrim(campaign_key))
       and campaign_key ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  constraint marketing_campaign_name_nonempty check (btrim(internal_name) <> ''),
  constraint marketing_campaign_period check (starts_at is null or ends_at is null or ends_at > starts_at),
  constraint marketing_campaign_scope_unique unique (id, tenant_id),
  constraint marketing_campaign_key_unique unique (tenant_id, campaign_key)
);

create table public.marketing_campaign_versions (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  campaign_id uuid not null,
  version_number integer not null check (version_number > 0),
  trigger_kind text not null
    check (trigger_kind in (
      'RENTAL_COMPLETED_FINANCIALLY_CLEARED','BIRTHDAY','FIRST_RENTAL',
      'INACTIVITY','BOOKING_CONFIRMED','MANUAL','CUSTOM'
    )),
  discount_type text not null check (discount_type in ('PERCENT','FIXED')),
  discount_value numeric(12,2) not null check (discount_value > 0),
  discount_scope text not null check (discount_scope in ('SERVICE_ONLY','ORDER_SUBTOTAL')),
  validity_basis text not null check (validity_basis in ('BOOKING_CONFIRMATION','RENTAL_START')),
  validity_days integer not null check (validity_days between 1 and 3650),
  max_uses integer not null default 1 check (max_uses > 0),
  max_uses_per_customer integer not null default 1 check (max_uses_per_customer > 0),
  recurring_after_discounted_rental boolean not null default false,
  applies_to_extras boolean not null default false,
  applies_to_hour_packages boolean not null default false,
  stacking_policy text not null default 'EXCLUSIVE'
    check (stacking_policy in ('EXCLUSIVE','ALLOW_PAYMENT_INCENTIVE')),
  max_discount_amount numeric(12,2) check (max_discount_amount > 0),
  eligibility_rules jsonb not null default '{}'::jsonb
    check (jsonb_typeof(eligibility_rules) = 'object'),
  trigger_rules jsonb not null default '{}'::jsonb
    check (jsonb_typeof(trigger_rules) = 'object'),
  message_rules jsonb not null default '{}'::jsonb
    check (jsonb_typeof(message_rules) = 'object'),
  created_by_admin_id uuid references public.admin_users(id) on delete set null,
  created_at timestamptz not null default now(),
  constraint marketing_campaign_version_pct_limit
    check (discount_type <> 'PERCENT' or discount_value <= 100),
  constraint marketing_campaign_version_scope_fk
    foreign key (campaign_id, tenant_id)
    references public.marketing_campaigns(id, tenant_id) on delete restrict,
  constraint marketing_campaign_version_number_unique
    unique (campaign_id, version_number),
  constraint marketing_campaign_version_scope_unique
    unique (id, campaign_id, tenant_id),
  constraint marketing_campaign_version_extras_scope
    check (discount_scope <> 'SERVICE_ONLY' or not applies_to_extras)
);

-- A composite key is needed to enforce coupon ownership at the database boundary.
-- This adds a uniqueness constraint, not a new business system or a data backfill.
alter table public.coupons add constraint coupons_id_customer_key unique (id, customer_id);

-- Issuance ledger for S4: the immutable campaign version row IS the offer snapshot.
-- Do not duplicate it as unchecked JSON that could contradict the canonical version.
-- S1 does not generate coupons or send messages.
create table public.marketing_campaign_issuances (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  campaign_id uuid not null,
  campaign_version_id uuid not null,
  coupon_id uuid not null unique,
  customer_id uuid not null references public.customers(id) on delete restrict,
  source_appointment_id uuid references public.appointments(id) on delete restrict,
  idempotency_key text not null,
  issued_at timestamptz not null default now(),
  constraint marketing_campaign_issuance_key_nonempty
    check (length(btrim(idempotency_key)) between 8 and 256),
  constraint marketing_campaign_issuance_version_fk
    foreign key (campaign_version_id, campaign_id, tenant_id)
    references public.marketing_campaign_versions(id, campaign_id, tenant_id)
    on delete restrict,
  constraint marketing_campaign_issuance_coupon_customer_fk
    foreign key (coupon_id, customer_id)
    references public.coupons(id, customer_id) on delete restrict,
  constraint marketing_campaign_issuance_idempotency_unique
    unique (campaign_id, idempotency_key)
);

-- Audit envelope: actual audited writes/transition authorization belong to S2.
create table public.marketing_campaign_audit_events (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  campaign_id uuid not null,
  actor_admin_id uuid references public.admin_users(id) on delete set null,
  event_kind text not null
    check (event_kind in (
      'CREATED','VERSION_CREATED','SCHEDULED','ACTIVATED','PAUSED',
      'RESUMED','ENDED','ARCHIVED','ISSUANCE_LINKED','REVOKED'
    )),
  before_snapshot jsonb,
  after_snapshot jsonb,
  reason text,
  created_at timestamptz not null default now(),
  constraint marketing_campaign_audit_fk
    foreign key (campaign_id, tenant_id)
    references public.marketing_campaigns(id, tenant_id) on delete restrict,
  constraint marketing_campaign_audit_snapshots
    check ((before_snapshot is null or jsonb_typeof(before_snapshot) = 'object')
       and (after_snapshot is null or jsonb_typeof(after_snapshot) = 'object'))
);

create index marketing_campaigns_tenant_state_idx
  on public.marketing_campaigns(tenant_id, state);
create index marketing_campaign_versions_tenant_campaign_idx
  on public.marketing_campaign_versions(tenant_id, campaign_id, version_number desc);
create index marketing_campaign_issuances_customer_idx
  on public.marketing_campaign_issuances(customer_id, issued_at desc);
create index marketing_campaign_issuances_version_idx
  on public.marketing_campaign_issuances(campaign_version_id, campaign_id, tenant_id);
create index marketing_campaign_issuances_origin_idx
  on public.marketing_campaign_issuances(source_appointment_id)
  where source_appointment_id is not null;
create index marketing_campaign_audit_events_campaign_idx
  on public.marketing_campaign_audit_events(campaign_id, created_at desc);

-- Private, service-only foundation. No policies expose these tables to browser roles.
alter table public.marketing_campaigns enable row level security;
alter table public.marketing_campaign_versions enable row level security;
alter table public.marketing_campaign_issuances enable row level security;
alter table public.marketing_campaign_audit_events enable row level security;

revoke all on public.marketing_campaigns,
  public.marketing_campaign_versions,
  public.marketing_campaign_issuances,
  public.marketing_campaign_audit_events
  from public, anon, authenticated, service_role;

-- Fail closed until S2/S4 provide audited, authorized transactional write endpoints.
-- SELECT access is for internal diagnostics; even INSERT could create an ACTIVE
-- campaign or fabricate an issuance without an audit trail.
grant select on public.marketing_campaigns,
  public.marketing_campaign_versions,
  public.marketing_campaign_issuances,
  public.marketing_campaign_audit_events to service_role;

comment on table public.marketing_campaigns is
  'S1: inert tenant-scoped campaign catalogue; no automated activation or issuance.';
comment on table public.marketing_campaign_versions is
  'S1: append-only typed offer revisions are the canonical immutable offer snapshots; S2 must enforce audited publication.';
comment on table public.marketing_campaign_issuances is
  'S1: future idempotent linkage to an immutable offer version and exact coupon owner; no coupons are created by this migration.';
comment on column public.marketing_campaign_versions.validity_basis is
  'BOOKING_CONFIRMATION checks new booking confirmation within validity_days; RENTAL_START checks the rental start. S5 must wire this to checkout.';
comment on column public.marketing_campaign_versions.recurring_after_discounted_rental is
  'If enabled by an S3/S4 evaluator, a rental that redeemed an earlier reward remains eligible to generate a new reward.';
