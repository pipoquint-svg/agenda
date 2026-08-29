-- Keep the customer admin surface behind the same service-role-only RPC boundary
-- used by the rest of Gestão. The frontend never receives or uses service_role.
create or replace function public.service_admin_list_customer_service_options()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', s.id,
        'name', s.name,
        'slug', s.slug,
        'operation_scope', s.operation_scope
      )
      order by s.sort_order, s.name, s.id
    ),
    '[]'::jsonb
  )
  from public.services s
  where s.is_active = true
    and s.operation_scope is not null;
$$;

revoke all on function public.service_admin_list_customer_service_options() from public, anon, authenticated;
grant execute on function public.service_admin_list_customer_service_options() to service_role;

comment on function public.service_admin_list_customer_service_options() is
  'Service-role-only read model for active scoped services shown inside Gestão customer profiles.';
