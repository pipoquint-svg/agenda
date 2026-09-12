-- Fast path read-only for monthly availability.
-- Public contract remains public.public_list_available_dates_month(...)->TABLE(local_date date).
-- The checkout/hold path remains authoritative and unchanged.

create or replace function agenda_public_bridge.has_available_slot_for_duration_impl(
  p_service_id uuid,
  p_service_employee_id uuid,
  p_duration_blocks integer,
  p_extra_selections jsonb default '[]'::jsonb,
  p_people_count integer default 1,
  p_local_date date default current_date,
  p_earliest_slot_start_at timestamptz default null
)
returns boolean
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
  v_pre integer;
  v_post integer;
  v_resource record;
  v_resource_local_date date;
  v_resource_dow smallint;
  v_resource_ok boolean;
  v_service_window_ok boolean;
  v_now timestamptz := coalesce(
    nullif(current_setting('agenda.test_now', true), '')::timestamptz,
    now()
  );
begin
  -- p_people_count intentionally remains in the signature so the fast path tracks
  -- the public availability contract even though current physical-slot rules do
  -- not consume it after assert_public_booking_duration has validated selection.
  perform p_people_count;

  select * into v_service
  from public.services
  where id = p_service_id and is_active;

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

  v_contracted_minutes := public.resolve_service_contracted_minutes(
    p_service_id,
    p_duration_blocks
  );

  select timezone into v_timezone
  from public.operation_settings
  where id = 1;

  v_dow := extract(dow from p_local_date)::smallint;
  v_slot_interval := coalesce(v_service.slot_interval_minutes, 30);

  -- This gate is independent of the candidate start. The current authoritative
  -- list function rejects every slot when the employee resource is stale.
  if exists (
    select 1
    from public.service_employees se
    join public.employees e on e.id = se.employee_id
    where se.id = p_service_employee_id
      and se.service_id = p_service_id
      and se.is_active
      and e.resource_id is not null
      and not public.google_resource_sync_is_ready(e.resource_id, 600)
  ) then
    return false;
  end if;

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
    ),
    open_candidates as (
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
    if p_earliest_slot_start_at is not null and v_appointment_start < p_earliest_slot_start_at then
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
        from public.resource_allocations ra
        where ra.resource_id = v_resource.resource_id
          and ra.status in ('HELD','AWAITING_PAYMENT','CONFIRMED','BLOCKED','EXTERNAL_ACTIVE')
          and ra.occupied_range && v_resource.occupied_range
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

      if not public.google_resource_sync_is_ready(v_resource.resource_id, 600) then
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
    end loop;

    if not v_resource_ok then
      continue;
    end if;

    if exists (
      select 1
      from public.service_employees se
      join public.employees e on e.id = se.employee_id
      join public.schedule_divergences sd on sd.resource_id = e.resource_id
      where se.id = p_service_employee_id
        and se.service_id = p_service_id
        and se.is_active
        and e.resource_id is not null
        and sd.status = 'OPEN'
        and sd.reason = 'GOOGLE_EVENT_CONFLICT'
        and sd.desired_range && tstzrange(v_appointment_start, v_appointment_end, '[)')
    ) then
      continue;
    end if;

    if exists (
      select 1
      from public.service_employees se
      join public.employees e on e.id = se.employee_id
      join public.resource_allocations ra on ra.resource_id = e.resource_id
      where se.id = p_service_employee_id
        and se.service_id = p_service_id
        and se.is_active
        and e.resource_id is not null
        and ra.status in ('HELD','AWAITING_PAYMENT','CONFIRMED','BLOCKED','EXTERNAL_ACTIVE')
        and ra.occupied_range && tstzrange(v_appointment_start, v_appointment_end, '[)')
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

    return true;
  end loop;

  return false;
end;
$function$;

create or replace function agenda_public_bridge.list_available_dates_month_impl(
  p_booking_page_slug text,
  p_service_id uuid,
  p_service_employee_id uuid,
  p_contracted_minutes integer,
  p_extra_selections jsonb default '[]'::jsonb,
  p_people_count integer default 1,
  p_month date default current_date
)
returns table(local_date date)
language plpgsql
stable security definer
set search_path to ''
as $function$
declare
  v_blocks integer;
  v_month_start date;
  v_month_end date;
  v_public_minimum_booking_notice_hours integer := 0;
  v_earliest_slot_start_at timestamptz;
begin
  if p_month is null then
    raise exception 'MONTH_REQUIRED' using errcode = '22023';
  end if;

  v_blocks := public.resolve_service_duration_blocks_from_minutes(
    p_service_id,
    p_contracted_minutes
  );

  perform public.assert_public_booking_duration(
    p_booking_page_slug,
    p_service_id,
    p_service_employee_id,
    v_blocks,
    p_extra_selections,
    p_people_count
  );

  select coalesce(s.public_minimum_booking_notice_hours, 0)
    into v_public_minimum_booking_notice_hours
  from public.services s
  where s.id = p_service_id;

  if v_public_minimum_booking_notice_hours > 0 then
    v_earliest_slot_start_at := now() + make_interval(hours => v_public_minimum_booking_notice_hours);
  end if;

  v_month_start := date_trunc('month', p_month::timestamp)::date;
  v_month_end := (v_month_start + interval '1 month')::date;

  return query
  select d.local_date
  from generate_series(v_month_start, v_month_end - 1, interval '1 day') as g(day)
  cross join lateral (select g.day::date as local_date) d
  where agenda_public_bridge.has_available_slot_for_duration_impl(
    p_service_id,
    p_service_employee_id,
    v_blocks,
    p_extra_selections,
    p_people_count,
    d.local_date,
    v_earliest_slot_start_at
  )
  order by d.local_date;
end;
$function$;

comment on function agenda_public_bridge.has_available_slot_for_duration_impl(
  uuid, uuid, integer, jsonb, integer, date, timestamptz
) is 'Internal read-only fast path for monthly availability. Mirrors authoritative physical-slot and Google readiness gates but intentionally skips pricing.';
