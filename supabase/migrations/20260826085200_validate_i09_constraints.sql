-- I-09 finalization, phase 2b: validate only after the staging marker
-- reconciliation migration has committed, so no deferred trigger events remain.

alter table public.appointments
  validate constraint appointments_confirmed_requires_policy_snapshot_ck;

alter table public.appointments
  validate constraint appointments_change_policy_snapshot_fk;
