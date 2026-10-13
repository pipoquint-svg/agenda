-- Autorização administrativa em uma única ida ao banco.
--
-- As Edge Functions resolviam o admin (service_admin_resolve_auth_user) e só
-- depois liam o perfil de permissões (service_admin_get_access_profile). Esta
-- função faz as duas leituras numa chamada, com a mesma regra: apenas admin_users
-- ativos, perfil calculado pelo service_admin_has_permission de sempre.
-- O chamador só a usa depois de o Auth confirmar o token (ver _shared/admin-auth.ts).

create or replace function public.service_admin_resolve_access_profile(p_auth_user_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select public.service_admin_get_access_profile(au.id)
  from public.admin_users au
  where au.auth_user_id = p_auth_user_id
    and au.is_active = true
  limit 1;
$$;

alter function public.service_admin_resolve_access_profile(uuid) owner to postgres;
revoke all on function public.service_admin_resolve_access_profile(uuid) from public, anon, authenticated;
grant execute on function public.service_admin_resolve_access_profile(uuid) to service_role;

comment on function public.service_admin_resolve_access_profile(uuid) is
  'Service-role-only: active admin access profile (including admin_user_id) for an auth.users id, after Auth token verification.';
