-- Keep the semantic service cadence constraint in the canonical textual form
-- expected by the regression suite and already used in production.
-- This does not change the allowed values: 30-minute multiples from 30 to 480.

alter table public.services
  drop constraint if exists services_slot_interval_minutes_check;

alter table public.services
  add constraint services_slot_interval_minutes_check
  check (
    slot_interval_minutes >= 30
    and slot_interval_minutes <= 480
    and slot_interval_minutes % 30 = 0
  );
