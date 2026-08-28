-- Disposable administrative fixture for BlackSheep /gestao critical-flow E2E tests.
-- Loaded only into the local Supabase stack created by the test runner.
-- It is not a migration and must never be applied to production.
--
-- The helper deliberately delegates to the authoritative RBAC services:
-- - first local admin: service_bootstrap_first_owner (service-role-only primitive);
-- - later local admins: service_admin_register_admin_user with the active OWNER as actor.
--
-- The wrapper exists only because production intentionally revokes direct table grants from
-- service_role. It is SECURITY DEFINER solely inside this disposable local database, and its
-- EXECUTE privilege is revoked from PUBLIC/anon/authenticated before being granted to service_role.

create or replace function public.qa_create_gestao_admin_profile(
  p_auth_user_id uuid,
  p_display_name text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_owner_id uuid;
  v_display_name text := btrim(coalesce(p_display_name, ''));
begin
  if p_auth_user_id is null or not exists (
    select 1 from auth.users where id = p_auth_user_id
  ) then
    raise exception using errcode = 'P0001', message = 'QA_ADMIN_AUTH_USER_NOT_FOUND';
  end if;

  if length(v_display_name) < 2 or length(v_display_name) > 120 then
    raise exception using errcode = 'P0001', message = 'QA_ADMIN_DISPLAY_NAME_INVALID';
  end if;

  if exists (
    select 1 from public.admin_users where auth_user_id = p_auth_user_id
  ) then
    return public.service_admin_get_access_profile(
      (select id from public.admin_users where auth_user_id = p_auth_user_id limit 1)
    );
  end if;

  if not exists (select 1 from public.admin_users) then
    return public.service_bootstrap_first_owner(
      p_auth_user_id,
      v_display_name,
      gen_random_uuid()
    );
  end if;

  select id
    into v_owner_id
  from public.admin_users
  where is_active
    and role = 'OWNER'
  order by created_at asc
  limit 1;

  if v_owner_id is null then
    raise exception using errcode = 'P0001', message = 'QA_ADMIN_ACTIVE_OWNER_NOT_FOUND';
  end if;

  return public.service_admin_register_admin_user(
    p_auth_user_id,
    v_display_name,
    'ADMIN',
    v_owner_id
  );
end;
$$;

revoke all on function public.qa_create_gestao_admin_profile(uuid, text) from public;
revoke all on function public.qa_create_gestao_admin_profile(uuid, text) from anon;
revoke all on function public.qa_create_gestao_admin_profile(uuid, text) from authenticated;
grant execute on function public.qa_create_gestao_admin_profile(uuid, text) to service_role;

comment on function public.qa_create_gestao_admin_profile(uuid, text) is
  'TEST ONLY. Disposable local helper for /gestao E2E. Delegates admin creation to the production RBAC service functions and is executable only by service_role.';