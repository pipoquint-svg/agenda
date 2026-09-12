-- Gestante V2 / reusable public booking primitive:
-- return the first N authoritative slots inside a bounded local-date range.
--
-- The caller decides which date range is editorially relevant (for example,
-- a gestational recommendation window). Availability, resources, external
-- conflicts, extras, people count and public booking notice remain authoritative
-- in the existing backend functions.

begin;

create or replace function agenda_public_bridge.list_available_slots_range_impl(
  p_booking_page_slug text,
  p_service_id uuid,
  p_service_employee_id uuid,
  p_start_date date,
  p_end_date date,
  p_extra_selections jsonb default '[]'::jsonb,
  p_people_count integer default 1,
  p_limit integer default 5
)
returns table(
  slot_start_at timestamptz,
  slot_end_at timestamptz,
  core_start_at timestamptz,
  core_end_at timestamptz,
  pre_service_minutes integer,
  post_service_minutes integer,
  duration_minutes integer,
  commercial_value numeric,
  local_date date
)
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare
  v_day date;
  v_slot record;
  v_returned integer := 0;
  v_public_minimum_booking_notice_hours integer := 0;
begin
  if p_start_date is null or p_end_date is null or p_start_date > p_end_date then
    raise exception 'DATE_RANGE_INVALID' using errcode = '22023';
  end if;

  -- Keep this endpoint cheap enough for anonymous/public traffic. The Gestante
  -- recommendation windows are at most ~3 weeks; 62 days also supports a safe
  -- fallback query without turning this into an unbounded calendar scan.
  if (p_end_date - p_start_date) > 62 then
    raise exception 'DATE_RANGE_TOO_WIDE' using errcode = '22023';
  end if;

  if p_limit is null or p_limit < 1 or p_limit > 10 then
    raise exception 'LIMIT_INVALID' using errcode = '22023';
  end if;

  perform public.assert_public_booking_selection(
    p_booking_page_slug,
    p_service_id,
    p_service_employee_id,
    coalesce(p_extra_selections, '[]'::jsonb),
    p_people_count
  );

  select coalesce(s.public_minimum_booking_notice_hours, 0)
    into v_public_minimum_booking_notice_hours
  from public.services s
  where s.id = p_service_id;

  for v_day in
    select gs::date
    from generate_series(
      p_start_date::timestamp,
      p_end_date::timestamp,
      interval '1 day'
    ) as gs
    order by gs
  loop
    for v_slot in
      select r.*
      from public.list_available_slots(
        p_service_id,
        p_service_employee_id,
        coalesce(p_extra_selections, '[]'::jsonb),
        p_people_count,
        v_day,
        null
      ) r
      where v_public_minimum_booking_notice_hours = 0
         or r.slot_start_at >= now() + make_interval(hours => v_public_minimum_booking_notice_hours)
      order by r.core_start_at
    loop
      slot_start_at := v_slot.slot_start_at;
      slot_end_at := v_slot.slot_end_at;
      core_start_at := v_slot.core_start_at;
      core_end_at := v_slot.core_end_at;
      pre_service_minutes := v_slot.pre_service_minutes;
      post_service_minutes := v_slot.post_service_minutes;
      duration_minutes := v_slot.duration_minutes;
      commercial_value := v_slot.commercial_value;
      local_date := v_day;
      return next;

      v_returned := v_returned + 1;
      if v_returned >= p_limit then
        return;
      end if;
    end loop;
  end loop;
end;
$function$;

revoke all on function agenda_public_bridge.list_available_slots_range_impl(
  text, uuid, uuid, date, date, jsonb, integer, integer
) from public;
grant execute on function agenda_public_bridge.list_available_slots_range_impl(
  text, uuid, uuid, date, date, jsonb, integer, integer
) to anon, authenticated, service_role;

create or replace function public.public_list_available_slots_range(
  p_booking_page_slug text,
  p_service_id uuid,
  p_service_employee_id uuid,
  p_start_date date,
  p_end_date date,
  p_extra_selections jsonb default '[]'::jsonb,
  p_people_count integer default 1,
  p_limit integer default 5
)
returns table(
  slot_start_at timestamptz,
  slot_end_at timestamptz,
  core_start_at timestamptz,
  core_end_at timestamptz,
  pre_service_minutes integer,
  post_service_minutes integer,
  duration_minutes integer,
  commercial_value numeric,
  local_date date
)
language sql
stable
set search_path to ''
as $function$
  select *
  from agenda_public_bridge.list_available_slots_range_impl(
    p_booking_page_slug,
    p_service_id,
    p_service_employee_id,
    p_start_date,
    p_end_date,
    p_extra_selections,
    p_people_count,
    p_limit
  );
$function$;

revoke all on function public.public_list_available_slots_range(
  text, uuid, uuid, date, date, jsonb, integer, integer
) from public;
grant execute on function public.public_list_available_slots_range(
  text, uuid, uuid, date, date, jsonb, integer, integer
) to anon, authenticated, service_role;

commit;
