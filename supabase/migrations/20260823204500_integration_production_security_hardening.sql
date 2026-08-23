-- Production hardening discovered during the integration audit on 2026-08-23.
-- Direct browser/database access is deny-by-default. Public booking reads remain exposed
-- only through the intentionally public SECURITY DEFINER RPC contracts.

revoke all privileges on all tables in schema public from anon, authenticated;
revoke all privileges on all sequences in schema public from anon, authenticated;

-- Preserve the five intentional public booking RPCs. Their definitions already pin
-- search_path=public and untrusted roles cannot CREATE in public, preventing object shadowing.
grant execute on function public.public_get_booking_page(text) to anon, authenticated;
grant execute on function public.public_list_available_slots(text, uuid, uuid, jsonb, integer, date) to anon, authenticated;
grant execute on function public.public_list_available_slots_duration(text, uuid, uuid, integer, jsonb, integer, date) to anon, authenticated;
grant execute on function public.public_quote_booking(text, uuid, uuid, jsonb, integer) to anon, authenticated;
grant execute on function public.public_quote_booking_duration(text, uuid, uuid, integer, jsonb, integer) to anon, authenticated;

-- Future objects must be granted deliberately instead of inheriting broad browser rights.
alter default privileges in schema public revoke all privileges on tables from anon, authenticated;
alter default privileges in schema public revoke all privileges on sequences from anon, authenticated;
alter default privileges in schema public revoke execute on functions from anon, authenticated;

-- Cover foreign keys reported by the Supabase performance advisor. These are additive
-- indexes only; no existing integrity/uniqueness index is removed.
create index if not exists admin_user_permissions_updated_by_idx
  on public.admin_user_permissions(updated_by_admin_id);
create index if not exists authorship_events_admin_user_idx
  on public.appointment_authorship_events(admin_user_id);
create index if not exists authorship_events_access_token_idx
  on public.appointment_authorship_events(appointment_access_token_id);
create index if not exists final_settlements_admin_user_idx
  on public.appointment_final_settlements(admin_user_id);
create index if not exists policy_actions_refund_tx_idx
  on public.appointment_policy_actions(refund_transaction_id);
create index if not exists booking_page_services_service_idx
  on public.booking_page_services(service_id);
create index if not exists coupon_services_service_idx
  on public.coupon_services(service_id);
create index if not exists coupons_customer_idx
  on public.coupons(customer_id);
create index if not exists coupons_source_appointment_idx
  on public.coupons(source_appointment_id);
create index if not exists balance_movements_admin_user_idx
  on public.customer_balance_movements(admin_user_id);
create index if not exists balance_refund_requests_admin_idx
  on public.customer_balance_refund_requests(admin_user_id);
create index if not exists prebook_authorized_services_service_idx
  on public.customer_prebook_authorized_services(service_id);
create index if not exists extra_resources_resource_idx
  on public.extra_resources(resource_id);
create index if not exists google_calendar_resources_resource_idx
  on public.google_calendar_resources(resource_id);
create index if not exists google_oauth_states_admin_idx
  on public.google_oauth_states(requested_by_admin_user_id);
create index if not exists google_watch_channels_calendar_idx
  on public.google_watch_channels(google_calendar_id);
create index if not exists hour_package_services_service_idx
  on public.hour_package_services(service_id);
create index if not exists legacy_amelia_first_batch_idx
  on public.legacy_amelia_bookings(first_import_batch_id);
create index if not exists legacy_amelia_last_batch_idx
  on public.legacy_amelia_bookings(last_import_batch_id);
create index if not exists legacy_amelia_matched_customer_idx
  on public.legacy_amelia_bookings(matched_customer_id);
create index if not exists legacy_amelia_batches_admin_idx
  on public.legacy_amelia_import_batches(created_by_admin_user_id);
create index if not exists operation_settings_occupancy_resource_idx
  on public.operation_settings(dashboard_occupancy_resource_id);
create index if not exists employee_calendar_write_calendar_idx
  on public.service_employee_calendar_write(google_calendar_id);
