-- PR-03: private, set-based monthly availability engine.
--
-- This is intentionally additive. The public monthly bridge remains on V1 until
-- PR-04, while the differential harness compares this function with V1.

create or replace function agenda_internal.list_available_dates_month_v2(
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
stable
set search_path = ''
as $function$
declare
  v_service public.services%rowtype;
  v_blocks integer;
  v_contracted_minutes integer;
  v_timezone text;
  v_employee_resource_id uuid;
  v_employee_google_ready boolean := true;
  v_month_start date;
  v_month_end date;
  v_now timestamptz := coalesce(
    nullif(current_setting('agenda.test_now', true), '')::timestamptz,
    now()
  );
begin
  if p_month is null then
    raise exception 'MONTH_REQUIRED' using errcode = '22023';
  end if;

  -- Keep public selection validation and duration normalization identical to V1.
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

  -- Match the daily duration engine exactly; p_contracted_minutes is the
  -- public selection input, while this is the canonical duration it resolves.
  v_contracted_minutes := public.resolve_service_contracted_minutes(
    p_service_id,
    v_blocks
  );

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

  select os.timezone
    into v_timezone
  from public.operation_settings os
  where os.id = 1;

  -- LEGACY SINGLE-TENANT COMPATIBILITY: operation_settings.id = 1 remains the
  -- source of operational timezone until the tenant foundation work.
  select e.resource_id
    into v_employee_resource_id
  from public.service_employees se
  join public.employees e on e.id = se.employee_id
  where se.id = p_service_employee_id
    and se.service_id = p_service_id
    and se.is_active;

  if v_employee_resource_id is not null then
    select public.google_resource_sync_is_ready(v_employee_resource_id, 600)
      into v_employee_google_ready;
  end if;

  v_month_start := date_trunc('month', p_month::timestamp)::date;
  v_month_end := (v_month_start + interval '1 month')::date;

  return query
  with month_days as materialized (
    select g.day::date as local_date
    from generate_series(v_month_start, v_month_end - 1, interval '1 day') as g(day)
  ), weekly_candidates as materialized (
    select d.local_date,
      gs at time zone v_timezone as anchor_start_at
    from month_days d
    join public.availability_rules ar
      on ar.weekday = extract(dow from d.local_date)::smallint
     and ar.service_employee_id = p_service_employee_id
     and ar.is_active
    cross join lateral generate_series(
      d.local_date + ar.start_local_time,
      (d.local_date + ar.end_local_time) - interval '1 microsecond',
      make_interval(mins => coalesce(v_service.slot_interval_minutes, 30))
    ) as gs
  ), open_candidates as materialized (
    select (gs at time zone v_timezone)::date as local_date,
      gs as anchor_start_at
    from public.availability_exceptions ae
    cross join lateral generate_series(
      ae.start_at,
      ae.end_at - interval '1 microsecond',
      make_interval(mins => coalesce(v_service.slot_interval_minutes, 30))
    ) as gs
    where ae.service_employee_id = p_service_employee_id
      and ae.exception_type = 'OPEN'
      and tstzrange(ae.start_at, ae.end_at, '[)') && tstzrange(
        v_month_start::timestamp at time zone v_timezone,
        v_month_end::timestamp at time zone v_timezone,
        '[)'
      )
      and (gs at time zone v_timezone)::date >= v_month_start
      and (gs at time zone v_timezone)::date < v_month_end
  ), candidate_starts as materialized (
    select wc.local_date, wc.anchor_start_at from weekly_candidates wc
    union
    select oc.local_date, oc.anchor_start_at from open_candidates oc
  ), candidate_schedule as materialized (
    select c.local_date,
      c.anchor_start_at,
      c.anchor_start_at + make_interval(mins => v_contracted_minutes) as core_end_at,
      coalesce((profile.value->>'pre_service_minutes')::integer, 0) as pre_service_minutes,
      coalesce((profile.value->>'post_service_minutes')::integer, 0) as post_service_minutes
    from candidate_starts c
    cross join lateral (
      select public.resolve_extra_schedule_profile(
        p_service_id,
        p_extra_selections,
        c.anchor_start_at
      ) as value
    ) profile
  ), bounded_candidates as materialized (
    select c.*,
      c.anchor_start_at - make_interval(mins => c.pre_service_minutes) as appointment_start_at,
      c.core_end_at + make_interval(mins => c.post_service_minutes) as appointment_end_at
    from candidate_schedule c
    where c.anchor_start_at - make_interval(mins => c.pre_service_minutes)
        >= v_now + make_interval(mins => v_service.minimum_booking_notice_minutes)
      and c.anchor_start_at
        <= v_now + make_interval(days => v_service.maximum_booking_horizon_days)
      and (
        coalesce(v_service.public_minimum_booking_notice_hours, 0) = 0
        or c.anchor_start_at - make_interval(mins => c.pre_service_minutes)
          >= now() + make_interval(hours => v_service.public_minimum_booking_notice_hours)
      )
  ), employee_available_candidates as materialized (
    select c.*
    from bounded_candidates c
    where (
      exists (
        select 1
        from public.availability_rules ar
        where ar.service_employee_id = p_service_employee_id
          and ar.weekday = extract(dow from c.local_date)::smallint
          and ar.is_active
          and tstzrange(
            (c.local_date + ar.start_local_time) at time zone v_timezone,
            (c.local_date + ar.end_local_time) at time zone v_timezone,
            '[)'
          ) @> tstzrange(c.anchor_start_at, c.core_end_at, '[)')
      )
      or exists (
        select 1
        from public.availability_exceptions ae
        where ae.service_employee_id = p_service_employee_id
          and ae.exception_type = 'OPEN'
          and tstzrange(ae.start_at, ae.end_at, '[)') @> tstzrange(c.anchor_start_at, c.core_end_at, '[)')
      )
    )
    and not exists (
      select 1
      from public.availability_exceptions ae
      where ae.service_employee_id = p_service_employee_id
        and ae.exception_type = 'BLOCK'
        and tstzrange(ae.start_at, ae.end_at, '[)') && tstzrange(c.anchor_start_at, c.core_end_at, '[)')
    )
  ), resource_ranges as materialized (
    select c.anchor_start_at,
      r.resource_id,
      r.occupied_range
    from employee_available_candidates c
    cross join lateral agenda_internal.calculate_booking_resource_ranges_resolved_duration(
      p_service_id,
      p_extra_selections,
      c.anchor_start_at,
      v_contracted_minutes,
      v_service.buffer_before_minutes,
      v_service.buffer_after_minutes
    ) r
  ), resource_google_readiness as materialized (
    select distinct rr.resource_id,
      public.google_resource_sync_is_ready(rr.resource_id, 600) as is_ready
    from resource_ranges rr
  )
  select distinct c.local_date
  from employee_available_candidates c
  where v_employee_google_ready
    and not exists (
      select 1
      from resource_ranges rr
      join resource_google_readiness gr on gr.resource_id = rr.resource_id
      where rr.anchor_start_at = c.anchor_start_at
        and not gr.is_ready
    )
    and not exists (
      select 1
      from resource_ranges rr
      where rr.anchor_start_at = c.anchor_start_at
        and (
          not (
            exists (
              select 1
              from public.resource_availability_rules rar
              where rar.resource_id = rr.resource_id
                and rar.weekday = extract(dow from (lower(rr.occupied_range) at time zone v_timezone)::date)::smallint
                and rar.is_active
                and tstzrange(
                  (((lower(rr.occupied_range) at time zone v_timezone)::date + rar.start_local_time) at time zone v_timezone),
                  (((lower(rr.occupied_range) at time zone v_timezone)::date + rar.end_local_time) at time zone v_timezone),
                  '[)'
                ) @> rr.occupied_range
            )
            or exists (
              select 1
              from public.availability_exceptions ae
              where ae.resource_id = rr.resource_id
                and ae.exception_type = 'OPEN'
                and tstzrange(ae.start_at, ae.end_at, '[)') @> rr.occupied_range
            )
          )
          or exists (
            select 1
            from public.availability_exceptions ae
            where ae.resource_id = rr.resource_id
              and ae.exception_type = 'BLOCK'
              and tstzrange(ae.start_at, ae.end_at, '[)') && rr.occupied_range
          )
          or exists (
            select 1
            from public.resource_allocations ra
            where ra.resource_id = rr.resource_id
              and ra.status in ('HELD','AWAITING_PAYMENT','CONFIRMED','BLOCKED','EXTERNAL_ACTIVE')
              and ra.occupied_range && rr.occupied_range
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
          )
          or exists (
            select 1
            from public.schedule_divergences sd
            where sd.resource_id = rr.resource_id
              and sd.status = 'OPEN'
              and sd.reason = 'GOOGLE_EVENT_CONFLICT'
              and sd.desired_range && rr.occupied_range
          )
        )
    )
    and not exists (
      select 1
      from public.schedule_divergences sd
      where sd.resource_id = v_employee_resource_id
        and sd.status = 'OPEN'
        and sd.reason = 'GOOGLE_EVENT_CONFLICT'
        and sd.desired_range && tstzrange(c.appointment_start_at, c.appointment_end_at, '[)')
    )
    and not exists (
      select 1
      from public.resource_allocations ra
      where ra.resource_id = v_employee_resource_id
        and ra.status in ('HELD','AWAITING_PAYMENT','CONFIRMED','BLOCKED','EXTERNAL_ACTIVE')
        and ra.occupied_range && tstzrange(c.appointment_start_at, c.appointment_end_at, '[)')
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
    )
  order by c.local_date;
end;
$function$;

revoke all on function agenda_internal.list_available_dates_month_v2(text, uuid, uuid, integer, jsonb, integer, date)
  from public, anon, authenticated;
grant execute on function agenda_internal.list_available_dates_month_v2(text, uuid, uuid, integer, jsonb, integer, date)
  to service_role;

comment on function agenda_internal.list_available_dates_month_v2(text, uuid, uuid, integer, jsonb, integer, date) is
  'PR-03 private V2 month engine. Set-based candidate generation over the month; public monthly availability remains on V1 until PR-04.';
