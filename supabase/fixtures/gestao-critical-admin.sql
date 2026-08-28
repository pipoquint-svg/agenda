-- Disposable helper for BlackSheep /gestao critical-flow E2E tests.
-- Loaded only by the local test runner. It is not a migration and must never be
-- applied to production.

create or replace function public.qa_create_gestao_admin_profile(
  p_auth_user_id uuid,
  p_display_name text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.admin_users (
    auth_user_id,
    display_name,
    role,
    is_active
  ) values (
    p_auth_user_id,
    p_display_name,
    'OWNER',
    true
  );
end;
$$;

revoke all on function public.qa_create_gestao_admin_profile(uuid, text) from public;
grant execute on function public.qa_create_gestao_admin_profile(uuid, text) to service_role;
