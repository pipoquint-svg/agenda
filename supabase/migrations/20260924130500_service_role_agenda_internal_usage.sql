-- Restore the server-only schema traversal required by availability RPCs.
--
-- The duration availability engine calls the private
-- agenda_internal.calculate_booking_resource_ranges_resolved_duration helper.
-- service_role already has EXECUTE on that helper, but schema USAGE was revoked,
-- causing admin/manual slot queries to fail with:
--   permission denied for schema agenda_internal
--
-- USAGE only permits name resolution/traversal. It does not grant EXECUTE on
-- other functions or access to tables. anon/authenticated remain denied.

grant usage on schema agenda_internal to service_role;

revoke all on schema agenda_internal from anon, authenticated;
