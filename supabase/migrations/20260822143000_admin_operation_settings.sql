-- Explicit admin configuration for dashboard occupancy base resource.
-- No resource is inferred or auto-selected.

create or replace function public.service_admin_get_operation_settings()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'dashboard_occupancy_resource_id', os.dashboard_occupancy_resource_id,
    'dashboard_occupancy_resource', case
      when r.id is null then null
      else jsonb_build_object(
        'id', r.id,
        'name', r.name,
        'resource_type', r.resource_type,
        'is_active', r.is_active
      )
    end,
    'eligible_occupancy_resources', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', er.id,
        'name', er.name,
        'resource_type', er.resource_type,
        'is_active', er.is_active
      ) order by er.name)
      from public.resources er
      where er.resource_type = 'PHYSICAL'
        and er.is_active = true
    ), '[]'::jsonb)
  )
  from public.operation_settings os
  left join public.resources r on r.id = os.dashboard_occupancy_resource_id
  where os.id = 1;
$$;

create or replace function public.service_admin_set_dashboard_occupancy_resource(
  p_resource_id uuid,
  p_actor_admin_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_before jsonb;
  v_after jsonb;
  v_resource public.resources%rowtype;
begin
  if not exists (
    select 1 from public.admin_users
    where id = p_actor_admin_id and is_active = true
  ) then
    raise exception using errcode = 'P0001', message = 'ADMIN_USER_NOT_FOUND';
  end if;

  if p_resource_id is not null then
    select * into v_resource from public.resources where id = p_resource_id;
    if not found then
      raise exception using errcode = 'P0001', message = 'OCCUPANCY_RESOURCE_NOT_FOUND';
    end if;
    if v_resource.resource_type <> 'PHYSICAL' or v_resource.is_active is not true then
      raise exception using errcode = 'P0001', message = 'OCCUPANCY_RESOURCE_NOT_ELIGIBLE';
    end if;
  end if;

  select public.service_admin_get_operation_settings() into v_before;

  update public.operation_settings
  set dashboard_occupancy_resource_id = p_resource_id,
      updated_at = now()
  where id = 1;

  select public.service_admin_get_operation_settings() into v_after;

  if (v_before->>'dashboard_occupancy_resource_id') is distinct from (v_after->>'dashboard_occupancy_resource_id') then
    insert into public.audit_logs(
      admin_user_id, entity_type, entity_id, action,
      before_json, after_json, origin
    ) values (
      p_actor_admin_id,
      'OPERATION_SETTINGS',
      null,
      'DASHBOARD_OCCUPANCY_RESOURCE_CHANGED',
      v_before,
      v_after,
      'ADMIN'
    );
  end if;

  return v_after;
end;
$$;

revoke all on function public.service_admin_get_operation_settings() from public, anon, authenticated;
grant execute on function public.service_admin_get_operation_settings() to service_role;

revoke all on function public.service_admin_set_dashboard_occupancy_resource(uuid,uuid) from public, anon, authenticated;
grant execute on function public.service_admin_set_dashboard_occupancy_resource(uuid,uuid) to service_role;

comment on function public.service_admin_get_operation_settings() is
  'Admin read model for operation settings; occupancy resources are explicit active PHYSICAL resources only.';
comment on function public.service_admin_set_dashboard_occupancy_resource(uuid,uuid) is
  'Admin mutation for explicit dashboard occupancy resource selection with audit before/after.';
