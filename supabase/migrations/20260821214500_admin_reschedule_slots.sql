-- Admin slot discovery for rescheduling. Uses the same authoritative availability
-- engine as checkout while preserving the original appointment's service, duration,
-- people count and extras. Existing slot remains occupied until a hold is created/applied.

create or replace function public.service_admin_list_reschedule_slots(
  p_appointment_id uuid,
  p_local_date date
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_appointment public.appointments%rowtype;
  v_extras jsonb;
begin
  if p_local_date is null then
    raise exception using errcode = 'P0001', message = 'RESCHEDULE_DATE_REQUIRED';
  end if;

  select * into v_appointment
  from public.appointments
  where id = p_appointment_id
    and deleted_at is null;

  if not found then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_NOT_FOUND';
  end if;

  if v_appointment.status <> 'CONFIRMED' then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_NOT_RESCHEDULABLE';
  end if;

  if exists (
    select 1
    from public.appointment_package_usage apu
    where apu.appointment_id = p_appointment_id
      and apu.reversal_movement_id is null
  ) then
    raise exception using errcode = 'P0001', message = 'RESCHEDULE_PACKAGE_RECONCILIATION_REQUIRED';
  end if;

  select coalesce(jsonb_agg(
    jsonb_build_object('extra_id', ae.extra_id, 'quantity', ae.quantity)
    order by ae.extra_id
  ), '[]'::jsonb)
  into v_extras
  from public.appointment_extras ae
  where ae.appointment_id = p_appointment_id
    and ae.extra_id is not null;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'slot_start_at', s.slot_start_at,
      'slot_end_at', s.slot_end_at,
      'core_start_at', s.core_start_at,
      'core_end_at', s.core_end_at,
      'pre_service_minutes', s.pre_service_minutes,
      'post_service_minutes', s.post_service_minutes,
      'duration_minutes', s.duration_minutes
    ) order by s.slot_start_at)
    from public.list_available_slots_for_duration(
      v_appointment.service_id,
      v_appointment.service_employee_id,
      v_appointment.duration_blocks,
      v_extras,
      v_appointment.people_count,
      p_local_date,
      null
    ) s
  ), '[]'::jsonb);
end;
$$;

revoke all on function public.service_admin_list_reschedule_slots(uuid,date) from public, anon, authenticated;
grant execute on function public.service_admin_list_reschedule_slots(uuid,date) to service_role;

comment on function public.service_admin_list_reschedule_slots(uuid,date) is
  'Lists valid replacement slots for an existing confirmed appointment using its original service, duration, extras and people count. Package-backed appointments remain blocked pending package reconciliation.';
