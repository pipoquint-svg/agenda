-- Private waitlist rounds are server-only storage. They are reached through
-- SECURITY DEFINER RPCs exposed only to service_role, so direct relation grants
-- are intentionally not part of the application contract.
--
-- Reapply this hardening after the historical dynamic Item 2A baseline during
-- idempotence tests: that older migration grants service_role CRUD to every
-- public relation it can see, including relations created later in history.

revoke all privileges on table public.waitlist_private_rounds
  from public, anon, authenticated, service_role;
revoke all privileges on table public.waitlist_private_round_slots
  from public, anon, authenticated, service_role;
revoke all privileges on table public.waitlist_private_round_invites
  from public, anon, authenticated, service_role;
