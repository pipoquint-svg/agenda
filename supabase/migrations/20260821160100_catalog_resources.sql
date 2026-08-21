create table public.resources (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  resource_type public.resource_type not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (name)
);

create table public.employees (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  email text,
  phone text,
  is_active boolean not null default true,
  resource_id uuid unique references public.resources(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.categories (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  slug text not null unique,
  sort_order integer not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.services (
  id uuid primary key default gen_random_uuid(),
  category_id uuid references public.categories(id) on delete set null,
  name text not null,
  slug text not null unique,
  short_description text,
  full_description text,
  cover_image_url text,
  base_duration_minutes integer not null check (base_duration_minutes > 0),
  buffer_before_minutes integer not null default 0 check (buffer_before_minutes >= 0),
  buffer_after_minutes integer not null default 0 check (buffer_after_minutes >= 0),
  base_price numeric(12,2) not null default 0 check (base_price >= 0),
  minimum_people integer not null default 1 check (minimum_people >= 1),
  maximum_people integer not null default 1 check (maximum_people >= minimum_people),
  minimum_booking_notice_minutes integer not null default 0 check (minimum_booking_notice_minutes >= 0),
  maximum_booking_horizon_days integer not null default 365 check (maximum_booking_horizon_days > 0),
  confirmation_percentage numeric(5,2) check (confirmation_percentage > 0 and confirmation_percentage <= 100),
  checkout_hold_minutes integer check (checkout_hold_minutes > 0),
  payment_hold_minutes integer check (payment_hold_minutes > 0),
  allow_reschedule boolean not null default true,
  reschedule_min_notice_minutes integer not null default 0 check (reschedule_min_notice_minutes >= 0),
  max_reschedules integer check (max_reschedules is null or max_reschedules >= 0),
  allow_cancel boolean not null default true,
  cancel_min_notice_minutes integer not null default 0 check (cancel_min_notice_minutes >= 0),
  requires_terms boolean not null default false,
  is_active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.service_employees (
  id uuid primary key default gen_random_uuid(),
  service_id uuid not null references public.services(id) on delete cascade,
  employee_id uuid not null references public.employees(id) on delete restrict,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (service_id, employee_id)
);

create table public.service_resources (
  service_id uuid not null references public.services(id) on delete cascade,
  resource_id uuid not null references public.resources(id) on delete restrict,
  is_required boolean not null default true,
  primary key (service_id, resource_id)
);

create table public.extras (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  description text,
  price numeric(12,2) not null default 0 check (price >= 0),
  duration_delta_minutes integer not null default 0 check (duration_delta_minutes >= 0),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.service_extras (
  service_id uuid not null references public.services(id) on delete cascade,
  extra_id uuid not null references public.extras(id) on delete restrict,
  sort_order integer not null default 0,
  is_required boolean not null default false,
  max_quantity integer not null default 1 check (max_quantity > 0),
  primary key (service_id, extra_id)
);

create table public.extra_resources (
  extra_id uuid not null references public.extras(id) on delete cascade,
  resource_id uuid not null references public.resources(id) on delete restrict,
  is_required boolean not null default true,
  primary key (extra_id, resource_id)
);

create table public.service_fields (
  id uuid primary key default gen_random_uuid(),
  service_id uuid not null references public.services(id) on delete cascade,
  field_key text not null,
  label text not null,
  field_type text not null check (field_type in ('TEXT','TEXTAREA','NUMBER','DATE','SELECT','BOOLEAN')),
  help_text text,
  placeholder text,
  is_required boolean not null default false,
  sort_order integer not null default 0,
  options_json jsonb,
  is_active boolean not null default true,
  unique (service_id, field_key)
);

create index services_active_idx on public.services (is_active, sort_order);
create index service_employees_service_idx on public.service_employees (service_id) where is_active;
