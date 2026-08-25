-- Unified employee administration for service assignments, recurring work hours and exceptions.

alter table public.employees add column if not exists notes text;

create or replace function public.admin_list_employees()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
select coalesce(jsonb_agg(jsonb_build_object(
  'id', e.id,
  'name', e.name,
  'email', e.email,
  'phone', e.phone,
  'notes', e.notes,
  'is_active', e.is_active,
  'resource_id', e.resource_id,
  'service_assignments', coalesce((
    select jsonb_agg(jsonb_build_object(
      'service_employee_id', se.id,
      'service_id', se.service_id,
      'service_name', s.name,
      'operation_scope', s.operation_scope,
      'category_id', s.category_id,
      'is_active', se.is_active,
      'work_hours', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', ar.id, 'weekday', ar.weekday, 'start_local_time', ar.start_local_time,
          'end_local_time', ar.end_local_time, 'slot_interval_minutes', ar.slot_interval_minutes,
          'is_active', ar.is_active
        ) order by ar.weekday, ar.start_local_time, ar.id)
        from public.availability_rules ar where ar.service_employee_id=se.id
      ), '[]'::jsonb),
      'exceptions', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', ax.id, 'exception_type', ax.exception_type, 'start_at', ax.start_at,
          'end_at', ax.end_at, 'reason', ax.reason, 'created_at', ax.created_at
        ) order by ax.start_at, ax.id)
        from public.availability_exceptions ax where ax.service_employee_id=se.id and ax.end_at >= now() - interval '30 days'
      ), '[]'::jsonb),
      'write_calendar', (
        select jsonb_build_object(
          'google_calendar_id', secw.google_calendar_id,
          'calendar_name', gc.name,
          'time_scope', secw.time_scope
        )
        from public.service_employee_calendar_write secw
        join public.google_calendars gc on gc.id=secw.google_calendar_id
        where secw.service_employee_id=se.id
      )
    ) order by s.operation_scope, s.name, se.id)
    from public.service_employees se join public.services s on s.id=se.service_id
    where se.employee_id=e.id
  ), '[]'::jsonb)
) order by e.name,e.id),'[]'::jsonb)
from public.employees e;
$$;

create or replace function public.admin_create_employee_audited(
  p_name text,p_email text,p_phone text,p_notes text,p_admin_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path=public
as $$
declare v_id uuid; v_after jsonb;
begin
  if not public.service_admin_has_permission(p_admin_id,'SERVICES_MANAGE') then raise exception using errcode='P0001',message='ADMIN_PERMISSION_DENIED'; end if;
  if nullif(btrim(p_name),'') is null then raise exception using errcode='P0001',message='EMPLOYEE_NAME_REQUIRED'; end if;
  insert into public.employees(name,email,phone,notes,is_active)
  values(btrim(p_name),nullif(lower(btrim(p_email)),''),nullif(btrim(p_phone),''),nullif(btrim(p_notes),''),true)
  returning id into v_id;
  select item into v_after from jsonb_array_elements(public.admin_list_employees()) item where item->>'id'=v_id::text limit 1;
  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
  values(p_admin_id,'EMPLOYEE',v_id,'EMPLOYEE_CREATED',null,v_after,'ADMIN');
  return v_after;
end;
$$;

create or replace function public.admin_update_employee_audited(
  p_employee_id uuid,p_name text,p_email text,p_phone text,p_notes text,p_is_active boolean,p_admin_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path=public
as $$
declare v_before jsonb; v_after jsonb;
begin
  if not public.service_admin_has_permission(p_admin_id,'SERVICES_MANAGE') then raise exception using errcode='P0001',message='ADMIN_PERMISSION_DENIED'; end if;
  select item into v_before from jsonb_array_elements(public.admin_list_employees()) item where item->>'id'=p_employee_id::text limit 1;
  if v_before is null then raise exception using errcode='P0001',message='EMPLOYEE_NOT_FOUND'; end if;
  if nullif(btrim(p_name),'') is null then raise exception using errcode='P0001',message='EMPLOYEE_NAME_REQUIRED'; end if;
  update public.employees set name=btrim(p_name),email=nullif(lower(btrim(p_email)),''),phone=nullif(btrim(p_phone),''),notes=nullif(btrim(p_notes),''),is_active=coalesce(p_is_active,true),updated_at=now() where id=p_employee_id;
  select item into v_after from jsonb_array_elements(public.admin_list_employees()) item where item->>'id'=p_employee_id::text limit 1;
  if v_before is distinct from v_after then insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin) values(p_admin_id,'EMPLOYEE',p_employee_id,'EMPLOYEE_UPDATED',v_before,v_after,'ADMIN'); end if;
  return v_after;
end;
$$;

create or replace function public.admin_replace_employee_services_audited(
  p_employee_id uuid,p_service_ids uuid[],p_admin_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path=public
as $$
declare v_before jsonb; v_after jsonb; v_service_id uuid;
begin
  if not public.service_admin_has_permission(p_admin_id,'SERVICES_MANAGE') then raise exception using errcode='P0001',message='ADMIN_PERMISSION_DENIED'; end if;
  if not exists(select 1 from public.employees where id=p_employee_id) then raise exception using errcode='P0001',message='EMPLOYEE_NOT_FOUND'; end if;
  if exists(select 1 from unnest(coalesce(p_service_ids,'{}'::uuid[])) sid where not exists(select 1 from public.services s where s.id=sid and s.is_active)) then raise exception using errcode='P0001',message='EMPLOYEE_SERVICE_NOT_AVAILABLE'; end if;
  select item into v_before from jsonb_array_elements(public.admin_list_employees()) item where item->>'id'=p_employee_id::text limit 1;
  update public.service_employees set is_active=false where employee_id=p_employee_id and not (service_id=any(coalesce(p_service_ids,'{}'::uuid[])));
  foreach v_service_id in array coalesce(p_service_ids,'{}'::uuid[]) loop
    insert into public.service_employees(service_id,employee_id,is_active)
    values(v_service_id,p_employee_id,true)
    on conflict(service_id,employee_id) do update set is_active=true;
  end loop;
  select item into v_after from jsonb_array_elements(public.admin_list_employees()) item where item->>'id'=p_employee_id::text limit 1;
  if v_before is distinct from v_after then insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin) values(p_admin_id,'EMPLOYEE',p_employee_id,'EMPLOYEE_SERVICES_UPDATED',v_before,v_after,'ADMIN'); end if;
  return v_after;
end;
$$;

create or replace function public.admin_replace_work_hours_audited(
  p_service_employee_id uuid,p_rules jsonb,p_admin_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path=public
as $$
declare v_before jsonb; v_after jsonb; v_rule jsonb;
begin
  if not public.service_admin_has_permission(p_admin_id,'SERVICES_MANAGE') then raise exception using errcode='P0001',message='ADMIN_PERMISSION_DENIED'; end if;
  if not exists(select 1 from public.service_employees where id=p_service_employee_id) then raise exception using errcode='P0001',message='SERVICE_EMPLOYEE_NOT_FOUND'; end if;
  if jsonb_typeof(coalesce(p_rules,'[]'::jsonb))<>'array' then raise exception using errcode='P0001',message='WORK_HOURS_INVALID'; end if;
  select coalesce(jsonb_agg(to_jsonb(ar) order by ar.weekday,ar.start_local_time,ar.id),'[]'::jsonb) into v_before from public.availability_rules ar where ar.service_employee_id=p_service_employee_id;
  delete from public.availability_rules where service_employee_id=p_service_employee_id;
  for v_rule in select value from jsonb_array_elements(coalesce(p_rules,'[]'::jsonb)) loop
    if (v_rule->>'weekday')::integer not between 0 and 6 or (v_rule->>'end_local_time')::time <= (v_rule->>'start_local_time')::time then raise exception using errcode='P0001',message='WORK_HOURS_INVALID'; end if;
    insert into public.availability_rules(service_employee_id,weekday,start_local_time,end_local_time,slot_interval_minutes,is_active)
    values(p_service_employee_id,(v_rule->>'weekday')::smallint,(v_rule->>'start_local_time')::time,(v_rule->>'end_local_time')::time,coalesce((v_rule->>'slot_interval_minutes')::integer,30),coalesce((v_rule->>'is_active')::boolean,true));
  end loop;
  select coalesce(jsonb_agg(to_jsonb(ar) order by ar.weekday,ar.start_local_time,ar.id),'[]'::jsonb) into v_after from public.availability_rules ar where ar.service_employee_id=p_service_employee_id;
  if v_before is distinct from v_after then insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin) values(p_admin_id,'SERVICE_EMPLOYEE',p_service_employee_id,'WORK_HOURS_UPDATED',v_before,v_after,'ADMIN'); end if;
  return v_after;
end;
$$;

create or replace function public.admin_add_employee_exception_audited(
  p_service_employee_id uuid,p_exception_type text,p_start_at timestamptz,p_end_at timestamptz,p_reason text,p_admin_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path=public
as $$
declare v_id uuid; v_type text:=upper(btrim(coalesce(p_exception_type,''))); v_after jsonb;
begin
  if not public.service_admin_has_permission(p_admin_id,'SERVICES_MANAGE') then raise exception using errcode='P0001',message='ADMIN_PERMISSION_DENIED'; end if;
  if v_type not in ('BLOCK','OPEN') then raise exception using errcode='P0001',message='AVAILABILITY_EXCEPTION_TYPE_INVALID'; end if;
  if p_end_at<=p_start_at then raise exception using errcode='P0001',message='AVAILABILITY_EXCEPTION_RANGE_INVALID'; end if;
  if not exists(select 1 from public.service_employees where id=p_service_employee_id) then raise exception using errcode='P0001',message='SERVICE_EMPLOYEE_NOT_FOUND'; end if;
  insert into public.availability_exceptions(service_employee_id,exception_type,start_at,end_at,reason,created_by)
  values(p_service_employee_id,v_type,p_start_at,p_end_at,nullif(btrim(p_reason),''),p_admin_id) returning id into v_id;
  select to_jsonb(ax) into v_after from public.availability_exceptions ax where ax.id=v_id;
  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin) values(p_admin_id,'AVAILABILITY_EXCEPTION',v_id,'AVAILABILITY_EXCEPTION_CREATED',null,v_after,'ADMIN');
  return v_after;
end;
$$;

create or replace function public.admin_remove_employee_exception_audited(p_exception_id uuid,p_admin_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path=public
as $$
declare v_before jsonb;
begin
  if not public.service_admin_has_permission(p_admin_id,'SERVICES_MANAGE') then raise exception using errcode='P0001',message='ADMIN_PERMISSION_DENIED'; end if;
  select to_jsonb(ax) into v_before from public.availability_exceptions ax where ax.id=p_exception_id for update;
  if v_before is null then raise exception using errcode='P0001',message='AVAILABILITY_EXCEPTION_NOT_FOUND'; end if;
  delete from public.availability_exceptions where id=p_exception_id;
  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin) values(p_admin_id,'AVAILABILITY_EXCEPTION',p_exception_id,'AVAILABILITY_EXCEPTION_DELETED',v_before,null,'ADMIN');
  return jsonb_build_object('exception_id',p_exception_id,'removed',true);
end;
$$;

revoke all on function public.admin_list_employees() from public,anon,authenticated;
revoke all on function public.admin_create_employee_audited(text,text,text,text,uuid) from public,anon,authenticated;
revoke all on function public.admin_update_employee_audited(uuid,text,text,text,text,boolean,uuid) from public,anon,authenticated;
revoke all on function public.admin_replace_employee_services_audited(uuid,uuid[],uuid) from public,anon,authenticated;
revoke all on function public.admin_replace_work_hours_audited(uuid,jsonb,uuid) from public,anon,authenticated;
revoke all on function public.admin_add_employee_exception_audited(uuid,text,timestamptz,timestamptz,text,uuid) from public,anon,authenticated;
revoke all on function public.admin_remove_employee_exception_audited(uuid,uuid) from public,anon,authenticated;
grant execute on function public.admin_list_employees() to service_role;
grant execute on function public.admin_create_employee_audited(text,text,text,text,uuid) to service_role;
grant execute on function public.admin_update_employee_audited(uuid,text,text,text,text,boolean,uuid) to service_role;
grant execute on function public.admin_replace_employee_services_audited(uuid,uuid[],uuid) to service_role;
grant execute on function public.admin_replace_work_hours_audited(uuid,jsonb,uuid) to service_role;
grant execute on function public.admin_add_employee_exception_audited(uuid,text,timestamptz,timestamptz,text,uuid) to service_role;
grant execute on function public.admin_remove_employee_exception_audited(uuid,uuid) to service_role;
