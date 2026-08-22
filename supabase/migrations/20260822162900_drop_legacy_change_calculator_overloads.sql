-- Prepare the retained-settlement calculator contract.
-- PostgreSQL does not allow CREATE OR REPLACE to erase/rename existing input
-- parameter names. Drop the exact legacy overloads first; the following migration
-- recreates them only as fail-closed compatibility stubs that require explicit
-- CLIENT/OPERATION origin through calculate_reservation_change.

drop function if exists public.calculate_appointment_change_policy(uuid,text,timestamptz,numeric);
drop function if exists public.calculate_appointment_change_policy(uuid,text,timestamptz);
