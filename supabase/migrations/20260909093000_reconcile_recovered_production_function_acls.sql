-- Reproduce the effective production ACLs for functions whose original
-- production migrations were recovered into version control after the fact.
--
-- These grants already describe production. This migration makes a clean
-- rebuild deterministic and prevents PostgreSQL's default PUBLIC EXECUTE on
-- newly-created functions from widening access during disaster recovery,
-- local rebuilds or future deployments.

revoke all on function public.public_create_service_waitlist_entry_v2(text,uuid,text,text,text,date)
  from public, anon, authenticated, service_role;
grant execute on function public.public_create_service_waitlist_entry_v2(text,uuid,text,text,text,date)
  to service_role;

revoke all on function public.service_admin_record_manual_receipt(uuid,text,numeric,timestamptz,text,uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.service_admin_record_manual_receipt(uuid,text,numeric,timestamptz,text,uuid)
  to service_role;

revoke all on function public.coalesce_natal_kommo_pending_jobs()
  from public, anon, authenticated, service_role;
grant execute on function public.coalesce_natal_kommo_pending_jobs()
  to service_role;

revoke all on function public.service_admin_create_manual_appointment(uuid,uuid,uuid,timestamptz,uuid,integer,jsonb,integer,text)
  from public, anon, authenticated, service_role;
grant execute on function public.service_admin_create_manual_appointment(uuid,uuid,uuid,timestamptz,uuid,integer,jsonb,integer,text)
  to service_role;

revoke all on function public.service_admin_confirm_manual_appointment_unpaid(uuid,text)
  from public, anon, authenticated, service_role;
grant execute on function public.service_admin_confirm_manual_appointment_unpaid(uuid,text)
  to authenticated, service_role;
