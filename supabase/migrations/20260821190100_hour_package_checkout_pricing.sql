alter table public.hour_package_usages
  add column package_discount_amount numeric(12,2) not null default 0
    check (package_discount_amount >= 0),
  add column remaining_commercial_value numeric(12,2) not null default 0
    check (remaining_commercial_value >= 0);

create or replace function public.hour_package_monetary_breakdown(p_checkout_hold_id uuid)
returns table (
  package_discount_amount numeric(12,2),
  remaining_commercial_value numeric(12,2)
)
language plpgsql
stable
set search_path = public
as $$
declare
  v_hold public.checkout_holds%rowtype;
  v_quote jsonb;
  v_service_component numeric(12,2);
  v_covered_extras numeric(12,2);
  v_discount numeric(12,2);
  v_remaining numeric(12,2);
begin
  select * into v_hold
  from public.checkout_holds
  where id = p_checkout_hold_id;

  if not found then
    raise exception using errcode = 'P0001', message = 'CHECKOUT_HOLD_NOT_FOUND';
  end if;

  v_quote := public.calculate_booking_quote(
    v_hold.service_id,
    v_hold.service_employee_id,
    v_hold.extra_selections,
    v_hold.people_count,
    v_hold.requested_start_at,
    null
  );

  v_service_component := greatest(
    (v_quote->>'base_price')::numeric + (v_quote->>'day_time_adjustment')::numeric,
    0
  );

  select coalesce(sum(e.price * x.quantity), 0)
  into v_covered_extras
  from jsonb_to_recordset(coalesce(v_hold.extra_selections, '[]'::jsonb))
    as x(extra_id uuid, quantity integer)
  join public.extras e on e.id = x.extra_id
  where e.hour_package_covers_price;

  v_discount := round(least(
    (v_quote->>'commercial_value')::numeric,
    greatest(v_service_component + v_covered_extras, 0)
  ), 2);

  v_remaining := round(greatest(
    (v_quote->>'commercial_value')::numeric - v_discount,
    0
  ), 2);

  package_discount_amount := v_discount;
  remaining_commercial_value := v_remaining;
  return next;
end;
$$;

drop function public.reserve_hour_package_usage(uuid, uuid, uuid);

create function public.reserve_hour_package_usage(
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
  available_after_seconds bigint,
  package_discount_amount numeric(12,2),
  remaining_commercial_value numeric(12,2)
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
  v_package_discount numeric(12,2);
  v_remaining numeric(12,2);
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

  if not found or v_package.customer_id <> p_customer_id or v_package.status <> 'ACTIVE' then
    raise exception using errcode = 'P0001', message = 'HOUR_PACKAGE_NOT_ELIGIBLE';
  end if;

  if v_hold.requested_start_at < v_package.valid_from or v_hold.requested_start_at >= v_package.expires_at then
    raise exception using errcode = 'P0001', message = 'HOUR_PACKAGE_EXPIRED';
  end if;

  if not exists (
    select 1 from public.hour_package_services ps
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
      select v_existing.id, v_existing.base_seconds, v_existing.surcharge_percent,
             v_existing.surcharge_seconds, v_existing.charged_seconds,
             public.hour_package_available_seconds(v_package.id),
             v_existing.package_discount_amount, v_existing.remaining_commercial_value;
    return;
  end if;

  v_base_seconds := extract(epoch from (v_hold.requested_end_at - v_hold.requested_start_at))::bigint;
  v_surcharge_percent := public.hour_package_surcharge_percent_for_period(
    v_hold.service_employee_id, v_hold.requested_start_at, v_hold.requested_end_at
  );
  v_surcharge_seconds := round(v_base_seconds::numeric * v_surcharge_percent / 100)::bigint;
  v_charged_seconds := v_base_seconds + v_surcharge_seconds;
  v_available := public.hour_package_available_seconds(v_package.id);

  if v_available < v_charged_seconds then
    raise exception using errcode = 'P0001', message = 'HOUR_PACKAGE_INSUFFICIENT_BALANCE';
  end if;

  select b.package_discount_amount, b.remaining_commercial_value
  into v_package_discount, v_remaining
  from public.hour_package_monetary_breakdown(v_hold.id) b;

  insert into public.hour_package_usages (
    package_id, checkout_hold_id, status, base_seconds,
    surcharge_percent, surcharge_seconds, reason,
    package_discount_amount, remaining_commercial_value
  ) values (
    v_package.id, v_hold.id, 'HELD', v_base_seconds,
    v_surcharge_percent, v_surcharge_seconds, 'Checkout hold package reservation',
    v_package_discount, v_remaining
  ) returning id into v_usage_id;

  return query
    select v_usage_id, v_base_seconds, v_surcharge_percent, v_surcharge_seconds,
           v_charged_seconds, public.hour_package_available_seconds(v_package.id),
           v_package_discount, v_remaining;
end;
$$;

revoke all on function public.reserve_hour_package_usage(uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function public.reserve_hour_package_usage(uuid, uuid, uuid) to service_role;
