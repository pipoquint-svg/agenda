alter table public.hour_packages
  add column total_seconds bigint generated always as (total_minutes::bigint * 60) stored;

alter table public.hour_package_movements
  alter column minutes_delta type numeric(12,2) using minutes_delta::numeric;

alter table public.hour_package_movements
  add column seconds_delta bigint;

alter table public.hour_package_movements disable trigger hour_package_movements_immutable_trg;
update public.hour_package_movements
set seconds_delta = round(minutes_delta * 60)::bigint
where seconds_delta is null;
alter table public.hour_package_movements enable trigger hour_package_movements_immutable_trg;

alter table public.hour_package_movements
  alter column seconds_delta set not null,
  add constraint hour_package_movements_seconds_nonzero_check check (seconds_delta <> 0),
  add constraint hour_package_movements_sign_consistency_check check (
    (minutes_delta > 0 and seconds_delta > 0)
    or (minutes_delta < 0 and seconds_delta < 0)
  );

alter table public.checkout_hour_package_reservations
  add column required_seconds bigint,
  add column surcharge_seconds bigint,
  add column charged_seconds bigint;

update public.checkout_hour_package_reservations
set required_seconds = required_minutes::bigint * 60,
    surcharge_seconds = case
      when is_special_period then round(required_minutes::numeric * 60 * special_surcharge_percent / 100)::bigint
      else 0
    end,
    charged_seconds = required_minutes::bigint * 60 + case
      when is_special_period then round(required_minutes::numeric * 60 * special_surcharge_percent / 100)::bigint
      else 0
    end;

alter table public.checkout_hour_package_reservations
  alter column required_seconds set not null,
  alter column surcharge_seconds set not null,
  alter column charged_seconds set not null,
  add constraint checkout_hour_package_seconds_check check (
    required_seconds > 0
    and surcharge_seconds >= 0
    and charged_seconds = required_seconds + surcharge_seconds
  );

alter table public.appointment_package_usage
  add column required_seconds bigint,
  add column surcharge_seconds bigint,
  add column charged_seconds bigint;

update public.appointment_package_usage
set required_seconds = covered_minutes::bigint * 60,
    surcharge_seconds = case
      when is_special_period then round(covered_minutes::numeric * 60 * special_surcharge_percent / 100)::bigint
      else 0
    end,
    charged_seconds = covered_minutes::bigint * 60 + case
      when is_special_period then round(covered_minutes::numeric * 60 * special_surcharge_percent / 100)::bigint
      else 0
    end;

alter table public.appointment_package_usage
  alter column required_seconds set not null,
  alter column surcharge_seconds set not null,
  alter column charged_seconds set not null,
  add constraint appointment_package_usage_seconds_check check (
    required_seconds > 0
    and surcharge_seconds >= 0
    and charged_seconds = required_seconds + surcharge_seconds
  );

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
    seconds_delta,
    reason,
    created_by_admin_id
  ) values (
    new.id,
    'INITIAL_CREDIT',
    new.total_minutes,
    new.total_seconds,
    'PACKAGE_CREATED',
    new.created_by_admin_id
  );
  return new;
end;
$$;

drop view public.hour_package_balances;

create view public.hour_package_balances as
select
  p.id as hour_package_id,
  p.customer_id,
  p.name,
  p.total_minutes,
  p.total_seconds,
  p.purchased_value,
  p.reference_minute_value,
  (coalesce(sum(m.seconds_delta), 0) / 60)::bigint as ledger_minutes,
  coalesce(sum(m.seconds_delta), 0)::bigint as ledger_seconds,
  (
    (
      coalesce(sum(m.seconds_delta), 0)
      - coalesce((
        select sum(r.charged_seconds)
        from public.checkout_hour_package_reservations r
        where r.hour_package_id = p.id
          and r.status = 'HELD'
      ), 0)
    ) / 60
  )::bigint as available_minutes,
  (
    coalesce(sum(m.seconds_delta), 0)
    - coalesce((
      select sum(r.charged_seconds)
      from public.checkout_hour_package_reservations r
      where r.hour_package_id = p.id
        and r.status = 'HELD'
    ), 0)
  )::bigint as available_seconds,
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
  v_available_seconds bigint;
  v_required_seconds bigint;
  v_surcharge_seconds bigint;
  v_charged_seconds bigint;
  v_extras numeric(12,2);
  v_people_adjustment numeric(12,2);
  v_cash_due numeric(12,2);
  v_covered_reference numeric(12,2);
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

  if v_hold.duration_minutes is null or v_hold.duration_minutes <= 0 then
    raise exception using errcode = 'P0001', message = 'CHECKOUT_HOLD_DURATION_MISSING';
  end if;

  v_required_seconds := v_hold.duration_minutes::bigint * 60;

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

  v_surcharge_seconds := case
    when v_is_special then round(v_required_seconds::numeric * v_package.special_surcharge_percent / 100)::bigint
    else 0
  end;
  v_charged_seconds := v_required_seconds + v_surcharge_seconds;

  select available_seconds into v_available_seconds
  from public.hour_package_balances
  where hour_package_id = v_package.id;

  if coalesce(v_available_seconds, 0) < v_charged_seconds then
    raise exception using errcode = 'P0001', message = 'HOUR_PACKAGE_INSUFFICIENT_BALANCE';
  end if;

  v_quote := public.calculate_booking_quote(
    v_hold.service_id,
    v_hold.service_employee_id,
    v_hold.extra_selections,
    v_hold.people_count,
    v_hold.requested_start_at,
    null
  );

  v_extras := coalesce((v_quote->>'extras_total')::numeric, 0);
  v_people_adjustment := greatest(coalesce((v_quote->>'people_adjustment')::numeric, 0), 0);
  v_cash_due := round(v_extras + v_people_adjustment, 2);
  v_covered_reference := round(v_package.reference_minute_value * v_hold.duration_minutes, 2);

  return jsonb_build_object(
    'hour_package_id', v_package.id,
    'required_minutes', v_hold.duration_minutes,
    'required_seconds', v_required_seconds,
    'available_minutes', floor(v_available_seconds / 60.0)::bigint,
    'available_seconds', v_available_seconds,
    'covered_minutes', v_hold.duration_minutes,
    'uncovered_minutes', 0,
    'package_reference_minute_value', v_package.reference_minute_value,
    'covered_reference_value', v_covered_reference,
    'is_special_period', v_is_special,
    'special_surcharge_percent', case when v_is_special then v_package.special_surcharge_percent else 0 end,
    'surcharge_seconds', v_surcharge_seconds,
    'charged_seconds', v_charged_seconds,
    'special_surcharge_amount', 0,
    'uncovered_time_amount', 0,
    'extras_cash_amount', v_extras,
    'people_cash_amount', v_people_adjustment,
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
    required_seconds,
    surcharge_seconds,
    charged_seconds,
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
    0,
    (v_quote->>'required_seconds')::bigint,
    (v_quote->>'surcharge_seconds')::bigint,
    (v_quote->>'charged_seconds')::bigint,
    (v_quote->>'package_reference_minute_value')::numeric,
    (v_quote->>'covered_reference_value')::numeric,
    (v_quote->>'is_special_period')::boolean,
    (v_quote->>'special_surcharge_percent')::numeric,
    0,
    0,
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
    seconds_delta,
    reason
  ) values (
    v_package.id,
    p_appointment_id,
    'RESERVATION_DEBIT',
    -(v_res.charged_seconds::numeric / 60),
    -v_res.charged_seconds,
    'APPOINTMENT_CONFIRMED'
  ) returning id into v_movement_id;

  insert into public.appointment_package_usage (
    appointment_id,
    hour_package_id,
    covered_minutes,
    uncovered_minutes,
    required_seconds,
    surcharge_seconds,
    charged_seconds,
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
    v_res.required_minutes,
    0,
    v_res.required_seconds,
    v_res.surcharge_seconds,
    v_res.charged_seconds,
    v_res.package_reference_minute_value,
    v_res.covered_reference_value,
    v_res.is_special_period,
    v_res.special_surcharge_percent,
    0,
    0,
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
    'required_seconds', v_res.required_seconds,
    'surcharge_seconds', v_res.surcharge_seconds,
    'charged_seconds', v_res.charged_seconds,
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
    seconds_delta,
    reason,
    created_by_admin_id
  ) values (
    v_usage.hour_package_id,
    p_appointment_id,
    'CANCELLATION_REVERSAL',
    v_usage.charged_seconds::numeric / 60,
    v_usage.charged_seconds,
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