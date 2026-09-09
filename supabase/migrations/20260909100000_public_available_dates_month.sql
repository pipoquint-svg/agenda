create or replace function public.public_list_available_dates_month(
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
security definer
set search_path = 'public'
as $$
declare
  v_blocks integer;
  v_month_start date;
  v_month_end date;
  v_public_minimum_booking_notice_hours integer := 0;
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

  v_month_start := date_trunc('month', p_month::timestamp)::date;
  v_month_end := (v_month_start + interval '1 month')::date;

  return query
  select d.local_date
  from generate_series(v_month_start, v_month_end - 1, interval '1 day') as g(day)
  cross join lateral (select g.day::date as local_date) d
  where exists (
    select 1
    from public.list_available_slots_for_duration(
      p_service_id,
      p_service_employee_id,
      v_blocks,
      p_extra_selections,
      p_people_count,
      d.local_date,
      null
    ) r
    where v_public_minimum_booking_notice_hours = 0
       or r.slot_start_at >= now() + make_interval(hours => v_public_minimum_booking_notice_hours)
    limit 1
  )
  order by d.local_date;
end;
$$;

revoke all on function public.public_list_available_dates_month(text, uuid, uuid, integer, jsonb, integer, date) from public;
grant execute on function public.public_list_available_dates_month(text, uuid, uuid, integer, jsonb, integer, date) to anon, authenticated, service_role;
