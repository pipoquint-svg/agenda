-- Keep reschedule availability consistent with new-booking availability.
-- The selected employee PERSON resource participates in Google sync health,
-- active occupancy and OPEN Google divergence checks, while the appointment
-- being rescheduled remains excluded through p_ignore_appointment_id.
-- Required service resources also fail closed on OPEN GOOGLE_EVENT_CONFLICT,
-- matching the new-booking path and protecting both reschedule listing + hold.

create or replace function public.list_available_slots_for_duration_reschedule_base(
  p_service_id uuid,
  p_service_employee_id uuid,
  p_duration_blocks integer default null::integer,
  p_extra_selections jsonb default '[]'::jsonb,
  p_people_count integer default 1,
  p_local_date date default current_date,
  p_coupon_code text default null::text,
  p_ignore_appointment_id uuid default null::uuid
)
returns table(
  slot_start_at timestamptz,
  slot_end_at timestamptz,
  core_start_at timestamptz,
  core_end_at timestamptz,
  pre_service_minutes integer,
  post_service_minutes integer,
  duration_minutes integer,
  commercial_value numeric
)
language plpgsql
stable
set search_path to 'public', 'extensions'
as $function$
declare
  v_service public.services%rowtype;
  v_timezone text;
  v_slot_interval integer := 30;
  v_dow smallint;
  v_anchor_start timestamptz;
  v_core_end timestamptz;
  v_appointment_start timestamptz;
  v_appointment_end timestamptz;
  v_contracted_minutes integer;
  v_profile jsonb;
  v_candidates jsonb := '[]'::jsonb;
  v_pre integer;
  v_post integer;
  v_resource record;
  v_resource_local_date date;
  v_resource_dow smallint;
  v_resource_ok boolean;
  v_service_window_ok boolean;
  v_employee_resource_id uuid;
  v_now timestamptz := coalesce(
    nullif(current_setting('agenda.test_now', true), '')::timestamptz,
    now()
  );
begin
  select * into v_service
  from public.services
  where id = p_service_id and is_active;

  if not found then
    raise exception using errcode = 'P0001', message = 'SERVICE_NOT_AVAILABLE';
  end if;

  select e.resource_id
  into v_employee_resource_id
  from public.service_employees se
  join public.employees e on e.id = se.employee_id
  where se.id = p_service_employee_id
    and se.service_id = p_service_id
    and se.is_active;

  if not found then
    raise exception using errcode = 'P0001', message = 'EMPLOYEE_NOT_AVAILABLE_FOR_SERVICE';
  end if;

  -- Fail closed when the selected professional's Google mirror is stale.
  -- Resources without an active Google mapping remain ready by definition.
  if v_employee_resource_id is not null
     and not public.google_resource_sync_is_ready(v_employee_resource_id, 600) then
    return;
  end if;

  v_contracted_minutes := public.resolve_service_contracted_minutes(
    p_service_id,
    p_duration_blocks
  );

  select timezone into v_timezone
  from public.operation_settings
  where id = 1;

  v_dow := extract(dow from p_local_date)::smallint;
  v_slot_interval := coalesce(v_service.slot_interval_minutes, 30);

  for v_anchor_start in
    with weekly_candidates as (
      select gs at time zone v_timezone as candidate_start
      from public.availability_rules ar
      cross join lateral generate_series(
        p_local_date + ar.start_local_time,
        (p_local_date + ar.end_local_time) - interval '1 microsecond',
        make_interval(mins => v_slot_interval)
      ) gs
      where ar.service_employee_id = p_service_employee_id
        and ar.weekday = v_dow
        and ar.is_active
    ), open_candidates as (
      select gs as candidate_start
      from (
        select ae.*
        from public.availability_exceptions ae
        where ae.service_employee_id = p_service_employee_id
          and ae.exception_type = 'OPEN'
          and tstzrange(ae.start_at, ae.end_at, '[)') && tstzrange(
            p_local_date::timestamp at time zone v_timezone,
            (p_local_date + 1)::timestamp at time zone v_timezone,
            '[)'
          )
      ) ae
      cross join lateral generate_series(
        ae.start_at,
        ae.end_at - interval '1 microsecond',
        make_interval(mins => v_slot_interval)
      ) gs
      where (gs at time zone v_timezone)::date = p_local_date
    )
    select candidate_start from weekly_candidates
    union
    select candidate_start from open_candidates
    order by 1
  loop
    v_core_end := v_anchor_start + make_interval(mins => v_contracted_minutes);
    v_profile := public.resolve_extra_schedule_profile(
      p_service_id,
      p_extra_selections,
      v_anchor_start
    );
    v_pre := coalesce((v_profile->>'pre_service_minutes')::integer, 0);
    v_post := coalesce((v_profile->>'post_service_minutes')::integer, 0);
    v_appointment_start := v_anchor_start - make_interval(mins => v_pre);
    v_appointment_end := v_core_end + make_interval(mins => v_post);

    if v_appointment_start < v_now + make_interval(mins => v_service.minimum_booking_notice_minutes) then
      continue;
    end if;
    if v_anchor_start > v_now + make_interval(days => v_service.maximum_booking_horizon_days) then
      continue;
    end if;

    select (
      exists (
        select 1
        from public.availability_rules ar
        where ar.service_employee_id = p_service_employee_id
          and ar.weekday = v_dow
          and ar.is_active
          and tstzrange(
            (p_local_date + ar.start_local_time) at time zone v_timezone,
            (p_local_date + ar.end_local_time) at time zone v_timezone,
            '[)'
          ) @> tstzrange(v_anchor_start, v_core_end, '[)')
      )
      or exists (
        select 1
        from public.availability_exceptions ae
        where ae.service_employee_id = p_service_employee_id
          and ae.exception_type = 'OPEN'
          and tstzrange(ae.start_at, ae.end_at, '[)') @> tstzrange(v_anchor_start, v_core_end, '[)')
      )
    ) into v_service_window_ok;

    if not v_service_window_ok then
      continue;
    end if;

    if exists (
      select 1
      from public.availability_exceptions ae
      where ae.service_employee_id = p_service_employee_id
        and ae.exception_type = 'BLOCK'
        and tstzrange(ae.start_at, ae.end_at, '[)') && tstzrange(v_anchor_start, v_core_end, '[)')
    ) then
      continue;
    end if;

    v_resource_ok := true;

    for v_resource in
      select *
      from public.calculate_booking_resource_ranges_for_duration(
        p_service_id,
        p_extra_selections,
        v_anchor_start,
        p_duration_blocks
      )
    loop
      v_resource_local_date := (lower(v_resource.occupied_range) at time zone v_timezone)::date;
      v_resource_dow := extract(dow from v_resource_local_date)::smallint;

      if not (
        exists (
          select 1
          from public.resource_availability_rules rar
          where rar.resource_id = v_resource.resource_id
            and rar.weekday = v_resource_dow
            and rar.is_active
            and tstzrange(
              (v_resource_local_date + rar.start_local_time) at time zone v_timezone,
              (v_resource_local_date + rar.end_local_time) at time zone v_timezone,
              '[)'
            ) @> v_resource.occupied_range
        )
        or exists (
          select 1
          from public.availability_exceptions ae
          where ae.resource_id = v_resource.resource_id
            and ae.exception_type = 'OPEN'
            and tstzrange(ae.start_at, ae.end_at, '[)') @> v_resource.occupied_range
        )
      ) then
        v_resource_ok := false;
        exit;
      end if;

      if exists (
        select 1
        from public.availability_exceptions ae
        where ae.resource_id = v_resource.resource_id
          and ae.exception_type = 'BLOCK'
          and tstzrange(ae.start_at, ae.end_at, '[)') && v_resource.occupied_range
      ) then
        v_resource_ok := false;
        exit;
      end if;

      if exists (
        select 1
        from public.schedule_divergences sd
        where sd.resource_id = v_resource.resource_id
          and sd.status = 'OPEN'
          and sd.reason = 'GOOGLE_EVENT_CONFLICT'
          and sd.desired_range && v_resource.occupied_range
      ) then
        v_resource_ok := false;
        exit;
      end if;

      if exists (
        select 1
        from public.resource_allocations ra
        where ra.resource_id = v_resource.resource_id
          and ra.status in ('HELD','AWAITING_PAYMENT','CONFIRMED','BLOCKED','EXTERNAL_ACTIVE')
          and ra.occupied_range && v_resource.occupied_range
          and (p_ignore_appointment_id is null or ra.appointment_id is distinct from p_ignore_appointment_id)
          and (
            ra.status <> 'HELD'
            or ra.allocation_type <> 'CHECKOUT_HOLD'
            or exists (
              select 1
              from public.checkout_holds ch
              where ch.id = ra.checkout_hold_id
                and ch.status = 'ACTIVE'
                and ch.expires_at > v_now
            )
          )
          and not (
            ra.status = 'AWAITING_PAYMENT'
            and ra.appointment_id is not null
            and exists (
              select 1
              from public.appointments a
              where a.id = ra.appointment_id
                and a.status = 'AWAITING_PAYMENT'
                and a.hold_expires_at is not null
                and a.hold_expires_at <= v_now
            )
          )
      ) then
        v_resource_ok := false;
        exit;
      end if;
    end loop;

    if not v_resource_ok then
      continue;
    end if;

    -- The professional PERSON resource uses the actual appointment interval,
    -- not the physical studio cleanup buffer.
    if v_employee_resource_id is not null then
      if exists (
        select 1
        from public.schedule_divergences sd
        where sd.resource_id = v_employee_resource_id
          and sd.status = 'OPEN'
          and sd.reason = 'GOOGLE_EVENT_CONFLICT'
          and sd.desired_range && tstzrange(v_appointment_start, v_appointment_end, '[)')
      ) then
        continue;
      end if;

      if exists (
        select 1
        from public.resource_allocations ra
        where ra.resource_id = v_employee_resource_id
          and ra.status in ('HELD','AWAITING_PAYMENT','CONFIRMED','BLOCKED','EXTERNAL_ACTIVE')
          and ra.occupied_range && tstzrange(v_appointment_start, v_appointment_end, '[)')
          and (p_ignore_appointment_id is null or ra.appointment_id is distinct from p_ignore_appointment_id)
          and (
            ra.status <> 'HELD'
            or ra.allocation_type <> 'CHECKOUT_HOLD'
            or exists (
              select 1
              from public.checkout_holds ch
              where ch.id = ra.checkout_hold_id
                and ch.status = 'ACTIVE'
                and ch.expires_at > v_now
            )
          )
          and not (
            ra.status = 'AWAITING_PAYMENT'
            and ra.appointment_id is not null
            and exists (
              select 1
              from public.appointments a
              where a.id = ra.appointment_id
                and a.status = 'AWAITING_PAYMENT'
                and a.hold_expires_at is not null
                and a.hold_expires_at <= v_now
            )
          )
      ) then
        continue;
      end if;
    end if;

    v_candidates := v_candidates || jsonb_build_array(jsonb_build_object(
      'slot_start_at', v_appointment_start,
      'slot_end_at', v_appointment_end,
      'core_start_at', v_anchor_start,
      'core_end_at', v_core_end,
      'pre_service_minutes', v_pre,
      'post_service_minutes', v_post,
      'duration_minutes', v_contracted_minutes + v_pre + v_post
    ));
  end loop;

  if jsonb_array_length(v_candidates) = 0 then
    return;
  end if;

  return query
  with candidates as (
    select
      ord::bigint ord,
      (item->>'slot_start_at')::timestamptz slot_start_at,
      (item->>'slot_end_at')::timestamptz slot_end_at,
      (item->>'core_start_at')::timestamptz core_start_at,
      (item->>'core_end_at')::timestamptz core_end_at,
      (item->>'pre_service_minutes')::integer pre_service_minutes,
      (item->>'post_service_minutes')::integer post_service_minutes,
      (item->>'duration_minutes')::integer duration_minutes
    from jsonb_array_elements(v_candidates) with ordinality x(item, ord)
  ), quotes as (
    select b.requested_start_at, b.quote
    from public.calculate_booking_quotes_for_duration_listing_batch(
      p_service_id,
      p_service_employee_id,
      p_duration_blocks,
      p_extra_selections,
      p_people_count,
      (select array_agg(c.core_start_at order by c.ord) from candidates c),
      p_coupon_code
    ) b
  )
  select
    c.slot_start_at,
    c.slot_end_at,
    c.core_start_at,
    c.core_end_at,
    c.pre_service_minutes,
    c.post_service_minutes,
    c.duration_minutes,
    (q.quote->>'commercial_value')::numeric(12,2)
  from candidates c
  join quotes q on q.requested_start_at = c.core_start_at
  order by c.ord;
end;
$function$;
