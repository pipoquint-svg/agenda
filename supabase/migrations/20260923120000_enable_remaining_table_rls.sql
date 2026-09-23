-- Items 2 and 7 of the RLS/performance audit action plan — defense-in-depth RLS
-- for every remaining public-schema table that predates the rls_auto_enable event
-- trigger (20260823044200_version_hosted_rls_guard.sql) and was never retrofitted
-- the way the 11 tables in Item 2B were.
--
-- Same policy model as Item 2B: deny by default, zero policies. This is safe because
-- the public ACL baseline (20260823204500_integration_production_security_hardening.sql)
-- already revokes all anon/authenticated table grants and the web client never issues a
-- direct PostgREST query (every read/write goes through an allow-listed public_* RPC or an
-- edge function using the service_role key, which bypasses RLS). Enabling RLS here removes
-- a single point of failure: if a future migration ever re-grants anon/authenticated access,
-- or an edge function is ever misconfigured to use the anon key, these tables stay closed.
--
-- Table list reconciled against tests/rls-parity/production_rls_baseline.txt (the 50 tables
-- previously marked RLS-disabled there); scripts/rls-inventory.sql / the item-02a-bis CI gate
-- must be re-run against production to refresh that baseline once this migration deploys.

-- Priority: PII, financial, and integration-secret-adjacent tables.
alter table public.employees enable row level security;
alter table public.customer_commercial_terms enable row level security;
alter table public.payment_incidents enable row level security;
alter table public.pre_reservations enable row level security;
alter table public.customer_prebook_authorized_services enable row level security;
alter table public.google_oauth_states enable row level security;
alter table public.google_watch_channels enable row level security;
alter table public.google_sync_state enable row level security;
alter table public.google_calendars enable row level security;
alter table public.google_calendar_resources enable row level security;
alter table public.audit_retention_policy enable row level security;
alter table public.audit_purge_runs enable row level security;

-- Remaining catalog/configuration/operational tables.
alter table public.appointment_answers enable row level security;
alter table public.appointment_change_policy_snapshot_terms enable row level security;
alter table public.appointment_change_policy_snapshots enable row level security;
alter table public.appointment_discounts enable row level security;
alter table public.appointment_extras enable row level security;
alter table public.appointment_package_usage enable row level security;
alter table public.appointment_participants enable row level security;
alter table public.appointment_policy_actions enable row level security;
alter table public.appointment_term_acceptances enable row level security;
alter table public.availability_exceptions enable row level security;
alter table public.availability_rules enable row level security;
alter table public.categories enable row level security;
alter table public.checkout_hour_package_reservations enable row level security;
alter table public.coupon_services enable row level security;
alter table public.coupons enable row level security;
alter table public.extra_resources enable row level security;
alter table public.extras enable row level security;
alter table public.hour_package_movements enable row level security;
alter table public.hour_package_services enable row level security;
alter table public.hour_packages enable row level security;
alter table public.integration_jobs enable row level security;
alter table public.message_templates enable row level security;
alter table public.operation_settings enable row level security;
alter table public.pricing_rules enable row level security;
alter table public.public_rate_limit_buckets enable row level security;
alter table public.resource_allocations enable row level security;
alter table public.resource_availability_rules enable row level security;
alter table public.resources enable row level security;
alter table public.schedule_divergences enable row level security;
alter table public.service_change_policies enable row level security;
alter table public.service_employee_calendar_write enable row level security;
alter table public.service_employees enable row level security;
alter table public.service_extra_schedule_rules enable row level security;
alter table public.service_extras enable row level security;
alter table public.service_fields enable row level security;
alter table public.service_resources enable row level security;
alter table public.services enable row level security;
alter table public.terms_versions enable row level security;
