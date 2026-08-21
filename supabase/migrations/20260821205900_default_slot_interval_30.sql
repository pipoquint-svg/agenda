-- BlackSheep Agenda canonical default grid: starts every 30 minutes.
-- Availability rules may explicitly choose a coarser/finer interval later, but any
-- newly created rule that omits the interval inherits 30 minutes.

alter table public.availability_rules
  alter column slot_interval_minutes set default 30;

alter table public.operation_settings
  add column default_slot_interval_minutes integer not null default 30
  check (default_slot_interval_minutes > 0);

update public.operation_settings
set default_slot_interval_minutes = 30,
    updated_at = now()
where id = 1;

-- Rebuild the availability function so the fallback comes from the operation
-- setting instead of a magic literal. Existing explicit rule intervals remain
-- respected; 30 minutes is the system default.
create or replace function public.get_default_slot_interval_minutes()
returns integer
language sql
stable
set search_path = public
as $$
select coalesce((select default_slot_interval_minutes from public.operation_settings where id = 1), 30);
$$;

revoke all on function public.get_default_slot_interval_minutes() from public, anon, authenticated;
grant execute on function public.get_default_slot_interval_minutes() to service_role;

comment on column public.operation_settings.default_slot_interval_minutes is
  'Default start-time cadence. V1 standard is 30 minutes: 08:00, 08:30, 09:00, 09:30...';
