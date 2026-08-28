-- Resolve an active administrative profile from the authenticated Supabase user.
--
-- Edge Functions validate the bearer token with Auth first and then call this
-- service-role-only boundary. Direct SELECT on admin_users remains unavailable
-- to application roles and to service_role.

create or replace function public.service_admin_get_access_profile_by_auth_user(
  p_auth_user_id uuid
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select public.service_admin_get_access_profile(a.id)
  from public.admin_users a
  where a.auth_user_id = p_auth_user_id
    and a.is_active = true
  limit 1;
$$;

revoke all on function public.service_admin_get_access_profile_by_auth_user(uuid)
  from public, anon, authenticated;
grant execute on function public.service_admin_get_access_profile_by_auth_user(uuid)
  to service_role;

comment on function public.service_admin_get_access_profile_by_auth_user(uuid) is
  'Service-role-only resolver used after Supabase Auth validates the administrative bearer token.';
