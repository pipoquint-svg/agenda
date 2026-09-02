-- Item 2C / #371: service_role must use audited/admin boundaries, not primitives.
-- Keep owner/maintenance access intact; revoke only the application service role.

revoke execute on function public.service_admin_upsert_change_policy(uuid, jsonb) from service_role;
revoke execute on function public.service_admin_update_timing(uuid, text, integer, integer, integer, integer, numeric, numeric, integer, integer) from service_role;
revoke execute on function public.service_admin_replace_duration_configuration(uuid, jsonb, jsonb) from service_role;
revoke execute on function public.maintenance_purge_audit_logs(timestamptz, text, text) from service_role;
revoke execute on function public.maintenance_purge_appointment_token_network_evidence(timestamptz, text, text) from service_role;
