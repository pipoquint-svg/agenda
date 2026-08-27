-- Prevent the active administrator from revoking their own TEAM_MANAGE permission.
-- UI already blocks this path; the backend must enforce the same invariant.

create or replace function public.service_admin_set_permission(
  p_target_admin_id uuid,
  p_permission text,
  p_is_granted boolean,
  p_actor_admin_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_before jsonb;
  v_after jsonb;
begin
  if not public.service_admin_has_permission(p_actor_admin_id, 'TEAM_MANAGE') then
    raise exception using errcode = 'P0001', message = 'ADMIN_PERMISSION_DENIED';
  end if;

  if not exists(select 1 from public.admin_users where id = p_target_admin_id) then
    raise exception using errcode = 'P0001', message = 'ADMIN_USER_NOT_FOUND';
  end if;

  if p_permission not in (
    'DASHBOARD_VIEW',
    'AGENDA_VIEW',
    'AGENDA_MANAGE',
    'CUSTOMERS_VIEW',
    'CUSTOMERS_MANAGE',
    'CUSTOMER_ACCESS_DETAIL_VIEW',
    'FINANCE_VIEW',
    'FINANCE_MANAGE',
    'PACKAGES_VIEW',
    'PACKAGES_MANAGE',
    'SERVICES_VIEW',
    'SERVICES_MANAGE',
    'INTEGRATIONS_VIEW',
    'INTEGRATIONS_MANAGE',
    'LEADS_VIEW',
    'LEADS_MANAGE',
    'AUDIT_VIEW',
    'TEAM_MANAGE'
  ) then
    raise exception using errcode = 'P0001', message = 'ADMIN_PERMISSION_INVALID';
  end if;

  if p_target_admin_id = p_actor_admin_id
     and p_permission = 'TEAM_MANAGE'
     and p_is_granted is false then
    raise exception using errcode = 'P0001', message = 'ADMIN_SELF_LOCKOUT_FORBIDDEN';
  end if;

  select public.service_admin_get_access_profile(p_target_admin_id) into v_before;

  insert into public.admin_user_permissions(
    admin_user_id,
    permission,
    is_granted,
    updated_by_admin_id,
    updated_at
  ) values (
    p_target_admin_id,
    p_permission,
    p_is_granted,
    p_actor_admin_id,
    now()
  )
  on conflict(admin_user_id, permission)
  do update set
    is_granted = excluded.is_granted,
    updated_by_admin_id = excluded.updated_by_admin_id,
    updated_at = now();

  select public.service_admin_get_access_profile(p_target_admin_id) into v_after;

  insert into public.audit_logs(
    admin_user_id,
    entity_type,
    entity_id,
    action,
    before_json,
    after_json,
    origin
  ) values (
    p_actor_admin_id,
    'ADMIN_USER',
    p_target_admin_id,
    'PERMISSION_CHANGED',
    v_before,
    v_after,
    'ADMIN'
  );

  return v_after;
end;
$$;
