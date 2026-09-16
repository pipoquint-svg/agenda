-- The browser no longer calls this compatibility RPC directly. Current UI goes
-- through admin-appointment-edit, which authenticates the bearer token, resolves
-- the active admin identity, checks AGENDA_MANAGE, then invokes the service-role
-- primitive service_admin_confirm_appointment_unpaid with the resolved admin id.
--
-- Keep the wrapper for internal/backward compatibility, but remove it from the
-- authenticated PostgREST attack surface.

revoke all on function public.service_admin_confirm_manual_appointment_unpaid(uuid,text)
  from public, anon, authenticated;

grant execute on function public.service_admin_confirm_manual_appointment_unpaid(uuid,text)
  to service_role;

comment on function public.service_admin_confirm_manual_appointment_unpaid(uuid,text) is
  'Deprecated compatibility wrapper. Service-role-only; browser confirmation must use admin-appointment-edit, which enforces Auth and AGENDA_MANAGE before calling service_admin_confirm_appointment_unpaid.';
