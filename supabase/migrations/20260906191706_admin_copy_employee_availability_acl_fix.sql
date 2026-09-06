-- Idempotent ACL marker for the availability-copy RPC.
revoke all on function public.admin_copy_employee_availability_audited(uuid, uuid[], boolean, boolean, boolean, uuid) from public, anon, authenticated;
grant execute on function public.admin_copy_employee_availability_audited(uuid, uuid[], boolean, boolean, boolean, uuid) to service_role;
