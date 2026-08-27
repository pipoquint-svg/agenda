
-- BEGIN RC MIGRATION 20260822160000_appointment_change_policy_snapshot.sql
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
-- END RC MIGRATION 20260822160000_appointment_change_policy_snapshot.sql

-- BEGIN RC MIGRATION 20260822161000_consolidated_change_policy_v2.sql
-- Consolidated commercial policy V2.
-- This stage changes policy selection and calculation only. It deliberately does
-- NOT remove legacy cancellation-credit structures yet; issued-credit inventory
-- is a mandatory gate before that removal.

alter table public.service_change_policies
  add column reschedule_first_early_percent numeric(5,2),
  add column reschedule_first_late_percent numeric(5,2),
  add column reschedule_repeat_percent numeric(5,2),
  add column cancellation_late_percent numeric(5,2),
  add constraint service_change_policy_v2_first_early_percent_check
    check (reschedule_first_early_percent is null or reschedule_first_early_percent between 0 and 100),
  add constraint service_change_policy_v2_first_late_percent_check
    check (reschedule_first_late_percent is null or reschedule_first_late_percent between 0 and 100),
  add constraint service_change_policy_v2_repeat_percent_check
    check (reschedule_repeat_percent is null or reschedule_repeat_percent between 0 and 100),
  add constraint service_change_policy_v2_cancel_late_percent_check
    check (cancellation_late_percent is null or cancellation_late_percent between 0 and 100),
  add constraint service_change_policy_v2_all_or_none_check
    check (
      (reschedule_first_early_percent is null
       and reschedule_first_late_percent is null
       and reschedule_repeat_percent is null
       and cancellation_late_percent is null)
      or
      (reschedule_first_early_percent is not null
       and reschedule_first_late_percent is not null
       and reschedule_repeat_percent is not null
       and cancellation_late_percent is not null)
    );

comment on column public.service_change_policies.reschedule_first_early_percent is
  'V2 percent for first client reschedule at or above the notice boundary. Official initial value: 0.';
comment on column public.service_change_policies.reschedule_first_late_percent is
  'V2 percent for first client reschedule inside the notice window. Official initial value: 20.';
comment on column public.service_change_policies.reschedule_repeat_percent is
  'V2 percent for second and later client reschedules. Takes precedence over notice window. Official initial value: 30.';
comment on column public.service_change_policies.cancellation_late_percent is
  'V2 percent for cancellation inside the notice window. Cancellation at or above the boundary is always 0 percent.';

-- Policy/default values must never materialize silently. Historical columns remain
-- temporarily for compatibility until the credit-removal gate is resolved, but
-- their database defaults are removed now.
alter table public.service_change_policies
  alter column notice_hours drop default,
  alter column reschedule_first_penalty_type drop default,
  alter column reschedule_first_penalty_value drop default,
  alter column reschedule_repeat_penalty_type drop default,
  alter column reschedule_repeat_penalty_value drop default,
  alter column reschedule_late_penalty_type drop default,
  alter column reschedule_late_penalty_value drop default,
  alter column cancellation_early_penalty_type drop default,
  alter column cancellation_early_penalty_value drop default,
  alter column cancellation_late_penalty_type drop default,
  alter column cancellation_late_penalty_value drop default,
  alter column cancellation_early_refund_allowed drop default,
  alter column cancellation_early_credit_allowed drop default,
  alter column cancellation_late_refund_allowed drop default,
  alter column cancellation_late_credit_allowed drop default,
  alter column cancellation_credit_validity_days drop default;

-- Explicitly migrate every currently configured service to the consolidated
-- forward-looking policy. Existing appointments are protected by immutable V1
-- snapshots and therefore keep the policy they contracted.
do $$
declare
  r record;
  v_before jsonb;
  v_after jsonb;
begin
  for r in
    select service_id
    from public.service_change_policies
    order by service_id
    for update
  loop
    select to_jsonb(cp) into v_before
    from public.service_change_policies cp
    where cp.service_id = r.service_id;

    update public.service_change_policies
    set notice_hours = 48,
        reschedule_first_early_percent = 0,
        reschedule_first_late_percent = 20,
        reschedule_repeat_percent = 30,
        cancellation_late_percent = 30,
        -- Temporary legacy mirrors. They no longer drive V2 calculations.
        reschedule_first_penalty_type = 'NONE',
        reschedule_first_penalty_value = 0,
        reschedule_repeat_penalty_type = 'PERCENT',
        reschedule_repeat_penalty_value = 30,
        reschedule_late_penalty_type = 'PERCENT',
        reschedule_late_penalty_value = 20,
        cancellation_early_penalty_type = 'NONE',
        cancellation_early_penalty_value = 0,
        cancellation_late_penalty_type = 'PERCENT',
        cancellation_late_penalty_value = 30,
        updated_at = now()
    where service_id = r.service_id;

    select to_jsonb(cp) into v_after
    from public.service_change_policies cp
    where cp.service_id = r.service_id;

    if v_before is distinct from v_after then
      insert into public.audit_logs(
        admin_user_id, entity_type, entity_id, action,
        before_json, after_json, origin
      ) values (
        null, 'SERVICE', r.service_id,
        'SERVICE_CHANGE_POLICY_CONSOLIDATED_V2_MIGRATED',
        jsonb_build_object('change_policy', v_before),
        jsonb_build_object('change_policy', v_after),
        'SYSTEM'
      );
    end if;
  end loop;
end;
$$;

-- Any new/edited row that uses the legacy compatibility shape must be explicit
-- and percentage-based. This prevents post-V2 creation of fixed-amount legacy
-- policies while the old columns still exist for the issued-credit gate.
create or replace function public.enforce_consolidated_change_policy_v2()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_has_v2 boolean;
begin
  v_has_v2 := new.reschedule_first_early_percent is not null
    or new.reschedule_first_late_percent is not null
    or new.reschedule_repeat_percent is not null
    or new.cancellation_late_percent is not null;

  if v_has_v2 then
    if new.reschedule_first_early_percent is null
       or new.reschedule_first_late_percent is null
       or new.reschedule_repeat_percent is null
       or new.cancellation_late_percent is null then
      raise exception using errcode='P0001', message='CHANGE_POLICY_V2_COMPLETE_CONFIGURATION_REQUIRED';
    end if;
  else
    -- Compatibility mapping is allowed only from an explicit complete legacy row.
    if new.reschedule_first_penalty_type = 'FIXED'
       or new.reschedule_late_penalty_type = 'FIXED'
       or new.reschedule_repeat_penalty_type = 'FIXED'
       or new.cancellation_late_penalty_type = 'FIXED' then
      raise exception using errcode='P0001', message='CHANGE_POLICY_V2_PERCENT_ONLY';
    end if;
    if new.cancellation_early_penalty_type <> 'NONE'
       or new.cancellation_early_penalty_value <> 0 then
      raise exception using errcode='P0001', message='CHANGE_POLICY_V2_EARLY_CANCELLATION_MUST_BE_ZERO';
    end if;

    new.reschedule_first_early_percent := case
      when new.reschedule_first_penalty_type = 'NONE' then 0
      else new.reschedule_first_penalty_value
    end;
    new.reschedule_first_late_percent := case
      when new.reschedule_late_penalty_type = 'NONE' then 0
      else new.reschedule_late_penalty_value
    end;
    new.reschedule_repeat_percent := case
      when new.reschedule_repeat_penalty_type = 'NONE' then 0
      else new.reschedule_repeat_penalty_value
    end;
    new.cancellation_late_percent := case
      when new.cancellation_late_penalty_type = 'NONE' then 0
      else new.cancellation_late_penalty_value
    end;
  end if;

  -- Keep temporary legacy mirrors consistent. The V2 engine does not read them.
  new.reschedule_first_penalty_type := case when new.reschedule_first_early_percent = 0 then 'NONE'::public.change_penalty_type else 'PERCENT'::public.change_penalty_type end;
  new.reschedule_first_penalty_value := new.reschedule_first_early_percent;
  new.reschedule_late_penalty_type := case when new.reschedule_first_late_percent = 0 then 'NONE'::public.change_penalty_type else 'PERCENT'::public.change_penalty_type end;
  new.reschedule_late_penalty_value := new.reschedule_first_late_percent;
  new.reschedule_repeat_penalty_type := case when new.reschedule_repeat_percent = 0 then 'NONE'::public.change_penalty_type else 'PERCENT'::public.change_penalty_type end;
  new.reschedule_repeat_penalty_value := new.reschedule_repeat_percent;
  new.cancellation_early_penalty_type := 'NONE';
  new.cancellation_early_penalty_value := 0;
  new.cancellation_late_penalty_type := case when new.cancellation_late_percent = 0 then 'NONE'::public.change_penalty_type else 'PERCENT'::public.change_penalty_type end;
  new.cancellation_late_penalty_value := new.cancellation_late_percent;

  return new;
end;
$$;

create trigger service_change_policies_enforce_v2
before insert or update on public.service_change_policies
for each row execute function public.enforce_consolidated_change_policy_v2();

-- Snapshot normalization distinguishes the immutable historical shape from the
-- consolidated forward-looking shape. Existing snapshot rows are not mutated.
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
      'snapshot_schema_version', case
        when nullif(p_policy->>'reschedule_first_early_percent','') is not null
         and nullif(p_policy->>'reschedule_first_late_percent','') is not null
         and nullif(p_policy->>'reschedule_repeat_percent','') is not null
         and nullif(p_policy->>'cancellation_late_percent','') is not null
        then 'CONSOLIDATED_POLICY_V2'
        else 'CHANGE_POLICY_SNAPSHOT_V1'
      end
    )
  end;
$$;

-- Canonical four-argument engine. p_new_contract_value is optional at the caller
-- level but intentionally has no SQL default so the legacy wrapper stays unambiguous.
create or replace function public.calculate_appointment_change_policy(
  p_appointment_id uuid,
  p_action_type text,
  p_requested_at timestamptz,
  p_new_contract_value numeric
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
  v_schema text;
  v_notice_hours integer;
  v_seconds_before numeric;
  v_hours_before numeric(12,2);
  v_inside_window boolean;
  v_prior_reschedules integer;
  v_contract_value numeric(12,2);
  v_paid numeric(12,2);
  v_penalty_type public.change_penalty_type;
  v_penalty_value numeric(12,2) := 0;
  v_theoretical_penalty numeric(12,2) := 0;
  v_penalty numeric(12,2) := 0;
  v_penalty_due_now numeric(12,2) := 0;
  v_refund_allowed boolean := false;
  v_credit_allowed boolean := false;
  v_refundable numeric(12,2) := 0;
  v_credit numeric(12,2) := 0;
  v_outstanding numeric(12,2) := 0;
  v_applicable numeric(12,2) := 0;
  v_difference numeric(12,2);
  v_excess numeric(12,2);
begin
  if p_action_type not in ('RESCHEDULE','CANCEL') then
    raise exception using errcode='P0001', message='INVALID_CHANGE_ACTION';
  end if;
  if p_requested_at is null then
    raise exception using errcode='P0001', message='CHANGE_REQUESTED_AT_REQUIRED';
  end if;
  if p_new_contract_value is not null and p_new_contract_value < 0 then
    raise exception using errcode='P0001', message='NEW_CONTRACT_VALUE_INVALID';
  end if;

  select * into v_appointment
  from public.appointments
  where id=p_appointment_id and deleted_at is null;
  if not found then raise exception using errcode='P0001', message='APPOINTMENT_NOT_FOUND'; end if;

  select * into v_snapshot
  from public.appointment_change_policy_snapshots
  where appointment_id=p_appointment_id;
  if not found then raise exception using errcode='P0001', message='APPOINTMENT_CHANGE_POLICY_SNAPSHOT_MISSING'; end if;

  v_policy:=v_snapshot.policy_json;
  v_schema:=coalesce(v_policy->>'snapshot_schema_version','CHANGE_POLICY_SNAPSHOT_V1');
  v_notice_hours:=(v_policy->>'notice_hours')::integer;
  if v_notice_hours is null then raise exception using errcode='P0001', message='APPOINTMENT_CHANGE_POLICY_SNAPSHOT_INVALID'; end if;

  v_seconds_before:=extract(epoch from (v_appointment.start_at-p_requested_at));
  v_hours_before:=round(v_seconds_before/3600.0,2);
  -- Exact boundary is explicitly early/no-penalty: only strictly less is late.
  v_inside_window:=v_seconds_before < (v_notice_hours::numeric*3600);

  select count(*)::integer into v_prior_reschedules
  from public.appointment_policy_actions apa
  where apa.appointment_id=p_appointment_id
    and apa.action_type='RESCHEDULE'
    and apa.status='APPLIED';

  v_contract_value:=round(coalesce(v_appointment.commercial_value,0),2);
  v_paid:=round(public.appointment_net_paid_amount(p_appointment_id),2);

  if v_schema='CONSOLIDATED_POLICY_V2' then
    v_penalty_type:='PERCENT';
    if p_action_type='RESCHEDULE' then
      -- Human decision: recurrence has precedence over notice window.
      if v_prior_reschedules>0 then
        v_penalty_value:=(v_policy->>'reschedule_repeat_percent')::numeric;
      elsif v_inside_window then
        v_penalty_value:=(v_policy->>'reschedule_first_late_percent')::numeric;
      else
        v_penalty_value:=(v_policy->>'reschedule_first_early_percent')::numeric;
      end if;
    else
      -- Cancellation ignores recurrence. At/above the boundary it is always 0%.
      v_penalty_value:=case when v_inside_window
        then (v_policy->>'cancellation_late_percent')::numeric
        else 0::numeric
      end;
    end if;

    v_theoretical_penalty:=round(v_contract_value*v_penalty_value/100,2);
    -- Commercial invariant: no debt can arise from a penalty. The percentage is
    -- calculated on total contract value, then retention is capped by money paid.
    v_penalty:=round(least(v_theoretical_penalty,v_paid),2);
    v_penalty_due_now:=0;
    v_outstanding:=0;
    v_applicable:=round(greatest(v_paid-v_penalty,0),2);

    if p_action_type='CANCEL' then
      v_refundable:=v_applicable;
      v_refund_allowed:=v_refundable>0;
      -- Legacy cancellation credit is intentionally NOT activated by V2. A new
      -- customer-balance entity is implemented only after the issued-credit gate.
      v_credit_allowed:=false;
      v_credit:=0;
    elsif p_new_contract_value is not null then
      v_difference:=round(greatest(p_new_contract_value-v_applicable,0),2);
      v_excess:=round(greatest(v_applicable-p_new_contract_value,0),2);
    end if;
  else
    -- Historical V1 snapshots retain exactly the policy accepted at booking.
    if p_action_type='RESCHEDULE' then
      if v_inside_window then
        v_penalty_type:=(v_policy->>'reschedule_late_penalty_type')::public.change_penalty_type;
        v_penalty_value:=(v_policy->>'reschedule_late_penalty_value')::numeric;
      elsif v_prior_reschedules>0 then
        v_penalty_type:=(v_policy->>'reschedule_repeat_penalty_type')::public.change_penalty_type;
        v_penalty_value:=(v_policy->>'reschedule_repeat_penalty_value')::numeric;
      else
        v_penalty_type:=(v_policy->>'reschedule_first_penalty_type')::public.change_penalty_type;
        v_penalty_value:=(v_policy->>'reschedule_first_penalty_value')::numeric;
      end if;
      v_penalty:=public.calculate_change_penalty(v_penalty_type,v_penalty_value,v_contract_value);
      v_theoretical_penalty:=v_penalty;
      v_penalty_due_now:=v_penalty;
    else
      if v_inside_window then
        v_penalty_type:=(v_policy->>'cancellation_late_penalty_type')::public.change_penalty_type;
        v_penalty_value:=(v_policy->>'cancellation_late_penalty_value')::numeric;
        v_refund_allowed:=coalesce((v_policy->>'cancellation_late_refund_allowed')::boolean,false);
        v_credit_allowed:=coalesce((v_policy->>'cancellation_late_credit_allowed')::boolean,false);
      else
        v_penalty_type:=(v_policy->>'cancellation_early_penalty_type')::public.change_penalty_type;
        v_penalty_value:=(v_policy->>'cancellation_early_penalty_value')::numeric;
        v_refund_allowed:=coalesce((v_policy->>'cancellation_early_refund_allowed')::boolean,false);
        v_credit_allowed:=coalesce((v_policy->>'cancellation_early_credit_allowed')::boolean,false);
      end if;
      v_penalty:=public.calculate_change_penalty(v_penalty_type,v_penalty_value,v_contract_value);
      v_theoretical_penalty:=v_penalty;
      v_refundable:=round(greatest(v_paid-v_penalty,0),2);
      v_credit:=v_refundable;
      v_outstanding:=round(greatest(v_penalty-v_paid,0),2);
      v_applicable:=v_refundable;
    end if;
  end if;

  return jsonb_build_object(
    'appointment_id',p_appointment_id,
    'service_id',v_appointment.service_id,
    'action_type',p_action_type,
    'requested_at',p_requested_at,
    'original_start_at',v_appointment.start_at,
    'hours_before_start',v_hours_before,
    'notice_hours',v_notice_hours,
    'inside_notice_window',v_inside_window,
    'notice_boundary_semantics',v_snapshot.notice_boundary_semantics,
    'prior_customer_reschedules',v_prior_reschedules,
    'max_customer_reschedules',v_snapshot.max_customer_reschedules,
    'contract_value',v_contract_value,
    'net_paid',v_paid,
    'penalty_type',v_penalty_type,
    'penalty_value',v_penalty_value,
    'penalty_calculated_on_total',v_theoretical_penalty,
    'penalty_amount',v_penalty,
    'retained_amount',v_penalty,
    'penalty_due_now',v_penalty_due_now,
    'applicable_amount',v_applicable,
    'new_contract_value',p_new_contract_value,
    'difference_to_pay',v_difference,
    'retained_excess',v_excess,
    'refund_allowed',v_refund_allowed,
    'credit_allowed',v_credit_allowed,
    'credit_validity_days',case when v_schema='CONSOLIDATED_POLICY_V2' then null else nullif(v_policy->>'cancellation_credit_validity_days','')::integer end,
    'refundable_amount',v_refundable,
    'credit_amount',v_credit,
    'cancellation_penalty_outstanding',v_outstanding,
    'policy_snapshot_schema',v_schema,
    'policy_snapshot_source',v_snapshot.source,
    'policy_snapshot_effective_at',v_snapshot.effective_at
  );
end;
$$;

-- Compatibility wrapper: no calculation lives here.
create or replace function public.calculate_appointment_change_policy(
  p_appointment_id uuid,
  p_action_type text,
  p_requested_at timestamptz default now()
)
returns jsonb
language sql
stable
set search_path = public
as $$
  select public.calculate_appointment_change_policy(
    p_appointment_id,p_action_type,p_requested_at,null::numeric
  );
$$;

revoke all on function public.calculate_appointment_change_policy(uuid,text,timestamptz,numeric) from public,anon,authenticated;
grant execute on function public.calculate_appointment_change_policy(uuid,text,timestamptz,numeric) to service_role;
-- END RC MIGRATION 20260822161000_consolidated_change_policy_v2.sql

-- BEGIN RC MIGRATION 20260822161100_v2_legacy_compatibility_gate.sql
-- Temporary compatibility gate required by the issued-credit inventory stop.
-- Existing production service rows were explicitly migrated to V2 in the prior
-- migration. Rows that still use only the historical shape remain V1-compatible
-- until the issued cancellation-credit inventory is presented and decided.
-- This prevents accidental semantic conversion/removal before that mandatory gate.

create or replace function public.enforce_consolidated_change_policy_v2()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_v2_count integer;
begin
  v_v2_count :=
    (case when new.reschedule_first_early_percent is null then 0 else 1 end) +
    (case when new.reschedule_first_late_percent is null then 0 else 1 end) +
    (case when new.reschedule_repeat_percent is null then 0 else 1 end) +
    (case when new.cancellation_late_percent is null then 0 else 1 end);

  -- Historical-only rows are deliberately left untouched until the issued-credit
  -- inventory gate is resolved. They create V1 snapshots and preserve contracted
  -- legacy behavior. No forward service in the live catalog should remain here,
  -- because the previous migration explicitly converted every configured row.
  if v_v2_count = 0 then
    return new;
  end if;

  if v_v2_count <> 4 then
    raise exception using errcode='P0001', message='CHANGE_POLICY_V2_COMPLETE_CONFIGURATION_REQUIRED';
  end if;

  if new.cancellation_early_penalty_type <> 'NONE'
     or new.cancellation_early_penalty_value <> 0 then
    raise exception using errcode='P0001', message='CHANGE_POLICY_V2_EARLY_CANCELLATION_MUST_BE_ZERO';
  end if;

  -- V2 supports percentages only. The legacy columns are compatibility mirrors,
  -- never an independent calculation source.
  new.reschedule_first_penalty_type := case
    when new.reschedule_first_early_percent = 0 then 'NONE'::public.change_penalty_type
    else 'PERCENT'::public.change_penalty_type end;
  new.reschedule_first_penalty_value := new.reschedule_first_early_percent;

  new.reschedule_late_penalty_type := case
    when new.reschedule_first_late_percent = 0 then 'NONE'::public.change_penalty_type
    else 'PERCENT'::public.change_penalty_type end;
  new.reschedule_late_penalty_value := new.reschedule_first_late_percent;

  new.reschedule_repeat_penalty_type := case
    when new.reschedule_repeat_percent = 0 then 'NONE'::public.change_penalty_type
    else 'PERCENT'::public.change_penalty_type end;
  new.reschedule_repeat_penalty_value := new.reschedule_repeat_percent;

  new.cancellation_early_penalty_type := 'NONE';
  new.cancellation_early_penalty_value := 0;
  new.cancellation_late_penalty_type := case
    when new.cancellation_late_percent = 0 then 'NONE'::public.change_penalty_type
    else 'PERCENT'::public.change_penalty_type end;
  new.cancellation_late_penalty_value := new.cancellation_late_percent;

  return new;
end;
$$;
-- END RC MIGRATION 20260822161100_v2_legacy_compatibility_gate.sql

-- BEGIN RC MIGRATION 20260822161200_admin_change_policy_v2_contract.sql
-- Administrative contract for consolidated change-policy V2.
-- Creation requires the complete V2 contract. Updates may patch existing V2
-- values, but omission only preserves an already-persisted value; it never
-- invents a percentage, notice window or validity period.

alter table public.service_change_policies
  alter column cancellation_credit_validity_days drop not null;

-- Forward V2 policies do not advertise the legacy automatic-credit option.
update public.service_change_policies
set cancellation_early_refund_allowed = true,
    cancellation_early_credit_allowed = false,
    cancellation_late_refund_allowed = true,
    cancellation_late_credit_allowed = false,
    cancellation_credit_validity_days = null,
    updated_at = now()
where reschedule_first_early_percent is not null
  and reschedule_first_late_percent is not null
  and reschedule_repeat_percent is not null
  and cancellation_late_percent is not null;

create or replace function public.service_admin_upsert_change_policy(
  p_service_id uuid,
  p_policy jsonb
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_current public.service_change_policies%rowtype;
  v_result public.service_change_policies%rowtype;
  v_exists boolean;
  v_notice_hours integer;
  v_first_early numeric(5,2);
  v_first_late numeric(5,2);
  v_repeat numeric(5,2);
  v_cancel_late numeric(5,2);
  v_required_keys text[] := array[
    'notice_hours',
    'reschedule_first_early_percent',
    'reschedule_first_late_percent',
    'reschedule_repeat_percent',
    'cancellation_late_percent'
  ];
begin
  if not exists(select 1 from public.services where id=p_service_id) then
    raise exception using errcode='P0001', message='SERVICE_NOT_FOUND';
  end if;
  if p_policy is null or jsonb_typeof(p_policy)<>'object' then
    raise exception using errcode='P0001', message='INVALID_CHANGE_POLICY';
  end if;

  select * into v_current
  from public.service_change_policies
  where service_id=p_service_id
  for update;
  v_exists:=found;

  if not v_exists and not (p_policy ?& v_required_keys) then
    raise exception using errcode='P0001', message='CHANGE_POLICY_COMPLETE_CONFIGURATION_REQUIRED';
  end if;

  -- Reject legacy policy knobs from the administrative write surface. Their
  -- columns remain temporarily only to honor issued legacy credits/reservations.
  if p_policy ?| array[
    'reschedule_first_penalty_type','reschedule_first_penalty_value',
    'reschedule_repeat_penalty_type','reschedule_repeat_penalty_value',
    'reschedule_late_penalty_type','reschedule_late_penalty_value',
    'cancellation_early_penalty_type','cancellation_early_penalty_value',
    'cancellation_late_penalty_type','cancellation_late_penalty_value',
    'cancellation_early_refund_allowed','cancellation_early_credit_allowed',
    'cancellation_late_refund_allowed','cancellation_late_credit_allowed',
    'cancellation_credit_validity_days'
  ] then
    raise exception using errcode='P0001', message='LEGACY_CHANGE_POLICY_FIELDS_NOT_ACCEPTED';
  end if;

  begin
    v_notice_hours:=case when p_policy ? 'notice_hours'
      then (p_policy->>'notice_hours')::integer else v_current.notice_hours end;
    v_first_early:=case when p_policy ? 'reschedule_first_early_percent'
      then (p_policy->>'reschedule_first_early_percent')::numeric else v_current.reschedule_first_early_percent end;
    v_first_late:=case when p_policy ? 'reschedule_first_late_percent'
      then (p_policy->>'reschedule_first_late_percent')::numeric else v_current.reschedule_first_late_percent end;
    v_repeat:=case when p_policy ? 'reschedule_repeat_percent'
      then (p_policy->>'reschedule_repeat_percent')::numeric else v_current.reschedule_repeat_percent end;
    v_cancel_late:=case when p_policy ? 'cancellation_late_percent'
      then (p_policy->>'cancellation_late_percent')::numeric else v_current.cancellation_late_percent end;
  exception
    when invalid_text_representation or numeric_value_out_of_range then
      raise exception using errcode='P0001', message='INVALID_CHANGE_POLICY';
  end;

  if v_notice_hours is null or v_notice_hours<0
     or v_first_early is null or v_first_early not between 0 and 100
     or v_first_late is null or v_first_late not between 0 and 100
     or v_repeat is null or v_repeat not between 0 and 100
     or v_cancel_late is null or v_cancel_late not between 0 and 100 then
    raise exception using errcode='P0001', message='INVALID_CHANGE_POLICY';
  end if;

  insert into public.service_change_policies(
    service_id, notice_hours,
    reschedule_first_penalty_type,reschedule_first_penalty_value,
    reschedule_repeat_penalty_type,reschedule_repeat_penalty_value,
    reschedule_late_penalty_type,reschedule_late_penalty_value,
    cancellation_early_penalty_type,cancellation_early_penalty_value,
    cancellation_late_penalty_type,cancellation_late_penalty_value,
    cancellation_early_refund_allowed,cancellation_early_credit_allowed,
    cancellation_late_refund_allowed,cancellation_late_credit_allowed,
    cancellation_credit_validity_days,
    reschedule_first_early_percent,reschedule_first_late_percent,
    reschedule_repeat_percent,cancellation_late_percent
  ) values (
    p_service_id,v_notice_hours,
    case when v_first_early=0 then 'NONE'::public.change_penalty_type else 'PERCENT'::public.change_penalty_type end,v_first_early,
    case when v_repeat=0 then 'NONE'::public.change_penalty_type else 'PERCENT'::public.change_penalty_type end,v_repeat,
    case when v_first_late=0 then 'NONE'::public.change_penalty_type else 'PERCENT'::public.change_penalty_type end,v_first_late,
    'NONE',0,
    case when v_cancel_late=0 then 'NONE'::public.change_penalty_type else 'PERCENT'::public.change_penalty_type end,v_cancel_late,
    true,false,true,false,null,
    v_first_early,v_first_late,v_repeat,v_cancel_late
  )
  on conflict(service_id) do update
  set notice_hours=excluded.notice_hours,
      reschedule_first_early_percent=excluded.reschedule_first_early_percent,
      reschedule_first_late_percent=excluded.reschedule_first_late_percent,
      reschedule_repeat_percent=excluded.reschedule_repeat_percent,
      cancellation_late_percent=excluded.cancellation_late_percent,
      cancellation_early_refund_allowed=true,
      cancellation_early_credit_allowed=false,
      cancellation_late_refund_allowed=true,
      cancellation_late_credit_allowed=false,
      cancellation_credit_validity_days=null,
      updated_at=now()
  returning * into v_result;

  return jsonb_build_object(
    'notice_hours',v_result.notice_hours,
    'reschedule_first_early_percent',v_result.reschedule_first_early_percent,
    'reschedule_first_late_percent',v_result.reschedule_first_late_percent,
    'reschedule_repeat_percent',v_result.reschedule_repeat_percent,
    'cancellation_late_percent',v_result.cancellation_late_percent
  );
end;
$$;

create or replace function public.service_admin_upsert_change_policy_audited(
  p_service_id uuid,
  p_policy jsonb,
  p_admin_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_before jsonb;
  v_after jsonb;
  v_result jsonb;
begin
  if not public.service_admin_has_permission(p_admin_id,'SERVICES_MANAGE')
     or not public.service_admin_has_permission(p_admin_id,'FINANCE_MANAGE') then
    raise exception using errcode='P0001', message='ADMIN_PERMISSION_DENIED';
  end if;
  if p_policy is null or jsonb_typeof(p_policy)<>'object' then
    raise exception using errcode='P0001', message='INVALID_CHANGE_POLICY';
  end if;

  v_before:=public.service_admin_service_snapshot(p_service_id);
  if v_before is null then
    raise exception using errcode='P0001', message='SERVICE_NOT_FOUND';
  end if;

  v_result:=public.service_admin_upsert_change_policy(p_service_id,p_policy);
  v_after:=public.service_admin_service_snapshot(p_service_id);

  if v_before is distinct from v_after then
    insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
    values(p_admin_id,'SERVICE',p_service_id,'SERVICE_CHANGE_POLICY_UPDATED',v_before,v_after,'ADMIN');
  end if;
  return v_result;
end;
$$;

revoke all on function public.service_admin_upsert_change_policy(uuid,jsonb) from public,anon,authenticated,service_role;
revoke all on function public.service_admin_upsert_change_policy_audited(uuid,jsonb,uuid) from public,anon,authenticated;
grant execute on function public.service_admin_upsert_change_policy_audited(uuid,jsonb,uuid) to service_role;
-- END RC MIGRATION 20260822161200_admin_change_policy_v2_contract.sql

-- BEGIN RC MIGRATION 20260822162900_drop_legacy_change_calculator_overloads.sql
-- Prepare the retained-settlement change-action contract.
-- PostgreSQL does not allow CREATE OR REPLACE to erase/rename existing input
-- parameter names. Drop the exact legacy overloads first; following migrations
-- recreate them only as fail-closed compatibility stubs. New callers must pass
-- explicit CLIENT/OPERATION origin through the V2 functions.

drop function if exists public.calculate_appointment_change_policy(uuid,text,timestamptz,numeric);
drop function if exists public.calculate_appointment_change_policy(uuid,text,timestamptz);

drop function if exists public.service_admin_create_reschedule_hold(uuid,timestamptz,timestamptz,uuid);
drop function if exists public.service_admin_cancel_appointment(uuid,text,text,timestamptz,uuid);
-- END RC MIGRATION 20260822162900_drop_legacy_change_calculator_overloads.sql

-- BEGIN RC MIGRATION 20260822163000_customer_balance_and_change_settlement.sql
-- Consolidated settlement model for cancellation/rescheduling.
-- Replaces separate penalty collection and expiring cancellation-credit coupons.
-- Customer money is either applied to the active contract, retained as an explicit
-- penalty, refundable, or held as customer-owned excess. It never becomes debt.

-- Booking payment invariant: the only confirmation choices are 50% or 100%.
alter table public.operation_settings
  drop constraint if exists operation_settings_default_confirmation_percentage_check;
alter table public.operation_settings
  add constraint operation_settings_default_confirmation_percentage_check
  check (default_confirmation_percentage in (50,100));

alter table public.services
  drop constraint if exists services_confirmation_percentage_check;
alter table public.services
  add constraint services_confirmation_percentage_check
  check (confirmation_percentage is null or confirmation_percentage in (50,100));

-- Hard gate: old automatic cancellation credits must be inventoried before this
-- migration may remove their issuance model. No current production database exists,
-- so the expected count is zero. Never silently migrate a non-zero environment.
do $$
declare
  v_legacy jsonb;
begin
  select coalesce(jsonb_agg(jsonb_build_object(
    'coupon_id',c.id,
    'customer_id',c.customer_id,
    'source_appointment_id',c.source_appointment_id,
    'amount',c.discount_value,
    'valid_until',c.valid_until,
    'used_count',c.used_count
  ) order by c.created_at,c.id),'[]'::jsonb)
  into v_legacy
  from public.coupons c
  where c.source='CANCELLATION_CREDIT';

  if jsonb_array_length(v_legacy)>0 then
    raise exception using
      errcode='P0001',
      message='LEGACY_CANCELLATION_CREDITS_REQUIRE_HUMAN_MIGRATION_DECISION',
      detail=v_legacy::text;
  end if;
end;
$$;

-- Remove the legacy automatic-credit issuance path. Promotional coupons remain.
drop function if exists public.issue_cancellation_credit_coupon(uuid);
drop index if exists public.coupons_cancellation_credit_appointment_uq;
alter table public.coupons drop constraint if exists cancellation_credit_coupon_shape_check;
alter table public.coupons drop constraint if exists coupons_source_check;
alter table public.coupons
  add constraint coupons_source_check check (source='PROMOTION');

-- The live service policy now contains only the consolidated contract. Historical
-- reservations keep legacy policy shapes solely inside their immutable snapshots.
drop trigger if exists service_change_policies_enforce_v2 on public.service_change_policies;
drop function if exists public.enforce_consolidated_change_policy_v2();
alter table public.service_change_policies
  drop constraint if exists service_change_policy_first_penalty_shape,
  drop constraint if exists service_change_policy_repeat_penalty_shape,
  drop constraint if exists service_change_policy_late_reschedule_penalty_shape,
  drop constraint if exists service_change_policy_early_cancel_penalty_shape,
  drop constraint if exists service_change_policy_late_cancel_penalty_shape;
alter table public.service_change_policies
  drop column if exists reschedule_first_penalty_type,
  drop column if exists reschedule_first_penalty_value,
  drop column if exists reschedule_repeat_penalty_type,
  drop column if exists reschedule_repeat_penalty_value,
  drop column if exists reschedule_late_penalty_type,
  drop column if exists reschedule_late_penalty_value,
  drop column if exists cancellation_early_penalty_type,
  drop column if exists cancellation_early_penalty_value,
  drop column if exists cancellation_late_penalty_type,
  drop column if exists cancellation_late_penalty_value,
  drop column if exists cancellation_early_refund_allowed,
  drop column if exists cancellation_early_credit_allowed,
  drop column if exists cancellation_late_refund_allowed,
  drop column if exists cancellation_late_credit_allowed,
  drop column if exists cancellation_credit_validity_days;
alter table public.service_change_policies
  alter column notice_hours set not null,
  alter column reschedule_first_early_percent set not null,
  alter column reschedule_first_late_percent set not null,
  alter column reschedule_repeat_percent set not null,
  alter column cancellation_late_percent set not null;

-- Action authorship must be explicit. If an existing environment contains action
-- rows created before this rule, abort rather than guessing CLIENT vs OPERATION.
alter table public.appointment_policy_actions
  add column change_origin text,
  add column policy_schema_version text,
  add column contract_applied_before numeric(12,2),
  add column excess_before numeric(12,2),
  add column applicable_amount numeric(12,2),
  add column excess_amount numeric(12,2),
  add column difference_due numeric(12,2),
  add column refund_due numeric(12,2);

do $$
declare v_unresolved jsonb;
begin
  select coalesce(jsonb_agg(jsonb_build_object('policy_action_id',id,'appointment_id',appointment_id,'action_type',action_type,'status',status)),'[]'::jsonb)
  into v_unresolved
  from public.appointment_policy_actions
  where change_origin is null;
  if jsonb_array_length(v_unresolved)>0 then
    raise exception using errcode='P0001',message='UNRESOLVED_CHANGE_ACTION_ORIGINS',detail=v_unresolved::text;
  end if;
end;
$$;

alter table public.appointment_policy_actions
  alter column change_origin set not null,
  add constraint appointment_policy_actions_change_origin_check check (change_origin in ('CLIENT','OPERATION')),
  add constraint appointment_policy_actions_contract_applied_before_check check (contract_applied_before is null or contract_applied_before>=0),
  add constraint appointment_policy_actions_excess_before_check check (excess_before is null or excess_before>=0),
  add constraint appointment_policy_actions_applicable_amount_check check (applicable_amount is null or applicable_amount>=0),
  add constraint appointment_policy_actions_excess_amount_check check (excess_amount is null or excess_amount>=0),
  add constraint appointment_policy_actions_difference_due_check check (difference_due is null or difference_due>=0),
  add constraint appointment_policy_actions_refund_due_check check (refund_due is null or refund_due>=0);

-- Retired action states/fields are removed after the legacy-credit gate.
alter table public.appointment_policy_actions drop constraint if exists appointment_policy_actions_status_check;
alter table public.appointment_policy_actions
  add constraint appointment_policy_actions_status_check check (status in (
    'PREVIEW','AWAITING_DIFFERENCE_PAYMENT','APPLIED','PENDING_REFUND','REFUNDED','FAILED','VOIDED'
  ));
alter table public.appointment_policy_actions drop constraint if exists appointment_policy_actions_settlement_choice_check;
alter table public.appointment_policy_actions
  add constraint appointment_policy_actions_settlement_choice_check
  check (settlement_choice is null or settlement_choice in ('REFUND','CUSTOMER_BALANCE'));
alter table public.appointment_policy_actions
  drop column if exists penalty_due_now,
  drop column if exists refund_allowed,
  drop column if exists credit_allowed,
  drop column if exists credit_validity_days_snapshot,
  drop column if exists credit_amount,
  drop column if exists cancellation_penalty_outstanding,
  drop column if exists generated_coupon_id,
  drop column if exists penalty_payment_transaction_id;

-- Immutable calculation ledger. One row records the authoritative financial
-- consequence of one change action; action status controls whether it is effective.
create table public.appointment_change_settlements (
  id uuid primary key default gen_random_uuid(),
  policy_action_id uuid not null unique references public.appointment_policy_actions(id) on delete restrict,
  appointment_id uuid not null references public.appointments(id) on delete restrict,
  customer_id uuid not null references public.customers(id) on delete restrict,
  action_type text not null check (action_type in ('RESCHEDULE','CANCEL')),
  change_origin text not null check (change_origin in ('CLIENT','OPERATION')),
  contract_value numeric(12,2) not null check (contract_value>=0),
  new_contract_value numeric(12,2) check (new_contract_value is null or new_contract_value>=0),
  customer_funds_before numeric(12,2) not null check (customer_funds_before>=0),
  contract_applied_before numeric(12,2) not null check (contract_applied_before>=0),
  excess_before numeric(12,2) not null check (excess_before>=0),
  penalty_percent numeric(5,2) not null check (penalty_percent between 0 and 100),
  theoretical_penalty numeric(12,2) not null check (theoretical_penalty>=0),
  penalty_retained numeric(12,2) not null check (penalty_retained>=0 and penalty_retained<=contract_applied_before),
  customer_funds_after_penalty numeric(12,2) not null check (customer_funds_after_penalty>=0),
  applicable_amount numeric(12,2) not null check (applicable_amount>=0),
  excess_after numeric(12,2) not null check (excess_after>=0),
  difference_due numeric(12,2) not null check (difference_due>=0),
  refund_due numeric(12,2) not null check (refund_due>=0),
  created_at timestamptz not null default now(),
  check (round(customer_funds_before-penalty_retained,2)=customer_funds_after_penalty),
  check (action_type='RESCHEDULE' or new_contract_value is null),
  check (action_type='CANCEL' or refund_due=0)
);
create index appointment_change_settlements_appointment_idx
  on public.appointment_change_settlements(appointment_id,created_at);

-- New customer-balance entity. It is an indefinite liability, never a coupon and
-- never revenue. Available balance is derived from immutable movements.
create table public.customer_balance_movements (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customers(id) on delete restrict,
  movement_type text not null check (movement_type in ('CREDIT_FROM_RETURN','APPLY_TO_APPOINTMENT')),
  direction text not null check (direction in ('CREDIT','DEBIT')),
  amount numeric(12,2) not null check (amount>0),
  appointment_id uuid references public.appointments(id) on delete restrict,
  policy_action_id uuid references public.appointment_policy_actions(id) on delete restrict,
  choice_origin text not null check (choice_origin in ('CLIENT_TOKEN','ADMIN_UI')),
  admin_user_id uuid references public.admin_users(id) on delete restrict,
  admin_request_reference text,
  ip_address inet not null,
  user_agent text not null check (btrim(user_agent)<>''),
  request_id text not null check (btrim(request_id)<>''),
  idempotency_key text not null unique,
  created_at timestamptz not null default now(),
  check ((movement_type='CREDIT_FROM_RETURN' and direction='CREDIT') or (movement_type='APPLY_TO_APPOINTMENT' and direction='DEBIT')),
  check (
    (choice_origin='CLIENT_TOKEN' and admin_user_id is null)
    or
    (choice_origin='ADMIN_UI' and admin_user_id is not null and nullif(btrim(admin_request_reference),'') is not null)
  )
);
create index customer_balance_movements_customer_idx
  on public.customer_balance_movements(customer_id,created_at,id);

create table public.customer_balance_refund_requests (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customers(id) on delete restrict,
  amount numeric(12,2) not null check (amount>0),
  status text not null default 'PENDING' check (status in ('PENDING','COMPLETED','FAILED')),
  choice_origin text not null check (choice_origin in ('CLIENT_TOKEN','ADMIN_UI')),
  admin_user_id uuid references public.admin_users(id) on delete restrict,
  admin_request_reference text,
  ip_address inet not null,
  user_agent text not null check (btrim(user_agent)<>''),
  request_id text not null check (btrim(request_id)<>''),
  idempotency_key text not null unique,
  requested_at timestamptz not null default now(),
  completed_at timestamptz,
  check (
    (choice_origin='CLIENT_TOKEN' and admin_user_id is null)
    or
    (choice_origin='ADMIN_UI' and admin_user_id is not null and nullif(btrim(admin_request_reference),'') is not null)
  )
);

alter table public.appointment_change_settlements enable row level security;
alter table public.customer_balance_movements enable row level security;
alter table public.customer_balance_refund_requests enable row level security;
revoke all on public.appointment_change_settlements from public,anon,authenticated;
revoke all on public.customer_balance_movements from public,anon,authenticated;
revoke all on public.customer_balance_refund_requests from public,anon,authenticated;
grant select on public.appointment_change_settlements to service_role;
grant select on public.customer_balance_movements to service_role;
grant select on public.customer_balance_refund_requests to service_role;
revoke update,delete,truncate on public.appointment_change_settlements from service_role;
revoke update,delete,truncate on public.customer_balance_movements from service_role;

create or replace function public.reject_financial_ledger_mutation()
returns trigger language plpgsql set search_path=public as $$
begin
  raise exception using errcode='42501',message='FINANCIAL_LEDGER_IMMUTABLE';
end;
$$;
create trigger appointment_change_settlements_immutable
before update or delete on public.appointment_change_settlements
for each row execute function public.reject_financial_ledger_mutation();
create trigger customer_balance_movements_immutable
before update or delete on public.customer_balance_movements
for each row execute function public.reject_financial_ledger_mutation();

-- Customer balance is a liability. Pending refund requests reserve the full amount
-- so it cannot be spent while a cash refund is being processed.
create or replace function public.customer_balance_available(p_customer_id uuid)
returns numeric(12,2)
language sql stable set search_path=public as $$
  select round(greatest(
    coalesce(sum(case when cbm.direction='CREDIT' then cbm.amount else -cbm.amount end),0)
    - coalesce((select sum(r.amount) from public.customer_balance_refund_requests r
                where r.customer_id=p_customer_id and r.status in ('PENDING','COMPLETED')),0),
    0
  ),2)::numeric(12,2)
  from public.customer_balance_movements cbm
  where cbm.customer_id=p_customer_id;
$$;

-- Funds under a reservation include cash contract payments and balance applied to
-- the reservation, less penalties already consumed by applied CLIENT reschedules.
create or replace function public.appointment_customer_funds_amount(p_appointment_id uuid)
returns numeric(12,2)
language sql stable set search_path=public as $$
  select round(greatest(
    public.appointment_net_paid_amount(p_appointment_id)
    + coalesce((select sum(cbm.amount) from public.customer_balance_movements cbm
                where cbm.appointment_id=p_appointment_id
                  and cbm.movement_type='APPLY_TO_APPOINTMENT'
                  and cbm.direction='DEBIT'),0)
    - coalesce((select sum(acs.penalty_retained)
                from public.appointment_change_settlements acs
                join public.appointment_policy_actions apa on apa.id=acs.policy_action_id
                where acs.appointment_id=p_appointment_id
                  and acs.action_type='RESCHEDULE'
                  and apa.status='APPLIED'),0),
    0
  ),2)::numeric(12,2);
$$;

create or replace function public.appointment_client_reschedule_count(p_appointment_id uuid)
returns integer
language sql stable set search_path=public as $$
  select count(*)::integer
  from public.appointment_policy_actions apa
  where apa.appointment_id=p_appointment_id
    and apa.action_type='RESCHEDULE'
    and apa.change_origin='CLIENT'
    and apa.status='APPLIED';
$$;

create or replace function public.enforce_appointment_reschedule_limit(p_appointment_id uuid,p_change_origin text)
returns void
language plpgsql stable set search_path=public as $$
declare v_limit integer; v_count integer;
begin
  if p_change_origin not in ('CLIENT','OPERATION') then
    raise exception using errcode='P0001',message='CHANGE_ORIGIN_REQUIRED';
  end if;
  if p_change_origin='OPERATION' then return; end if;
  select max_customer_reschedules into v_limit
  from public.appointment_change_policy_snapshots where appointment_id=p_appointment_id;
  if v_limit is null then raise exception using errcode='P0001',message='APPOINTMENT_CHANGE_POLICY_SNAPSHOT_MISSING'; end if;
  v_count:=public.appointment_client_reschedule_count(p_appointment_id);
  if v_count>=v_limit then
    raise exception using errcode='P0001',message='CLIENT_RESCHEDULE_LIMIT_REACHED',detail=jsonb_build_object('limit',v_limit,'count',v_count)::text;
  end if;
end;
$$;

-- One authoritative calculator. Financial values are rounded once in BRL to two
-- decimal places. Exact notice boundary is outside the penalty window.
create or replace function public.calculate_reservation_change(
  p_appointment_id uuid,
  p_action_type text,
  p_requested_at timestamptz,
  p_change_origin text,
  p_new_contract_value numeric
)
returns jsonb
language plpgsql stable set search_path=public as $$
declare
  v_appointment public.appointments%rowtype;
  v_snapshot public.appointment_change_policy_snapshots%rowtype;
  v_policy jsonb; v_schema text; v_notice integer; v_seconds numeric; v_hours numeric(12,2); v_inside boolean;
  v_count integer; v_contract numeric(12,2); v_funds numeric(12,2); v_applied numeric(12,2); v_excess_before numeric(12,2);
  v_percent numeric(5,2):=0; v_theoretical numeric(12,2):=0; v_retained numeric(12,2):=0;
  v_after numeric(12,2):=0; v_applicable numeric(12,2):=0; v_excess_after numeric(12,2):=0;
  v_difference numeric(12,2):=0; v_refund numeric(12,2):=0;
  v_legacy_type public.change_penalty_type; v_legacy_value numeric(12,2):=0;
begin
  if p_action_type not in ('RESCHEDULE','CANCEL') then raise exception using errcode='P0001',message='INVALID_CHANGE_ACTION'; end if;
  if p_requested_at is null then raise exception using errcode='P0001',message='CHANGE_REQUESTED_AT_REQUIRED'; end if;
  if p_change_origin not in ('CLIENT','OPERATION') then raise exception using errcode='P0001',message='CHANGE_ORIGIN_REQUIRED'; end if;
  if p_action_type='RESCHEDULE' and p_new_contract_value is null then raise exception using errcode='P0001',message='NEW_CONTRACT_VALUE_REQUIRED'; end if;
  if p_new_contract_value is not null and p_new_contract_value<0 then raise exception using errcode='P0001',message='NEW_CONTRACT_VALUE_INVALID'; end if;

  select * into v_appointment from public.appointments where id=p_appointment_id and deleted_at is null;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if;
  select * into v_snapshot from public.appointment_change_policy_snapshots where appointment_id=p_appointment_id;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_CHANGE_POLICY_SNAPSHOT_MISSING'; end if;

  v_policy:=v_snapshot.policy_json;
  v_schema:=coalesce(v_policy->>'snapshot_schema_version','CHANGE_POLICY_SNAPSHOT_V1');
  v_notice:=(v_policy->>'notice_hours')::integer;
  if v_notice is null then raise exception using errcode='P0001',message='APPOINTMENT_CHANGE_POLICY_SNAPSHOT_INVALID'; end if;
  v_seconds:=extract(epoch from (v_appointment.start_at-p_requested_at));
  v_hours:=round(v_seconds/3600.0,2);
  v_inside:=v_seconds<(v_notice::numeric*3600);
  v_count:=public.appointment_client_reschedule_count(p_appointment_id);
  v_contract:=round(coalesce(v_appointment.commercial_value,0),2);
  v_funds:=round(public.appointment_customer_funds_amount(p_appointment_id),2);
  v_applied:=round(least(v_funds,v_contract),2);
  v_excess_before:=round(greatest(v_funds-v_contract,0),2);

  if p_change_origin='OPERATION' then
    v_percent:=0;
  elsif v_schema='CONSOLIDATED_POLICY_V2' then
    if p_action_type='RESCHEDULE' then
      if v_count>0 then v_percent:=(v_policy->>'reschedule_repeat_percent')::numeric;
      elsif v_inside then v_percent:=(v_policy->>'reschedule_first_late_percent')::numeric;
      else v_percent:=(v_policy->>'reschedule_first_early_percent')::numeric;
      end if;
    else
      v_percent:=case when v_inside then (v_policy->>'cancellation_late_percent')::numeric else 0 end;
    end if;
  else
    -- Historical snapshots remain honored without consulting the live policy.
    if p_action_type='RESCHEDULE' then
      if v_count>0 then
        v_legacy_type:=(v_policy->>'reschedule_repeat_penalty_type')::public.change_penalty_type;
        v_legacy_value:=(v_policy->>'reschedule_repeat_penalty_value')::numeric;
      elsif v_inside then
        v_legacy_type:=(v_policy->>'reschedule_late_penalty_type')::public.change_penalty_type;
        v_legacy_value:=(v_policy->>'reschedule_late_penalty_value')::numeric;
      else
        v_legacy_type:=(v_policy->>'reschedule_first_penalty_type')::public.change_penalty_type;
        v_legacy_value:=(v_policy->>'reschedule_first_penalty_value')::numeric;
      end if;
    else
      if v_inside then
        v_legacy_type:=(v_policy->>'cancellation_late_penalty_type')::public.change_penalty_type;
        v_legacy_value:=(v_policy->>'cancellation_late_penalty_value')::numeric;
      else
        v_legacy_type:=(v_policy->>'cancellation_early_penalty_type')::public.change_penalty_type;
        v_legacy_value:=(v_policy->>'cancellation_early_penalty_value')::numeric;
      end if;
    end if;
    if v_legacy_type='PERCENT' then v_percent:=v_legacy_value;
    elsif v_legacy_type='NONE' then v_percent:=0;
    else
      -- Fixed historical penalty is preserved as an amount; percentage is only display metadata.
      v_percent:=0;
      v_theoretical:=round(v_legacy_value,2);
    end if;
  end if;

  if v_theoretical=0 then v_theoretical:=round(v_contract*v_percent/100,2); end if;
  v_retained:=case when p_change_origin='OPERATION' then 0 else round(least(v_theoretical,v_applied),2) end;
  v_after:=round(greatest(v_funds-v_retained,0),2);

  if p_action_type='RESCHEDULE' then
    v_applicable:=round(least(v_after,p_new_contract_value),2);
    v_excess_after:=round(greatest(v_after-p_new_contract_value,0),2);
    v_difference:=round(greatest(p_new_contract_value-v_after,0),2);
  else
    v_applicable:=round(greatest(v_applied-v_retained,0),2);
    v_excess_after:=v_excess_before;
    v_refund:=round(v_applicable+v_excess_before,2);
  end if;

  return jsonb_build_object(
    'appointment_id',p_appointment_id,'service_id',v_appointment.service_id,'action_type',p_action_type,'change_origin',p_change_origin,
    'requested_at',p_requested_at,'original_start_at',v_appointment.start_at,'hours_before_start',v_hours,'notice_hours',v_notice,
    'inside_notice_window',v_inside,'prior_customer_reschedules',v_count,'max_customer_reschedules',v_snapshot.max_customer_reschedules,
    'contract_value',v_contract,'new_contract_value',p_new_contract_value,'customer_funds_before',v_funds,
    'contract_applied_before',v_applied,'excess_before',v_excess_before,'penalty_percent',v_percent,
    'theoretical_penalty',v_theoretical,'penalty_retained',v_retained,'penalty_amount',v_retained,
    'customer_funds_after_penalty',v_after,'applicable_amount',v_applicable,'excess_amount',v_excess_after,
    'difference_due',v_difference,'refund_due',v_refund,'refundable_amount',v_refund,
    'customer_reschedule_limit_reached',(p_action_type='RESCHEDULE' and p_change_origin='CLIENT' and v_count>=v_snapshot.max_customer_reschedules),
    'snapshot_schema_version',v_schema
  );
end;
$$;

-- Retire calculator overloads that could infer CLIENT origin.
create or replace function public.calculate_appointment_change_policy(uuid,text,timestamptz,numeric)
returns jsonb language plpgsql stable set search_path=public as $$
begin raise exception using errcode='P0001',message='CHANGE_ORIGIN_REQUIRED_USE_CALCULATE_RESERVATION_CHANGE'; end;
$$;
create or replace function public.calculate_appointment_change_policy(uuid,text,timestamptz)
returns jsonb language plpgsql stable set search_path=public as $$
begin raise exception using errcode='P0001',message='CHANGE_ORIGIN_REQUIRED_USE_CALCULATE_RESERVATION_CHANGE'; end;
$$;

create or replace function public.record_appointment_change_settlement(
  p_policy_action_id uuid,
  p_preview jsonb
)
returns uuid
language plpgsql volatile security definer set search_path=public as $$
declare v_action public.appointment_policy_actions%rowtype; v_customer uuid; v_id uuid;
begin
  select * into v_action from public.appointment_policy_actions where id=p_policy_action_id for update;
  if not found then raise exception using errcode='P0001',message='CHANGE_ACTION_NOT_FOUND'; end if;
  select primary_customer_id into v_customer from public.appointments where id=v_action.appointment_id;
  if v_customer is null then raise exception using errcode='P0001',message='APPOINTMENT_CUSTOMER_REQUIRED'; end if;
  insert into public.appointment_change_settlements(
    policy_action_id,appointment_id,customer_id,action_type,change_origin,contract_value,new_contract_value,
    customer_funds_before,contract_applied_before,excess_before,penalty_percent,theoretical_penalty,penalty_retained,
    customer_funds_after_penalty,applicable_amount,excess_after,difference_due,refund_due
  ) values (
    p_policy_action_id,v_action.appointment_id,v_customer,v_action.action_type,v_action.change_origin,
    (p_preview->>'contract_value')::numeric,(p_preview->>'new_contract_value')::numeric,
    (p_preview->>'customer_funds_before')::numeric,(p_preview->>'contract_applied_before')::numeric,(p_preview->>'excess_before')::numeric,
    (p_preview->>'penalty_percent')::numeric,(p_preview->>'theoretical_penalty')::numeric,(p_preview->>'penalty_retained')::numeric,
    (p_preview->>'customer_funds_after_penalty')::numeric,(p_preview->>'applicable_amount')::numeric,(p_preview->>'excess_amount')::numeric,
    (p_preview->>'difference_due')::numeric,(p_preview->>'refund_due')::numeric
  ) returning id into v_id;
  return v_id;
end;
$$;

-- Complete V2 service-policy write surface after legacy columns are gone.
create or replace function public.service_admin_upsert_change_policy(p_service_id uuid,p_policy jsonb)
returns jsonb language plpgsql volatile security definer set search_path=public as $$
declare v_current public.service_change_policies%rowtype; v_exists boolean; v_notice integer; v_a numeric(5,2); v_b numeric(5,2); v_c numeric(5,2); v_d numeric(5,2); v_result public.service_change_policies%rowtype;
begin
  if not exists(select 1 from public.services where id=p_service_id) then raise exception using errcode='P0001',message='SERVICE_NOT_FOUND'; end if;
  if p_policy is null or jsonb_typeof(p_policy)<>'object' then raise exception using errcode='P0001',message='INVALID_CHANGE_POLICY'; end if;
  select * into v_current from public.service_change_policies where service_id=p_service_id for update; v_exists:=found;
  if not v_exists and not (p_policy ?& array['notice_hours','reschedule_first_early_percent','reschedule_first_late_percent','reschedule_repeat_percent','cancellation_late_percent']) then
    raise exception using errcode='P0001',message='CHANGE_POLICY_COMPLETE_CONFIGURATION_REQUIRED';
  end if;
  if p_policy ?| array['reschedule_first_penalty_type','reschedule_first_penalty_value','reschedule_repeat_penalty_type','reschedule_repeat_penalty_value','reschedule_late_penalty_type','reschedule_late_penalty_value','cancellation_early_penalty_type','cancellation_early_penalty_value','cancellation_late_penalty_type','cancellation_late_penalty_value','cancellation_early_refund_allowed','cancellation_early_credit_allowed','cancellation_late_refund_allowed','cancellation_late_credit_allowed','cancellation_credit_validity_days'] then
    raise exception using errcode='P0001',message='LEGACY_CHANGE_POLICY_FIELDS_NOT_ACCEPTED';
  end if;
  v_notice:=case when p_policy?'notice_hours' then (p_policy->>'notice_hours')::integer else v_current.notice_hours end;
  v_a:=case when p_policy?'reschedule_first_early_percent' then (p_policy->>'reschedule_first_early_percent')::numeric else v_current.reschedule_first_early_percent end;
  v_b:=case when p_policy?'reschedule_first_late_percent' then (p_policy->>'reschedule_first_late_percent')::numeric else v_current.reschedule_first_late_percent end;
  v_c:=case when p_policy?'reschedule_repeat_percent' then (p_policy->>'reschedule_repeat_percent')::numeric else v_current.reschedule_repeat_percent end;
  v_d:=case when p_policy?'cancellation_late_percent' then (p_policy->>'cancellation_late_percent')::numeric else v_current.cancellation_late_percent end;
  if v_notice is null or v_notice<0 or v_a not between 0 and 100 or v_b not between 0 and 100 or v_c not between 0 and 100 or v_d not between 0 and 100 then raise exception using errcode='P0001',message='INVALID_CHANGE_POLICY'; end if;
  insert into public.service_change_policies(service_id,notice_hours,reschedule_first_early_percent,reschedule_first_late_percent,reschedule_repeat_percent,cancellation_late_percent)
  values(p_service_id,v_notice,v_a,v_b,v_c,v_d)
  on conflict(service_id) do update set notice_hours=excluded.notice_hours,reschedule_first_early_percent=excluded.reschedule_first_early_percent,reschedule_first_late_percent=excluded.reschedule_first_late_percent,reschedule_repeat_percent=excluded.reschedule_repeat_percent,cancellation_late_percent=excluded.cancellation_late_percent,updated_at=now()
  returning * into v_result;
  return jsonb_build_object('notice_hours',v_result.notice_hours,'reschedule_first_early_percent',v_result.reschedule_first_early_percent,'reschedule_first_late_percent',v_result.reschedule_first_late_percent,'reschedule_repeat_percent',v_result.reschedule_repeat_percent,'cancellation_late_percent',v_result.cancellation_late_percent);
end;
$$;

-- Separate penalty collection no longer exists. Penalties are retained from funds.
drop function if exists public.service_admin_register_reschedule_penalty_payment(uuid,text,text,uuid);

-- Explicit customer choice can turn a returnable amount into indefinite balance.
create or replace function public.service_credit_customer_balance_from_return(
  p_appointment_id uuid,p_policy_action_id uuid,p_choice_origin text,p_admin_id uuid,
  p_ip inet,p_user_agent text,p_request_id text,p_admin_request_reference text
)
returns jsonb
language plpgsql volatile security definer set search_path=public as $$
declare v_appointment public.appointments%rowtype; v_action public.appointment_policy_actions%rowtype; v_settlement public.appointment_change_settlements%rowtype; v_amount numeric(12,2); v_key text; v_id uuid;
begin
  if p_choice_origin not in ('CLIENT_TOKEN','ADMIN_UI') or p_ip is null or nullif(btrim(p_user_agent),'') is null or nullif(btrim(p_request_id),'') is null then raise exception using errcode='P0001',message='BALANCE_AUTHORSHIP_EVIDENCE_REQUIRED'; end if;
  if p_choice_origin='ADMIN_UI' and (p_admin_id is null or nullif(btrim(p_admin_request_reference),'') is null) then raise exception using errcode='P0001',message='BALANCE_ADMIN_REQUEST_EVIDENCE_REQUIRED'; end if;
  select * into v_appointment from public.appointments where id=p_appointment_id for update;
  if not found or v_appointment.primary_customer_id is null then raise exception using errcode='P0001',message='APPOINTMENT_CUSTOMER_REQUIRED'; end if;
  select * into v_action from public.appointment_policy_actions where id=p_policy_action_id and appointment_id=p_appointment_id for update;
  if not found then raise exception using errcode='P0001',message='CHANGE_ACTION_NOT_FOUND'; end if;
  select * into v_settlement from public.appointment_change_settlements where policy_action_id=v_action.id;
  if not found then raise exception using errcode='P0001',message='CHANGE_SETTLEMENT_NOT_FOUND'; end if;
  if v_action.action_type='CANCEL' then v_amount:=v_settlement.refund_due; else v_amount:=v_settlement.excess_after; end if;
  if v_amount<=0 then raise exception using errcode='P0001',message='NO_RETURNABLE_AMOUNT'; end if;
  v_key:='balance-credit:'||p_appointment_id::text||':'||p_policy_action_id::text;
  insert into public.customer_balance_movements(customer_id,movement_type,direction,amount,appointment_id,policy_action_id,choice_origin,admin_user_id,admin_request_reference,ip_address,user_agent,request_id,idempotency_key)
  values(v_appointment.primary_customer_id,'CREDIT_FROM_RETURN','CREDIT',v_amount,p_appointment_id,p_policy_action_id,p_choice_origin,p_admin_id,nullif(btrim(p_admin_request_reference),''),p_ip,p_user_agent,p_request_id,v_key)
  on conflict(idempotency_key) do update set idempotency_key=excluded.idempotency_key returning id into v_id;
  update public.appointment_policy_actions set settlement_choice='CUSTOMER_BALANCE',status=case when action_type='CANCEL' then 'APPLIED' else status end,updated_at=now() where id=v_action.id;
  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,after_json,origin)
  values(p_admin_id,'APPOINTMENT',p_appointment_id,'CUSTOMER_BALANCE_CREATED',jsonb_build_object('policy_action_id',v_action.id,'amount',v_amount,'customer_id',v_appointment.primary_customer_id,'choice_origin',p_choice_origin,'request_id',p_request_id),case when p_choice_origin='ADMIN_UI' then 'ADMIN' else 'CLIENT' end);
  return jsonb_build_object('movement_id',v_id,'customer_id',v_appointment.primary_customer_id,'amount',v_amount,'balance_available',public.customer_balance_available(v_appointment.primary_customer_id));
end;
$$;

-- Integral-only application. The entire available balance moves to the reservation.
-- If it is larger than the amount currently due, the remainder becomes customer-owned
-- excess on that reservation and remains returnable at final settlement.
create or replace function public.service_apply_customer_balance_to_appointment(
  p_appointment_id uuid,p_policy_action_id uuid,p_choice_origin text,p_admin_id uuid,
  p_ip inet,p_user_agent text,p_request_id text,p_admin_request_reference text
)
returns jsonb
language plpgsql volatile security definer set search_path=public as $$
declare v_appointment public.appointments%rowtype; v_balance numeric(12,2); v_due numeric(12,2); v_before numeric(12,2); v_existing numeric(12,2); v_key text; v_id uuid;
begin
  if p_choice_origin not in ('CLIENT_TOKEN','ADMIN_UI') or p_ip is null or nullif(btrim(p_user_agent),'') is null or nullif(btrim(p_request_id),'') is null then raise exception using errcode='P0001',message='BALANCE_AUTHORSHIP_EVIDENCE_REQUIRED'; end if;
  if p_choice_origin='ADMIN_UI' and (p_admin_id is null or nullif(btrim(p_admin_request_reference),'') is null) then raise exception using errcode='P0001',message='BALANCE_ADMIN_REQUEST_EVIDENCE_REQUIRED'; end if;
  select * into v_appointment from public.appointments where id=p_appointment_id for update;
  if not found or v_appointment.primary_customer_id is null then raise exception using errcode='P0001',message='APPOINTMENT_CUSTOMER_REQUIRED'; end if;
  v_balance:=public.customer_balance_available(v_appointment.primary_customer_id);
  if v_balance<=0 then raise exception using errcode='P0001',message='CUSTOMER_BALANCE_EMPTY'; end if;
  v_before:=public.appointment_customer_funds_amount(p_appointment_id);
  if p_policy_action_id is null then
    v_due:=round(greatest(coalesce(v_appointment.commercial_value,0)-least(v_before,coalesce(v_appointment.commercial_value,0)),0),2);
  else
    select coalesce(sum(cbm.amount),0)::numeric(12,2) into v_existing from public.customer_balance_movements cbm where cbm.policy_action_id=p_policy_action_id and cbm.movement_type='APPLY_TO_APPOINTMENT';
    select round(greatest(acs.difference_due-v_existing,0),2) into v_due from public.appointment_change_settlements acs where acs.policy_action_id=p_policy_action_id and acs.appointment_id=p_appointment_id;
    if v_due is null then raise exception using errcode='P0001',message='CHANGE_SETTLEMENT_NOT_FOUND'; end if;
  end if;
  if v_due<=0 then raise exception using errcode='P0001',message='NO_AMOUNT_DUE_FOR_BALANCE_APPLICATION'; end if;
  v_key:='balance-apply:'||p_appointment_id::text||':'||coalesce(p_policy_action_id::text,'BOOKING');
  insert into public.customer_balance_movements(customer_id,movement_type,direction,amount,appointment_id,policy_action_id,choice_origin,admin_user_id,admin_request_reference,ip_address,user_agent,request_id,idempotency_key)
  values(v_appointment.primary_customer_id,'APPLY_TO_APPOINTMENT','DEBIT',v_balance,p_appointment_id,p_policy_action_id,p_choice_origin,p_admin_id,nullif(btrim(p_admin_request_reference),''),p_ip,p_user_agent,p_request_id,v_key)
  on conflict(idempotency_key) do update set idempotency_key=excluded.idempotency_key returning id into v_id;
  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,after_json,origin)
  values(p_admin_id,'APPOINTMENT',p_appointment_id,'CUSTOMER_BALANCE_APPLIED',jsonb_build_object('policy_action_id',p_policy_action_id,'amount_applied',v_balance,'amount_due_before',v_due,'excess_generated',greatest(v_balance-v_due,0),'request_id',p_request_id),case when p_choice_origin='ADMIN_UI' then 'ADMIN' else 'CLIENT' end);
  return jsonb_build_object('movement_id',v_id,'amount_applied',v_balance,'amount_due_before',v_due,'outstanding_after',greatest(v_due-v_balance,0),'excess_generated',greatest(v_balance-v_due,0),'balance_available',public.customer_balance_available(v_appointment.primary_customer_id));
end;
$$;

-- Customer may convert the entire available balance to a cash-refund request at
-- any time. The request reserves the liability immediately; completion is separate.
create or replace function public.service_request_customer_balance_refund(
  p_customer_id uuid,p_choice_origin text,p_admin_id uuid,p_ip inet,p_user_agent text,p_request_id text,p_admin_request_reference text
)
returns jsonb
language plpgsql volatile security definer set search_path=public as $$
declare v_amount numeric(12,2); v_key text; v_id uuid;
begin
  if p_choice_origin not in ('CLIENT_TOKEN','ADMIN_UI') or p_ip is null or nullif(btrim(p_user_agent),'') is null or nullif(btrim(p_request_id),'') is null then raise exception using errcode='P0001',message='BALANCE_AUTHORSHIP_EVIDENCE_REQUIRED'; end if;
  if p_choice_origin='ADMIN_UI' and (p_admin_id is null or nullif(btrim(p_admin_request_reference),'') is null) then raise exception using errcode='P0001',message='BALANCE_ADMIN_REQUEST_EVIDENCE_REQUIRED'; end if;
  perform 1 from public.customers where id=p_customer_id for update;
  if not found then raise exception using errcode='P0001',message='CUSTOMER_NOT_FOUND'; end if;
  v_amount:=public.customer_balance_available(p_customer_id);
  if v_amount<=0 then raise exception using errcode='P0001',message='CUSTOMER_BALANCE_EMPTY'; end if;
  v_key:='balance-refund:'||p_customer_id::text||':'||p_request_id;
  insert into public.customer_balance_refund_requests(customer_id,amount,choice_origin,admin_user_id,admin_request_reference,ip_address,user_agent,request_id,idempotency_key)
  values(p_customer_id,v_amount,p_choice_origin,p_admin_id,nullif(btrim(p_admin_request_reference),''),p_ip,p_user_agent,p_request_id,v_key)
  on conflict(idempotency_key) do update set idempotency_key=excluded.idempotency_key returning id into v_id;
  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,after_json,origin)
  values(p_admin_id,'CUSTOMER',p_customer_id,'CUSTOMER_BALANCE_REFUND_REQUESTED',jsonb_build_object('refund_request_id',v_id,'amount',v_amount,'request_id',p_request_id),case when p_choice_origin='ADMIN_UI' then 'ADMIN' else 'CLIENT' end);
  return jsonb_build_object('refund_request_id',v_id,'amount',v_amount,'status','PENDING','balance_available',public.customer_balance_available(p_customer_id));
end;
$$;

revoke all on function public.calculate_reservation_change(uuid,text,timestamptz,text,numeric) from public,anon,authenticated;
revoke all on function public.record_appointment_change_settlement(uuid,jsonb) from public,anon,authenticated,service_role;
revoke all on function public.customer_balance_available(uuid) from public,anon,authenticated;
revoke all on function public.appointment_customer_funds_amount(uuid) from public,anon,authenticated;
revoke all on function public.appointment_client_reschedule_count(uuid) from public,anon,authenticated;
revoke all on function public.enforce_appointment_reschedule_limit(uuid,text) from public,anon,authenticated;
revoke all on function public.service_credit_customer_balance_from_return(uuid,uuid,text,uuid,inet,text,text,text) from public,anon,authenticated;
revoke all on function public.service_apply_customer_balance_to_appointment(uuid,uuid,text,uuid,inet,text,text,text) from public,anon,authenticated;
revoke all on function public.service_request_customer_balance_refund(uuid,text,uuid,inet,text,text,text) from public,anon,authenticated;
grant execute on function public.calculate_reservation_change(uuid,text,timestamptz,text,numeric) to service_role;
grant execute on function public.customer_balance_available(uuid) to service_role;
grant execute on function public.appointment_customer_funds_amount(uuid) to service_role;
grant execute on function public.appointment_client_reschedule_count(uuid) to service_role;
grant execute on function public.enforce_appointment_reschedule_limit(uuid,text) to service_role;
grant execute on function public.service_credit_customer_balance_from_return(uuid,uuid,text,uuid,inet,text,text,text) to service_role;
grant execute on function public.service_apply_customer_balance_to_appointment(uuid,uuid,text,uuid,inet,text,text,text) to service_role;
grant execute on function public.service_request_customer_balance_refund(uuid,text,uuid,inet,text,text,text) to service_role;

comment on table public.customer_balance_movements is 'Customer-owned indefinite liability ledger. Never expires and never contributes to service revenue.';
comment on table public.appointment_change_settlements is 'Immutable authoritative ledger of penalty retention, applied funds, excess, refund and difference for reservation changes.';
-- END RC MIGRATION 20260822163000_customer_balance_and_change_settlement.sql
