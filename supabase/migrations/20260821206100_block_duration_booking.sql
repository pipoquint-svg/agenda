-- Block-duration booking path.
-- Contracted duration and service buffers are distinct by design:
-- contracted_minutes = block_minutes * block_count
-- occupied service-resource range = contracted period + buffer_before/buffer_after ONCE.

create or replace function public.calculate_booking_quote_for_duration(
  p_service_id uuid,
  p_service_employee_id uuid,
  p_duration_blocks integer default null,
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
  v_dynamic_base numeric := 0;
  v_after_day_time numeric := 0;
  v_after_people numeric := 0;
  v_day_time_adjustment numeric := 0;
  v_people_adjustment numeric := 0;
  v_extras_total numeric := 0;
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
  v_contracted_minutes integer;
  v_profile jsonb;
  v_pre integer := 0;
  v_post integer := 0;
  v_pricing_version text;
  r record;
begin
  select * into v_service
  from public.services
  where id = p_service_id and is_active;

  if not found then
    raise exception using errcode = 'P0001', message = 'SERVICE_NOT_AVAILABLE';
  end if;

  if not exists (
    select 1 from public.service_employees se
    where se.id = p_service_employee_id
      and se.service_id = p_service_id
      and se.is_active
  ) then
    raise exception using errcode = 'P0001', message = 'EMPLOYEE_NOT_AVAILABLE_FOR_SERVICE';
  end if;

  v_contracted_minutes := public.resolve_service_contracted_minutes(p_service_id, p_duration_blocks);

  -- Fixed services keep the existing mature pricing engine unchanged.
  if v_service.duration_mode = 'FIXED' then
    return public.calculate_booking_quote(
      p_service_id,
      p_service_employee_id,
      p_extra_selections,
      p_people_count,
      p_requested_start_at,
      p_coupon_code
    ) || jsonb_build_object(
      'duration_mode', 'FIXED',
      'duration_blocks', null,
      'contracted_minutes', v_contracted_minutes,
      'buffer_before_minutes', v_service.buffer_before_minutes,
      'buffer_after_minutes', v_service.buffer_after_minutes
    );
  end if;

  if p_people_count < v_service.minimum_people or p_people_count > v_service.maximum_people then
    raise exception using errcode = 'P0001', message = 'INVALID_PEOPLE_COUNT';
  end if;

  if jsonb_typeof(coalesce(p_extra_selections, '[]'::jsonb)) <> 'array' then
    raise exception using errcode = 'P0001', message = 'INVALID_EXTRA';
  end if;

  select count(*) into v_requested_extras
  from jsonb_array_elements(coalesce(p_extra_selections, '[]'::jsonb));

  if exists (
    select 1
    from jsonb_to_recordset(coalesce(p_extra_selections, '[]'::jsonb)) x(extra_id uuid, quantity integer)
    group by x.extra_id having count(*) > 1
  ) then
    raise exception using errcode = 'P0001', message = 'INVALID_EXTRA';
  end if;

  v_dynamic_base := round(v_service.price_per_block * p_duration_blocks, 2);
  v_price := v_dynamic_base;

  for r in
    select e.id, e.price, x.quantity, se.max_quantity
    from jsonb_to_recordset(coalesce(p_extra_selections, '[]'::jsonb)) x(extra_id uuid, quantity integer)
    join public.service_extras se on se.service_id = p_service_id and se.extra_id = x.extra_id
    join public.extras e on e.id = x.extra_id and e.is_active
  loop
    if r.quantity is null or r.quantity < 1 or r.quantity > r.max_quantity then
      raise exception using errcode = 'P0001', message = 'INVALID_EXTRA_QUANTITY';
    end if;
    v_processed_extras := v_processed_extras + 1;
    v_extras_total := v_extras_total + (r.price * r.quantity);
  end loop;

  if v_processed_extras <> v_requested_extras then
    raise exception using errcode = 'P0001', message = 'INVALID_EXTRA';
  end if;

  select timezone into v_timezone from public.operation_settings where id = 1;

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
      order by pr.priority, pr.id
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
  v_day_time_adjustment := v_after_day_time - v_dynamic_base;
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
    order by pr.priority, pr.id
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
  v_subtotal := round(greatest(v_after_people + v_extras_total, 0), 2);

  if p_coupon_code is not null and btrim(p_coupon_code) <> '' then
    select c.* into v_coupon
    from public.coupons c
    where lower(c.code) = lower(btrim(p_coupon_code))
      and c.is_active
      and (c.valid_from is null or coalesce(p_requested_start_at, now()) >= c.valid_from)
      and (c.valid_until is null or coalesce(p_requested_start_at, now()) <= c.valid_until)
      and (
        not exists (select 1 from public.coupon_services cs where cs.coupon_id = c.id)
        or exists (select 1 from public.coupon_services cs where cs.coupon_id = c.id and cs.service_id = p_service_id)
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
    where sr.service_id = p_service_id and sr.is_required
    union
    select er.resource_id
    from jsonb_to_recordset(coalesce(p_extra_selections, '[]'::jsonb)) x(extra_id uuid, quantity integer)
    join public.extra_resources er on er.extra_id = x.extra_id and er.is_required
  ) q;

  v_profile := public.resolve_extra_schedule_profile(p_service_id, p_extra_selections, p_requested_start_at);
  v_pre := coalesce((v_profile->>'pre_service_minutes')::integer, 0);
  v_post := coalesce((v_profile->>'post_service_minutes')::integer, 0);

  select md5(concat_ws('|',
    v_service.updated_at::text,
    p_duration_blocks::text,
    v_dynamic_base::text,
    coalesce((select max(updated_at)::text from public.pricing_rules where service_id = p_service_id), ''),
    coalesce((select max(e.updated_at)::text
      from jsonb_to_recordset(coalesce(p_extra_selections, '[]'::jsonb)) x(extra_id uuid, quantity integer)
      join public.extras e on e.id = x.extra_id), ''),
    coalesce(v_coupon.updated_at::text, ''),
    coalesce(v_profile->>'schedule_version', '')
  )) into v_pricing_version;

  return jsonb_build_object(
    'service_id', p_service_id,
    'service_employee_id', p_service_employee_id,
    'duration_mode', 'BLOCKS',
    'duration_blocks', p_duration_blocks,
    'booking_block_minutes', v_service.booking_block_minutes,
    'contracted_minutes', v_contracted_minutes,
    'core_duration_minutes', v_contracted_minutes,
    'pre_service_minutes', v_pre,
    'post_service_minutes', v_post,
    'duration_minutes', v_contracted_minutes + v_pre + v_post,
    'buffer_before_minutes', v_service.buffer_before_minutes,
    'buffer_after_minutes', v_service.buffer_after_minutes,
    'resource_ids', to_jsonb(v_resource_ids),
    'base_price', v_dynamic_base,
    'day_time_adjustment', round(v_day_time_adjustment, 2),
    'people_adjustment', round(v_people_adjustment, 2),
    'extras_total', v_extras_total,
    'coupon_discount', v_coupon_discount,
    'commercial_value', v_commercial_value,
    'schedule_profile', v_profile,
    'pricing_version', v_pricing_version
  );
end;
$$;

create or replace function public.calculate_booking_resource_ranges_for_duration(
  p_service_id uuid,
  p_extra_selections jsonb,
  p_anchor_start_at timestamptz,
  p_duration_blocks integer default null
)
returns table(resource_id uuid, occupied_range tstzrange)
language sql
stable
set search_path = public
as $$
with service_data as (
  select
    public.resolve_service_contracted_minutes(p_service_id, p_duration_blocks) as contracted_minutes,
    s.buffer_before_minutes,
    s.buffer_after_minutes,
    public.resolve_extra_schedule_profile(p_service_id, p_extra_selections, p_anchor_start_at) as profile
  from public.services s
  where s.id = p_service_id
), bounds as (
  select
    p_anchor_start_at as core_start_at,
    p_anchor_start_at + make_interval(mins => contracted_minutes) as core_end_at,
    p_anchor_start_at - make_interval(mins => coalesce((profile->>'pre_service_minutes')::integer, 0)) as appointment_start_at,
    p_anchor_start_at + make_interval(mins => contracted_minutes + coalesce((profile->>'post_service_minutes')::integer, 0)) as appointment_end_at,
    buffer_before_minutes,
    buffer_after_minutes,
    profile
  from service_data
), ranges as (
  select
    sr.resource_id,
    tstzrange(
      b.core_start_at - make_interval(mins => b.buffer_before_minutes),
      b.core_end_at + make_interval(mins => b.buffer_after_minutes),
      '[)'
    ) as r
  from public.service_resources sr
  cross join bounds b
  where sr.service_id = p_service_id and sr.is_required

  union all

  select er.resource_id,
    case d.placement
      when 'PREPEND' then tstzrange(b.appointment_start_at, b.core_start_at, '[)')
      when 'APPEND' then tstzrange(b.core_end_at, b.appointment_end_at, '[)')
    end
  from bounds b
  cross join lateral jsonb_to_recordset(b.profile->'details') d(
    extra_id uuid, quantity integer, placement text,
    minutes_per_unit integer, total_schedule_minutes integer
  )
  join public.extra_resources er on er.extra_id = d.extra_id and er.is_required
  where d.total_schedule_minutes > 0
), nonempty as (
  select resource_id, r from ranges where r is not null and not isempty(r)
)
select resource_id, tstzrange(min(lower(r)), max(upper(r)), '[)')
from nonempty
group by resource_id;
$$;

create or replace function public.list_available_slots_for_duration(
  p_service_id uuid,
  p_service_employee_id uuid,
  p_duration_blocks integer default null,
  p_extra_selections jsonb default '[]'::jsonb,
  p_people_count integer default 1,
  p_local_date date default current_date,
  p_coupon_code text default null
)
returns table (
  slot_start_at timestamptz,
  slot_end_at timestamptz,
  core_start_at timestamptz,
  core_end_at timestamptz,
  pre_service_minutes integer,
  post_service_minutes integer,
  duration_minutes integer,
  commercial_value numeric(12,2)
)
language plpgsql
stable
set search_path = public, extensions
as $$
declare
  v_service public.services%rowtype;
  v_timezone text;
  v_slot_interval integer := 30;
  v_dow smallint;
  v_candidate_local timestamp without time zone;
  v_anchor_start timestamptz;
  v_core_end timestamptz;
  v_appointment_start timestamptz;
  v_appointment_end timestamptz;
  v_contracted_minutes integer;
  v_quote jsonb;
  v_pre integer;
  v_post integer;
  v_resource record;
  v_resource_local_date date;
  v_resource_dow smallint;
  v_resource_ok boolean;
  v_service_window_ok boolean;
begin
  select * into v_service from public.services where id = p_service_id and is_active;
  if not found then
    raise exception using errcode = 'P0001', message = 'SERVICE_NOT_AVAILABLE';
  end if;

  if not exists (
    select 1 from public.service_employees se
    where se.id = p_service_employee_id and se.service_id = p_service_id and se.is_active
  ) then
    raise exception using errcode = 'P0001', message = 'EMPLOYEE_NOT_AVAILABLE_FOR_SERVICE';
  end if;

  v_contracted_minutes := public.resolve_service_contracted_minutes(p_service_id, p_duration_blocks);
  select timezone into v_timezone from public.operation_settings where id = 1;
  v_dow := extract(dow from p_local_date)::smallint;

  select coalesce(min(ar.slot_interval_minutes), public.get_default_slot_interval_minutes())
  into v_slot_interval
  from public.availability_rules ar
  where ar.service_employee_id = p_service_employee_id
    and ar.weekday = v_dow
    and ar.is_active;

  for v_candidate_local in
    select gs from generate_series(
      p_local_date::timestamp,
      (p_local_date + 1)::timestamp - interval '1 minute',
      make_interval(mins => v_slot_interval)
    ) gs
  loop
    v_anchor_start := v_candidate_local at time zone v_timezone;
    v_core_end := v_anchor_start + make_interval(mins => v_contracted_minutes);

    v_quote := public.calculate_booking_quote_for_duration(
      p_service_id, p_service_employee_id, p_duration_blocks,
      p_extra_selections, p_people_count, v_anchor_start, p_coupon_code
    );
    v_pre := coalesce((v_quote->>'pre_service_minutes')::integer, 0);
    v_post := coalesce((v_quote->>'post_service_minutes')::integer, 0);
    v_appointment_start := v_anchor_start - make_interval(mins => v_pre);
    v_appointment_end := v_core_end + make_interval(mins => v_post);

    if v_appointment_start < now() + make_interval(mins => v_service.minimum_booking_notice_minutes) then continue; end if;
    if v_anchor_start > now() + make_interval(days => v_service.maximum_booking_horizon_days) then continue; end if;

    select (
      exists (
        select 1 from public.availability_rules ar
        where ar.service_employee_id = p_service_employee_id
          and ar.weekday = v_dow and ar.is_active
          and tstzrange(
            (p_local_date + ar.start_local_time) at time zone v_timezone,
            (p_local_date + ar.end_local_time) at time zone v_timezone,
            '[)'
          ) @> tstzrange(v_anchor_start, v_core_end, '[)')
      )
      or exists (
        select 1 from public.availability_exceptions ae
        where ae.service_employee_id = p_service_employee_id
          and ae.exception_type = 'OPEN'
          and tstzrange(ae.start_at, ae.end_at, '[)') @> tstzrange(v_anchor_start, v_core_end, '[)')
      )
    ) into v_service_window_ok;
    if not v_service_window_ok then continue; end if;

    if exists (
      select 1 from public.availability_exceptions ae
      where ae.service_employee_id = p_service_employee_id
        and ae.exception_type = 'BLOCK'
        and tstzrange(ae.start_at, ae.end_at, '[)') && tstzrange(v_anchor_start, v_core_end, '[)')
    ) then continue; end if;

    v_resource_ok := true;
    for v_resource in
      select * from public.calculate_booking_resource_ranges_for_duration(
        p_service_id, p_extra_selections, v_anchor_start, p_duration_blocks
      )
    loop
      v_resource_local_date := (lower(v_resource.occupied_range) at time zone v_timezone)::date;
      v_resource_dow := extract(dow from v_resource_local_date)::smallint;

      if exists (
        select 1 from public.resource_availability_rules rar
        where rar.resource_id = v_resource.resource_id
          and rar.weekday = v_resource_dow and rar.is_active
      ) then
        if not (
          exists (
            select 1 from public.resource_availability_rules rar
            where rar.resource_id = v_resource.resource_id
              and rar.weekday = v_resource_dow and rar.is_active
              and tstzrange(
                (v_resource_local_date + rar.start_local_time) at time zone v_timezone,
                (v_resource_local_date + rar.end_local_time) at time zone v_timezone,
                '[)'
              ) @> v_resource.occupied_range
          )
          or exists (
            select 1 from public.availability_exceptions ae
            where ae.resource_id = v_resource.resource_id
              and ae.exception_type = 'OPEN'
              and tstzrange(ae.start_at, ae.end_at, '[)') @> v_resource.occupied_range
          )
        ) then
          v_resource_ok := false; exit;
        end if;
      end if;

      if exists (
        select 1 from public.availability_exceptions ae
        where ae.resource_id = v_resource.resource_id
          and ae.exception_type = 'BLOCK'
          and tstzrange(ae.start_at, ae.end_at, '[)') && v_resource.occupied_range
      ) then v_resource_ok := false; exit; end if;

      if exists (
        select 1 from public.resource_allocations ra
        where ra.resource_id = v_resource.resource_id
          and ra.status in ('HELD','AWAITING_PAYMENT','CONFIRMED','BLOCKED','EXTERNAL_ACTIVE')
          and ra.occupied_range && v_resource.occupied_range
      ) then v_resource_ok := false; exit; end if;
    end loop;

    if not v_resource_ok then continue; end if;

    slot_start_at := v_appointment_start;
    slot_end_at := v_appointment_end;
    core_start_at := v_anchor_start;
    core_end_at := v_core_end;
    pre_service_minutes := v_pre;
    post_service_minutes := v_post;
    duration_minutes := v_contracted_minutes + v_pre + v_post;
    commercial_value := (v_quote->>'commercial_value')::numeric(12,2);
    return next;
  end loop;
end;
$$;

create or replace function public.create_checkout_hold_for_duration(
  p_service_id uuid,
  p_service_employee_id uuid,
  p_duration_blocks integer,
  p_extra_selections jsonb,
  p_people_count integer,
  p_requested_start_at timestamptz
)
returns jsonb
language plpgsql
volatile
set search_path = public, extensions
as $$
declare
  v_timezone text;
  v_requested_local_date date;
  v_slot record;
  v_quote jsonb;
  v_resource_ids uuid[] := '{}'::uuid[];
  v_hold_id uuid;
  v_raw_token text;
  v_token_hash text;
  v_selection_hash text;
  v_canonical_extras jsonb;
  v_expires_at timestamptz;
  v_hold_minutes integer;
  v_contracted_minutes integer;
begin
  perform public.expire_due_checkout_holds();
  v_contracted_minutes := public.resolve_service_contracted_minutes(p_service_id, p_duration_blocks);
  select timezone into v_timezone from public.operation_settings where id = 1;

  select coalesce(jsonb_agg(
    jsonb_build_object('extra_id', x.extra_id, 'quantity', x.quantity) order by x.extra_id
  ), '[]'::jsonb)
  into v_canonical_extras
  from jsonb_to_recordset(coalesce(p_extra_selections, '[]'::jsonb)) x(extra_id uuid, quantity integer);

  v_requested_local_date := (p_requested_start_at at time zone v_timezone)::date;

  select s.* into v_slot
  from (
    select * from public.list_available_slots_for_duration(
      p_service_id, p_service_employee_id, p_duration_blocks,
      v_canonical_extras, p_people_count, v_requested_local_date, null
    )
    union all
    select * from public.list_available_slots_for_duration(
      p_service_id, p_service_employee_id, p_duration_blocks,
      v_canonical_extras, p_people_count, v_requested_local_date + 1, null
    )
  ) s
  where s.slot_start_at = p_requested_start_at
  order by s.core_start_at limit 1;

  if not found then
    raise exception using errcode = 'P0001', message = 'SLOT_NO_LONGER_AVAILABLE';
  end if;

  v_quote := public.calculate_booking_quote_for_duration(
    p_service_id, p_service_employee_id, p_duration_blocks,
    v_canonical_extras, p_people_count, v_slot.core_start_at, null
  );

  select coalesce(array_agg(r.resource_id order by r.resource_id), '{}'::uuid[])
  into v_resource_ids
  from public.calculate_booking_resource_ranges_for_duration(
    p_service_id, v_canonical_extras, v_slot.core_start_at, p_duration_blocks
  ) r;

  if coalesce(array_length(v_resource_ids, 1), 0) = 0 then
    raise exception using errcode = 'P0001', message = 'SERVICE_HAS_NO_REQUIRED_RESOURCES';
  end if;

  select coalesce(s.checkout_hold_minutes, os.checkout_hold_minutes)
  into v_hold_minutes
  from public.services s cross join public.operation_settings os
  where s.id = p_service_id and os.id = 1;

  v_expires_at := now() + make_interval(mins => v_hold_minutes);
  v_raw_token := encode(gen_random_bytes(32), 'hex');
  v_token_hash := encode(digest(v_raw_token, 'sha256'), 'hex');
  v_selection_hash := md5(concat_ws('|',
    p_service_id::text,
    p_service_employee_id::text,
    coalesce(p_duration_blocks::text, 'FIXED'),
    v_canonical_extras::text,
    p_people_count::text,
    v_slot.slot_start_at::text,
    v_slot.core_start_at::text,
    v_quote->>'pricing_version'
  ));

  insert into public.checkout_holds (
    public_token_hash, service_id, service_employee_id, selection_hash, people_count,
    requested_start_at, requested_end_at, core_start_at, core_end_at,
    pre_service_minutes, post_service_minutes, schedule_profile,
    status, expires_at, extra_selections, commercial_value, pricing_version,
    duration_minutes, resource_ids, duration_blocks, contracted_minutes
  ) values (
    v_token_hash, p_service_id, p_service_employee_id, v_selection_hash, p_people_count,
    v_slot.slot_start_at, v_slot.slot_end_at, v_slot.core_start_at, v_slot.core_end_at,
    v_slot.pre_service_minutes, v_slot.post_service_minutes, v_quote->'schedule_profile',
    'ACTIVE', v_expires_at, v_canonical_extras,
    (v_quote->>'commercial_value')::numeric(12,2), v_quote->>'pricing_version',
    v_slot.duration_minutes, v_resource_ids, p_duration_blocks, v_contracted_minutes
  ) returning id into v_hold_id;

  begin
    insert into public.resource_allocations(
      resource_id, checkout_hold_id, allocation_type, status, occupied_range
    )
    select r.resource_id, v_hold_id, 'CHECKOUT_HOLD', 'HELD', r.occupied_range
    from public.calculate_booking_resource_ranges_for_duration(
      p_service_id, v_canonical_extras, v_slot.core_start_at, p_duration_blocks
    ) r;
  exception when exclusion_violation then
    raise exception using errcode = 'P0001', message = 'SLOT_NO_LONGER_AVAILABLE';
  end;

  return jsonb_build_object(
    'checkout_hold_token', v_raw_token,
    'checkout_hold_id', v_hold_id,
    'status', 'ACTIVE',
    'expires_at', v_expires_at,
    'slot_start_at', v_slot.slot_start_at,
    'slot_end_at', v_slot.slot_end_at,
    'core_start_at', v_slot.core_start_at,
    'core_end_at', v_slot.core_end_at,
    'pre_service_minutes', v_slot.pre_service_minutes,
    'post_service_minutes', v_slot.post_service_minutes,
    'commercial_value', (v_quote->>'commercial_value')::numeric(12,2),
    'duration_minutes', v_slot.duration_minutes,
    'duration_blocks', p_duration_blocks,
    'contracted_minutes', v_contracted_minutes,
    'pricing_version', v_quote->>'pricing_version'
  );
end;
$$;

create or replace function public.sync_promoted_appointment_schedule()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.promoted_appointment_id is not null
     and (old.promoted_appointment_id is distinct from new.promoted_appointment_id) then
    update public.appointments
    set core_start_at = new.core_start_at,
        core_end_at = new.core_end_at,
        pre_service_minutes = new.pre_service_minutes,
        post_service_minutes = new.post_service_minutes,
        schedule_profile_snapshot = new.schedule_profile,
        duration_blocks = new.duration_blocks,
        contracted_minutes = new.contracted_minutes,
        updated_at = now()
    where id = new.promoted_appointment_id;
  end if;
  return new;
end;
$$;

revoke all on function public.calculate_booking_quote_for_duration(uuid,uuid,integer,jsonb,integer,timestamptz,text)
  from public, anon, authenticated;
revoke all on function public.calculate_booking_resource_ranges_for_duration(uuid,jsonb,timestamptz,integer)
  from public, anon, authenticated;
revoke all on function public.list_available_slots_for_duration(uuid,uuid,integer,jsonb,integer,date,text)
  from public, anon, authenticated;
revoke all on function public.create_checkout_hold_for_duration(uuid,uuid,integer,jsonb,integer,timestamptz)
  from public, anon, authenticated;

grant execute on function public.calculate_booking_quote_for_duration(uuid,uuid,integer,jsonb,integer,timestamptz,text) to service_role;
grant execute on function public.calculate_booking_resource_ranges_for_duration(uuid,jsonb,timestamptz,integer) to service_role;
grant execute on function public.list_available_slots_for_duration(uuid,uuid,integer,jsonb,integer,date,text) to service_role;
grant execute on function public.create_checkout_hold_for_duration(uuid,uuid,integer,jsonb,integer,timestamptz) to service_role;
