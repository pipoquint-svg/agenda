-- Resolve an authenticated Supabase user to the active administrative identity
-- without restoring direct service_role access to public.admin_users.
--
-- Admin Edge Functions authenticate the bearer token through Auth first, then use
-- this service-role-only SECURITY DEFINER primitive to cross the RBAC boundary.
create or replace function public.service_admin_resolve_auth_user(p_auth_user_id uuid)
returns uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select au.id
  from public.admin_users au
  where au.auth_user_id = p_auth_user_id
    and au.is_active = true
  limit 1;
$$;

revoke all on function public.service_admin_resolve_auth_user(uuid) from public;
revoke all on function public.service_admin_resolve_auth_user(uuid) from anon;
revoke all on function public.service_admin_resolve_auth_user(uuid) from authenticated;
grant execute on function public.service_admin_resolve_auth_user(uuid) to service_role;

comment on function public.service_admin_resolve_auth_user(uuid) is
  'Service-role-only RBAC resolver used after Auth token verification. Returns the active admin_users.id for an auth.users id without granting direct table access.';