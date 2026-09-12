-- PR-02: internal compatibility seam for request-constant duration data.
-- LEGACY SINGLE-TENANT COMPATIBILITY: timezone remains resolved from
-- operation_settings.id = 1 by the caller; this migration does not model tenants.

create or replace function agenda_internal.calculate_booking_resource_ranges_resolved_duration(
  p_service_id uuid,
  p_extra_selections jsonb,
  p_anchor_start_at timestamptz,
  p_contracted_minutes integer,
  p_buffer_before_minutes integer,
  p_buffer_after_minutes integer
)
returns table(resource_id uuid, occupied_range tstzrange)
language sql
stable
set search_path = ''
as $$
  with profile as (
    select public.resolve_extra_schedule_profile(p_service_id, p_extra_selections, p_anchor_start_at) as value
  ), bounds as (
    select p_anchor_start_at as core_start_at,
      p_anchor_start_at + make_interval(mins => p_contracted_minutes) as core_end_at,
      p_anchor_start_at - make_interval(mins => coalesce((value->>'pre_service_minutes')::integer, 0)) as appointment_start_at,
      p_anchor_start_at + make_interval(mins => p_contracted_minutes + coalesce((value->>'post_service_minutes')::integer, 0)) as appointment_end_at,
      value from profile
  ), ranges as (
    select sr.resource_id, tstzrange(b.core_start_at - make_interval(mins => p_buffer_before_minutes), b.core_end_at + make_interval(mins => p_buffer_after_minutes), '[)') as r
    from public.service_resources sr cross join bounds b where sr.service_id=p_service_id and sr.is_required
    union all
    select er.resource_id, case d.placement when 'PREPEND' then tstzrange(b.appointment_start_at,b.core_start_at,'[)') when 'APPEND' then tstzrange(b.core_end_at,b.appointment_end_at,'[)') end
    from bounds b cross join lateral jsonb_to_recordset(b.value->'details') d(extra_id uuid, quantity integer, placement text, minutes_per_unit integer, total_schedule_minutes integer)
    join public.extra_resources er on er.extra_id=d.extra_id and er.is_required where d.total_schedule_minutes>0
  )
  select resource_id, tstzrange(min(lower(r)),max(upper(r)),'[)') from ranges where r is not null and not isempty(r) group by resource_id;
$$;

revoke all on function agenda_internal.calculate_booking_resource_ranges_resolved_duration(uuid,jsonb,timestamptz,integer,integer,integer) from public, anon, authenticated;
grant execute on function agenda_internal.calculate_booking_resource_ranges_resolved_duration(uuid,jsonb,timestamptz,integer,integer,integer) to service_role;

do $migration$
declare v_oid oid; v_def text; v_old text := E'public.calculate_booking_resource_ranges_for_duration(\n        p_service_id,\n        p_extra_selections,\n        v_anchor_start,\n        p_duration_blocks\n      )'; v_new text := E'agenda_internal.calculate_booking_resource_ranges_resolved_duration(\n        p_service_id,\n        p_extra_selections,\n        v_anchor_start,\n        v_contracted_minutes,\n        v_service.buffer_before_minutes,\n        v_service.buffer_after_minutes\n      )';
begin
 select p.oid into v_oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='list_available_slots_for_duration_without_google_sync_gate' and pg_get_function_identity_arguments(p.oid)='p_service_id uuid, p_service_employee_id uuid, p_duration_blocks integer, p_extra_selections jsonb, p_people_count integer, p_local_date date, p_coupon_code text';
 if v_oid is null then raise exception 'duration slot function not found'; end if;
 v_def:=pg_get_functiondef(v_oid); if position(v_old in v_def)=0 then raise exception 'expected resource range call not found'; end if; execute replace(v_def,v_old,v_new);
end $migration$;
