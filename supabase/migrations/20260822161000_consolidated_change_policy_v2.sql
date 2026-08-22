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
