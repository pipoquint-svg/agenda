-- Keep the monthly fast-path helper private to the SECURITY DEFINER bridge.
-- The public wrapper and the existing list_available_dates_month_impl grants remain unchanged.

revoke all on function agenda_public_bridge.has_available_slot_for_duration_impl(
  uuid, uuid, integer, jsonb, integer, date, timestamptz
) from public;

revoke all on function agenda_public_bridge.has_available_slot_for_duration_impl(
  uuid, uuid, integer, jsonb, integer, date, timestamptz
) from anon, authenticated, service_role;
