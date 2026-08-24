-- Auditable administrative confirmation for free visits.
create or replace function public.service_admin_confirm_free_visit(
  p_appointment_id uuid,
  p_admin_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path=public
as $$
declare
  v_appointment public.appointments%rowtype;
  v_service public.services%rowtype;
begin
  if not public.service_admin_has_permission(p_admin_id,'AGENDA_MANAGE') then
    raise exception using errcode='42501',message='ADMIN_PERMISSION_DENIED';
  end if;

  select * into v_appointment
  from public.appointments
  where id=p_appointment_id
  for update;
  if not found then
    raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND';
  end if;

  select * into v_service from public.services where id=v_appointment.service_id;
  if not found or v_service.booking_product_type<>'FREE_VISIT' then
    raise exception using errcode='P0001',message='FREE_VISIT_REQUIRED';
  end if;
  if v_appointment.status<>'CONFIRMED' then
    raise exception using errcode='P0001',message='FREE_VISIT_NOT_CONFIRMABLE';
  end if;
  if v_appointment.start_at<=now() then
    raise exception using errcode='P0001',message='FREE_VISIT_ALREADY_STARTED';
  end if;
  if v_appointment.free_visit_confirmation_deadline is not null
     and v_appointment.free_visit_confirmation_deadline<=now() then
    raise exception using errcode='P0001',message='FREE_VISIT_CONFIRMATION_DEADLINE_PASSED';
  end if;

  if v_appointment.free_visit_confirmed_at is null then
    update public.appointments
    set free_visit_confirmed_at=now(),updated_at=now()
    where id=p_appointment_id;

    insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
    values(
      p_admin_id,'APPOINTMENT',p_appointment_id,'FREE_VISIT_CONFIRMED',
      jsonb_build_object('free_visit_confirmed_at',null,'confirmation_deadline',v_appointment.free_visit_confirmation_deadline),
      jsonb_build_object('free_visit_confirmed_at',now(),'confirmation_deadline',v_appointment.free_visit_confirmation_deadline),
      'ADMIN'
    );
  end if;

  return jsonb_build_object(
    'appointment_id',p_appointment_id,
    'confirmed',true,
    'free_visit_confirmed_at',(select free_visit_confirmed_at from public.appointments where id=p_appointment_id),
    'confirmation_deadline',v_appointment.free_visit_confirmation_deadline
  );
end;
$$;

revoke all on function public.service_admin_confirm_free_visit(uuid,uuid) from public,anon,authenticated;
grant execute on function public.service_admin_confirm_free_visit(uuid,uuid) to service_role;
