-- Prepare the retained-settlement change-action contract.
-- PostgreSQL does not allow CREATE OR REPLACE to erase/rename existing input
-- parameter names. Drop the exact legacy overloads first; following migrations
-- recreate them only as fail-closed compatibility stubs. New callers must pass
-- explicit CLIENT/OPERATION origin through the V2 functions.

drop function if exists public.calculate_appointment_change_policy(uuid,text,timestamptz,numeric);
drop function if exists public.calculate_appointment_change_policy(uuid,text,timestamptz);

drop function if exists public.service_admin_create_reschedule_hold(uuid,timestamptz,timestamptz,uuid);
drop function if exists public.service_admin_cancel_appointment(uuid,text,text,timestamptz,uuid);
