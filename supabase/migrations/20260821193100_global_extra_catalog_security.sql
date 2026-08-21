revoke all on function public.set_extra_service_assignments(uuid, uuid[], uuid)
  from public, anon, authenticated;

grant execute on function public.set_extra_service_assignments(uuid, uuid[], uuid)
  to service_role;

revoke all on table public.extra_catalog_admin
  from public, anon, authenticated;

grant select on table public.extra_catalog_admin
  to service_role;
