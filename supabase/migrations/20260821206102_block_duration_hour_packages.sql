-- Hour packages cover contracted service time only.
-- Service buffers and PREPEND/APPEND extra time are operational occupancy, not package consumption.

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
  v_required_minutes integer;
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

  if coalesce(v_hold.core_start_at, v_hold.requested_start_at) < v_package.valid_from
     or coalesce(v_hold.core_start_at, v_hold.requested_start_at) >= v_package.valid_until then
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

  v_required_minutes := coalesce(v_hold.contracted_minutes, v_hold.duration_minutes);
  if v_required_minutes is null or v_required_minutes <= 0 then
    raise exception using errcode = 'P0001', message = 'CHECKOUT_HOLD_DURATION_MISSING';
  end if;

  v_required_seconds := v_required_minutes::bigint * 60;

  select timezone into v_timezone
  from public.operation_settings
  where id = 1;

  -- Special-period classification follows the contracted core period, not hidden
  -- buffer or extra preparation time.
  v_local_start := coalesce(v_hold.core_start_at, v_hold.requested_start_at) at time zone v_timezone;
  v_local_end := coalesce(v_hold.core_end_at, v_hold.requested_end_at) at time zone v_timezone;
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

  v_quote := public.calculate_booking_quote_for_duration(
    v_hold.service_id,
    v_hold.service_employee_id,
    v_hold.duration_blocks,
    v_hold.extra_selections,
    v_hold.people_count,
    coalesce(v_hold.core_start_at, v_hold.requested_start_at),
    null
  );

  v_extras := coalesce((v_quote->>'extras_total')::numeric, 0);
  v_people_adjustment := greatest(coalesce((v_quote->>'people_adjustment')::numeric, 0), 0);
  v_cash_due := round(v_extras + v_people_adjustment, 2);
  v_covered_reference := round(v_package.reference_minute_value * v_required_minutes, 2);

  return jsonb_build_object(
    'hour_package_id', v_package.id,
    'required_minutes', v_required_minutes,
    'required_seconds', v_required_seconds,
    'available_minutes', floor(v_available_seconds / 60.0)::bigint,
    'available_seconds', v_available_seconds,
    'covered_minutes', v_required_minutes,
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

comment on function public.calculate_hour_package_quote(uuid,uuid,uuid) is
  'Packages consume only contracted core service time. Buffers and extra schedule phases never consume package balance; extras/people adjustments remain cash.';
