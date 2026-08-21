alter table public.availability_rules
  add column availability_class text not null default 'REGULAR'
    check (availability_class in ('REGULAR','SPECIAL'));

alter table public.customer_time_packages
  alter column purchase_amount set not null,
  add constraint customer_time_packages_purchase_amount_positive
    check (purchase_amount > 0),
  add column special_time_surcharge_percent numeric(5,2) not null default 15
    check (special_time_surcharge_percent >= 0 and special_time_surcharge_percent <= 100);

alter table public.time_package_usages
  add column covered_value_snapshot numeric(12,2) not null default 0
    check (covered_value_snapshot >= 0),
  add column surcharge_percent_snapshot numeric(5,2) not null default 0
    check (surcharge_percent_snapshot >= 0 and surcharge_percent_snapshot <= 100),
  add column surcharge_amount_snapshot numeric(12,2) not null default 0
    check (surcharge_amount_snapshot >= 0),
  add column extras_cash_amount_snapshot numeric(12,2) not null default 0
    check (extras_cash_amount_snapshot >= 0),
  add column cash_due_snapshot numeric(12,2) not null default 0
    check (cash_due_snapshot >= 0);

alter table public.appointments
  add column time_package_minutes_used integer
    check (time_package_minutes_used is null or time_package_minutes_used > 0),
  add column time_package_covered_value numeric(12,2) not null default 0
    check (time_package_covered_value >= 0),
  add column time_package_surcharge_amount numeric(12,2) not null default 0
    check (time_package_surcharge_amount >= 0),
  add column time_package_cash_due numeric(12,2) not null default 0
    check (time_package_cash_due >= 0);

create or replace function public.calculate_time_package_quote(
  p_package_id uuid,
  p_required_minutes integer,
  p_start_at timestamptz,
  p_availability_class text,
  p_extras_cash_amount numeric default 0
)
returns table (
  covered_value numeric,
  surcharge_percent numeric,
  surcharge_amount numeric,
  extras_cash_amount numeric,
  cash_due numeric,
  is_special_time boolean
)
language plpgsql
stable
set search_path = public
as $$
declare
  v_package public.customer_time_packages%rowtype;
  v_local_start timestamp without time zone;
  v_is_weekend boolean;
  v_is_special boolean;
begin
  if p_required_minutes <= 0 then
    raise exception 'INVALID_PACKAGE_MINUTES' using errcode = 'P0001';
  end if;

  if p_availability_class not in ('REGULAR','SPECIAL') then
    raise exception 'INVALID_AVAILABILITY_CLASS' using errcode = 'P0001';
  end if;

  if p_extras_cash_amount < 0 then
    raise exception 'INVALID_EXTRAS_AMOUNT' using errcode = 'P0001';
  end if;

  select * into v_package
  from public.customer_time_packages
  where id = p_package_id;

  if not found then
    raise exception 'TIME_PACKAGE_NOT_FOUND' using errcode = 'P0001';
  end if;

  v_local_start := p_start_at at time zone 'America/Sao_Paulo';
  v_is_weekend := extract(isodow from v_local_start) in (6,7);
  v_is_special := v_is_weekend or p_availability_class = 'SPECIAL';

  covered_value := round(
    (v_package.purchase_amount * p_required_minutes::numeric) / v_package.total_minutes::numeric,
    2
  );

  surcharge_percent := case
    when v_is_special then v_package.special_time_surcharge_percent
    else 0
  end;

  surcharge_amount := round(covered_value * surcharge_percent / 100, 2);
  extras_cash_amount := round(p_extras_cash_amount, 2);
  cash_due := surcharge_amount + extras_cash_amount;
  is_special_time := v_is_special;

  return next;
end;
$$;

create or replace function public.reserve_time_package_minutes(
  p_package_id uuid,
  p_checkout_hold_id uuid,
  p_required_minutes integer,
  p_start_at timestamptz,
  p_availability_class text,
  p_extras_cash_amount numeric default 0
)
returns public.time_package_usages
language plpgsql
security definer
set search_path = public
as $$
declare
  v_package public.customer_time_packages%rowtype;
  v_available integer;
  v_quote record;
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

  select * into v_quote
  from public.calculate_time_package_quote(
    p_package_id,
    p_required_minutes,
    p_start_at,
    p_availability_class,
    p_extras_cash_amount
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
    p_required_minutes,
    'HELD',
    v_quote.covered_value,
    v_quote.surcharge_percent,
    v_quote.surcharge_amount,
    v_quote.extras_cash_amount,
    v_quote.cash_due
  )
  returning * into v_usage;

  return v_usage;
end;
$$;
