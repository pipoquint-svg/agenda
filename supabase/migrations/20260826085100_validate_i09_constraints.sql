-- I-09 finalization, phase 2: validate only after the fixture-repair migration
-- has committed and all deferred trigger events on appointments are drained.

alter table public.appointments
  validate constraint appointments_confirmed_requires_policy_snapshot_ck;

alter table public.appointments
  validate constraint appointments_change_policy_snapshot_fk;
