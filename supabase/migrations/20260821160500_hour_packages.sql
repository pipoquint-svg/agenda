alter table public.operation_settings
  add column hour_package_surcharge_percent numeric(5,2) not null default 15
    check (hour_package_surcharge_percent >= 0 and hour_package_surcharge_percent <= 100);

create table public.customer_hour_packages (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customers(id) on delete restrict,
  name text not null,
  purchased_seconds bigint not null check (purchased_seconds > 0),
  purchase_price numeric(12,2) check (purchase_price is null or purchase_price >= 0),
  valid_from timestamptz not null default now(),
  expires_at timestamptz not null,
  status text not null default 'ACTIVE'
    check (status in ('ACTIVE','EXHAUSTED','EXPIRED','CANCELLED')),
  notes text,
  created_by_admin_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (expires_at > valid_from)
);

create index customer_hour_packages_customer_idx
  on public.customer_hour_packages (customer_id, status, expires_at);

create table public.hour_package_services (
  package_id uuid not null references public.customer_hour_packages(id) on delete cascade,
  service_id uuid not null references public.services(id) on delete cascade,
  primary key (package_id, service_id)
);

create table public.hour_package_adjustments (
  id uuid primary key default gen_random_uuid(),
  package_id uuid not null references public.customer_hour_packages(id) on delete restrict,
  delta_seconds bigint not null check (delta_seconds <> 0),
  reason text not null,
  created_by_admin_id uuid,
  created_at timestamptz not null default now()
);

create index hour_package_adjustments_package_idx
  on public.hour_package_adjustments (package_id, created_at);

create table public.hour_package_usages (
  id uuid primary key default gen_random_uuid(),
  package_id uuid not null references public.customer_hour_packages(id) on delete restrict,
  checkout_hold_id uuid references public.checkout_holds(id) on delete restrict,
  appointment_id uuid references public.appointments(id) on delete restrict,
  status text not null default 'HELD'
    check (status in ('HELD','CONSUMED','RELEASED','REVERSED')),
  base_seconds bigint not null check (base_seconds >= 0),
  surcharge_percent numeric(5,2) not null default 0
    check (surcharge_percent >= 0 and surcharge_percent <= 100),
  surcharge_seconds bigint not null default 0 check (surcharge_seconds >= 0),
  charged_seconds bigint generated always as (base_seconds + surcharge_seconds) stored,
  reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  consumed_at timestamptz,
  released_at timestamptz,
  check (checkout_hold_id is not null or appointment_id is not null),
  check (
    (status = 'HELD' and checkout_hold_id is not null)
    or status <> 'HELD'
  )
);

create unique index hour_package_usages_checkout_hold_uq
  on public.hour_package_usages (package_id, checkout_hold_id)
  where checkout_hold_id is not null;

create index hour_package_usages_package_status_idx
  on public.hour_package_usages (package_id, status);

create index hour_package_usages_appointment_idx
  on public.hour_package_usages (appointment_id)
  where appointment_id is not null;

create or replace function public.hour_package_available_seconds(p_package_id uuid)
returns bigint
language sql
stable
set search_path = public
as $$
  select greatest(
    0,
    p.purchased_seconds
      + coalesce((
          select sum(a.delta_seconds)
          from public.hour_package_adjustments a
          where a.package_id = p.id
        ), 0)
      - coalesce((
          select sum(u.charged_seconds)
          from public.hour_package_usages u
          where u.package_id = p.id
            and u.status in ('HELD','CONSUMED')
        ), 0)
  )::bigint
  from public.customer_hour_packages p
  where p.id = p_package_id;
$$;

create or replace function public.hour_package_surcharge_percent_for_period(
  p_service_employee_id uuid,
  p_start_at timestamptz,
  p_end_at timestamptz
)
returns numeric(5,2)
language plpgsql
stable
set search_path = public
as $$
declare
  v_timezone text;
  v_surcharge numeric(5,2);
  v_local_start timestamp;
  v_local_end timestamp;
  v_dow integer;
  v_inside_standard_hours boolean;
begin
  if p_end_at <= p_start_at then
    raise exception 'invalid package period';
  end if;

  select timezone, hour_package_surcharge_percent
    into v_timezone, v_surcharge
  from public.operation_settings
  where id = 1;

  v_local_start := p_start_at at time zone v_timezone;
  v_local_end := p_end_at at time zone v_timezone;
  v_dow := extract(dow from v_local_start)::integer;

  if v_dow in (0, 6) then
    return v_surcharge;
  end if;

  if v_local_start::date <> v_local_end::date then
    return v_surcharge;
  end if;

  select exists (
    select 1
    from public.availability_rules ar
    where ar.service_employee_id = p_service_employee_id
      and ar.is_active
      and ar.weekday = v_dow
      and ar.start_local_time <= v_local_start::time
      and ar.end_local_time >= v_local_end::time
  ) into v_inside_standard_hours;

  if not v_inside_standard_hours then
    return v_surcharge;
  end if;

  return 0;
end;
$$;
