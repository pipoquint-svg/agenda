-- Manage where Agenda writes reservations for each service/employee assignment.
-- OAuth/account connection is intentionally outside this RPC; only already-discovered active calendars may be mapped.

create or replace function public.admin_set_service_employee_write_calendar_audited(
  p_service_employee_id uuid,
  p_google_calendar_id uuid,
  p_time_scope text,
  p_admin_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path=public
as $$
declare
  v_before jsonb;
  v_after jsonb;
  v_scope text:=upper(btrim(coalesce(p_time_scope,'')));
begin
  if not public.service_admin_has_permission(p_admin_id,'INTEGRATIONS_MANAGE') then
    raise exception using errcode='P0001',message='ADMIN_PERMISSION_DENIED';
  end if;
  if not exists(select 1 from public.service_employees where id=p_service_employee_id and is_active) then
    raise exception using errcode='P0001',message='SERVICE_EMPLOYEE_NOT_FOUND';
  end if;
  if v_scope not in ('FULL_APPOINTMENT','CORE_ONLY') then
    raise exception using errcode='P0001',message='GOOGLE_WRITE_TIME_SCOPE_INVALID';
  end if;
  if not exists(
    select 1 from public.google_calendars
    where id=p_google_calendar_id and is_active and access_role in ('writer','owner')
  ) then
    raise exception using errcode='P0001',message='GOOGLE_CALENDAR_WRITE_ACCESS_REQUIRED';
  end if;

  select to_jsonb(x) into v_before
  from public.service_employee_calendar_write x
  where x.service_employee_id=p_service_employee_id;

  insert into public.service_employee_calendar_write(service_employee_id,google_calendar_id,time_scope)
  values(p_service_employee_id,p_google_calendar_id,v_scope)
  on conflict(service_employee_id) do update
  set google_calendar_id=excluded.google_calendar_id,time_scope=excluded.time_scope,updated_at=now();

  select to_jsonb(x) into v_after
  from public.service_employee_calendar_write x
  where x.service_employee_id=p_service_employee_id;

  if v_before is distinct from v_after then
    insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
    values(p_admin_id,'SERVICE_EMPLOYEE',p_service_employee_id,'GOOGLE_WRITE_CALENDAR_UPDATED',v_before,v_after,'ADMIN');
  end if;
  return v_after;
end;
$$;

create or replace function public.admin_clear_service_employee_write_calendar_audited(
  p_service_employee_id uuid,
  p_admin_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path=public
as $$
declare v_before jsonb;
begin
  if not public.service_admin_has_permission(p_admin_id,'INTEGRATIONS_MANAGE') then
    raise exception using errcode='P0001',message='ADMIN_PERMISSION_DENIED';
  end if;
  select to_jsonb(x) into v_before
  from public.service_employee_calendar_write x
  where x.service_employee_id=p_service_employee_id for update;
  if v_before is null then return jsonb_build_object('removed',false); end if;
  delete from public.service_employee_calendar_write where service_employee_id=p_service_employee_id;
  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
  values(p_admin_id,'SERVICE_EMPLOYEE',p_service_employee_id,'GOOGLE_WRITE_CALENDAR_CLEARED',v_before,null,'ADMIN');
  return jsonb_build_object('removed',true,'service_employee_id',p_service_employee_id);
end;
$$;

revoke all on function public.admin_set_service_employee_write_calendar_audited(uuid,uuid,text,uuid) from public,anon,authenticated;
revoke all on function public.admin_clear_service_employee_write_calendar_audited(uuid,uuid) from public,anon,authenticated;
grant execute on function public.admin_set_service_employee_write_calendar_audited(uuid,uuid,text,uuid) to service_role;
grant execute on function public.admin_clear_service_employee_write_calendar_audited(uuid,uuid) to service_role;
