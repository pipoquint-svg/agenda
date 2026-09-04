-- Item A: restore the administrative no-show RPC still consumed by admin-change-actions.
-- This is the last known production definition, removed while its caller remained active.
create or replace function public.service_admin_mark_appointment_no_show_evidenced(
  p_appointment_id uuid,
  p_reason text,
  p_admin_id uuid,
  p_ip inet,
  p_user_agent text,
  p_request_id text,
  p_session_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public','pg_temp'
as $function$
declare
  v_before jsonb;
  v_after jsonb;
  v_appointment public.appointments%rowtype;
  v_financial jsonb;
begin
  if not public.service_admin_has_permission(p_admin_id,'AGENDA_MANAGE') then
    raise exception using errcode='P0001',message='ADMIN_PERMISSION_DENIED';
  end if;
  if p_ip is null or nullif(btrim(coalesce(p_user_agent,'')),'') is null or nullif(btrim(coalesce(p_request_id,'')),'') is null then
    raise exception using errcode='P0001',message='AUTHORSHIP_ADMIN_EVIDENCE_REQUIRED';
  end if;

  select * into v_appointment
  from public.appointments
  where id=p_appointment_id and deleted_at is null
  for update;
  if not found then
    raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND';
  end if;
  if v_appointment.status<>'CONFIRMED' then
    raise exception using errcode='P0001',message='APPOINTMENT_NOT_ELIGIBLE_FOR_NO_SHOW';
  end if;
  if now()<v_appointment.start_at then
    raise exception using errcode='P0001',message='NO_SHOW_BEFORE_APPOINTMENT_START';
  end if;

  v_before:=public.service_appointment_authorship_snapshot(p_appointment_id);

  update public.appointments
  set status='NO_SHOW',
      no_show_at=now(),
      version=version+1,
      updated_at=now()
  where id=p_appointment_id;

  v_after:=public.service_appointment_authorship_snapshot(p_appointment_id);

  perform public.service_record_appointment_authorship_event(
    p_appointment_id,'ADMIN_UI','APPOINTMENT_NO_SHOW',p_admin_id,null,
    v_before,v_after,nullif(btrim(coalesce(p_reason,'')),''),
    p_ip,p_user_agent,p_request_id,p_session_id,null,null
  );

  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
  values(
    p_admin_id,'APPOINTMENT',p_appointment_id,'APPOINTMENT_NO_SHOW',
    v_before,
    v_after || jsonb_build_object(
      'reason',nullif(btrim(coalesce(p_reason,'')),''),
      'financial_rule','SERVICE_PERFORMED_NO_REFUND_NO_CREDIT_BALANCE_DUE_REMAINS'
    ),
    'ADMIN'
  );

  v_financial:=public.get_appointment_financial_summary(p_appointment_id);

  return jsonb_build_object(
    'appointment_id',p_appointment_id,
    'status','NO_SHOW',
    'no_show_at',now(),
    'financial',v_financial
  );
end;
$function$;

revoke all on function public.service_admin_mark_appointment_no_show_evidenced(uuid,text,uuid,inet,text,text,text) from public;
revoke all on function public.service_admin_mark_appointment_no_show_evidenced(uuid,text,uuid,inet,text,text,text) from anon;
revoke all on function public.service_admin_mark_appointment_no_show_evidenced(uuid,text,uuid,inet,text,text,text) from authenticated;
grant execute on function public.service_admin_mark_appointment_no_show_evidenced(uuid,text,uuid,inet,text,text,text) to service_role;
