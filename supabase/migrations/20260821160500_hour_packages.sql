alter table public.operation_settings
  add column hour_package_surcharge_percent numeric(5,2) not null default 15
    check (hour_package_surcharge_percent >= 0 and hour_package_surcharge_percent <= 100);

alter table public.extras
  add column hour_package_covers_price boolean not null default false;

alter table public.appointments
  add column hour_package_discount_amount numeric(12,2) not null default 0
    check (hour_package_discount_amount >= 0);

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

create unique index hour_package_usages_active_checkout_hold_uq
  on public.hour_package_usages (checkout_hold_id)
  where checkout_hold_id is not null and status = 'HELD';

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
    raise exception using errcode = 'P0001', message = 'INVALID_PACKAGE_PERIOD';
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

create or replace function public.reserve_hour_package_usage(
  p_package_id uuid,
  p_checkout_hold_id uuid,
  p_customer_id uuid
)
returns table (
  usage_id uuid,
  base_seconds bigint,
  surcharge_percent numeric(5,2),
  surcharge_seconds bigint,
  charged_seconds bigint,
  available_after_seconds bigint
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_hold public.checkout_holds%rowtype;
  v_package public.customer_hour_packages%rowtype;
  v_existing public.hour_package_usages%rowtype;
  v_base_seconds bigint;
  v_surcharge_percent numeric(5,2);
  v_surcharge_seconds bigint;
  v_charged_seconds bigint;
  v_available bigint;
  v_usage_id uuid;
begin
  select * into v_hold
  from public.checkout_holds
  where id = p_checkout_hold_id
  for update;

  if not found or v_hold.status <> 'ACTIVE' or v_hold.expires_at <= now() then
    raise exception using errcode = 'P0001', message = 'CHECKOUT_HOLD_EXPIRED';
  end if;

  select * into v_package
  from public.customer_hour_packages
  where id = p_package_id
  for update;

  if not found or v_package.customer_id <> p_customer_id then
    raise exception using errcode = 'P0001', message = 'HOUR_PACKAGE_NOT_ELIGIBLE';
  end if;

  if v_package.status <> 'ACTIVE' then
    raise exception using errcode = 'P0001', message = 'HOUR_PACKAGE_NOT_ELIGIBLE';
  end if;

  if v_hold.requested_start_at < v_package.valid_from
     or v_hold.requested_start_at >= v_package.expires_at then
    raise exception using errcode = 'P0001', message = 'HOUR_PACKAGE_EXPIRED';
  end if;

  if not exists (
    select 1
    from public.hour_package_services ps
    where ps.package_id = v_package.id
      and ps.service_id = v_hold.service_id
  ) then
    raise exception using errcode = 'P0001', message = 'HOUR_PACKAGE_NOT_ELIGIBLE';
  end if;

  select * into v_existing
  from public.hour_package_usages u
  where u.checkout_hold_id = v_hold.id
    and u.status = 'HELD'
  limit 1;

  if found then
    if v_existing.package_id <> v_package.id then
      raise exception using errcode = 'P0001', message = 'CHECKOUT_HOLD_ALREADY_HAS_PACKAGE';
    end if;

    return query
      select
        v_existing.id,
        v_existing.base_seconds,
        v_existing.surcharge_percent,
        v_existing.surcharge_seconds,
        v_existing.charged_seconds,
        public.hour_package_available_seconds(v_package.id);
    return;
  end if;

  v_base_seconds := extract(epoch from (v_hold.requested_end_at - v_hold.requested_start_at))::bigint;
  v_surcharge_percent := public.hour_package_surcharge_percent_for_period(
    v_hold.service_employee_id,
    v_hold.requested_start_at,
    v_hold.requested_end_at
  );
  v_surcharge_seconds := round(v_base_seconds::numeric * v_surcharge_percent / 100)::bigint;
  v_charged_seconds := v_base_seconds + v_surcharge_seconds;
  v_available := public.hour_package_available_seconds(v_package.id);

  if v_available < v_charged_seconds then
    raise exception using errcode = 'P0001', message = 'HOUR_PACKAGE_INSUFFICIENT_BALANCE';
  end if;

  insert into public.hour_package_usages (
    package_id,
    checkout_hold_id,
    status,
    base_seconds,
    surcharge_percent,
    surcharge_seconds,
    reason
  ) values (
    v_package.id,
    v_hold.id,
    'HELD',
    v_base_seconds,
    v_surcharge_percent,
    v_surcharge_seconds,
    'Checkout hold package reservation'
  )
  returning id into v_usage_id;

  return query
    select
      v_usage_id,
      v_base_seconds,
      v_surcharge_percent,
      v_surcharge_seconds,
      v_charged_seconds,
      public.hour_package_available_seconds(v_package.id);
end;
$$;

create or replace function public.release_hour_package_usage(
  p_checkout_hold_id uuid,
  p_reason text default 'Checkout hold released'
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
begin
  update public.hour_package_usages
  set status = 'RELEASED',
      reason = coalesce(p_reason, reason),
      released_at = now(),
      updated_at = now()
  where checkout_hold_id = p_checkout_hold_id
    and status = 'HELD';

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

create or replace function public.consume_hour_package_usage(
  p_checkout_hold_id uuid,
  p_appointment_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_usage_id uuid;
begin
  update public.hour_package_usages
  set status = 'CONSUMED',
      appointment_id = p_appointment_id,
      consumed_at = now(),
      updated_at = now()
  where checkout_hold_id = p_checkout_hold_id
    and status = 'HELD'
  returning id into v_usage_id;

  return v_usage_id;
end;
$$;

revoke all on function public.reserve_hour_package_usage(uuid, uuid, uuid) from public, anon, authenticated;
revoke all on function public.release_hour_package_usage(uuid, text) from public, anon, authenticated;
revoke all on function public.consume_hour_package_usage(uuid, uuid) from public, anon, authenticated;

grant execute on function public.reserve_hour_package_usage(uuid, uuid, uuid) to service_role;
grant execute on function public.release_hour_package_usage(uuid, text) to service_role;
grant execute on function public.consume_hour_package_usage(uuid, uuid) to service_role;
