-- I-09 final destination invariant.
-- Existing historical rows are intentionally not rewritten: both constraints
-- are introduced NOT VALID and are enforced only for new/updated states.

alter table public.appointments
  add column if not exists change_policy_snapshot_appointment_id uuid;

create or replace function public.mark_confirmed_appointment_policy_snapshot()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.status = 'CONFIRMED' then
    new.change_policy_snapshot_appointment_id := new.id;
  end if;
  return new;
end;
$$;

drop trigger if exists appointments_mark_confirmed_policy_snapshot on public.appointments;
create trigger appointments_mark_confirmed_policy_snapshot
before insert or update of status on public.appointments
for each row execute function public.mark_confirmed_appointment_policy_snapshot();

alter table public.appointments
  drop constraint if exists appointments_confirmed_requires_policy_snapshot_ck;
alter table public.appointments
  add constraint appointments_confirmed_requires_policy_snapshot_ck
  check (
    status <> 'CONFIRMED'
    or (
      confirmed_at is not null
      and change_policy_snapshot_appointment_id is not null
    )
  ) not valid;

alter table public.appointments
  drop constraint if exists appointments_change_policy_snapshot_fk;
alter table public.appointments
  add constraint appointments_change_policy_snapshot_fk
  foreign key (change_policy_snapshot_appointment_id)
  references public.appointment_change_policy_snapshots(appointment_id)
  deferrable initially deferred
  not valid;

create index if not exists appointments_change_policy_snapshot_idx
  on public.appointments(change_policy_snapshot_appointment_id)
  where change_policy_snapshot_appointment_id is not null;

comment on column public.appointments.change_policy_snapshot_appointment_id is
  'I-09 marker/FK: a CONFIRMED appointment must resolve to its immutable change-policy snapshot by transaction commit.';

comment on constraint appointments_confirmed_requires_policy_snapshot_ck on public.appointments is
  'NOT VALID during pre-production closeout: new/updated CONFIRMED states require confirmed_at and a policy-snapshot marker; historical fixtures are not rewritten.';
