create table public.checkout_holds (
  id uuid primary key default gen_random_uuid(),
  public_token_hash text not null unique,
  service_id uuid not null references public.services(id) on delete restrict,
  service_employee_id uuid not null references public.service_employees(id) on delete restrict,
  selection_hash text not null,
  people_count integer not null check (people_count >= 1),
  requested_start_at timestamptz not null,
  requested_end_at timestamptz not null,
  status text not null default 'ACTIVE' check (status in ('ACTIVE','PROMOTED','EXPIRED','INVALIDATED')),
  expires_at timestamptz not null,
  promoted_appointment_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (requested_end_at > requested_start_at),
  check (expires_at > created_at)
);

create table public.appointments (
  id uuid primary key default gen_random_uuid(),
  public_code text not null unique,
  service_id uuid not null references public.services(id) on delete restrict,
  service_employee_id uuid not null references public.service_employees(id) on delete restrict,
  status public.appointment_status not null default 'HELD',
  financial_status public.financial_status not null default 'NOT_STARTED',
  start_at timestamptz not null,
  end_at timestamptz not null,
  duration_minutes integer not null check (duration_minutes > 0),
  people_count integer not null check (people_count >= 1),
  hold_expires_at timestamptz,
  version integer not null default 1 check (version >= 1),
  origin text not null default 'PUBLIC' check (origin in ('PUBLIC','ADMIN','AMELIA_MIGRATION')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  check (end_at > start_at)
);

alter table public.checkout_holds
  add constraint checkout_holds_promoted_appointment_fk
  foreign key (promoted_appointment_id)
  references public.appointments(id)
  on delete restrict;

create table public.resource_allocations (
  id uuid primary key default gen_random_uuid(),
  resource_id uuid not null references public.resources(id) on delete restrict,
  appointment_id uuid references public.appointments(id) on delete restrict,
  checkout_hold_id uuid references public.checkout_holds(id) on delete restrict,
  allocation_type public.allocation_type not null,
  status public.allocation_status not null,
  occupied_range tstzrange not null,
  reason text,
  created_by_admin_id uuid,
  external_source text,
  external_calendar_id text,
  external_event_id text,
  external_event_recurring_id text,
  external_event_instance_start timestamptz,
  ignored_by_admin_id uuid,
  ignored_at timestamptz,
  ignore_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (not isempty(occupied_range)),
  check (lower(occupied_range) < upper(occupied_range)),
  check (lower_inc(occupied_range) and not upper_inc(occupied_range)),
  constraint resource_allocations_owner_check check (
    (allocation_type = 'APPOINTMENT' and appointment_id is not null and checkout_hold_id is null)
    or
    (allocation_type = 'CHECKOUT_HOLD' and checkout_hold_id is not null and appointment_id is null)
    or
    (allocation_type in ('MANUAL_BLOCK','EXTERNAL_BLOCK') and appointment_id is null and checkout_hold_id is null)
  ),
  constraint resource_allocations_external_check check (
    allocation_type <> 'EXTERNAL_BLOCK'
    or (external_source is not null and external_calendar_id is not null and external_event_id is not null)
  )
);

alter table public.resource_allocations
  add constraint resource_allocations_no_overlap
  exclude using gist (
    resource_id with =,
    occupied_range with &&
  )
  where (status in ('HELD','AWAITING_PAYMENT','CONFIRMED','BLOCKED','EXTERNAL_ACTIVE'));

create unique index resource_allocations_external_event_resource_uq
  on public.resource_allocations (
    external_source,
    external_calendar_id,
    external_event_id,
    resource_id,
    coalesce(external_event_instance_start, '-infinity'::timestamptz)
  )
  where (allocation_type = 'EXTERNAL_BLOCK');

create index resource_allocations_appointment_idx
  on public.resource_allocations (appointment_id)
  where appointment_id is not null;

create index resource_allocations_checkout_hold_idx
  on public.resource_allocations (checkout_hold_id)
  where checkout_hold_id is not null;

create index resource_allocations_resource_idx
  on public.resource_allocations (resource_id);

create index checkout_holds_expiry_idx
  on public.checkout_holds (expires_at)
  where status = 'ACTIVE';

create index appointments_start_idx
  on public.appointments (start_at);
