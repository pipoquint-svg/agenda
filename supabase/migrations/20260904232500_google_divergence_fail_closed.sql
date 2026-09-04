-- Fail closed while a blocking Google event cannot be represented as an
-- active resource allocation because another allocation already overlaps it.
--
-- schedule_divergences.desired_range is the authoritative blocked interval
-- captured by apply_google_calendar_event_state().  Public availability and
-- checkout-hold creation already flow through these two listing functions, so
-- filtering here prevents known Google conflicts from being offered/reserved
-- without weakening resource_allocations_no_overlap.

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
  );
$function$;
