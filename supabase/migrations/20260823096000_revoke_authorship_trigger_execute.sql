-- Trigger-only function: PostgreSQL triggers execute it as the function owner.
-- It is not part of the public/admin RPC surface and must never be callable
-- directly through PostgREST by anon, authenticated or service_role.

revoke execute on function public.reject_appointment_authorship_mutation()
from public, anon, authenticated, service_role;

comment on function public.reject_appointment_authorship_mutation() is
  'Internal trigger-only append-only guard. Direct EXECUTE is intentionally revoked from API roles.';
