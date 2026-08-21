-- BlackSheep Agenda V1 default grid: starts every 30 minutes.
-- Existing explicit availability-rule intervals remain valid for exceptional cases;
-- every new rule that omits an interval inherits the canonical 30-minute cadence.

alter table public.availability_rules
  alter column slot_interval_minutes set default 30;

comment on column public.availability_rules.slot_interval_minutes is
  'Start-time cadence for this availability window. Default: 30 minutes (08:00, 08:30, 09:00, 09:30...).';
