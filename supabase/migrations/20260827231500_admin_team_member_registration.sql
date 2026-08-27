-- Registers an already-created Auth user as an administrative team member.
-- OWNER promotion is intentionally excluded from the normal UI workflow.

create or replace function public.service_admin_register_admin_user(
  p_auth_user_id uuid,
  p_display_name text,
  p_role text,
  p_actor_admin_id uuid
)
returns jsonb
language plpgsql
volatile
set search_path = public
as $$
declare
  v_role text := upper(btrim(coalesce(p_role, '')));
  v_admin_id uuid;
  v_after jsonb;
begin
  if not public.service_admin_has_permission(p_actor_admin_id, 'TEAM_MANAGE') then
    raise exception using errcode='P0001', message='ADMIN_PERMISSION_DENIED';
  end if;

  if p_auth_user_id is null then
    raise exception using errcode='P0001', message='ADMIN_AUTH_USER_REQUIRED';
  end if;
  if nullif(btrim(p_display_name), '') is null then
    raise exception using errcode='P0001', message='ADMIN_DISPLAY_NAME_REQUIRED';
  end if;
  if v_role not in ('ADMIN','OPERATION','FINANCE') then
    raise exception using errcode='P0001', message='ADMIN_ROLE_INVALID';
  end if;
  if exists(select 1 from public.admin_users where auth_user_id=p_auth_user_id) then
    raise exception using errcode='P0001', message='ADMIN_USER_ALREADY_REGISTERED';
  end if;

  insert into public.admin_users(auth_user_id, display_name, role, is_active)
  values(p_auth_user_id, btrim(p_display_name), v_role, true)
  returning id into v_admin_id;

  select public.service_admin_get_access_profile(v_admin_id) into v_after;

  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
  values(p_actor_admin_id,'ADMIN_USER',v_admin_id,'ADMIN_USER_CREATED',null,v_after,'ADMIN');

  return v_after;
end;
$$;

revoke all on function public.service_admin_register_admin_user(uuid,text,text,uuid) from public,anon,authenticated;
grant execute on function public.service_admin_register_admin_user(uuid,text,text,uuid) to service_role;

comment on function public.service_admin_register_admin_user(uuid,text,text,uuid) is
  'Registers a server-created Auth user as ADMIN, OPERATION or FINANCE. OWNER changes require a separate controlled migration.';
