alter table public.checkout_holds
  add column primary_customer_id uuid references public.customers(id) on delete restrict;

create table public.hour_packages (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customers(id) on delete restrict,
  name text not null,
  total_minutes integer not null check (total_minutes > 0),
  purchased_value numeric(12,2) not null check (purchased_value > 0),
  reference_minute_value numeric(16,6) generated always as (purchased_value / total_minutes::numeric) stored,
  valid_from timestamptz not null,
  valid_until timestamptz not null,
  status text not null default 'ACTIVE' check (status in ('ACTIVE','EXHAUSTED','EXPIRED','CANCELLED')),
  special_surcharge_percent numeric(5,2) not null default 15 check (special_surcharge_percent >= 0 and special_surcharge_percent <= 100),
  standard_start_local_time time without time zone not null,
  standard_end_local_time time without time zone not null,
  notes text,
  created_by_admin_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (valid_until > valid_from),
  check (standard_end_local_time > standard_start_local_time)
);

create index hour_packages_customer_active_idx
  on public.hour_packages (customer_id, valid_until)
  where status = 'ACTIVE';

create table public.hour_package_services (
  hour_package_id uuid not null references public.hour_packages(id) on delete cascade,
  service_id uuid not null references public.services(id) on delete cascade,
  primary key (hour_package_id, service_id)
);

create table public.hour_package_movements (
  id uuid primary key default gen_random_uuid(),
  hour_package_id uuid not null references public.hour_packages(id) on delete restrict,
  appointment_id uuid references public.appointments(id) on delete restrict,
  movement_type text not null check (movement_type in (
    'INITIAL_CREDIT',
    'RESERVATION_DEBIT',
    'CANCELLATION_REVERSAL',
    'DURATION_ADJUSTMENT',
    'ADMIN_ADJUSTMENT'
  )),
  minutes_delta integer not null check (minutes_delta <> 0),
  reason text,
  created_by_admin_id uuid,
  created_at timestamptz not null default now(),
  check (
    (movement_type = 'INITIAL_CREDIT' and minutes_delta > 0 and appointment_id is null)
    or (movement_type = 'RESERVATION_DEBIT' and minutes_delta < 0 and appointment_id is not null)
    or (movement_type = 'CANCELLATION_REVERSAL' and minutes_delta > 0 and appointment_id is not null)
    or (movement_type in ('DURATION_ADJUSTMENT','ADMIN_ADJUSTMENT'))
  )
);

create index hour_package_movements_package_idx
  on public.hour_package_movements (hour_package_id, created_at);

create unique index hour_package_initial_credit_uq
  on public.hour_package_movements (hour_package_id)
  where movement_type = 'INITIAL_CREDIT';

create or replace function public.seed_hour_package_initial_credit()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  insert into public.hour_package_movements (
    hour_package_id,
    movement_type,
    minutes_delta,
    reason,
    created_by_admin_id
  ) values (
    new.id,
    'INITIAL_CREDIT',
    new.total_minutes,
    'PACKAGE_CREATED',
    new.created_by_admin_id
  );
  return new;
end;
$$;

create trigger hour_packages_initial_credit_trg
after insert on public.hour_packages
for each row execute function public.seed_hour_package_initial_credit();

create or replace function public.prevent_hour_package_movement_mutation()
returns trigger
language plpgsql
as $$
begin
  raise exception using errcode = 'P0001', message = 'HOUR_PACKAGE_LEDGER_IS_IMMUTABLE';
end;
$$;

create trigger hour_package_movements_immutable_trg
before update or delete on public.hour_package_movements
for each row execute function public.prevent_hour_package_movement_mutation();

create table public.checkout_hour_package_reservations (
  id uuid primary key default gen_random_uuid(),
  checkout_hold_id uuid not null references public.checkout_holds(id) on delete restrict,
  hour_package_id uuid not null references public.hour_packages(id) on delete restrict,
  required_minutes integer not null check (required_minutes > 0),
  covered_minutes integer not null check (covered_minutes > 0),
  uncovered_minutes integer not null check (uncovered_minutes >= 0),
  package_reference_minute_value numeric(16,6) not null check (package_reference_minute_value > 0),
  covered_reference_value numeric(12,2) not null check (covered_reference_value >= 0),
  is_special_period boolean not null default false,
  special_surcharge_percent numeric(5,2) not null default 0 check (special_surcharge_percent >= 0 and special_surcharge_percent <= 100),
  special_surcharge_amount numeric(12,2) not null default 0 check (special_surcharge_amount >= 0),
  uncovered_time_amount numeric(12,2) not null default 0 check (uncovered_time_amount >= 0),
  extras_cash_amount numeric(12,2) not null default 0 check (extras_cash_amount >= 0),
  cash_due numeric(12,2) not null default 0 check (cash_due >= 0),
  status text not null default 'HELD' check (status in ('HELD','CONSUMED','RELEASED')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  consumed_at timestamptz,
  released_at timestamptz,
  release_reason text,
  check (covered_minutes <= required_minutes),
  check (covered_minutes + uncovered_minutes = required_minutes)
);

create unique index checkout_hour_package_active_hold_uq
  on public.checkout_hour_package_reservations (checkout_hold_id)
  where status = 'HELD';

create index checkout_hour_package_package_idx
  on public.checkout_hour_package_reservations (hour_package_id, status);

create table public.appointment_package_usage (
  id uuid primary key default gen_random_uuid(),
  appointment_id uuid not null unique references public.appointments(id) on delete restrict,
  hour_package_id uuid not null references public.hour_packages(id) on delete restrict,
  covered_minutes integer not null check (covered_minutes > 0),
  uncovered_minutes integer not null default 0 check (uncovered_minutes >= 0),
  package_reference_minute_value numeric(16,6) not null check (package_reference_minute_value > 0),
  covered_reference_value numeric(12,2) not null check (covered_reference_value >= 0),
  is_special_period boolean not null default false,
  special_surcharge_percent numeric(5,2) not null default 0,
  special_surcharge_amount numeric(12,2) not null default 0 check (special_surcharge_amount >= 0),
  uncovered_time_amount numeric(12,2) not null default 0 check (uncovered_time_amount >= 0),
  extras_cash_amount numeric(12,2) not null default 0 check (extras_cash_amount >= 0),
  cash_due numeric(12,2) not null default 0 check (cash_due >= 0),
  debit_movement_id uuid not null references public.hour_package_movements(id) on delete restrict,
  reversal_movement_id uuid references public.hour_package_movements(id) on delete restrict,
  created_at timestamptz not null default now(),
  reversed_at timestamptz
);

create view public.hour_package_balances as
select
  p.id as hour_package_id,
  p.customer_id,
  p.name,
  p.total_minutes,
  p.purchased_value,
  p.reference_minute_value,
  coalesce(sum(m.minutes_delta), 0)::integer as ledger_minutes,
  (
    coalesce(sum(m.minutes_delta), 0)
    - coalesce((
      select sum(r.covered_minutes)
      from public.checkout_hour_package_reservations r
      where r.hour_package_id = p.id
        and r.status = 'HELD'
    ), 0)
  )::integer as available_minutes,
  p.valid_from,
  p.valid_until,
  p.status
from public.hour_packages p
left join public.hour_package_movements m on m.hour_package_id = p.id
group by p.id;

create or replace function public.calculate_hour_package_quote(
  p_hour_package_id uuid,
  p_checkout_hold_id uuid,
  p_customer_id uuid
)
returns jsonb
language plpgsql
stable
set search_path = public
as $$
declare
  v_package public.hour_packages%rowtype;
  v_hold public.checkout_holds%rowtype;
  v_quote jsonb;
  v_available integer;
  v_required integer;
  v_covered integer;
  v_uncovered integer;
  v_extras numeric(12,2);
  v_service_time_value numeric(12,2);
  v_current_minute_value numeric(16,6);
  v_covered_reference numeric(12,2);
  v_uncovered_amount numeric(12,2);
  v_surcharge numeric(12,2);
  v_cash_due numeric(12,2);
  v_timezone text;
  v_local_start timestamp without time zone;
  v_local_end timestamp without time zone;
  v_is_weekend boolean;
  v_is_outside_standard boolean;
  v_is_special boolean;
begin
  select * into v_package
  from public.hour_packages
  where id = p_hour_package_id;

  if not found then
    raise exception using errcode = 'P0001', message = 'HOUR_PACKAGE_NOT_FOUND';
  end if;

  select * into v_hold
  from public.checkout_holds
  where id = p_checkout_hold_id
    and status = 'ACTIVE'
    and expires_at > now();

  if not found then
    raise exception using errcode = 'P0001', message = 'CHECKOUT_HOLD_NOT_ACTIVE';
  end if;

  if v_package.customer_id <> p_customer_id then
    raise exception using errcode = 'P0001', message = 'HOUR_PACKAGE_CUSTOMER_MISMATCH';
  end if;

  if v_package.status <> 'ACTIVE' then
    raise exception using errcode = 'P0001', message = 'HOUR_PACKAGE_NOT_ACTIVE';
  end if;

  if v_hold.requested_start_at < v_package.valid_from or v_hold.requested_start_at >= v_package.valid_until then
    raise exception using errcode = 'P0001', message = 'HOUR_PACKAGE_OUTSIDE_VALIDITY';
  end if;

  if not exists (
    select 1
    from public.hour_package_services hps
    where hps.hour_package_id = v_package.id
      and hps.service_id = v_hold.service_id
  ) then
    raise exception using errcode = 'P0001', message = 'HOUR_PACKAGE_SERVICE_NOT_ELIGIBLE';
  end if;

  select available_minutes into v_available
  from public.hour_package_balances
  where hour_package_id = v_package.id;

  v_required := v_hold.duration_minutes;

  if v_required is null or v_required <= 0 then
    raise exception using errcode = 'P0001', message = 'CHECKOUT_HOLD_DURATION_MISSING';
  end if;

  v_covered := least(v_required, greatest(v_available, 0));

  if v_covered <= 0 then
    raise exception using errcode = 'P0001', message = 'HOUR_PACKAGE_NO_BALANCE';
  end if;

  v_uncovered := v_required - v_covered;

  v_quote := public.calculate_booking_quote(
    v_hold.service_id,
    v_hold.service_employee_id,
    v_hold.extra_selections,
    v_hold.people_count,
    v_hold.requested_start_at,
    null
  );

  v_extras := coalesce((v_quote->>'extras_total')::numeric, 0);
  v_service_time_value := greatest((v_quote->>'commercial_value')::numeric - v_extras, 0);
  v_current_minute_value := case when v_required > 0 then v_service_time_value / v_required else 0 end;
  v_uncovered_amount := round(v_current_minute_value * v_uncovered, 2);
  v_covered_reference := round(v_package.reference_minute_value * v_covered, 2);

  select timezone into v_timezone
  from public.operation_settings
  where id = 1;

  v_local_start := v_hold.requested_start_at at time zone v_timezone;
  v_local_end := v_hold.requested_end_at at time zone v_timezone;
  v_is_weekend := extract(dow from v_local_start)::integer in (0, 6);
  v_is_outside_standard :=
    v_local_start::date <> v_local_end::date
    or v_local_start::time < v_package.standard_start_local_time
    or v_local_end::time > v_package.standard_end_local_time;
  v_is_special := v_is_weekend or v_is_outside_standard;

  v_surcharge := case
    when v_is_special then round(v_covered_reference * v_package.special_surcharge_percent / 100, 2)
    else 0
  end;

  v_cash_due := round(v_uncovered_amount + v_extras + v_surcharge, 2);

  return jsonb_build_object(
    'hour_package_id', v_package.id,
    'required_minutes', v_required,
    'available_minutes', v_available,
    'covered_minutes', v_covered,
    'uncovered_minutes', v_uncovered,
    'package_reference_minute_value', v_package.reference_minute_value,
    'covered_reference_value', v_covered_reference,
    'is_special_period', v_is_special,
    'special_surcharge_percent', case when v_is_special then v_package.special_surcharge_percent else 0 end,
    'special_surcharge_amount', v_surcharge,
    'uncovered_time_amount', v_uncovered_amount,
    'extras_cash_amount', v_extras,
    'cash_due', v_cash_due
  );
end;
$$;

create or replace function public.reserve_hour_package_for_checkout(
  p_hour_package_id uuid,
  p_checkout_hold_id uuid,
  p_customer_id uuid
)
returns jsonb
language plpgsql
volatile
set search_path = public
as $$
declare
  v_package public.hour_packages%rowtype;
  v_hold public.checkout_holds%rowtype;
  v_quote jsonb;
  v_reservation_id uuid;
begin
  select * into v_hold
  from public.checkout_holds
  where id = p_checkout_hold_id
  for update;

  if not found or v_hold.status <> 'ACTIVE' or v_hold.expires_at <= now() then
    raise exception using errcode = 'P0001', message = 'CHECKOUT_HOLD_NOT_ACTIVE';
  end if;

  if v_hold.primary_customer_id is null then
    update public.checkout_holds
    set primary_customer_id = p_customer_id,
        updated_at = now()
    where id = v_hold.id;
  elsif v_hold.primary_customer_id <> p_customer_id then
    raise exception using errcode = 'P0001', message = 'CHECKOUT_CUSTOMER_MISMATCH';
  end if;

  select * into v_package
  from public.hour_packages
  where id = p_hour_package_id
  for update;

  if not found then
    raise exception using errcode = 'P0001', message = 'HOUR_PACKAGE_NOT_FOUND';
  end if;

  if v_package.customer_id <> p_customer_id then
    raise exception using errcode = 'P0001', message = 'HOUR_PACKAGE_CUSTOMER_MISMATCH';
  end if;

  update public.checkout_hour_package_reservations
  set status = 'RELEASED',
      released_at = now(),
      release_reason = 'REPLACED_BY_NEW_PACKAGE_SELECTION',
      updated_at = now()
  where checkout_hold_id = v_hold.id
    and status = 'HELD';

  v_quote := public.calculate_hour_package_quote(
    p_hour_package_id,
    p_checkout_hold_id,
    p_customer_id
  );

  insert into public.checkout_hour_package_reservations (
    checkout_hold_id,
    hour_package_id,
    required_minutes,
    covered_minutes,
    uncovered_minutes,
    package_reference_minute_value,
    covered_reference_value,
    is_special_period,
    special_surcharge_percent,
    special_surcharge_amount,
    uncovered_time_amount,
    extras_cash_amount,
    cash_due
  ) values (
    p_checkout_hold_id,
    p_hour_package_id,
    (v_quote->>'required_minutes')::integer,
    (v_quote->>'covered_minutes')::integer,
    (v_quote->>'uncovered_minutes')::integer,
    (v_quote->>'package_reference_minute_value')::numeric,
    (v_quote->>'covered_reference_value')::numeric,
    (v_quote->>'is_special_period')::boolean,
    (v_quote->>'special_surcharge_percent')::numeric,
    (v_quote->>'special_surcharge_amount')::numeric,
    (v_quote->>'uncovered_time_amount')::numeric,
    (v_quote->>'extras_cash_amount')::numeric,
    (v_quote->>'cash_due')::numeric
  ) returning id into v_reservation_id;

  return v_quote || jsonb_build_object(
    'checkout_hour_package_reservation_id', v_reservation_id,
    'status', 'HELD'
  );
end;
$$;

create or replace function public.consume_hour_package_checkout(
  p_checkout_hold_id uuid,
  p_appointment_id uuid
)
returns jsonb
language plpgsql
volatile
set search_path = public
as $$
declare
  v_res public.checkout_hour_package_reservations%rowtype;
  v_package public.hour_packages%rowtype;
  v_movement_id uuid;
begin
  select * into v_res
  from public.checkout_hour_package_reservations
  where checkout_hold_id = p_checkout_hold_id
    and status = 'HELD'
  for update;

  if not found then
    raise exception using errcode = 'P0001', message = 'HOUR_PACKAGE_RESERVATION_NOT_FOUND';
  end if;

  select * into v_package
  from public.hour_packages
  where id = v_res.hour_package_id
  for update;

  if not exists (
    select 1
    from public.appointments a
    join public.checkout_holds ch on ch.id = p_checkout_hold_id
    where a.id = p_appointment_id
      and ch.primary_customer_id is not null
      and a.primary_customer_id = ch.primary_customer_id
      and ch.primary_customer_id = v_package.customer_id
  ) then
    raise exception using errcode = 'P0001', message = 'HOUR_PACKAGE_APPOINTMENT_CUSTOMER_MISMATCH';
  end if;

  insert into public.hour_package_movements (
    hour_package_id,
    appointment_id,
    movement_type,
    minutes_delta,
    reason
  ) values (
    v_package.id,
    p_appointment_id,
    'RESERVATION_DEBIT',
    -v_res.covered_minutes,
    'APPOINTMENT_CONFIRMED'
  ) returning id into v_movement_id;

  insert into public.appointment_package_usage (
    appointment_id,
    hour_package_id,
    covered_minutes,
    uncovered_minutes,
    package_reference_minute_value,
    covered_reference_value,
    is_special_period,
    special_surcharge_percent,
    special_surcharge_amount,
    uncovered_time_amount,
    extras_cash_amount,
    cash_due,
    debit_movement_id
  ) values (
    p_appointment_id,
    v_package.id,
    v_res.covered_minutes,
    v_res.uncovered_minutes,
    v_res.package_reference_minute_value,
    v_res.covered_reference_value,
    v_res.is_special_period,
    v_res.special_surcharge_percent,
    v_res.special_surcharge_amount,
    v_res.uncovered_time_amount,
    v_res.extras_cash_amount,
    v_res.cash_due,
    v_movement_id
  );

  update public.checkout_hour_package_reservations
  set status = 'CONSUMED',
      consumed_at = now(),
      updated_at = now()
  where id = v_res.id;

  return jsonb_build_object(
    'appointment_id', p_appointment_id,
    'hour_package_id', v_package.id,
    'covered_minutes', v_res.covered_minutes,
    'cash_due', v_res.cash_due,
    'debit_movement_id', v_movement_id
  );
end;
$$;

create or replace function public.reverse_hour_package_usage(
  p_appointment_id uuid,
  p_reason text,
  p_admin_id uuid default null
)
returns uuid
language plpgsql
volatile
set search_path = public
as $$
declare
  v_usage public.appointment_package_usage%rowtype;
  v_reversal_id uuid;
begin
  select * into v_usage
  from public.appointment_package_usage
  where appointment_id = p_appointment_id
  for update;

  if not found then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_PACKAGE_USAGE_NOT_FOUND';
  end if;

  if v_usage.reversal_movement_id is not null then
    return v_usage.reversal_movement_id;
  end if;

  insert into public.hour_package_movements (
    hour_package_id,
    appointment_id,
    movement_type,
    minutes_delta,
    reason,
    created_by_admin_id
  ) values (
    v_usage.hour_package_id,
    p_appointment_id,
    'CANCELLATION_REVERSAL',
    v_usage.covered_minutes,
    p_reason,
    p_admin_id
  ) returning id into v_reversal_id;

  update public.appointment_package_usage
  set reversal_movement_id = v_reversal_id,
      reversed_at = now()
  where id = v_usage.id;

  return v_reversal_id;
end;
$$;

create or replace function public.expire_due_checkout_holds()
returns void
language plpgsql
volatile
set search_path = public
as $$
declare
  v_hold record;
begin
  for v_hold in
    select ch.id
    from public.checkout_holds ch
    where ch.status = 'ACTIVE'
      and ch.expires_at <= now()
    for update skip locked
  loop
    update public.checkout_holds
    set status = 'EXPIRED', updated_at = now()
    where id = v_hold.id;

    update public.resource_allocations
    set status = 'EXPIRED', updated_at = now()
    where checkout_hold_id = v_hold.id
      and status = 'HELD';

    update public.checkout_hour_package_reservations
    set status = 'RELEASED',
        released_at = now(),
        release_reason = 'CHECKOUT_HOLD_EXPIRED',
        updated_at = now()
    where checkout_hold_id = v_hold.id
      and status = 'HELD';
  end loop;
end;
$$;
