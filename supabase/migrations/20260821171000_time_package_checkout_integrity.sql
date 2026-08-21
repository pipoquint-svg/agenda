alter table public.checkout_holds
  add column customer_id uuid references public.customers(id) on delete restrict,
  add column extra_selections jsonb not null default '[]'::jsonb
    check (jsonb_typeof(extra_selections) = 'array');

create index checkout_holds_customer_idx
  on public.checkout_holds (customer_id)
  where customer_id is not null;

drop function if exists public.reserve_time_package_minutes(uuid, uuid, integer, timestamptz, text, numeric);

create or replace function public.reserve_time_package_minutes(
  p_package_id uuid,
  p_checkout_hold_id uuid
)
returns public.time_package_usages
language plpgsql
security definer
set search_path = public
as $$
declare
  v_package public.customer_time_packages%rowtype;
  v_hold public.checkout_holds%rowtype;
  v_available integer;
  v_required_minutes integer;
  v_timezone text;
  v_local_start_ts timestamp without time zone;
  v_local_end_ts timestamp without time zone;
  v_dow smallint;
  v_local_start_time time without time zone;
  v_local_end_time time without time zone;
  v_availability_matches integer := 0;
  v_has_special boolean := false;
  v_fully_regular boolean := false;
  v_availability_class text;
  v_booking_quote jsonb;
  v_extras_cash_amount numeric(12,2);
  v_package_quote record;
  v_usage public.time_package_usages%rowtype;
begin
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

  select * into v_hold
  from public.checkout_holds
  where id = p_checkout_hold_id
  for update;

  if not found or v_hold.status <> 'ACTIVE' or v_hold.expires_at <= now() then
    raise exception 'CHECKOUT_HOLD_NOT_ACTIVE' using errcode = 'P0001';
  end if;

  if v_hold.customer_id is null or v_hold.customer_id <> v_package.customer_id then
    raise exception 'TIME_PACKAGE_CUSTOMER_MISMATCH' using errcode = 'P0001';
  end if;

  if not exists (
    select 1
    from public.time_package_services tps
    where tps.package_id = v_package.id
      and tps.service_id = v_hold.service_id
  ) then
    raise exception 'TIME_PACKAGE_SERVICE_NOT_ELIGIBLE' using errcode = 'P0001';
  end if;

  v_required_minutes := (
    extract(epoch from (v_hold.requested_end_at - v_hold.requested_start_at)) / 60
  )::integer;

  if v_required_minutes <= 0 then
    raise exception 'INVALID_PACKAGE_MINUTES' using errcode = 'P0001';
  end if;

  select v_package.total_minutes
       - coalesce(sum(u.minutes) filter (where u.status in ('HELD','CONSUMED')), 0)::integer
  into v_available
  from public.time_package_usages u
  where u.package_id = v_package.id;

  if v_available < v_required_minutes then
    raise exception 'TIME_PACKAGE_INSUFFICIENT_BALANCE' using errcode = 'P0001';
  end if;

  select timezone into v_timezone
  from public.operation_settings
  where id = 1;

  v_local_start_ts := v_hold.requested_start_at at time zone v_timezone;
  v_local_end_ts := v_hold.requested_end_at at time zone v_timezone;

  if v_local_start_ts::date <> v_local_end_ts::date then
    raise exception 'TIME_PACKAGE_AVAILABILITY_NOT_CLASSIFIED' using errcode = 'P0001';
  end if;

  v_dow := extract(dow from v_local_start_ts)::smallint;
  v_local_start_time := v_local_start_ts::time;
  v_local_end_time := v_local_end_ts::time;

  select
    count(*)::integer,
    coalesce(bool_or(ar.availability_class = 'SPECIAL'), false),
    coalesce(bool_or(
      ar.availability_class = 'REGULAR'
      and v_local_start_time >= ar.start_local_time
      and v_local_end_time <= ar.end_local_time
    ), false)
  into v_availability_matches, v_has_special, v_fully_regular
  from public.availability_rules ar
  where ar.service_employee_id = v_hold.service_employee_id
    and ar.is_active
    and ar.weekday = v_dow
    and ar.start_local_time < v_local_end_time
    and ar.end_local_time > v_local_start_time;

  if v_availability_matches = 0 then
    raise exception 'TIME_PACKAGE_AVAILABILITY_NOT_CLASSIFIED' using errcode = 'P0001';
  end if;

  v_availability_class := case
    when v_has_special or not v_fully_regular then 'SPECIAL'
    else 'REGULAR'
  end;

  v_booking_quote := public.calculate_booking_quote(
    v_hold.service_id,
    v_hold.service_employee_id,
    v_hold.extra_selections,
    v_hold.people_count,
    v_hold.requested_start_at,
    null
  );

  v_extras_cash_amount := coalesce((v_booking_quote->>'extras_total')::numeric, 0);

  select * into v_package_quote
  from public.calculate_time_package_quote(
    p_package_id,
    v_required_minutes,
    v_hold.requested_start_at,
    v_availability_class,
    v_extras_cash_amount
  );

  insert into public.time_package_usages (
    package_id,
    checkout_hold_id,
    minutes,
    status,
    covered_value_snapshot,
    surcharge_percent_snapshot,
    surcharge_amount_snapshot,
    extras_cash_amount_snapshot,
    cash_due_snapshot
  ) values (
    p_package_id,
    p_checkout_hold_id,
    v_required_minutes,
    'HELD',
    v_package_quote.covered_value,
    v_package_quote.surcharge_percent,
    v_package_quote.surcharge_amount,
    v_package_quote.extras_cash_amount,
    v_package_quote.cash_due
  )
  returning * into v_usage;

  return v_usage;
end;
$$;
