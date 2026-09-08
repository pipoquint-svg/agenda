-- Keep private-waitlist trigger helpers trigger-only.
--
-- The historical Item 2A ACL baseline grants service_role EXECUTE broadly to
-- functions that exist when it is replayed. These helpers are invoked only by
-- database triggers and must not become callable application/service RPCs if an
-- older baseline is composed again during verification or disaster recovery.

revoke all on function public.trg_restore_waitlist_private_slot_allocation()
  from public, anon, authenticated, service_role;
revoke all on function public.trg_sync_waitlist_private_checkout_promotion()
  from public, anon, authenticated, service_role;
revoke all on function public.trg_sync_waitlist_private_appointment_status()
  from public, anon, authenticated, service_role;
revoke all on function public.trg_validate_waitlist_private_slot_service()
  from public, anon, authenticated, service_role;
