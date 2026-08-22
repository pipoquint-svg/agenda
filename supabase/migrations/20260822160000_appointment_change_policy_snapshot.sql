-- Priority gate: freeze the commercial change policy per appointment so later
-- service-policy edits can never retroactively alter a reservation.
--
-- Exact 48-hour decision is explicit: the exact boundary is OUTSIDE the penalty
-- window. The penalty window starts one instant after the 48h boundary.

create table public.appointment_change_policy_snapshots (
  appointment_id uuid primary key references public.appointments(id) on delete restrict,
  service_id uuid not null references public.services(id) on delete restrict,
  policy_json jsonb not null,
  effective_at timestamptz not null,
  source text not null check (source in ('BOOKING_CAPTURE','HISTORICAL_RECONSTRUCTION')),
  max_customer_reschedules smallint not null check (max_customer_reschedules = 3),
  policy_timezone text not null check (policy_timezone = 'America/Sao_Paulo'),
  notice_boundary_semantics text not null check (notice_boundary_semantics = 'EXACT_LIMIT_IS_OUTSIDE_WINDOW'),
  captured_at timestamptz not null default now(),
  check (jsonb_typeof(policy_json) = 'object')
);

create table public.appointment_change_policy_snapshot_terms (
  id uuid primary key default gen_random_uuid(),
  appointment_id uuid not null references public.appointment_change_policy_snapshots(appointment_id) on delete restrict,
  terms_version_id uuid not null references public.terms_versions(id) on delete restrict,
  name_snapshot text not null,
  version_snapshot text not null,
  content_snapshot text not null,
  published_at_snapshot timestamptz not null,
  captured_at timestamptz not null default now(),
  unique (appointment_id, terms_version_id)
);

comment on table public.appointment_change_policy_snapshots is
  'Immutable reservation-level snapshot of the change/cancellation policy. Calculations must read this snapshot, never the live service policy.';
comment on table public.appointment_change_policy_snapshot_terms is
  'Immutable terms-version evidence corresponding to the reservation policy snapshot. This does not fabricate acceptance; actual acceptance remains in appointment_term_acceptances.';

create or replace function public.normalize_change_policy_snapshot(p_policy jsonb)
returns jsonb
language sql
immutable
set search_path = public
as $$
  select case
    when p_policy is null then null
    else p_policy || jsonb_build_object(
      'max_customer_reschedules', 3,
      'policy_timezone', 'America/Sao_Paulo',
      'notice_boundary_semantics', 'EXACT_LIMIT_IS_OUTSIDE_WINDOW',
      'snapshot_schema_version', 'CHANGE_POLICY_SNAPSHOT_V1'
    )
  end;
$$;

create or replace function public.capture_appointment_policy_terms_snapshot(
  p_appointment_id uuid,
  p_service_id uuid,
  p_effective_at timestamptz
)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $$
begin
  -- Existing explicit acceptances are authoritative when present.
  if exists (
    select 1 from public.appointment_term_acceptances ata
    where ata.appointment_id = p_appointment_id
  ) then
    insert into public.appointment_change_policy_snapshot_terms(
      appointment_id, terms_version_id, name_snapshot, version_snapshot,
      content_snapshot, published_at_snapshot
    )
    select
      p_appointment_id, tv.id, tv.name, tv.version,
      ata.content_snapshot, tv.published_at
    from public.appointment_term_acceptances ata
    join public.terms_versions tv on tv.id = ata.terms_version_id
    where ata.appointment_id = p_appointment_id
    on conflict (appointment_id, terms_version_id) do nothing;
    return;
  end if;

  -- Administrative reservations may have no client acceptance. Snapshot the
  -- terms that were published for the service at the effective instant, but do
  -- not insert into appointment_term_acceptances and do not claim acceptance.
  insert into public.appointment_change_policy_snapshot_terms(
    appointment_id, terms_version_id, name_snapshot, version_snapshot,
    content_snapshot, published_at_snapshot
  )
  select
    p_appointment_id, selected.id, selected.name, selected.version,
    selected.content, selected.published_at
  from (
    select distinct on (tv.name)
      tv.id, tv.name, tv.version, tv.content, tv.published_at
    from public.terms_versions tv
    where tv.service_id = p_service_id
      and tv.is_active
      and tv.published_at <= p_effective_at
    order by tv.name, tv.published_at desc, tv.id
  ) selected
  on conflict (appointment_id, terms_version_id) do nothing;
end;
$$;

create or replace function public.capture_current_appointment_change_policy_snapshot()
returns trigger
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_policy public.service_change_policies%rowtype;
  v_effective_at timestamptz;
begin
  if new.status not in ('AWAITING_PAYMENT','CONFIRMED') then
    return new;
  end if;

  if exists (
    select 1 from public.appointment_change_policy_snapshots s
    where s.appointment_id = new.id
  ) then
    return new;
  end if;

  select * into v_policy
  from public.service_change_policies
  where service_id = new.service_id;

  -- Services without a configured policy keep their existing booking behavior,
  -- but change-policy calculation will refuse to run without a snapshot.
  if not found then
    return new;
  end if;

  -- AWAITING_PAYMENT reservations have already accepted checkout terms, so the
  -- reservation policy freezes at creation. CONFIRMED inserts freeze at their
  -- confirmation timestamp when present, otherwise at the insert instant.
  v_effective_at := case
    when new.status = 'AWAITING_PAYMENT' then new.created_at
    else coalesce(new.confirmed_at, new.created_at)
  end;

  insert into public.appointment_change_policy_snapshots(
    appointment_id, service_id, policy_json, effective_at, source,
    max_customer_reschedules, policy_timezone, notice_boundary_semantics
  ) values (
    new.id,
    new.service_id,
    public.normalize_change_policy_snapshot(to_jsonb(v_policy)),
    v_effective_at,
    'BOOKING_CAPTURE',
    3,
    'America/Sao_Paulo',
    'EXACT_LIMIT_IS_OUTSIDE_WINDOW'
  );

  perform public.capture_appointment_policy_terms_snapshot(new.id, new.service_id, v_effective_at);
  return new;
end;
$$;

create trigger appointments_capture_change_policy_snapshot
  after insert or update of status, confirmed_at on public.appointments
  for each row execute function public.capture_current_appointment_change_policy_snapshot();

create or replace function public.historical_change_policy_json(
  p_service_id uuid,
  p_effective_at timestamptz
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_current public.service_change_policies%rowtype;
  v_audit_boundary timestamptz;
  v_before jsonb;
begin
  if p_effective_at is null then
    return null;
  end if;

  select * into v_current
  from public.service_change_policies
  where service_id = p_service_id;

  if not found or v_current.created_at > p_effective_at then
    return null;
  end if;

  -- If the current row was last changed no later than the reservation instant,
  -- it is deterministically the policy that was in force at that instant.
  if v_current.updated_at <= p_effective_at then
    return public.normalize_change_policy_snapshot(to_jsonb(v_current));
  end if;

  -- audit_retention_policy was created after the audited policy mutation wrapper
  -- and destructive audit protections were installed. Reservations after this
  -- boundary can be reconstructed by rewinding the first audited later change.
  select arp.created_at into v_audit_boundary
  from public.audit_retention_policy arp
  where arp.id = 1;

  if v_audit_boundary is null or p_effective_at < v_audit_boundary then
    return null;
  end if;

  select al.before_json->'change_policy'
  into v_before
  from public.audit_logs al
  where al.entity_type = 'SERVICE'
    and al.entity_id = p_service_id
    and al.action = 'SERVICE_CHANGE_POLICY_UPDATED'
    and al.created_at > p_effective_at
  order by al.created_at asc, al.id asc
  limit 1;

  if v_before is null then
    return null;
  end if;

  return public.normalize_change_policy_snapshot(v_before);
end;
$$;

-- Safe historical backfill. It never substitutes the current policy when the
-- policy that was in force cannot be proven from timestamps/audit evidence.
do $$
declare
  r record;
  v_effective_at timestamptz;
  v_policy jsonb;
  v_unresolved jsonb := '[]'::jsonb;
begin
  for r in
    select a.id, a.service_id, a.status, a.created_at, a.confirmed_at
    from public.appointments a
    join public.service_change_policies cp on cp.service_id = a.service_id
    where a.status in ('AWAITING_PAYMENT','CONFIRMED','COMPLETED','CANCELLED','NO_SHOW')
      and not exists (
        select 1 from public.appointment_change_policy_snapshots s
        where s.appointment_id = a.id
      )
    order by a.created_at, a.id
  loop
    if r.status = 'AWAITING_PAYMENT' then
      v_effective_at := r.created_at;
    else
      v_effective_at := r.confirmed_at;
    end if;

    if v_effective_at is null then
      v_unresolved := v_unresolved || jsonb_build_array(jsonb_build_object(
        'appointment_id', r.id,
        'service_id', r.service_id,
        'reason', 'CONFIRMATION_INSTANT_UNKNOWN'
      ));
      continue;
    end if;

    v_policy := public.historical_change_policy_json(r.service_id, v_effective_at);
    if v_policy is null then
      v_unresolved := v_unresolved || jsonb_build_array(jsonb_build_object(
        'appointment_id', r.id,
        'service_id', r.service_id,
        'confirmed_at', v_effective_at,
        'reason', 'POLICY_AT_CONFIRMATION_NOT_DETERMINABLE'
      ));
      continue;
    end if;

    insert into public.appointment_change_policy_snapshots(
      appointment_id, service_id, policy_json, effective_at, source,
      max_customer_reschedules, policy_timezone, notice_boundary_semantics
    ) values (
      r.id, r.service_id, v_policy, v_effective_at,
      'HISTORICAL_RECONSTRUCTION', 3, 'America/Sao_Paulo',
      'EXACT_LIMIT_IS_OUTSIDE_WINDOW'
    );

    perform public.capture_appointment_policy_terms_snapshot(r.id, r.service_id, v_effective_at);
  end loop;

  if jsonb_array_length(v_unresolved) > 0 then
    raise exception using
      errcode = 'P0001',
      message = 'UNRESOLVED_APPOINTMENT_POLICY_SNAPSHOTS',
      detail = v_unresolved::text;
  end if;
end;
$$;

-- Snapshot tables are immutable evidence. Application-facing roles, including
-- service_role, cannot mutate or truncate them after insertion by the trigger.
revoke update, delete, truncate on table public.appointment_change_policy_snapshots from public, anon, authenticated, service_role;
revoke update, delete, truncate on table public.appointment_change_policy_snapshot_terms from public, anon, authenticated, service_role;

create or replace function public.reject_appointment_change_policy_snapshot_mutation()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  raise exception using errcode = '42501', message = 'APPOINTMENT_CHANGE_POLICY_SNAPSHOT_IMMUTABLE';
end;
$$;

create trigger appointment_change_policy_snapshots_reject_update_delete
before update or delete on public.appointment_change_policy_snapshots
for each row execute function public.reject_appointment_change_policy_snapshot_mutation();

create trigger appointment_change_policy_snapshots_reject_truncate
before truncate on public.appointment_change_policy_snapshots
for each statement execute function public.reject_appointment_change_policy_snapshot_mutation();

create trigger appointment_change_policy_snapshot_terms_reject_update_delete
before update or delete on public.appointment_change_policy_snapshot_terms
for each row execute function public.reject_appointment_change_policy_snapshot_mutation();

create trigger appointment_change_policy_snapshot_terms_reject_truncate
before truncate on public.appointment_change_policy_snapshot_terms
for each statement execute function public.reject_appointment_change_policy_snapshot_mutation();

revoke all on function public.normalize_change_policy_snapshot(jsonb) from public, anon, authenticated;
revoke all on function public.capture_appointment_policy_terms_snapshot(uuid,uuid,timestamptz) from public, anon, authenticated, service_role;
revoke all on function public.capture_current_appointment_change_policy_snapshot() from public, anon, authenticated, service_role;
revoke all on function public.historical_change_policy_json(uuid,timestamptz) from public, anon, authenticated, service_role;
revoke all on function public.reject_appointment_change_policy_snapshot_mutation() from public, anon, authenticated, service_role;

-- The calculation engine now reads ONLY the reservation snapshot. No live
-- service_change_policies lookup or fallback is allowed.
create or replace function public.calculate_appointment_change_policy(
  p_appointment_id uuid,
  p_action_type text,
  p_requested_at timestamptz default now()
)
returns jsonb
language plpgsql
stable
set search_path = public
as $$
declare
  v_appointment public.appointments%rowtype;
  v_snapshot public.appointment_change_policy_snapshots%rowtype;
  v_policy jsonb;
  v_notice_hours integer;
  v_hours_before numeric(12,2);
  v_inside_window boolean;
  v_prior_reschedules integer;
  v_contract_value numeric(12,2);
  v_paid numeric(12,2);
  v_penalty_type public.change_penalty_type;
  v_penalty_value numeric(12,2) := 0;
  v_penalty numeric(12,2) := 0;
  v_penalty_due_now numeric(12,2) := 0;
  v_refund_allowed boolean := false;
  v_credit_allowed boolean := false;
  v_refundable numeric(12,2) := 0;
  v_credit numeric(12,2) := 0;
  v_outstanding numeric(12,2) := 0;
begin
  if p_action_type not in ('RESCHEDULE','CANCEL') then
    raise exception using errcode = 'P0001', message = 'INVALID_CHANGE_ACTION';
  end if;

  select * into v_appointment
  from public.appointments
  where id = p_appointment_id
    and deleted_at is null;

  if not found then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_NOT_FOUND';
  end if;

  select * into v_snapshot
  from public.appointment_change_policy_snapshots
  where appointment_id = p_appointment_id;

  if not found then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_CHANGE_POLICY_SNAPSHOT_MISSING';
  end if;

  v_policy := v_snapshot.policy_json;
  v_notice_hours := (v_policy->>'notice_hours')::integer;
  if v_notice_hours is null then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_CHANGE_POLICY_SNAPSHOT_INVALID';
  end if;

  v_hours_before := round(extract(epoch from (v_appointment.start_at - p_requested_at)) / 3600.0, 2);
  -- Human decision: EXACTLY 48h (or the configured notice threshold) is outside
  -- the penalty window. Only strictly less than the threshold is inside.
  v_inside_window := extract(epoch from (v_appointment.start_at - p_requested_at)) < (v_notice_hours::numeric * 3600);

  select count(*)::integer
  into v_prior_reschedules
  from public.appointment_policy_actions apa
  where apa.appointment_id = p_appointment_id
    and apa.action_type = 'RESCHEDULE'
    and apa.status = 'APPLIED';

  v_contract_value := coalesce(v_appointment.commercial_value, 0);
  v_paid := public.appointment_net_paid_amount(p_appointment_id);

  if p_action_type = 'RESCHEDULE' then
    -- Precedence remains the pre-existing rule in this priority-only gate.
    -- The consolidated precedence is applied in the next propagation stage.
    if v_inside_window then
      v_penalty_type := (v_policy->>'reschedule_late_penalty_type')::public.change_penalty_type;
      v_penalty_value := (v_policy->>'reschedule_late_penalty_value')::numeric;
    elsif v_prior_reschedules > 0 then
      v_penalty_type := (v_policy->>'reschedule_repeat_penalty_type')::public.change_penalty_type;
      v_penalty_value := (v_policy->>'reschedule_repeat_penalty_value')::numeric;
    else
      v_penalty_type := (v_policy->>'reschedule_first_penalty_type')::public.change_penalty_type;
      v_penalty_value := (v_policy->>'reschedule_first_penalty_value')::numeric;
    end if;

    v_penalty := public.calculate_change_penalty(v_penalty_type, v_penalty_value, v_contract_value);
    v_penalty_due_now := v_penalty;
  else
    if v_inside_window then
      v_penalty_type := (v_policy->>'cancellation_late_penalty_type')::public.change_penalty_type;
      v_penalty_value := (v_policy->>'cancellation_late_penalty_value')::numeric;
      v_refund_allowed := coalesce((v_policy->>'cancellation_late_refund_allowed')::boolean, false);
      v_credit_allowed := coalesce((v_policy->>'cancellation_late_credit_allowed')::boolean, false);
    else
      v_penalty_type := (v_policy->>'cancellation_early_penalty_type')::public.change_penalty_type;
      v_penalty_value := (v_policy->>'cancellation_early_penalty_value')::numeric;
      v_refund_allowed := coalesce((v_policy->>'cancellation_early_refund_allowed')::boolean, false);
      v_credit_allowed := coalesce((v_policy->>'cancellation_early_credit_allowed')::boolean, false);
    end if;

    v_penalty := public.calculate_change_penalty(v_penalty_type, v_penalty_value, v_contract_value);
    v_refundable := round(greatest(v_paid - v_penalty, 0), 2);
    v_credit := v_refundable;
    v_outstanding := round(greatest(v_penalty - v_paid, 0), 2);
  end if;

  return jsonb_build_object(
    'appointment_id', p_appointment_id,
    'service_id', v_appointment.service_id,
    'action_type', p_action_type,
    'requested_at', p_requested_at,
    'original_start_at', v_appointment.start_at,
    'hours_before_start', v_hours_before,
    'notice_hours', v_notice_hours,
    'inside_notice_window', v_inside_window,
    'notice_boundary_semantics', v_snapshot.notice_boundary_semantics,
    'prior_customer_reschedules', v_prior_reschedules,
    'max_customer_reschedules', v_snapshot.max_customer_reschedules,
    'contract_value', v_contract_value,
    'net_paid', v_paid,
    'penalty_type', v_penalty_type,
    'penalty_value', v_penalty_value,
    'penalty_amount', v_penalty,
    'penalty_due_now', v_penalty_due_now,
    'refund_allowed', v_refund_allowed,
    'credit_allowed', v_credit_allowed,
    'credit_validity_days', nullif(v_policy->>'cancellation_credit_validity_days','')::integer,
    'refundable_amount', v_refundable,
    'credit_amount', v_credit,
    'cancellation_penalty_outstanding', v_outstanding,
    'policy_snapshot_source', v_snapshot.source,
    'policy_snapshot_effective_at', v_snapshot.effective_at
  );
end;
$$;
