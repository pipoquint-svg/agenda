-- I-09 finalization, phase 2: reconcile the two known pre-marker staging
-- confirmations, then validate after the fixture-repair migration has committed
-- and all deferred trigger events on appointments are drained.
--
-- These rows were confirmed before the marker column/trigger existed. Both
-- already have confirmed_at and a real appointment_change_policy_snapshots row;
-- this migration only links the marker to that existing snapshot. The exact IDs
-- are synthetic staging reservations. A partial or structurally inconsistent
-- set aborts instead of inferring or fabricating policy data.

do $$
declare
  v_present integer;
  v_ready integer;
begin
  select count(*)
    into v_present
  from public.appointments
  where id in (
    'be5125bc-2725-43e6-a8b0-283ea3a221ed'::uuid,
    'b98aa122-49a9-4f33-a76d-85208069f3d5'::uuid
  );

  if v_present not in (0, 2) then
    raise exception 'I09_STAGING_MARKER_FIXTURE_SET_UNEXPECTED: expected 0 or 2 rows, found %', v_present;
  end if;

  if v_present = 2 then
    select count(*)
      into v_ready
    from public.appointments a
    where a.id in (
      'be5125bc-2725-43e6-a8b0-283ea3a221ed'::uuid,
      'b98aa122-49a9-4f33-a76d-85208069f3d5'::uuid
    )
      and a.status = 'CONFIRMED'
      and a.confirmed_at is not null
      and exists (
        select 1
        from public.appointment_change_policy_snapshots s
        where s.appointment_id = a.id
      );

    if v_ready <> 2 then
      raise exception 'I09_STAGING_MARKER_FIXTURE_EVIDENCE_MISSING: expected 2 confirmed rows with timestamp and real snapshot, found %', v_ready;
    end if;

    update public.appointments
    set change_policy_snapshot_appointment_id = id
    where id in (
      'be5125bc-2725-43e6-a8b0-283ea3a221ed'::uuid,
      'b98aa122-49a9-4f33-a76d-85208069f3d5'::uuid
    )
      and change_policy_snapshot_appointment_id is null;
  end if;
end
$$;

alter table public.appointments
  validate constraint appointments_confirmed_requires_policy_snapshot_ck;

alter table public.appointments
  validate constraint appointments_change_policy_snapshot_fk;
