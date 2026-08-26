-- I-09 finalization, phase 1: deterministic fixture repair only.
--
-- The only rows preventing validation in the sandbox are two historical,
-- synthetic action-token fixtures created directly as CONFIRMED before the
-- confirmation invariant existed. Their fixture provenance is authoritative:
-- exact 9700... UUID namespace, service slug token-evidence-service-20260823,
-- @example.com token destination, token-test-* request ids and TEST_ONLY
-- financial-effect evidence.
--
-- Preserve those fixtures instead of deleting them. Reconstruct only the
-- minimum historical confirmation metadata needed by the invariant. No
-- commercial policy is inferred and no active service policy is created.
-- Constraint validation is intentionally a following migration so deferred
-- trigger events from this repair are committed before ALTER TABLE VALIDATE.

do $$
declare
  v_fixture_count integer;
begin
  select count(*)
  into v_fixture_count
  from public.appointments a
  join public.services s on s.id = a.service_id
  where a.id in (
      '97000000-0000-0000-0000-000000000030'::uuid,
      '97000000-0000-0000-0000-000000000031'::uuid
    )
    and a.service_id = '97000000-0000-0000-0000-000000000010'::uuid
    and s.slug = 'token-evidence-service-20260823'
    and s.is_active = false
    and a.status = 'CONFIRMED'
    and a.confirmed_at is null
    and a.change_policy_snapshot_appointment_id is null
    and exists (
      select 1
      from public.appointment_token_events e
      where e.appointment_id = a.id
        and e.event_type = 'ISSUED'
        and e.destination_masked = 't***@example.com'
        and e.request_id in ('token-test-issue', 'token-test-issue-2')
    );

  if v_fixture_count not in (0, 2) then
    raise exception using
      errcode = 'P0001',
      message = 'TOKEN_EVIDENCE_FIXTURE_SET_UNEXPECTED',
      detail = format('expected 0 or 2 exact fixtures, found %s', v_fixture_count);
  end if;

  -- A fresh rebuild has no sandbox-only fixture rows and needs no data repair.
  if v_fixture_count = 2 then
    if not exists (
      select 1
      from public.appointment_token_events e
      where e.appointment_id = '97000000-0000-0000-0000-000000000031'::uuid
        and e.event_type = 'ACTION_EXECUTED'
        and e.request_id = 'consume-ok'
        and e.metadata_json ->> 'financial_effect' = 'TEST_ONLY'
    ) then
      raise exception using
        errcode = 'P0001',
        message = 'TOKEN_EVIDENCE_TEST_ONLY_PROVENANCE_MISSING';
    end if;

    insert into public.appointment_change_policy_snapshots(
      appointment_id,
      service_id,
      policy_json,
      effective_at,
      source,
      max_customer_reschedules,
      policy_timezone,
      notice_boundary_semantics
    )
    select
      a.id,
      a.service_id,
      jsonb_build_object(
        'snapshot_schema_version', 'FIXTURE_RECONSTRUCTION_V1',
        'fixture_only', true,
        'notice_hours', 0,
        'max_customer_reschedules', 0,
        'reschedule_first_early_percent', 0,
        'reschedule_first_late_percent', 0,
        'reschedule_repeat_percent', 0,
        'cancellation_late_percent', 0,
        'policy_timezone', 'America/Sao_Paulo',
        'notice_boundary_semantics', 'EXACT_LIMIT_IS_OUTSIDE_WINDOW',
        'reconstruction_basis', 'DIRECT_CONFIRMED_TOKEN_TEST_FIXTURE'
      ),
      a.created_at,
      'HISTORICAL_RECONSTRUCTION',
      0,
      'America/Sao_Paulo',
      'EXACT_LIMIT_IS_OUTSIDE_WINDOW'
    from public.appointments a
    where a.id in (
      '97000000-0000-0000-0000-000000000030'::uuid,
      '97000000-0000-0000-0000-000000000031'::uuid
    )
    on conflict (appointment_id) do nothing;

    -- These rows were inserted directly already in CONFIRMED state. Their
    -- insertion timestamp is therefore the deterministic historical boundary:
    -- no application confirmation event exists to supply a different value.
    update public.appointments a
    set confirmed_at = a.created_at,
        change_policy_snapshot_appointment_id = a.id,
        updated_at = now()
    where a.id in (
      '97000000-0000-0000-0000-000000000030'::uuid,
      '97000000-0000-0000-0000-000000000031'::uuid
    )
      and a.confirmed_at is null
      and a.change_policy_snapshot_appointment_id is null;
  end if;
end
$$;
