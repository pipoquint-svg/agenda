create or replace function public.calculate_booking_quote(
  p_service_id uuid,
  p_service_employee_id uuid,
  p_extra_selections jsonb default '[]'::jsonb,
  p_people_count integer default 1,
  p_requested_start_at timestamptz default null,
  p_coupon_code text default null
)
returns jsonb
language plpgsql
stable
set search_path = public, extensions
as $$
declare
  v_service public.services%rowtype;
  v_timezone text;
  v_price numeric := 0;
  v_after_day_time numeric := 0;
  v_after_people numeric := 0;
  v_day_time_adjustment numeric := 0;
  v_people_adjustment numeric := 0;
  v_extras_total numeric := 0;
  v_extra_duration integer := 0;
  v_duration integer := 0;
  v_subtotal numeric := 0;
  v_coupon_discount numeric := 0;
  v_commercial_value numeric := 0;
  v_coupon public.coupons%rowtype;
  v_local_ts timestamp without time zone;
  v_local_date date;
  v_local_time time without time zone;
  v_dow smallint;
  v_processed_extras integer := 0;
  v_requested_extras integer := 0;
  v_resource_ids uuid[] := '{}'::uuid[];
  v_pricing_version text;
  r record;
begin
  select s.*
  into v_service
  from public.services s
  where s.id = p_service_id
    and s.is_active;

  if not found then
    raise exception using errcode = 'P0001', message = 'SERVICE_NOT_AVAILABLE';
  end if;

  if not exists (
    select 1
    from public.service_employees se
    where se.id = p_service_employee_id
      and se.service_id = p_service_id
      and se.is_active
  ) then
    raise exception using errcode = 'P0001', message = 'EMPLOYEE_NOT_AVAILABLE_FOR_SERVICE';
  end if;

  if p_people_count < v_service.minimum_people then
    raise exception using errcode = 'P0001', message = 'PEOPLE_BELOW_MINIMUM';
  end if;

  if p_people_count > v_service.maximum_people then
    raise exception using errcode = 'P0001', message = 'PEOPLE_ABOVE_MAXIMUM';
  end if;

  if jsonb_typeof(coalesce(p_extra_selections, '[]'::jsonb)) <> 'array' then
    raise exception using errcode = 'P0001', message = 'INVALID_EXTRA';
  end if;

  select count(*) into v_requested_extras
  from jsonb_array_elements(coalesce(p_extra_selections, '[]'::jsonb));

  if exists (
    select 1
    from jsonb_to_recordset(coalesce(p_extra_selections, '[]'::jsonb)) as x(extra_id uuid, quantity integer)
    group by x.extra_id
    having count(*) > 1
  ) then
    raise exception using errcode = 'P0001', message = 'INVALID_EXTRA';
  end if;

  v_price := v_service.base_price;
  v_duration := v_service.base_duration_minutes;

  for r in
    select
      e.id as extra_id,
      e.price,
      e.duration_delta_minutes,
      x.quantity,
      se.max_quantity
    from jsonb_to_recordset(coalesce(p_extra_selections, '[]'::jsonb)) as x(extra_id uuid, quantity integer)
    join public.service_extras se
      on se.service_id = p_service_id
     and se.extra_id = x.extra_id
    join public.extras e
      on e.id = x.extra_id
     and e.is_active
  loop
    if r.quantity is null or r.quantity < 1 or r.quantity > r.max_quantity then
      raise exception using errcode = 'P0001', message = 'INVALID_EXTRA_QUANTITY';
    end if;

    v_processed_extras := v_processed_extras + 1;
    v_extras_total := v_extras_total + (r.price * r.quantity);
    v_extra_duration := v_extra_duration + (r.duration_delta_minutes * r.quantity);
  end loop;

  if v_processed_extras <> v_requested_extras then
    raise exception using errcode = 'P0001', message = 'INVALID_EXTRA';
  end if;

  select os.timezone into v_timezone
  from public.operation_settings os
  where os.id = 1;

  if p_requested_start_at is not null then
    v_local_ts := p_requested_start_at at time zone v_timezone;
    v_local_date := v_local_ts::date;
    v_local_time := v_local_ts::time;
    v_dow := extract(dow from v_local_ts)::smallint;

    for r in
      select pr.*
      from public.pricing_rules pr
      where pr.service_id = p_service_id
        and pr.is_active
        and pr.rule_scope = 'DAY_TIME'
        and (pr.valid_from_date is null or v_local_date >= pr.valid_from_date)
        and (pr.valid_until_date is null or v_local_date <= pr.valid_until_date)
        and (pr.days_of_week is null or v_dow = any(pr.days_of_week))
        and (pr.start_local_time is null or v_local_time >= pr.start_local_time)
        and (pr.end_local_time is null or v_local_time < pr.end_local_time)
      order by pr.priority asc, pr.id asc
    loop
      if r.action_type = 'REPLACE_PRICE' then
        v_price := r.amount;
      elsif r.action_type = 'ADD_AMOUNT' then
        v_price := v_price + r.amount;
      elsif r.action_type = 'ADD_PERCENT' then
        v_price := v_price * (1 + (r.percentage / 100));
      end if;
    end loop;
  end if;

  v_after_day_time := round(greatest(v_price, 0), 2);
  v_day_time_adjustment := v_after_day_time - v_service.base_price;
  v_price := v_after_day_time;

  for r in
    select pr.*
    from public.pricing_rules pr
    where pr.service_id = p_service_id
      and pr.is_active
      and pr.rule_scope = 'PEOPLE'
      and p_people_count between pr.min_people and pr.max_people
      and (pr.valid_from_date is null or coalesce(v_local_date, current_date) >= pr.valid_from_date)
      and (pr.valid_until_date is null or coalesce(v_local_date, current_date) <= pr.valid_until_date)
    order by pr.priority asc, pr.id asc
  loop
    if r.action_type = 'REPLACE_PRICE' then
      v_price := r.amount;
    elsif r.action_type = 'ADD_AMOUNT' then
      v_price := v_price + r.amount;
    elsif r.action_type = 'ADD_PERCENT' then
      v_price := v_price * (1 + (r.percentage / 100));
    end if;
  end loop;

  v_after_people := round(greatest(v_price, 0), 2);
  v_people_adjustment := v_after_people - v_after_day_time;
  v_extras_total := round(v_extras_total, 2);
  v_duration := v_duration + v_extra_duration;
  v_subtotal := round(greatest(v_after_people + v_extras_total, 0), 2);

  if p_coupon_code is not null and btrim(p_coupon_code) <> '' then
    select c.*
    into v_coupon
    from public.coupons c
    where lower(c.code) = lower(btrim(p_coupon_code))
      and c.is_active
      and (c.valid_from is null or coalesce(p_requested_start_at, now()) >= c.valid_from)
      and (c.valid_until is null or coalesce(p_requested_start_at, now()) <= c.valid_until)
      and (
        not exists (select 1 from public.coupon_services cs where cs.coupon_id = c.id)
        or exists (
          select 1
          from public.coupon_services cs
          where cs.coupon_id = c.id
            and cs.service_id = p_service_id
        )
      )
    limit 1;

    if not found then
      raise exception using errcode = 'P0001', message = 'INVALID_COUPON';
    end if;

    if v_coupon.discount_type = 'FIXED' then
      v_coupon_discount := least(v_coupon.discount_value, v_subtotal);
    else
      v_coupon_discount := round(v_subtotal * (v_coupon.discount_value / 100), 2);
    end if;
  end if;

  v_coupon_discount := round(v_coupon_discount, 2);
  v_commercial_value := round(greatest(v_subtotal - v_coupon_discount, 0), 2);

  select coalesce(array_agg(distinct resource_id order by resource_id), '{}'::uuid[])
  into v_resource_ids
  from (
    select sr.resource_id
    from public.service_resources sr
    where sr.service_id = p_service_id
      and sr.is_required

    union

    select er.resource_id
    from jsonb_to_recordset(coalesce(p_extra_selections, '[]'::jsonb)) as x(extra_id uuid, quantity integer)
    join public.extra_resources er
      on er.extra_id = x.extra_id
     and er.is_required
  ) required_resources;

  select md5(concat_ws('|',
    v_service.updated_at::text,
    coalesce((select max(updated_at)::text from public.pricing_rules where service_id = p_service_id), ''),
    coalesce((
      select max(e.updated_at)::text
      from jsonb_to_recordset(coalesce(p_extra_selections, '[]'::jsonb)) as x(extra_id uuid, quantity integer)
      join public.extras e on e.id = x.extra_id
    ), ''),
    coalesce(v_coupon.updated_at::text, '')
  )) into v_pricing_version;

  return jsonb_build_object(
    'service_id', p_service_id,
    'service_employee_id', p_service_employee_id,
    'duration_minutes', v_duration,
    'buffer_before_minutes', v_service.buffer_before_minutes,
    'buffer_after_minutes', v_service.buffer_after_minutes,
    'resource_ids', to_jsonb(v_resource_ids),
    'base_price', round(v_service.base_price, 2),
    'day_time_adjustment', round(v_day_time_adjustment, 2),
    'people_adjustment', round(v_people_adjustment, 2),
    'extras_total', v_extras_total,
    'coupon_discount', v_coupon_discount,
    'commercial_value', v_commercial_value,
    'pricing_version', v_pricing_version
  );
end;
$$;
