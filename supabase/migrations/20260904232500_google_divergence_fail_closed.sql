-- Cutover safety for Google-backed availability.
--
-- Two independent concerns are handled here without changing Google events or
-- weakening resource_allocations_no_overlap:
--   1) OPEN GOOGLE_EVENT_CONFLICT rows fail closed for required service
--      resources;
--   2) the selected employee's PERSON resource participates in Google health,
--      external/manual occupancy and divergence checks for the actual session
--      interval (slot_start_at -> slot_end_at).
--
-- The second rule is required because employees.resource_id is already part of
-- calculate_booking_quote().resource_ids, while the low-level service resource
-- range helpers only materialize service_resources/extras.  Personal calendar
-- blocks therefore need an explicit availability gate here.  The shared studio
-- resource remains the authoritative capacity lock between studio services.

create or replace function public.list_available_slots(
  p_service_id uuid,
  p_service_employee_id uuid,
  p_extra_selections jsonb default '[]'::jsonb,
  p_people_count integer default 1,
  p_local_date date default current_date,
  p_coupon_code text default null::text
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
language sql
stable
set search_path to 'public', 'extensions'
as $function$
  select s.*
  from public.list_available_slots_without_google_sync_gate(
    p_service_id,
    p_service_employee_id,
    p_extra_selections,
    p_people_count,
    p_local_date,
    p_coupon_code
  ) s
  where not exists (
    select 1
    from public.calculate_booking_resource_ranges(
      p_service_id,
      p_extra_selections,
      s.core_start_at
    ) r
    where not public.google_resource_sync_is_ready(r.resource_id, 600)
  )
  and not exists (
    select 1
    from public.service_employees se
    join public.employees e on e.id = se.employee_id
    where se.id = p_service_employee_id
      and se.service_id = p_service_id
      and se.is_active
      and e.resource_id is not null
      and not public.google_resource_sync_is_ready(e.resource_id, 600)
  )
  and not exists (
    select 1
    from public.calculate_booking_resource_ranges(
      p_service_id,
      p_extra_selections,
      s.core_start_at
    ) r
    join public.schedule_divergences sd
      on sd.resource_id = r.resource_id
     and sd.status = 'OPEN'
     and sd.reason = 'GOOGLE_EVENT_CONFLICT'
     and sd.desired_range && r.occupied_range
  )
  and not exists (
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
      and sd.desired_range && tstzrange(s.slot_start_at, s.slot_end_at, '[)')
  )
  and not exists (
    select 1
    from public.service_employees se
    join public.employees e on e.id = se.employee_id
    join public.resource_allocations ra on ra.resource_id = e.resource_id
    where se.id = p_service_employee_id
      and se.service_id = p_service_id
      and se.is_active
      and e.resource_id is not null
      and ra.status in ('HELD','AWAITING_PAYMENT','CONFIRMED','BLOCKED','EXTERNAL_ACTIVE')
      and ra.occupied_range && tstzrange(s.slot_start_at, s.slot_end_at, '[)')
      and (
        ra.status <> 'HELD'
        or ra.allocation_type <> 'CHECKOUT_HOLD'
        or exists (
          select 1
          from public.checkout_holds ch
          where ch.id = ra.checkout_hold_id
            and ch.status = 'ACTIVE'
            and ch.expires_at > now()
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
            and a.hold_expires_at <= now()
        )
      )
  );
$function$;

create or replace function public.list_available_slots_for_duration(
  p_service_id uuid,
  p_service_employee_id uuid,
  p_duration_blocks integer default null::integer,
  p_extra_selections jsonb default '[]'::jsonb,
  p_people_count integer default 1,
  p_local_date date default current_date,
  p_coupon_code text default null::text
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
language sql
stable
set search_path to 'public', 'extensions'
as $function$
  select s.*
  from public.list_available_slots_for_duration_without_google_sync_gate(
    p_service_id,
    p_service_employee_id,
    p_duration_blocks,
    p_extra_selections,
    p_people_count,
    p_local_date,
    p_coupon_code
  ) s
  where not exists (
    select 1
    from public.calculate_booking_resource_ranges_for_duration(
      p_service_id,
      p_extra_selections,
      s.core_start_at,
      p_duration_blocks
    ) r
    where not public.google_resource_sync_is_ready(r.resource_id, 600)
  )
  and not exists (
    select 1
    from public.service_employees se
    join public.employees e on e.id = se.employee_id
    where se.id = p_service_employee_id
      and se.service_id = p_service_id
      and se.is_active
      and e.resource_id is not null
      and not public.google_resource_sync_is_ready(e.resource_id, 600)
  )
  and not exists (
    select 1
    from public.calculate_booking_resource_ranges_for_duration(
      p_service_id,
      p_extra_selections,
      s.core_start_at,
      p_duration_blocks
    ) r
    join public.schedule_divergences sd
      on sd.resource_id = r.resource_id
     and sd.status = 'OPEN'
     and sd.reason = 'GOOGLE_EVENT_CONFLICT'
     and sd.desired_range && r.occupied_range
  )
  and not exists (
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
      and sd.desired_range && tstzrange(s.slot_start_at, s.slot_end_at, '[)')
  )
  and not exists (
    select 1
    from public.service_employees se
    join public.employees e on e.id = se.employee_id
    join public.resource_allocations ra on ra.resource_id = e.resource_id
    where se.id = p_service_employee_id
      and se.service_id = p_service_id
      and se.is_active
      and e.resource_id is not null
      and ra.status in ('HELD','AWAITING_PAYMENT','CONFIRMED','BLOCKED','EXTERNAL_ACTIVE')
      and ra.occupied_range && tstzrange(s.slot_start_at, s.slot_end_at, '[)')
      and (
        ra.status <> 'HELD'
        or ra.allocation_type <> 'CHECKOUT_HOLD'
        or exists (
          select 1
          from public.checkout_holds ch
          where ch.id = ra.checkout_hold_id
            and ch.status = 'ACTIVE'
            and ch.expires_at > coalesce(
              nullif(current_setting('agenda.test_now', true), '')::timestamptz,
              now()
            )
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
            and a.hold_expires_at <= coalesce(
              nullif(current_setting('agenda.test_now', true), '')::timestamptz,
              now()
            )
        )
      )
  );
$function$;
