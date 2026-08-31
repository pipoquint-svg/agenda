-- Service creation from Gestão may include the selected operational employee.
-- The service row, employee assignment and both audit records commit atomically.
-- Draft activation remains a separate, policy-guarded action.

create or replace function public.service_admin_create_service_catalog_with_employee_audited(
  p_category_id uuid,
  p_name text,
  p_slug text,
  p_operation_scope text,
  p_short_description text,
  p_full_description text,
  p_duration_mode text,
  p_base_duration_minutes integer,
  p_base_price numeric,
  p_buffer_before_minutes integer,
  p_buffer_after_minutes integer,
  p_minimum_people integer,
  p_maximum_people integer,
  p_price_per_extra_person numeric,
  p_employee_id uuid,
  p_admin_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_service jsonb;
  v_service_id uuid;
  v_service_employee_id uuid;
begin
  if not public.service_admin_has_permission(p_admin_id, 'SERVICES_MANAGE') then
    raise exception using errcode = 'P0001', message = 'ADMIN_PERMISSION_DENIED';
  end if;

  if not exists (
    select 1
    from public.employees e
    where e.id = p_employee_id
      and e.is_active
  ) then
    raise exception using errcode = 'P0001', message = 'EMPLOYEE_NOT_AVAILABLE';
  end if;

  v_service := public.service_admin_create_service_catalog_audited(
    p_category_id,
    p_name,
    p_slug,
    p_operation_scope,
    p_short_description,
    p_full_description,
    p_duration_mode,
    p_base_duration_minutes,
    p_base_price,
    p_buffer_before_minutes,
    p_buffer_after_minutes,
    p_minimum_people,
    p_maximum_people,
    p_price_per_extra_person,
    p_admin_id
  );
  v_service_id := (v_service->>'id')::uuid;

  insert into public.service_employees(service_id, employee_id, is_active)
  values (v_service_id, p_employee_id, true)
  returning id into v_service_employee_id;

  insert into public.audit_logs(
    admin_user_id,
    entity_type,
    entity_id,
    action,
    before_json,
    after_json,
    origin
  )
  values (
    p_admin_id,
    'SERVICE_EMPLOYEE',
    v_service_employee_id,
    'SERVICE_EMPLOYEE_ASSIGNED_AT_CREATION',
    null,
    jsonb_build_object(
      'service_employee_id', v_service_employee_id,
      'service_id', v_service_id,
      'employee_id', p_employee_id,
      'is_active', true
    ),
    'ADMIN'
  );

  return v_service || jsonb_build_object(
    'employee_id', p_employee_id,
    'service_employee_id', v_service_employee_id
  );
end;
$$;

revoke all on function public.service_admin_create_service_catalog_with_employee_audited(
  uuid,text,text,text,text,text,text,integer,numeric,integer,integer,integer,integer,numeric,uuid,uuid
) from public, anon, authenticated;

grant execute on function public.service_admin_create_service_catalog_with_employee_audited(
  uuid,text,text,text,text,text,text,integer,numeric,integer,integer,integer,integer,numeric,uuid,uuid
) to service_role;

comment on function public.service_admin_create_service_catalog_with_employee_audited(
  uuid,text,text,text,text,text,text,integer,numeric,integer,integer,integer,integer,numeric,uuid,uuid
) is 'Atomically creates an inactive service draft and its selected operational employee assignment, with append-only audit evidence.';
