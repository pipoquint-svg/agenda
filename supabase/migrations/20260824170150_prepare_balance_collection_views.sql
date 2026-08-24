-- CREATE OR REPLACE VIEW cannot insert columns in the middle of an existing view.
-- The hardening migration intentionally expands the projection, so drop the V1 view
-- before recreating it with the authoritative finance columns.
drop view if exists public.appointment_open_balances;
