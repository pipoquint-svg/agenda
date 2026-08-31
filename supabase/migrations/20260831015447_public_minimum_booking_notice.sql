alter table public.services
  add column public_minimum_booking_notice_hours integer not null default 0;

alter table public.services
  add constraint services_public_minimum_booking_notice_hours_nonnegative
  check (public_minimum_booking_notice_hours >= 0);

comment on column public.services.public_minimum_booking_notice_hours is
  'Canonical minimum lead time in hours for public booking availability only. Applied only by public availability wrappers; 0 preserves existing public behavior.';

comment on column public.services.minimum_booking_notice_minutes is
  'LEGACY core/global minimum lead time in minutes. Keep at 0; do not use for public-only lead time. Candidate for separate future retirement after dependency inventory and compatibility work.';

create or replace function public.public_list_available_slots(
  p_booking_page_slug text,
  p_service_id uuid,
  p_service_employee_id uuid,
  p_extra_selections jsonb default '[]'::jsonb,
  p_people_count integer default 1,
  p_local_date date default current_date
)
returns table(
  slot_start_at timestamp with time zone,
  slot_end_at timestamp with time zone,
  core_start_at timestamp with time zone,
  core_end_at timestamp with time zone,
  pre_service_minutes integer,
  post_service_minutes integer,
  duration_minutes integer,
  commercial_value numeric
)
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_public_minimum_booking_notice_hours integer := 0;
begin
  perform public.assert_public_booking_selection(
    p_booking_page_slug,
    p_service_id,
    p_service_employee_id,
    p_extra_selections,
    p_people_count
  );

  select coalesce(s.public_minimum_booking_notice_hours, 0)
    into v_public_minimum_booking_notice_hours
  from public.services s
  where s.id = p_service_id;

  return query
  select r.*
  from public.list_available_slots(
    p_service_id,
    p_service_employee_id,
    p_extra_selections,
    p_people_count,
    p_local_date,
    null
  ) r
  where v_public_minimum_booking_notice_hours = 0
     or r.slot_start_at >= now() + make_interval(hours => v_public_minimum_booking_notice_hours);
end;
$function$;

create or replace function public.public_list_available_slots_duration(
  p_booking_page_slug text,
  p_service_id uuid,
  p_service_employee_id uuid,
  p_duration_blocks integer,
  p_extra_selections jsonb default '[]'::jsonb,
  p_people_count integer default 1,
  p_local_date date default current_date
)
returns table(
  slot_start_at timestamp with time zone,
  slot_end_at timestamp with time zone,
  core_start_at timestamp with time zone,
  core_end_at timestamp with time zone,
  pre_service_minutes integer,
  post_service_minutes integer,
  duration_minutes integer,
  commercial_value numeric
)
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_public_minimum_booking_notice_hours integer := 0;
begin
  perform public.assert_public_booking_duration(
    p_booking_page_slug,
    p_service_id,
    p_service_employee_id,
    p_duration_blocks,
    p_extra_selections,
    p_people_count
  );

  select coalesce(s.public_minimum_booking_notice_hours, 0)
    into v_public_minimum_booking_notice_hours
  from public.services s
  where s.id = p_service_id;

  return query
  select r.*
  from public.list_available_slots_for_duration(
    p_service_id,
    p_service_employee_id,
    p_duration_blocks,
    p_extra_selections,
    p_people_count,
    p_local_date,
    null
  ) r
  where v_public_minimum_booking_notice_hours = 0
     or r.slot_start_at >= now() + make_interval(hours => v_public_minimum_booking_notice_hours);
end;
$function$;

create or replace function public.public_list_available_slots_minutes(
  p_booking_page_slug text,
  p_service_id uuid,
  p_service_employee_id uuid,
  p_contracted_minutes integer,
  p_extra_selections jsonb default '[]'::jsonb,
  p_people_count integer default 1,
  p_local_date date default current_date
)
returns table(
  slot_start_at timestamp with time zone,
  slot_end_at timestamp with time zone,
  core_start_at timestamp with time zone,
  core_end_at timestamp with time zone,
  pre_service_minutes integer,
  post_service_minutes integer,
  duration_minutes integer,
  commercial_value numeric
)
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_blocks integer;
  v_public_minimum_booking_notice_hours integer := 0;
begin
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

  return query
  select r.*
  from public.list_available_slots_for_duration(
    p_service_id,
    p_service_employee_id,
    v_blocks,
    p_extra_selections,
    p_people_count,
    p_local_date,
    null
  ) r
  where v_public_minimum_booking_notice_hours = 0
     or r.slot_start_at >= now() + make_interval(hours => v_public_minimum_booking_notice_hours);
end;
$function$;
