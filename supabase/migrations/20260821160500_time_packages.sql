create table public.customer_time_packages (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customers(id) on delete restrict,
  name text not null,
  total_minutes integer not null check (total_minutes > 0),
  valid_from timestamptz not null default now(),
  expires_at timestamptz not null,
  status text not null default 'ACTIVE'
    check (status in ('ACTIVE','EXHAUSTED','EXPIRED','CANCELLED')),
  purchase_amount numeric(12,2) check (purchase_amount is null or purchase_amount >= 0),
  external_payment_note text,
  notes text,
  created_by_admin_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (expires_at > valid_from)
);

create index customer_time_packages_customer_active_idx
  on public.customer_time_packages (customer_id, expires_at)
  where status = 'ACTIVE';

create table public.time_package_services (
  package_id uuid not null references public.customer_time_packages(id) on delete cascade,
  service_id uuid not null references public.services(id) on delete cascade,
  primary key (package_id, service_id)
);

create table public.time_package_usages (
  id uuid primary key default gen_random_uuid(),
  package_id uuid not null references public.customer_time_packages(id) on delete restrict,
  checkout_hold_id uuid references public.checkout_holds(id) on delete restrict,
  appointment_id uuid references public.appointments(id) on delete restrict,
  minutes integer not null check (minutes > 0),
  status text not null default 'HELD'
    check (status in ('HELD','CONSUMED','RELEASED','CANCELLED')),
  held_at timestamptz not null default now(),
  consumed_at timestamptz,
  released_at timestamptz,
  release_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint time_package_usages_owner_check check (
    (checkout_hold_id is not null and appointment_id is null)
    or
    (checkout_hold_id is null and appointment_id is not null)
  )
);

create unique index time_package_usages_active_checkout_hold_uq
  on public.time_package_usages (checkout_hold_id)
  where checkout_hold_id is not null and status = 'HELD';

create unique index time_package_usages_active_appointment_uq
  on public.time_package_usages (appointment_id)
  where appointment_id is not null and status in ('HELD','CONSUMED');

create index time_package_usages_package_idx
  on public.time_package_usages (package_id, status);

create view public.customer_time_package_balances as
select
  p.id as package_id,
  p.customer_id,
  p.name,
  p.total_minutes,
  coalesce(sum(u.minutes) filter (where u.status in ('HELD','CONSUMED')), 0)::integer as reserved_or_consumed_minutes,
  (p.total_minutes - coalesce(sum(u.minutes) filter (where u.status in ('HELD','CONSUMED')), 0))::integer as available_minutes,
  p.valid_from,
  p.expires_at,
  p.status
from public.customer_time_packages p
left join public.time_package_usages u on u.package_id = p.id
group by p.id;

alter table public.appointments
  add column settlement_mode text not null default 'STANDARD'
    check (settlement_mode in ('STANDARD','TIME_PACKAGE')),
  add column time_package_id uuid references public.customer_time_packages(id) on delete restrict,
  add constraint appointments_time_package_mode_check check (
    (settlement_mode = 'STANDARD' and time_package_id is null)
    or
    (settlement_mode = 'TIME_PACKAGE' and time_package_id is not null)
  );

create or replace function public.reserve_time_package_minutes(
  p_package_id uuid,
  p_checkout_hold_id uuid,
  p_required_minutes integer
)
returns public.time_package_usages
language plpgsql
security definer
set search_path = public
as $$
declare
  v_package public.customer_time_packages%rowtype;
  v_available integer;
  v_usage public.time_package_usages%rowtype;
begin
  if p_required_minutes <= 0 then
    raise exception 'INVALID_PACKAGE_MINUTES' using errcode = 'P0001';
  end if;

  select * into v_package
  from public.customer_time_packages
  where id = p_package_id
  for update;

  if not found then
    raise exception 'TIME_PACKAGE_NOT_FOUND' using errcode = 'P0001';
  end if;

  if v_package.status <> 'ACTIVE' then
    raise exception 'TIME_PACKAGE_NOT_ACTIVE' using errcode = 'P0001';
  end if;

  if now() < v_package.valid_from or now() >= v_package.expires_at then
    raise exception 'TIME_PACKAGE_OUTSIDE_VALIDITY' using errcode = 'P0001';
  end if;

  if not exists (
    select 1
    from public.checkout_holds h
    where h.id = p_checkout_hold_id
      and h.status = 'ACTIVE'
      and h.expires_at > now()
  ) then
    raise exception 'CHECKOUT_HOLD_NOT_ACTIVE' using errcode = 'P0001';
  end if;

  select v_package.total_minutes
       - coalesce(sum(u.minutes) filter (where u.status in ('HELD','CONSUMED')), 0)::integer
  into v_available
  from public.time_package_usages u
  where u.package_id = v_package.id;

  if v_available < p_required_minutes then
    raise exception 'TIME_PACKAGE_INSUFFICIENT_BALANCE' using errcode = 'P0001';
  end if;

  insert into public.time_package_usages (
    package_id,
    checkout_hold_id,
    minutes,
    status
  ) values (
    p_package_id,
    p_checkout_hold_id,
    p_required_minutes,
    'HELD'
  )
  returning * into v_usage;

  return v_usage;
end;
$$;

create or replace function public.release_time_package_hold(
  p_checkout_hold_id uuid,
  p_reason text default 'CHECKOUT_HOLD_RELEASED'
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
begin
  update public.time_package_usages
  set status = 'RELEASED',
      released_at = now(),
      release_reason = p_reason,
      updated_at = now()
  where checkout_hold_id = p_checkout_hold_id
    and status = 'HELD';

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;
