-- Production hardening after initial OWNER bootstrap has completed.
-- The first-owner bootstrap must no longer be reachable from public/authenticated roles.

revoke execute on function public.service_bootstrap_first_owner_authenticated(text) from public, anon, authenticated;
grant execute on function public.service_bootstrap_first_owner_authenticated(text) to service_role;

-- Cover the FK used by administrative recharge audit/history lookups and deletes.
create index if not exists hour_package_recharges_created_by_admin_idx
  on public.hour_package_recharges(created_by_admin_id);

comment on function public.service_bootstrap_first_owner_authenticated(text) is
  'Initial OWNER bootstrap retained for service-role recovery only after production cutover; public/authenticated execution is revoked.';
