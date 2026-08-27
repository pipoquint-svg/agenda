
-- BEGIN RC MIGRATION 20260821213000_admin_cancellation_workflow.sql
-- Transactional administrative cancellation.
-- Operational cancellation is applied immediately; financial settlement remains explicit.
-- Cash refunds are never marked completed here: they enter PENDING_REFUND until a
-- provider/manual refund adapter records the real outcome.

create or replace function public.service_admin_cancel_appointment(
  p_appointment_id uuid,
  p_settlement_choice text default null,
  p_reason text default null,
  p_requested_at timestamptz default now(),
  p_admin_id uuid default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_appointment public.appointments%rowtype;
  v_preview jsonb;
  v_action_id uuid;
  v_new_version integer;
  v_settlement text := nullif(upper(btrim(coalesce(p_settlement_choice, ''))), '');
  v_refund_allowed boolean;
  v_credit_allowed boolean;
  v_refundable numeric(12,2);
  v_credit numeric(12,2);
  v_outstanding numeric(12,2);
  v_package_reversal_id uuid;
  v_coupon jsonb;
  v_action_status text;
  v_existing_action public.appointment_policy_actions%rowtype;
begin
  select * into v_appointment
  from public.appointments
  where id = p_appointment_id
    and deleted_at is null
  for update;

  if not found then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_NOT_FOUND';
  end if;

  if v_appointment.status = 'CANCELLED' then
    select * into v_existing_action
    from public.appointment_policy_actions
    where appointment_id = p_appointment_id
      and action_type = 'CANCEL'
      and status <> 'VOIDED'
    order by created_at desc
    limit 1;

    return jsonb_build_object(
      'appointment_id', p_appointment_id,
      'status', 'CANCELLED',
      'already_cancelled', true,
      'policy_action_id', v_existing_action.id,
      'policy_action_status', v_existing_action.status,
      'settlement_choice', v_existing_action.settlement_choice,
      'generated_coupon_id', v_existing_action.generated_coupon_id
    );
  end if;

  if v_appointment.status not in ('HELD','AWAITING_PAYMENT','CONFIRMED') then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_NOT_CANCELLABLE';
  end if;

  if p_requested_at is null then
    raise exception using errcode = 'P0001', message = 'CANCELLATION_REQUESTED_AT_REQUIRED';
  end if;

  if v_settlement is not null and v_settlement not in ('REFUND','CREDIT') then
    raise exception using errcode = 'P0001', message = 'INVALID_CANCELLATION_SETTLEMENT';
  end if;

  v_preview := public.calculate_appointment_change_policy(
    p_appointment_id,
    'CANCEL',
    p_requested_at
  );

  v_refund_allowed := coalesce((v_preview->>'refund_allowed')::boolean, false);
  v_credit_allowed := coalesce((v_preview->>'credit_allowed')::boolean, false);
  v_refundable := coalesce((v_preview->>'refundable_amount')::numeric, 0);
  v_credit := coalesce((v_preview->>'credit_amount')::numeric, 0);
  v_outstanding := coalesce((v_preview->>'cancellation_penalty_outstanding')::numeric, 0);

  if v_settlement = 'REFUND' and (not v_refund_allowed or v_refundable <= 0) then
    raise exception using errcode = 'P0001', message = 'CANCELLATION_REFUND_NOT_AVAILABLE';
  end if;

  if v_settlement = 'CREDIT' and (not v_credit_allowed or v_credit <= 0) then
    raise exception using errcode = 'P0001', message = 'CANCELLATION_CREDIT_NOT_AVAILABLE';
  end if;

  if v_settlement is null
     and ((v_refund_allowed and v_refundable > 0) or (v_credit_allowed and v_credit > 0)) then
    raise exception using errcode = 'P0001', message = 'CANCELLATION_SETTLEMENT_CHOICE_REQUIRED';
  end if;

  insert into public.appointment_policy_actions (
    appointment_id,
    action_type,
    status,
    settlement_choice,
    requested_at,
    original_start_at,
    hours_before_start,
    notice_hours_snapshot,
    is_inside_notice_window,
    prior_customer_reschedules,
    contract_value_snapshot,
    net_paid_snapshot,
    penalty_type,
    penalty_value,
    penalty_amount,
    penalty_due_now,
    refund_allowed,
    credit_allowed,
    credit_validity_days_snapshot,
    refundable_amount,
    credit_amount,
    cancellation_penalty_outstanding,
    created_by_admin_id
  ) values (
    p_appointment_id,
    'CANCEL',
    'PREVIEW',
    v_settlement,
    p_requested_at,
    (v_preview->>'original_start_at')::timestamptz,
    (v_preview->>'hours_before_start')::numeric,
    (v_preview->>'notice_hours')::integer,
    (v_preview->>'inside_notice_window')::boolean,
    (v_preview->>'prior_customer_reschedules')::integer,
    (v_preview->>'contract_value')::numeric,
    (v_preview->>'net_paid')::numeric,
    (v_preview->>'penalty_type')::public.change_penalty_type,
    (v_preview->>'penalty_value')::numeric,
    (v_preview->>'penalty_amount')::numeric,
    (v_preview->>'penalty_due_now')::numeric,
    v_refund_allowed,
    v_credit_allowed,
    (v_preview->>'credit_validity_days')::integer,
    v_refundable,
    v_credit,
    v_outstanding,
    p_admin_id
  ) returning id into v_action_id;

  update public.appointments
  set status = 'CANCELLED',
      cancelled_at = coalesce(cancelled_at, p_requested_at),
      cancel_reason = nullif(btrim(coalesce(p_reason, '')), ''),
      hold_expires_at = null,
      version = version + 1,
      updated_at = now()
  where id = p_appointment_id
  returning version into v_new_version;

  update public.resource_allocations
  set status = 'CANCELLED',
      updated_at = now()
  where appointment_id = p_appointment_id
    and allocation_type = 'APPOINTMENT'
    and status in ('HELD','AWAITING_PAYMENT','CONFIRMED','BLOCKED');

  -- A pending charge must no longer be treated as an active payment attempt after
  -- an administrative cancellation. A late provider approval is handled by the
  -- payment reconciliation/incident path rather than reviving the appointment.
  update public.payment_transactions
  set status = 'EXPIRED',
      updated_at = now(),
      notes = concat_ws(' | ', nullif(notes, ''), 'APPOINTMENT_CANCELLED_BEFORE_PAYMENT_COMPLETION')
  where appointment_id = p_appointment_id
    and transaction_type = 'CHARGE'
    and status = 'PENDING';

  if exists (
    select 1
    from public.appointment_package_usage apu
    where apu.appointment_id = p_appointment_id
      and apu.reversal_movement_id is null
  ) then
    v_package_reversal_id := public.reverse_hour_package_usage(
      p_appointment_id,
      'APPOINTMENT_CANCELLED',
      p_admin_id
    );
  end if;

  perform public.release_appointment_coupon_usage(p_appointment_id);

  insert into public.integration_jobs (
    job_type,
    entity_type,
    entity_id,
    entity_version,
    payload_json,
    idempotency_key
  ) values (
    'GOOGLE_APPOINTMENT_SYNC',
    'APPOINTMENT',
    p_appointment_id,
    v_new_version,
    jsonb_build_object('reason', 'APPOINTMENT_CANCELLED'),
    'google-appointment-sync:' || p_appointment_id::text || ':' || v_new_version::text
  ) on conflict (idempotency_key) do nothing;

  if v_outstanding > 0 then
    v_action_status := 'AWAITING_PENALTY_PAYMENT';
    update public.appointment_policy_actions
    set status = v_action_status,
        updated_at = now()
    where id = v_action_id;
  elsif v_settlement = 'CREDIT' and v_credit > 0 then
    select jsonb_build_object(
      'coupon_id', c.coupon_id,
      'code', c.code,
      'amount', c.amount,
      'expires_at', c.expires_at
    ) into v_coupon
    from public.issue_cancellation_credit_coupon(v_action_id) c;
    v_action_status := 'CREDIT_ISSUED';
  elsif v_settlement = 'REFUND' and v_refundable > 0 then
    v_action_status := 'PENDING_REFUND';
    update public.appointment_policy_actions
    set status = v_action_status,
        settlement_choice = 'REFUND',
        updated_at = now()
    where id = v_action_id;
  else
    v_action_status := 'APPLIED';
    update public.appointment_policy_actions
    set status = v_action_status,
        updated_at = now()
    where id = v_action_id;
  end if;

  insert into public.audit_logs (
    admin_user_id,
    entity_type,
    entity_id,
    action,
    before_json,
    after_json,
    origin
  ) values (
    p_admin_id,
    'APPOINTMENT',
    p_appointment_id,
    'APPOINTMENT_CANCELLED',
    jsonb_build_object(
      'status', v_appointment.status,
      'version', v_appointment.version,
      'start_at', v_appointment.start_at,
      'end_at', v_appointment.end_at
    ),
    jsonb_build_object(
      'status', 'CANCELLED',
      'version', v_new_version,
      'policy_action_id', v_action_id,
      'policy_action_status', v_action_status,
      'settlement_choice', v_settlement,
      'penalty_amount', v_preview->'penalty_amount',
      'refund_amount', v_refundable,
      'credit_amount', v_credit,
      'package_reversal_movement_id', v_package_reversal_id,
      'reason', nullif(btrim(coalesce(p_reason, '')), '')
    ),
    'ADMIN'
  );

  return jsonb_build_object(
    'appointment_id', p_appointment_id,
    'status', 'CANCELLED',
    'version', v_new_version,
    'policy_action_id', v_action_id,
    'policy_action_status', v_action_status,
    'settlement_choice', v_settlement,
    'penalty_amount', v_preview->'penalty_amount',
    'penalty_outstanding', v_outstanding,
    'refund_amount', case when v_settlement = 'REFUND' then v_refundable else 0 end,
    'credit_amount', case when v_settlement = 'CREDIT' then v_credit else 0 end,
    'coupon', v_coupon,
    'package_reversal_movement_id', v_package_reversal_id,
    'google_sync_enqueued', true,
    'already_cancelled', false
  );
end;
$$;

revoke all on function public.service_admin_cancel_appointment(uuid,text,text,timestamptz,uuid) from public, anon, authenticated;
grant execute on function public.service_admin_cancel_appointment(uuid,text,text,timestamptz,uuid) to service_role;

comment on function public.service_admin_cancel_appointment(uuid,text,text,timestamptz,uuid) is
  'Atomically cancels an operational appointment, releases resources, reverses hour-package usage, snapshots policy and initiates credit/refund settlement. Refund remains pending until real provider/manual confirmation.';
-- END RC MIGRATION 20260821213000_admin_cancellation_workflow.sql

-- BEGIN RC MIGRATION 20260821214000_admin_reschedule_holds.sql
-- Administrative rescheduling uses the same checkout-hold primitives as public
-- booking so the new slot is protected before the old allocation is released.
-- Package-backed appointments are intentionally blocked until special-period
-- package balance reconciliation is implemented.

alter table public.appointment_policy_actions
  add column reschedule_checkout_hold_id uuid references public.checkout_holds(id) on delete restrict,
  add column penalty_payment_transaction_id uuid references public.payment_transactions(id) on delete restrict;

create unique index appointment_policy_actions_active_reschedule_hold_uq
  on public.appointment_policy_actions(reschedule_checkout_hold_id)
  where reschedule_checkout_hold_id is not null;

create or replace function public.service_admin_create_reschedule_hold(
  p_appointment_id uuid,
  p_requested_start_at timestamptz,
  p_requested_at timestamptz default now(),
  p_admin_id uuid default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_appointment public.appointments%rowtype;
  v_preview jsonb;
  v_extras jsonb;
  v_hold jsonb;
  v_hold_id uuid;
  v_action_id uuid;
  v_action_status text;
  v_previous record;
begin
  if p_requested_start_at is null or p_requested_at is null then
    raise exception using errcode = 'P0001', message = 'RESCHEDULE_TIME_REQUIRED';
  end if;

  select * into v_appointment
  from public.appointments
  where id = p_appointment_id and deleted_at is null
  for update;

  if not found then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_NOT_FOUND';
  end if;

  if v_appointment.status <> 'CONFIRMED' then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_NOT_RESCHEDULABLE';
  end if;

  if exists (
    select 1 from public.appointment_package_usage apu
    where apu.appointment_id = p_appointment_id
      and apu.reversal_movement_id is null
  ) then
    raise exception using errcode = 'P0001', message = 'RESCHEDULE_PACKAGE_RECONCILIATION_REQUIRED';
  end if;

  -- Replace any prior not-yet-applied reschedule proposal and release its hold.
  for v_previous in
    select apa.id, apa.reschedule_checkout_hold_id
    from public.appointment_policy_actions apa
    where apa.appointment_id = p_appointment_id
      and apa.action_type = 'RESCHEDULE'
      and apa.status in ('PREVIEW','AWAITING_PENALTY_PAYMENT')
    for update
  loop
    if v_previous.reschedule_checkout_hold_id is not null then
      update public.resource_allocations
      set status = 'RELEASED', updated_at = now()
      where checkout_hold_id = v_previous.reschedule_checkout_hold_id
        and allocation_type = 'CHECKOUT_HOLD'
        and status = 'HELD';

      update public.checkout_holds
      set status = 'INVALIDATED', updated_at = now()
      where id = v_previous.reschedule_checkout_hold_id
        and status = 'ACTIVE';
    end if;

    update public.appointment_policy_actions
    set status = 'VOIDED', updated_at = now()
    where id = v_previous.id;
  end loop;

  select coalesce(jsonb_agg(
    jsonb_build_object('extra_id', ae.extra_id, 'quantity', ae.quantity)
    order by ae.extra_id
  ), '[]'::jsonb)
  into v_extras
  from public.appointment_extras ae
  where ae.appointment_id = p_appointment_id
    and ae.extra_id is not null;

  v_hold := public.create_checkout_hold_for_duration(
    v_appointment.service_id,
    v_appointment.service_employee_id,
    v_appointment.duration_blocks,
    v_extras,
    v_appointment.people_count,
    p_requested_start_at
  );

  v_hold_id := (v_hold->>'checkout_hold_id')::uuid;

  update public.checkout_holds
  set primary_customer_id = v_appointment.primary_customer_id,
      updated_at = now()
  where id = v_hold_id;

  v_preview := public.calculate_appointment_change_policy(
    p_appointment_id,
    'RESCHEDULE',
    p_requested_at
  );

  v_action_status := case
    when coalesce((v_preview->>'penalty_due_now')::numeric, 0) > 0
      then 'AWAITING_PENALTY_PAYMENT'
    else 'PREVIEW'
  end;

  insert into public.appointment_policy_actions(
    appointment_id,
    action_type,
    status,
    requested_at,
    original_start_at,
    requested_new_start_at,
    hours_before_start,
    notice_hours_snapshot,
    is_inside_notice_window,
    prior_customer_reschedules,
    contract_value_snapshot,
    net_paid_snapshot,
    penalty_type,
    penalty_value,
    penalty_amount,
    penalty_due_now,
    refund_allowed,
    credit_allowed,
    reschedule_checkout_hold_id,
    created_by_admin_id
  ) values (
    p_appointment_id,
    'RESCHEDULE',
    v_action_status,
    p_requested_at,
    v_appointment.start_at,
    (v_hold->>'slot_start_at')::timestamptz,
    (v_preview->>'hours_before_start')::numeric,
    (v_preview->>'notice_hours')::integer,
    (v_preview->>'inside_notice_window')::boolean,
    (v_preview->>'prior_customer_reschedules')::integer,
    (v_preview->>'contract_value')::numeric,
    (v_preview->>'net_paid')::numeric,
    (v_preview->>'penalty_type')::public.change_penalty_type,
    (v_preview->>'penalty_value')::numeric,
    (v_preview->>'penalty_amount')::numeric,
    (v_preview->>'penalty_due_now')::numeric,
    false,
    false,
    v_hold_id,
    p_admin_id
  ) returning id into v_action_id;

  return jsonb_build_object(
    'policy_action_id', v_action_id,
    'policy_action_status', v_action_status,
    'appointment_id', p_appointment_id,
    'original_start_at', v_appointment.start_at,
    'new_slot', jsonb_build_object(
      'checkout_hold_id', v_hold_id,
      'expires_at', v_hold->'expires_at',
      'slot_start_at', v_hold->'slot_start_at',
      'slot_end_at', v_hold->'slot_end_at',
      'core_start_at', v_hold->'core_start_at',
      'core_end_at', v_hold->'core_end_at'
    ),
    'penalty_type', v_preview->'penalty_type',
    'penalty_value', v_preview->'penalty_value',
    'penalty_due_now', v_preview->'penalty_due_now'
  );
end;
$$;

create or replace function public.service_admin_apply_reschedule(
  p_policy_action_id uuid,
  p_admin_id uuid default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_action public.appointment_policy_actions%rowtype;
  v_appointment public.appointments%rowtype;
  v_hold public.checkout_holds%rowtype;
  v_new_version integer;
  v_old_start timestamptz;
  v_old_end timestamptz;
begin
  select * into v_action
  from public.appointment_policy_actions
  where id = p_policy_action_id
  for update;

  if not found or v_action.action_type <> 'RESCHEDULE' then
    raise exception using errcode = 'P0001', message = 'INVALID_RESCHEDULE_ACTION';
  end if;

  if v_action.status = 'APPLIED' then
    select * into v_appointment from public.appointments where id = v_action.appointment_id;
    return jsonb_build_object(
      'policy_action_id', v_action.id,
      'appointment_id', v_action.appointment_id,
      'status', 'APPLIED',
      'appointment_version', v_appointment.version,
      'already_applied', true
    );
  end if;

  if v_action.status = 'AWAITING_PENALTY_PAYMENT' then
    raise exception using errcode = 'P0001', message = 'RESCHEDULE_PENALTY_PAYMENT_REQUIRED';
  end if;

  if v_action.status <> 'PREVIEW' then
    raise exception using errcode = 'P0001', message = 'RESCHEDULE_ACTION_NOT_APPLICABLE';
  end if;

  if coalesce(v_action.penalty_due_now, 0) > 0 and v_action.penalty_payment_transaction_id is null then
    raise exception using errcode = 'P0001', message = 'RESCHEDULE_PENALTY_PAYMENT_REQUIRED';
  end if;

  select * into v_appointment
  from public.appointments
  where id = v_action.appointment_id
  for update;

  if not found or v_appointment.status <> 'CONFIRMED' then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_NOT_RESCHEDULABLE';
  end if;

  if exists (
    select 1 from public.appointment_package_usage apu
    where apu.appointment_id = v_appointment.id
      and apu.reversal_movement_id is null
  ) then
    raise exception using errcode = 'P0001', message = 'RESCHEDULE_PACKAGE_RECONCILIATION_REQUIRED';
  end if;

  select * into v_hold
  from public.checkout_holds
  where id = v_action.reschedule_checkout_hold_id
  for update;

  if not found or v_hold.status <> 'ACTIVE' or v_hold.expires_at <= now() then
    raise exception using errcode = 'P0001', message = 'RESCHEDULE_HOLD_EXPIRED';
  end if;

  if v_hold.service_id <> v_appointment.service_id
     or v_hold.service_employee_id <> v_appointment.service_employee_id
     or v_hold.primary_customer_id is distinct from v_appointment.primary_customer_id then
    raise exception using errcode = 'P0001', message = 'RESCHEDULE_HOLD_MISMATCH';
  end if;

  v_old_start := v_appointment.start_at;
  v_old_end := v_appointment.end_at;

  -- The new interval is already protected by HELD allocations. Release the old
  -- ones and atomically transfer the protected allocations to the appointment.
  update public.resource_allocations
  set status = 'RELEASED', updated_at = now()
  where appointment_id = v_appointment.id
    and allocation_type = 'APPOINTMENT'
    and status in ('HELD','AWAITING_PAYMENT','CONFIRMED','BLOCKED');

  update public.resource_allocations
  set appointment_id = v_appointment.id,
      checkout_hold_id = null,
      allocation_type = 'APPOINTMENT',
      status = 'CONFIRMED',
      updated_at = now()
  where checkout_hold_id = v_hold.id
    and allocation_type = 'CHECKOUT_HOLD'
    and status = 'HELD';

  update public.appointments
  set start_at = v_hold.requested_start_at,
      end_at = v_hold.requested_end_at,
      core_start_at = v_hold.core_start_at,
      core_end_at = v_hold.core_end_at,
      pre_service_minutes = v_hold.pre_service_minutes,
      post_service_minutes = v_hold.post_service_minutes,
      schedule_profile_snapshot = v_hold.schedule_profile,
      duration_minutes = v_hold.duration_minutes,
      duration_blocks = v_hold.duration_blocks,
      contracted_minutes = v_hold.contracted_minutes,
      version = version + 1,
      updated_at = now()
  where id = v_appointment.id
  returning version into v_new_version;

  update public.checkout_holds
  set status = 'PROMOTED',
      promoted_appointment_id = v_appointment.id,
      updated_at = now()
  where id = v_hold.id;

  update public.appointment_policy_actions
  set status = 'APPLIED', updated_at = now()
  where id = v_action.id;

  insert into public.integration_jobs(
    job_type, entity_type, entity_id, entity_version, payload_json, idempotency_key
  ) values (
    'GOOGLE_APPOINTMENT_SYNC',
    'APPOINTMENT',
    v_appointment.id,
    v_new_version,
    jsonb_build_object('reason', 'APPOINTMENT_RESCHEDULED'),
    'google-appointment-sync:' || v_appointment.id::text || ':' || v_new_version::text
  ) on conflict (idempotency_key) do nothing;

  insert into public.audit_logs(
    admin_user_id, entity_type, entity_id, action, before_json, after_json, origin
  ) values (
    p_admin_id,
    'APPOINTMENT',
    v_appointment.id,
    'APPOINTMENT_RESCHEDULED',
    jsonb_build_object('start_at', v_old_start, 'end_at', v_old_end, 'version', v_appointment.version),
    jsonb_build_object(
      'start_at', v_hold.requested_start_at,
      'end_at', v_hold.requested_end_at,
      'version', v_new_version,
      'policy_action_id', v_action.id,
      'penalty_amount', v_action.penalty_amount
    ),
    'ADMIN'
  );

  return jsonb_build_object(
    'policy_action_id', v_action.id,
    'appointment_id', v_appointment.id,
    'status', 'APPLIED',
    'old_start_at', v_old_start,
    'new_start_at', v_hold.requested_start_at,
    'new_end_at', v_hold.requested_end_at,
    'appointment_version', v_new_version,
    'google_sync_enqueued', true,
    'already_applied', false
  );
end;
$$;

revoke all on function public.service_admin_create_reschedule_hold(uuid,timestamptz,timestamptz,uuid) from public, anon, authenticated;
revoke all on function public.service_admin_apply_reschedule(uuid,uuid) from public, anon, authenticated;
grant execute on function public.service_admin_create_reschedule_hold(uuid,timestamptz,timestamptz,uuid) to service_role;
grant execute on function public.service_admin_apply_reschedule(uuid,uuid) to service_role;

comment on function public.service_admin_create_reschedule_hold(uuid,timestamptz,timestamptz,uuid) is
  'Protects a proposed new slot using normal checkout-hold resource locking and snapshots the applicable reschedule policy.';
comment on function public.service_admin_apply_reschedule(uuid,uuid) is
  'Atomically swaps a confirmed appointment to its protected reschedule hold. Penalty-bearing and package-backed cases remain blocked until their settlement/reconciliation is complete.';
-- END RC MIGRATION 20260821214000_admin_reschedule_holds.sql

-- BEGIN RC MIGRATION 20260821214500_admin_reschedule_slots.sql
-- Admin slot discovery for rescheduling. Uses the same authoritative availability
-- engine as checkout while preserving the original appointment's service, duration,
-- people count and extras. Existing slot remains occupied until a hold is created/applied.

create or replace function public.service_admin_list_reschedule_slots(
  p_appointment_id uuid,
  p_local_date date
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_appointment public.appointments%rowtype;
  v_extras jsonb;
begin
  if p_local_date is null then
    raise exception using errcode = 'P0001', message = 'RESCHEDULE_DATE_REQUIRED';
  end if;

  select * into v_appointment
  from public.appointments
  where id = p_appointment_id
    and deleted_at is null;

  if not found then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_NOT_FOUND';
  end if;

  if v_appointment.status <> 'CONFIRMED' then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_NOT_RESCHEDULABLE';
  end if;

  if exists (
    select 1
    from public.appointment_package_usage apu
    where apu.appointment_id = p_appointment_id
      and apu.reversal_movement_id is null
  ) then
    raise exception using errcode = 'P0001', message = 'RESCHEDULE_PACKAGE_RECONCILIATION_REQUIRED';
  end if;

  select coalesce(jsonb_agg(
    jsonb_build_object('extra_id', ae.extra_id, 'quantity', ae.quantity)
    order by ae.extra_id
  ), '[]'::jsonb)
  into v_extras
  from public.appointment_extras ae
  where ae.appointment_id = p_appointment_id
    and ae.extra_id is not null;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'slot_start_at', s.slot_start_at,
      'slot_end_at', s.slot_end_at,
      'core_start_at', s.core_start_at,
      'core_end_at', s.core_end_at,
      'pre_service_minutes', s.pre_service_minutes,
      'post_service_minutes', s.post_service_minutes,
      'duration_minutes', s.duration_minutes
    ) order by s.slot_start_at)
    from public.list_available_slots_for_duration(
      v_appointment.service_id,
      v_appointment.service_employee_id,
      v_appointment.duration_blocks,
      v_extras,
      v_appointment.people_count,
      p_local_date,
      null
    ) s
  ), '[]'::jsonb);
end;
$$;

revoke all on function public.service_admin_list_reschedule_slots(uuid,date) from public, anon, authenticated;
grant execute on function public.service_admin_list_reschedule_slots(uuid,date) to service_role;

comment on function public.service_admin_list_reschedule_slots(uuid,date) is
  'Lists valid replacement slots for an existing confirmed appointment using its original service, duration, extras and people count. Package-backed appointments remain blocked pending package reconciliation.';
-- END RC MIGRATION 20260821214500_admin_reschedule_slots.sql

-- BEGIN RC MIGRATION 20260821215000_refund_finance_and_provider_plan.sql
-- Provider-backed cancellation refunds.
-- Refund targets are cash actually received, while contract settlement is restored
-- proportionally to the original charge (important for PIX discounts).

alter table public.payment_transactions
  add column policy_action_id uuid references public.appointment_policy_actions(id) on delete restrict;

create index payment_transactions_policy_action_idx
  on public.payment_transactions(policy_action_id)
  where policy_action_id is not null;

create unique index payment_transactions_provider_refund_uq
  on public.payment_transactions(provider, provider_payment_id)
  where provider_payment_id is not null and transaction_type = 'REFUND';

create or replace function public.get_appointment_financial_summary(p_appointment_id uuid)
returns jsonb
language plpgsql
stable
set search_path = public
as $$
declare
  v_appointment public.appointments%rowtype;
  v_gross_contract numeric(12,2);
  v_gross_cash numeric(12,2);
  v_refunded_contract numeric(12,2);
  v_refunded_cash numeric(12,2);
  v_pending_count integer;
  v_net_contract numeric(12,2);
  v_net_cash numeric(12,2);
begin
  select * into v_appointment from public.appointments where id = p_appointment_id;
  if not found then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_NOT_FOUND';
  end if;

  select
    coalesce(sum(contract_amount_settled) filter (
      where transaction_type = 'CHARGE' and status in ('APPROVED','PARTIALLY_REFUNDED','REFUNDED')
    ),0)::numeric(12,2),
    coalesce(sum(cash_amount) filter (
      where transaction_type = 'CHARGE' and status in ('APPROVED','PARTIALLY_REFUNDED','REFUNDED')
    ),0)::numeric(12,2),
    coalesce(sum(contract_amount_settled) filter (
      where transaction_type = 'REFUND' and status in ('APPROVED','REFUNDED')
    ),0)::numeric(12,2),
    coalesce(sum(cash_amount) filter (
      where transaction_type = 'REFUND' and status in ('APPROVED','REFUNDED')
    ),0)::numeric(12,2),
    count(*) filter (where transaction_type = 'CHARGE' and status = 'PENDING')::integer
  into v_gross_contract, v_gross_cash, v_refunded_contract, v_refunded_cash, v_pending_count
  from public.payment_transactions
  where appointment_id = p_appointment_id;

  v_net_contract := round(greatest(v_gross_contract - v_refunded_contract,0),2);
  v_net_cash := round(greatest(v_gross_cash - v_refunded_cash,0),2);

  return jsonb_build_object(
    'appointment_id', v_appointment.id,
    'commercial_value', coalesce(v_appointment.commercial_value,0),
    'gross_contract_settled', v_gross_contract,
    'gross_cash_received', v_gross_cash,
    'refunded_contract_amount', v_refunded_contract,
    'refunded_cash_amount', v_refunded_cash,
    'contract_settled', v_net_contract,
    'cash_received', v_net_cash,
    'contract_balance', round(greatest(coalesce(v_appointment.commercial_value,0) - v_net_contract,0),2),
    'pending_charge_count', v_pending_count,
    'financial_status', v_appointment.financial_status
  );
end;
$$;

create or replace function public.refresh_appointment_financial_status(p_appointment_id uuid)
returns public.financial_status
language plpgsql
volatile
set search_path = public
as $$
declare
  v_appointment public.appointments%rowtype;
  v_gross_contract numeric(12,2);
  v_gross_cash numeric(12,2);
  v_refunded_contract numeric(12,2);
  v_refunded_cash numeric(12,2);
  v_pending_count integer;
  v_net_contract numeric(12,2);
  v_net_cash numeric(12,2);
  v_new_status public.financial_status;
begin
  select * into v_appointment
  from public.appointments where id = p_appointment_id for update;
  if not found then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_NOT_FOUND';
  end if;

  select
    coalesce(sum(contract_amount_settled) filter (
      where transaction_type = 'CHARGE' and status in ('APPROVED','PARTIALLY_REFUNDED','REFUNDED')
    ),0)::numeric(12,2),
    coalesce(sum(cash_amount) filter (
      where transaction_type = 'CHARGE' and status in ('APPROVED','PARTIALLY_REFUNDED','REFUNDED')
    ),0)::numeric(12,2),
    coalesce(sum(contract_amount_settled) filter (
      where transaction_type = 'REFUND' and status in ('APPROVED','REFUNDED')
    ),0)::numeric(12,2),
    coalesce(sum(cash_amount) filter (
      where transaction_type = 'REFUND' and status in ('APPROVED','REFUNDED')
    ),0)::numeric(12,2),
    count(*) filter (where transaction_type = 'CHARGE' and status = 'PENDING')::integer
  into v_gross_contract, v_gross_cash, v_refunded_contract, v_refunded_cash, v_pending_count
  from public.payment_transactions where appointment_id = p_appointment_id;

  v_net_contract := round(greatest(v_gross_contract - v_refunded_contract,0),2);
  v_net_cash := round(greatest(v_gross_cash - v_refunded_cash,0),2);

  if v_refunded_cash > 0 and v_gross_cash > 0 and v_net_cash <= 0.01 then
    v_new_status := 'REFUNDED';
  elsif v_refunded_cash > 0 then
    v_new_status := 'PARTIALLY_REFUNDED';
  elsif v_net_contract >= coalesce(v_appointment.commercial_value,0)
     and coalesce(v_appointment.commercial_value,0) > 0 then
    v_new_status := 'PAID';
  elsif v_net_contract > 0 then
    v_new_status := 'PARTIALLY_PAID';
  elsif v_appointment.financial_status = 'UNPAID_AUTHORIZED' then
    v_new_status := 'UNPAID_AUTHORIZED';
  elsif v_pending_count > 0 then
    v_new_status := 'PENDING';
  elsif v_appointment.status = 'EXPIRED' then
    v_new_status := 'EXPIRED';
  else
    v_new_status := 'NOT_STARTED';
  end if;

  update public.appointments
  set financial_status = v_new_status, updated_at = now()
  where id = p_appointment_id;

  return v_new_status;
end;
$$;

create or replace function public.service_get_cancellation_refund_plan(p_policy_action_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_action public.appointment_policy_actions%rowtype;
  v_target numeric(12,2);
  v_recorded numeric(12,2);
  v_remaining numeric(12,2);
  v_provider_available numeric(12,2) := 0;
  v_plan jsonb := '[]'::jsonb;
  v_take numeric(12,2);
  r record;
begin
  select * into v_action
  from public.appointment_policy_actions
  where id = p_policy_action_id and action_type = 'CANCEL';

  if not found then
    raise exception using errcode = 'P0001', message = 'CANCELLATION_ACTION_NOT_FOUND';
  end if;

  if v_action.settlement_choice <> 'REFUND'
     or v_action.status not in ('PENDING_REFUND','REFUNDED') then
    raise exception using errcode = 'P0001', message = 'CANCELLATION_REFUND_NOT_PENDING';
  end if;

  v_target := round(coalesce(v_action.refundable_amount,0),2);
  select coalesce(sum(pt.cash_amount),0)::numeric(12,2)
  into v_recorded
  from public.payment_transactions pt
  where pt.policy_action_id = v_action.id
    and pt.transaction_type = 'REFUND'
    and pt.status in ('APPROVED','REFUNDED');

  v_remaining := round(greatest(v_target - v_recorded,0),2);

  for r in
    select
      pt.id as transaction_id,
      pt.provider_payment_id,
      pt.method,
      pt.cash_amount,
      pt.contract_amount_settled,
      greatest(pt.cash_amount - coalesce((
        select sum(rf.cash_amount)
        from public.payment_transactions rf
        where rf.parent_transaction_id = pt.id
          and rf.transaction_type = 'REFUND'
          and rf.status in ('APPROVED','REFUNDED')
      ),0),0)::numeric(12,2) as refundable_cash
    from public.payment_transactions pt
    where pt.appointment_id = v_action.appointment_id
      and pt.transaction_type = 'CHARGE'
      and pt.provider = 'MERCADO_PAGO'
      and pt.provider_payment_id is not null
      and pt.status in ('APPROVED','PARTIALLY_REFUNDED','REFUNDED')
    order by pt.paid_at nulls last, pt.created_at, pt.id
  loop
    if r.refundable_cash <= 0 then continue; end if;
    v_provider_available := v_provider_available + r.refundable_cash;
    if v_remaining > 0 then
      v_take := least(v_remaining, r.refundable_cash);
      v_plan := v_plan || jsonb_build_array(jsonb_build_object(
        'parent_transaction_id', r.transaction_id,
        'provider_payment_id', r.provider_payment_id,
        'method', r.method,
        'available_cash', r.refundable_cash,
        'refund_cash', v_take
      ));
      v_remaining := round(v_remaining - v_take,2);
    end if;
  end loop;

  return jsonb_build_object(
    'policy_action_id', v_action.id,
    'appointment_id', v_action.appointment_id,
    'status', v_action.status,
    'target_cash_amount', v_target,
    'recorded_refund_cash', v_recorded,
    'remaining_refund_cash', round(greatest(v_target - v_recorded,0),2),
    'mercado_pago_available_cash', round(v_provider_available,2),
    'manual_refund_cash', round(greatest((v_target - v_recorded) - v_provider_available,0),2),
    'payments', v_plan
  );
end;
$$;

create or replace function public.service_record_cancellation_provider_refund(
  p_policy_action_id uuid,
  p_parent_transaction_id uuid,
  p_provider_refund_id text,
  p_cash_amount numeric,
  p_provider_payload_json jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_action public.appointment_policy_actions%rowtype;
  v_parent public.payment_transactions%rowtype;
  v_existing public.payment_transactions%rowtype;
  v_parent_refunded_cash numeric(12,2);
  v_parent_refunded_contract numeric(12,2);
  v_parent_cash_remaining numeric(12,2);
  v_parent_contract_remaining numeric(12,2);
  v_contract_amount numeric(12,2);
  v_action_refunded_cash numeric(12,2);
  v_refund_id uuid;
  v_financial_status public.financial_status;
  v_action_status text;
begin
  if p_provider_refund_id is null or btrim(p_provider_refund_id) = '' or p_cash_amount <= 0 then
    raise exception using errcode = 'P0001', message = 'INVALID_PROVIDER_REFUND';
  end if;

  select * into v_existing
  from public.payment_transactions
  where transaction_type = 'REFUND'
    and provider = 'MERCADO_PAGO'
    and provider_payment_id = btrim(p_provider_refund_id);

  if found then
    return jsonb_build_object(
      'refund_transaction_id', v_existing.id,
      'appointment_id', v_existing.appointment_id,
      'cash_amount', v_existing.cash_amount,
      'idempotent_replay', true
    );
  end if;

  select * into v_action
  from public.appointment_policy_actions
  where id = p_policy_action_id and action_type = 'CANCEL'
  for update;
  if not found then
    raise exception using errcode = 'P0001', message = 'CANCELLATION_ACTION_NOT_FOUND';
  end if;
  if v_action.settlement_choice <> 'REFUND' or v_action.status not in ('PENDING_REFUND','REFUNDED') then
    raise exception using errcode = 'P0001', message = 'CANCELLATION_REFUND_NOT_PENDING';
  end if;

  select * into v_parent
  from public.payment_transactions
  where id = p_parent_transaction_id
  for update;
  if not found
     or v_parent.appointment_id <> v_action.appointment_id
     or v_parent.transaction_type <> 'CHARGE'
     or v_parent.provider <> 'MERCADO_PAGO'
     or v_parent.provider_payment_id is null
     or v_parent.status not in ('APPROVED','PARTIALLY_REFUNDED','REFUNDED') then
    raise exception using errcode = 'P0001', message = 'INVALID_REFUND_PARENT_TRANSACTION';
  end if;

  select
    coalesce(sum(cash_amount),0)::numeric(12,2),
    coalesce(sum(contract_amount_settled),0)::numeric(12,2)
  into v_parent_refunded_cash, v_parent_refunded_contract
  from public.payment_transactions
  where parent_transaction_id = v_parent.id
    and transaction_type = 'REFUND'
    and status in ('APPROVED','REFUNDED');

  v_parent_cash_remaining := round(greatest(v_parent.cash_amount - v_parent_refunded_cash,0),2);
  v_parent_contract_remaining := round(greatest(v_parent.contract_amount_settled - v_parent_refunded_contract,0),2);
  if p_cash_amount > v_parent_cash_remaining + 0.01 then
    raise exception using errcode = 'P0001', message = 'REFUND_EXCEEDS_PARENT_AVAILABLE_CASH';
  end if;

  select coalesce(sum(cash_amount),0)::numeric(12,2)
  into v_action_refunded_cash
  from public.payment_transactions
  where policy_action_id = v_action.id
    and transaction_type = 'REFUND'
    and status in ('APPROVED','REFUNDED');

  if v_action_refunded_cash + p_cash_amount > v_action.refundable_amount + 0.01 then
    raise exception using errcode = 'P0001', message = 'REFUND_EXCEEDS_POLICY_AMOUNT';
  end if;

  if v_parent.cash_amount > 0 then
    v_contract_amount := round(least(
      v_parent_contract_remaining,
      v_parent.contract_amount_settled * p_cash_amount / v_parent.cash_amount
    ),2);
  else
    v_contract_amount := 0;
  end if;

  insert into public.payment_transactions(
    appointment_id,
    transaction_type,
    method,
    provider,
    provider_payment_id,
    status,
    contract_amount_settled,
    payment_discount_amount,
    cash_amount,
    parent_transaction_id,
    policy_action_id,
    paid_at,
    provider_payload_json,
    notes
  ) values (
    v_action.appointment_id,
    'REFUND',
    v_parent.method,
    'MERCADO_PAGO',
    btrim(p_provider_refund_id),
    'APPROVED',
    v_contract_amount,
    0,
    round(p_cash_amount,2),
    v_parent.id,
    v_action.id,
    now(),
    coalesce(p_provider_payload_json,'{}'::jsonb),
    'CANCELLATION_REFUND'
  ) returning id into v_refund_id;

  select coalesce(sum(cash_amount),0)::numeric(12,2)
  into v_parent_refunded_cash
  from public.payment_transactions
  where parent_transaction_id = v_parent.id
    and transaction_type = 'REFUND'
    and status in ('APPROVED','REFUNDED');

  update public.payment_transactions
  set status = case
        when v_parent_refunded_cash >= cash_amount - 0.01 then 'REFUNDED'
        else 'PARTIALLY_REFUNDED'
      end,
      updated_at = now()
  where id = v_parent.id;

  select coalesce(sum(cash_amount),0)::numeric(12,2)
  into v_action_refunded_cash
  from public.payment_transactions
  where policy_action_id = v_action.id
    and transaction_type = 'REFUND'
    and status in ('APPROVED','REFUNDED');

  v_action_status := case
    when v_action_refunded_cash >= v_action.refundable_amount - 0.01 then 'REFUNDED'
    else 'PENDING_REFUND'
  end;

  update public.appointment_policy_actions
  set status = v_action_status,
      refund_transaction_id = coalesce(refund_transaction_id, v_refund_id),
      updated_at = now()
  where id = v_action.id;

  v_financial_status := public.refresh_appointment_financial_status(v_action.appointment_id);

  insert into public.audit_logs(entity_type,entity_id,action,after_json,origin)
  values (
    'APPOINTMENT',
    v_action.appointment_id,
    'MERCADO_PAGO_REFUND_RECORDED',
    jsonb_build_object(
      'policy_action_id', v_action.id,
      'refund_transaction_id', v_refund_id,
      'parent_transaction_id', v_parent.id,
      'provider_refund_id', p_provider_refund_id,
      'cash_amount', p_cash_amount,
      'contract_amount_restored', v_contract_amount,
      'policy_action_status', v_action_status,
      'financial_status', v_financial_status
    ),
    'MERCADO_PAGO'
  );

  return jsonb_build_object(
    'refund_transaction_id', v_refund_id,
    'appointment_id', v_action.appointment_id,
    'cash_amount', round(p_cash_amount,2),
    'contract_amount_restored', v_contract_amount,
    'policy_action_status', v_action_status,
    'financial_status', v_financial_status,
    'idempotent_replay', false
  );
end;
$$;

revoke all on function public.service_get_cancellation_refund_plan(uuid) from public, anon, authenticated;
revoke all on function public.service_record_cancellation_provider_refund(uuid,uuid,text,numeric,jsonb) from public, anon, authenticated;
grant execute on function public.service_get_cancellation_refund_plan(uuid) to service_role;
grant execute on function public.service_record_cancellation_provider_refund(uuid,uuid,text,numeric,jsonb) to service_role;
-- END RC MIGRATION 20260821215000_refund_finance_and_provider_plan.sql

-- BEGIN RC MIGRATION 20260821216000_payment_purpose_and_reschedule_penalty.sql
-- Payment purpose prevents operational penalties from inflating contract settlement.

alter table public.payment_transactions
  add column payment_purpose text not null default 'CONTRACT'
    check (payment_purpose in ('CONTRACT','RESCHEDULE_PENALTY','CANCELLATION_PENALTY'));

create index payment_transactions_purpose_idx
  on public.payment_transactions(appointment_id, payment_purpose, created_at);

create or replace function public.appointment_net_paid_amount(p_appointment_id uuid)
returns numeric(12,2)
language sql
stable
set search_path = public
as $$
  select round(greatest(
    coalesce(sum(case
      when pt.payment_purpose = 'CONTRACT'
       and pt.transaction_type = 'CHARGE'
       and pt.status in ('APPROVED','PARTIALLY_REFUNDED','REFUNDED')
      then pt.cash_amount else 0 end), 0)
    -
    coalesce(sum(case
      when pt.payment_purpose = 'CONTRACT'
       and pt.transaction_type = 'REFUND'
       and pt.status in ('APPROVED','REFUNDED')
      then pt.cash_amount else 0 end), 0),
    0
  ), 2)::numeric(12,2)
  from public.payment_transactions pt
  where pt.appointment_id = p_appointment_id;
$$;

create or replace function public.get_appointment_financial_summary(p_appointment_id uuid)
returns jsonb
language plpgsql
stable
set search_path = public
as $$
declare
  v_appointment public.appointments%rowtype;
  v_gross_contract numeric(12,2);
  v_gross_cash numeric(12,2);
  v_refunded_contract numeric(12,2);
  v_refunded_cash numeric(12,2);
  v_pending_count integer;
  v_net_contract numeric(12,2);
  v_net_cash numeric(12,2);
  v_penalties_cash numeric(12,2);
begin
  select * into v_appointment from public.appointments where id = p_appointment_id;
  if not found then raise exception using errcode='P0001', message='APPOINTMENT_NOT_FOUND'; end if;

  select
    coalesce(sum(contract_amount_settled) filter (
      where payment_purpose='CONTRACT' and transaction_type='CHARGE' and status in ('APPROVED','PARTIALLY_REFUNDED','REFUNDED')
    ),0)::numeric(12,2),
    coalesce(sum(cash_amount) filter (
      where payment_purpose='CONTRACT' and transaction_type='CHARGE' and status in ('APPROVED','PARTIALLY_REFUNDED','REFUNDED')
    ),0)::numeric(12,2),
    coalesce(sum(contract_amount_settled) filter (
      where payment_purpose='CONTRACT' and transaction_type='REFUND' and status in ('APPROVED','REFUNDED')
    ),0)::numeric(12,2),
    coalesce(sum(cash_amount) filter (
      where payment_purpose='CONTRACT' and transaction_type='REFUND' and status in ('APPROVED','REFUNDED')
    ),0)::numeric(12,2),
    count(*) filter (where payment_purpose='CONTRACT' and transaction_type='CHARGE' and status='PENDING')::integer,
    coalesce(sum(cash_amount) filter (
      where payment_purpose <> 'CONTRACT' and transaction_type='CHARGE' and status='APPROVED'
    ),0)::numeric(12,2)
  into v_gross_contract,v_gross_cash,v_refunded_contract,v_refunded_cash,v_pending_count,v_penalties_cash
  from public.payment_transactions where appointment_id=p_appointment_id;

  v_net_contract := round(greatest(v_gross_contract-v_refunded_contract,0),2);
  v_net_cash := round(greatest(v_gross_cash-v_refunded_cash,0),2);

  return jsonb_build_object(
    'appointment_id',v_appointment.id,
    'commercial_value',coalesce(v_appointment.commercial_value,0),
    'gross_contract_settled',v_gross_contract,
    'gross_cash_received',v_gross_cash,
    'refunded_contract_amount',v_refunded_contract,
    'refunded_cash_amount',v_refunded_cash,
    'contract_settled',v_net_contract,
    'cash_received',v_net_cash,
    'contract_balance',round(greatest(coalesce(v_appointment.commercial_value,0)-v_net_contract,0),2),
    'operational_penalties_cash_received',v_penalties_cash,
    'pending_charge_count',v_pending_count,
    'financial_status',v_appointment.financial_status
  );
end;
$$;

create or replace function public.refresh_appointment_financial_status(p_appointment_id uuid)
returns public.financial_status
language plpgsql
volatile
set search_path = public
as $$
declare
  v_appointment public.appointments%rowtype;
  v_gross_contract numeric(12,2);
  v_gross_cash numeric(12,2);
  v_refunded_contract numeric(12,2);
  v_refunded_cash numeric(12,2);
  v_pending_count integer;
  v_net_contract numeric(12,2);
  v_net_cash numeric(12,2);
  v_new_status public.financial_status;
begin
  select * into v_appointment from public.appointments where id=p_appointment_id for update;
  if not found then raise exception using errcode='P0001', message='APPOINTMENT_NOT_FOUND'; end if;

  select
    coalesce(sum(contract_amount_settled) filter (where payment_purpose='CONTRACT' and transaction_type='CHARGE' and status in ('APPROVED','PARTIALLY_REFUNDED','REFUNDED')),0)::numeric(12,2),
    coalesce(sum(cash_amount) filter (where payment_purpose='CONTRACT' and transaction_type='CHARGE' and status in ('APPROVED','PARTIALLY_REFUNDED','REFUNDED')),0)::numeric(12,2),
    coalesce(sum(contract_amount_settled) filter (where payment_purpose='CONTRACT' and transaction_type='REFUND' and status in ('APPROVED','REFUNDED')),0)::numeric(12,2),
    coalesce(sum(cash_amount) filter (where payment_purpose='CONTRACT' and transaction_type='REFUND' and status in ('APPROVED','REFUNDED')),0)::numeric(12,2),
    count(*) filter (where payment_purpose='CONTRACT' and transaction_type='CHARGE' and status='PENDING')::integer
  into v_gross_contract,v_gross_cash,v_refunded_contract,v_refunded_cash,v_pending_count
  from public.payment_transactions where appointment_id=p_appointment_id;

  v_net_contract:=round(greatest(v_gross_contract-v_refunded_contract,0),2);
  v_net_cash:=round(greatest(v_gross_cash-v_refunded_cash,0),2);

  if v_refunded_cash>0 and v_gross_cash>0 and v_net_cash<=0.01 then v_new_status:='REFUNDED';
  elsif v_refunded_cash>0 then v_new_status:='PARTIALLY_REFUNDED';
  elsif v_net_contract>=coalesce(v_appointment.commercial_value,0) and coalesce(v_appointment.commercial_value,0)>0 then v_new_status:='PAID';
  elsif v_net_contract>0 then v_new_status:='PARTIALLY_PAID';
  elsif v_appointment.financial_status='UNPAID_AUTHORIZED' then v_new_status:='UNPAID_AUTHORIZED';
  elsif v_pending_count>0 then v_new_status:='PENDING';
  elsif v_appointment.status='EXPIRED' then v_new_status:='EXPIRED';
  else v_new_status:='NOT_STARTED'; end if;

  update public.appointments set financial_status=v_new_status,updated_at=now() where id=p_appointment_id;
  return v_new_status;
end;
$$;

create or replace function public.service_admin_register_reschedule_penalty_payment(
  p_policy_action_id uuid,
  p_method text,
  p_notes text default null,
  p_admin_id uuid default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_action public.appointment_policy_actions%rowtype;
  v_existing public.payment_transactions%rowtype;
  v_transaction_id uuid;
  v_method text := upper(btrim(coalesce(p_method,'')));
begin
  if v_method not in ('PIX','CARD','CASH','TRANSFER','OTHER') then
    raise exception using errcode='P0001', message='INVALID_PENALTY_PAYMENT_METHOD';
  end if;

  select * into v_action from public.appointment_policy_actions
  where id=p_policy_action_id for update;
  if not found or v_action.action_type<>'RESCHEDULE' then
    raise exception using errcode='P0001', message='INVALID_RESCHEDULE_ACTION';
  end if;

  if v_action.penalty_payment_transaction_id is not null then
    select * into v_existing from public.payment_transactions where id=v_action.penalty_payment_transaction_id;
    if found and v_existing.status='APPROVED' then
      return jsonb_build_object(
        'policy_action_id',v_action.id,
        'payment_transaction_id',v_existing.id,
        'cash_amount',v_existing.cash_amount,
        'status','PAID',
        'idempotent_replay',true
      );
    end if;
  end if;

  if v_action.status<>'AWAITING_PENALTY_PAYMENT' or coalesce(v_action.penalty_due_now,0)<=0 then
    raise exception using errcode='P0001', message='RESCHEDULE_PENALTY_NOT_PAYABLE';
  end if;

  insert into public.payment_transactions(
    appointment_id,transaction_type,method,provider,status,
    contract_amount_settled,payment_discount_amount,cash_amount,
    payment_purpose,policy_action_id,paid_at,created_by_admin_id,notes
  ) values (
    v_action.appointment_id,'CHARGE',v_method,'MANUAL','APPROVED',
    0,0,round(v_action.penalty_due_now,2),
    'RESCHEDULE_PENALTY',v_action.id,now(),p_admin_id,nullif(btrim(p_notes),'')
  ) returning id into v_transaction_id;

  update public.appointment_policy_actions
  set penalty_payment_transaction_id=v_transaction_id,
      status='PREVIEW',
      updated_at=now()
  where id=v_action.id;

  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,after_json,origin)
  values (
    p_admin_id,'APPOINTMENT',v_action.appointment_id,'RESCHEDULE_PENALTY_PAYMENT_REGISTERED',
    jsonb_build_object('policy_action_id',v_action.id,'payment_transaction_id',v_transaction_id,'method',v_method,'cash_amount',v_action.penalty_due_now),
    'ADMIN'
  );

  return jsonb_build_object(
    'policy_action_id',v_action.id,
    'payment_transaction_id',v_transaction_id,
    'cash_amount',round(v_action.penalty_due_now,2),
    'status','PAID',
    'idempotent_replay',false
  );
end;
$$;

-- Cancellation refund planning must never use operational-penalty charges.
create or replace function public.service_get_cancellation_refund_plan(p_policy_action_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_action public.appointment_policy_actions%rowtype;
  v_target numeric(12,2); v_recorded numeric(12,2); v_remaining numeric(12,2);
  v_provider_available numeric(12,2):=0; v_plan jsonb:='[]'::jsonb; v_take numeric(12,2); r record;
begin
  select * into v_action from public.appointment_policy_actions where id=p_policy_action_id and action_type='CANCEL';
  if not found then raise exception using errcode='P0001', message='CANCELLATION_ACTION_NOT_FOUND'; end if;
  if v_action.settlement_choice<>'REFUND' or v_action.status not in ('PENDING_REFUND','REFUNDED') then
    raise exception using errcode='P0001', message='CANCELLATION_REFUND_NOT_PENDING';
  end if;

  v_target:=round(coalesce(v_action.refundable_amount,0),2);
  select coalesce(sum(pt.cash_amount),0)::numeric(12,2) into v_recorded
  from public.payment_transactions pt
  where pt.policy_action_id=v_action.id and pt.payment_purpose='CONTRACT'
    and pt.transaction_type='REFUND' and pt.status in ('APPROVED','REFUNDED');
  v_remaining:=round(greatest(v_target-v_recorded,0),2);

  for r in
    select pt.id transaction_id,pt.provider_payment_id,pt.method,pt.cash_amount,pt.contract_amount_settled,
      greatest(pt.cash_amount-coalesce((select sum(rf.cash_amount) from public.payment_transactions rf
        where rf.parent_transaction_id=pt.id and rf.payment_purpose='CONTRACT' and rf.transaction_type='REFUND' and rf.status in ('APPROVED','REFUNDED')),0),0)::numeric(12,2) refundable_cash
    from public.payment_transactions pt
    where pt.appointment_id=v_action.appointment_id and pt.payment_purpose='CONTRACT'
      and pt.transaction_type='CHARGE' and pt.provider='MERCADO_PAGO' and pt.provider_payment_id is not null
      and pt.status in ('APPROVED','PARTIALLY_REFUNDED','REFUNDED')
    order by pt.paid_at nulls last,pt.created_at,pt.id
  loop
    if r.refundable_cash<=0 then continue; end if;
    v_provider_available:=v_provider_available+r.refundable_cash;
    if v_remaining>0 then
      v_take:=least(v_remaining,r.refundable_cash);
      v_plan:=v_plan||jsonb_build_array(jsonb_build_object('parent_transaction_id',r.transaction_id,'provider_payment_id',r.provider_payment_id,'method',r.method,'available_cash',r.refundable_cash,'refund_cash',v_take));
      v_remaining:=round(v_remaining-v_take,2);
    end if;
  end loop;

  return jsonb_build_object('policy_action_id',v_action.id,'appointment_id',v_action.appointment_id,'status',v_action.status,'target_cash_amount',v_target,'recorded_refund_cash',v_recorded,'remaining_refund_cash',round(greatest(v_target-v_recorded,0),2),'mercado_pago_available_cash',round(v_provider_available,2),'manual_refund_cash',round(greatest((v_target-v_recorded)-v_provider_available,0),2),'payments',v_plan);
end;
$$;

revoke all on function public.service_admin_register_reschedule_penalty_payment(uuid,text,text,uuid) from public,anon,authenticated;
grant execute on function public.service_admin_register_reschedule_penalty_payment(uuid,text,text,uuid) to service_role;
-- END RC MIGRATION 20260821216000_payment_purpose_and_reschedule_penalty.sql

-- BEGIN RC MIGRATION 20260821217000_reschedule_package_reconciliation.sql
-- Package-backed rescheduling keeps one appointment_package_usage row and adjusts
-- the immutable ledger only by the difference between old and new package charge.

create or replace function public.service_quote_reschedule_package_hold(
  p_appointment_id uuid,
  p_checkout_hold_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_appointment public.appointments%rowtype;
  v_usage public.appointment_package_usage%rowtype;
  v_package public.hour_packages%rowtype;
  v_hold public.checkout_holds%rowtype;
  v_timezone text;
  v_local_start timestamp without time zone;
  v_local_end timestamp without time zone;
  v_special boolean;
  v_required bigint;
  v_surcharge bigint;
  v_charged bigint;
  v_delta bigint;
  v_available bigint;
begin
  select * into v_appointment from public.appointments where id=p_appointment_id and deleted_at is null;
  if not found then raise exception using errcode='P0001', message='APPOINTMENT_NOT_FOUND'; end if;

  select * into v_usage from public.appointment_package_usage
  where appointment_id=p_appointment_id and reversal_movement_id is null;
  if not found then return jsonb_build_object('uses_package',false); end if;

  select * into v_package from public.hour_packages where id=v_usage.hour_package_id;
  select * into v_hold from public.checkout_holds where id=p_checkout_hold_id and status='ACTIVE' and expires_at>now();
  if not found then raise exception using errcode='P0001', message='RESCHEDULE_HOLD_EXPIRED'; end if;

  if v_package.customer_id is distinct from v_appointment.primary_customer_id then
    raise exception using errcode='P0001', message='HOUR_PACKAGE_CUSTOMER_MISMATCH';
  end if;
  if v_package.status <> 'ACTIVE' then raise exception using errcode='P0001', message='HOUR_PACKAGE_NOT_ACTIVE'; end if;
  if v_hold.requested_start_at < v_package.valid_from or v_hold.requested_start_at >= v_package.valid_until then
    raise exception using errcode='P0001', message='HOUR_PACKAGE_OUTSIDE_VALIDITY';
  end if;
  if not exists(select 1 from public.hour_package_services where hour_package_id=v_package.id and service_id=v_appointment.service_id) then
    raise exception using errcode='P0001', message='HOUR_PACKAGE_SERVICE_NOT_ELIGIBLE';
  end if;

  select timezone into v_timezone from public.operation_settings where id=1;
  v_local_start:=v_hold.requested_start_at at time zone v_timezone;
  v_local_end:=v_hold.requested_end_at at time zone v_timezone;
  v_special:=extract(dow from v_local_start)::integer in (0,6)
    or v_local_start::date<>v_local_end::date
    or v_local_start::time<v_package.standard_start_local_time
    or v_local_end::time>v_package.standard_end_local_time;

  v_required:=v_hold.duration_minutes::bigint*60;
  v_surcharge:=case when v_special then round(v_required::numeric*v_package.special_surcharge_percent/100)::bigint else 0 end;
  v_charged:=v_required+v_surcharge;
  v_delta:=v_charged-v_usage.charged_seconds;
  select available_seconds into v_available from public.hour_package_balances where hour_package_id=v_package.id;

  if v_delta>0 and coalesce(v_available,0)<v_delta then
    raise exception using errcode='P0001', message='HOUR_PACKAGE_INSUFFICIENT_BALANCE';
  end if;

  return jsonb_build_object(
    'uses_package',true,
    'hour_package_id',v_package.id,
    'old_required_seconds',v_usage.required_seconds,
    'old_surcharge_seconds',v_usage.surcharge_seconds,
    'old_charged_seconds',v_usage.charged_seconds,
    'new_required_seconds',v_required,
    'new_surcharge_seconds',v_surcharge,
    'new_charged_seconds',v_charged,
    'delta_seconds',v_delta,
    'available_seconds',coalesce(v_available,0),
    'is_special_period',v_special,
    'special_surcharge_percent',case when v_special then v_package.special_surcharge_percent else 0 end
  );
end;
$$;

create or replace function public.service_reconcile_reschedule_package(
  p_appointment_id uuid,
  p_checkout_hold_id uuid,
  p_admin_id uuid default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_usage public.appointment_package_usage%rowtype;
  v_package public.hour_packages%rowtype;
  v_quote jsonb;
  v_delta bigint;
  v_movement_id uuid;
  v_required bigint;
  v_surcharge bigint;
  v_charged bigint;
  v_special boolean;
  v_percent numeric(5,2);
begin
  select * into v_usage from public.appointment_package_usage
  where appointment_id=p_appointment_id and reversal_movement_id is null for update;
  if not found then return jsonb_build_object('uses_package',false,'adjusted',false); end if;

  select * into v_package from public.hour_packages where id=v_usage.hour_package_id for update;
  v_quote:=public.service_quote_reschedule_package_hold(p_appointment_id,p_checkout_hold_id);
  v_delta:=(v_quote->>'delta_seconds')::bigint;
  v_required:=(v_quote->>'new_required_seconds')::bigint;
  v_surcharge:=(v_quote->>'new_surcharge_seconds')::bigint;
  v_charged:=(v_quote->>'new_charged_seconds')::bigint;
  v_special:=(v_quote->>'is_special_period')::boolean;
  v_percent:=(v_quote->>'special_surcharge_percent')::numeric;

  -- Quote is recalculated while package row is locked; checkout package reservations
  -- use the same package lock, making the delta balance check concurrency-safe.
  if v_delta<>0 then
    insert into public.hour_package_movements(
      hour_package_id,appointment_id,movement_type,minutes_delta,seconds_delta,reason,created_by_admin_id
    ) values (
      v_usage.hour_package_id,p_appointment_id,'DURATION_ADJUSTMENT',
      -(v_delta::numeric/60),-v_delta,'APPOINTMENT_RESCHEDULED_PACKAGE_RECONCILIATION',p_admin_id
    ) returning id into v_movement_id;
  end if;

  update public.appointment_package_usage
  set covered_minutes=(v_required/60)::integer,
      required_seconds=v_required,
      surcharge_seconds=v_surcharge,
      charged_seconds=v_charged,
      covered_reference_value=round(v_package.reference_minute_value*(v_required::numeric/60),2),
      is_special_period=v_special,
      special_surcharge_percent=v_percent,
      special_surcharge_amount=0
  where id=v_usage.id;

  return v_quote || jsonb_build_object('adjusted',v_delta<>0,'adjustment_movement_id',v_movement_id);
end;
$$;

create or replace function public.service_admin_list_reschedule_slots(
  p_appointment_id uuid,
  p_local_date date
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_appointment public.appointments%rowtype;
  v_usage public.appointment_package_usage%rowtype;
  v_package public.hour_packages%rowtype;
  v_extras jsonb;
  v_timezone text;
  v_available bigint;
  v_old_charged bigint;
  v_local_start timestamp without time zone;
  v_local_end timestamp without time zone;
  v_required bigint;
  v_surcharge bigint;
  v_delta bigint;
  v_special boolean;
  v_result jsonb:='[]'::jsonb;
  r record;
begin
  if p_local_date is null then raise exception using errcode='P0001', message='RESCHEDULE_DATE_REQUIRED'; end if;
  select * into v_appointment from public.appointments where id=p_appointment_id and deleted_at is null;
  if not found then raise exception using errcode='P0001', message='APPOINTMENT_NOT_FOUND'; end if;
  if v_appointment.status<>'CONFIRMED' then raise exception using errcode='P0001', message='APPOINTMENT_NOT_RESCHEDULABLE'; end if;

  select coalesce(jsonb_agg(jsonb_build_object('extra_id',ae.extra_id,'quantity',ae.quantity) order by ae.extra_id),'[]'::jsonb)
  into v_extras from public.appointment_extras ae where ae.appointment_id=p_appointment_id and ae.extra_id is not null;

  select * into v_usage from public.appointment_package_usage where appointment_id=p_appointment_id and reversal_movement_id is null;
  if found then
    select * into v_package from public.hour_packages where id=v_usage.hour_package_id;
    select available_seconds into v_available from public.hour_package_balances where hour_package_id=v_package.id;
    v_old_charged:=v_usage.charged_seconds;
    select timezone into v_timezone from public.operation_settings where id=1;
  end if;

  for r in select * from public.list_available_slots_for_duration(
    v_appointment.service_id,v_appointment.service_employee_id,v_appointment.duration_blocks,
    v_extras,v_appointment.people_count,p_local_date,null
  ) loop
    if v_usage.id is not null then
      if v_package.status<>'ACTIVE'
        or r.slot_start_at<v_package.valid_from or r.slot_start_at>=v_package.valid_until
        or not exists(select 1 from public.hour_package_services where hour_package_id=v_package.id and service_id=v_appointment.service_id)
      then continue; end if;

      v_local_start:=r.slot_start_at at time zone v_timezone;
      v_local_end:=r.slot_end_at at time zone v_timezone;
      v_special:=extract(dow from v_local_start)::integer in (0,6)
        or v_local_start::date<>v_local_end::date
        or v_local_start::time<v_package.standard_start_local_time
        or v_local_end::time>v_package.standard_end_local_time;
      v_required:=r.duration_minutes::bigint*60;
      v_surcharge:=case when v_special then round(v_required::numeric*v_package.special_surcharge_percent/100)::bigint else 0 end;
      v_delta:=(v_required+v_surcharge)-v_old_charged;
      if v_delta>0 and coalesce(v_available,0)<v_delta then continue; end if;
    end if;

    v_result:=v_result||jsonb_build_array(jsonb_build_object(
      'slot_start_at',r.slot_start_at,'slot_end_at',r.slot_end_at,
      'core_start_at',r.core_start_at,'core_end_at',r.core_end_at,
      'pre_service_minutes',r.pre_service_minutes,'post_service_minutes',r.post_service_minutes,
      'duration_minutes',r.duration_minutes,
      'package_delta_seconds',case when v_usage.id is null then 0 else v_delta end
    ));
  end loop;
  return v_result;
end;
$$;

create or replace function public.service_admin_create_reschedule_hold(
  p_appointment_id uuid,
  p_requested_start_at timestamptz,
  p_requested_at timestamptz default now(),
  p_admin_id uuid default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_appointment public.appointments%rowtype;
  v_preview jsonb; v_extras jsonb; v_hold jsonb; v_package_quote jsonb;
  v_hold_id uuid; v_action_id uuid; v_action_status text; v_previous record;
begin
  if p_requested_start_at is null or p_requested_at is null then raise exception using errcode='P0001', message='RESCHEDULE_TIME_REQUIRED'; end if;
  select * into v_appointment from public.appointments where id=p_appointment_id and deleted_at is null for update;
  if not found then raise exception using errcode='P0001', message='APPOINTMENT_NOT_FOUND'; end if;
  if v_appointment.status<>'CONFIRMED' then raise exception using errcode='P0001', message='APPOINTMENT_NOT_RESCHEDULABLE'; end if;

  for v_previous in select id,reschedule_checkout_hold_id from public.appointment_policy_actions
    where appointment_id=p_appointment_id and action_type='RESCHEDULE' and status in ('PREVIEW','AWAITING_PENALTY_PAYMENT') for update
  loop
    if v_previous.reschedule_checkout_hold_id is not null then
      update public.resource_allocations set status='RELEASED',updated_at=now()
      where checkout_hold_id=v_previous.reschedule_checkout_hold_id and allocation_type='CHECKOUT_HOLD' and status='HELD';
      update public.checkout_holds set status='INVALIDATED',updated_at=now()
      where id=v_previous.reschedule_checkout_hold_id and status='ACTIVE';
    end if;
    update public.appointment_policy_actions set status='VOIDED',updated_at=now() where id=v_previous.id;
  end loop;

  select coalesce(jsonb_agg(jsonb_build_object('extra_id',ae.extra_id,'quantity',ae.quantity) order by ae.extra_id),'[]'::jsonb)
  into v_extras from public.appointment_extras ae where ae.appointment_id=p_appointment_id and ae.extra_id is not null;

  v_hold:=public.create_checkout_hold_for_duration(v_appointment.service_id,v_appointment.service_employee_id,v_appointment.duration_blocks,v_extras,v_appointment.people_count,p_requested_start_at);
  v_hold_id:=(v_hold->>'checkout_hold_id')::uuid;
  update public.checkout_holds set primary_customer_id=v_appointment.primary_customer_id,updated_at=now() where id=v_hold_id;

  v_package_quote:=public.service_quote_reschedule_package_hold(p_appointment_id,v_hold_id);
  v_preview:=public.calculate_appointment_change_policy(p_appointment_id,'RESCHEDULE',p_requested_at);
  v_action_status:=case when coalesce((v_preview->>'penalty_due_now')::numeric,0)>0 then 'AWAITING_PENALTY_PAYMENT' else 'PREVIEW' end;

  insert into public.appointment_policy_actions(
    appointment_id,action_type,status,requested_at,original_start_at,requested_new_start_at,
    hours_before_start,notice_hours_snapshot,is_inside_notice_window,prior_customer_reschedules,
    contract_value_snapshot,net_paid_snapshot,penalty_type,penalty_value,penalty_amount,penalty_due_now,
    refund_allowed,credit_allowed,reschedule_checkout_hold_id,created_by_admin_id
  ) values (
    p_appointment_id,'RESCHEDULE',v_action_status,p_requested_at,v_appointment.start_at,(v_hold->>'slot_start_at')::timestamptz,
    (v_preview->>'hours_before_start')::numeric,(v_preview->>'notice_hours')::integer,(v_preview->>'inside_notice_window')::boolean,
    (v_preview->>'prior_customer_reschedules')::integer,(v_preview->>'contract_value')::numeric,(v_preview->>'net_paid')::numeric,
    (v_preview->>'penalty_type')::public.change_penalty_type,(v_preview->>'penalty_value')::numeric,(v_preview->>'penalty_amount')::numeric,
    (v_preview->>'penalty_due_now')::numeric,false,false,v_hold_id,p_admin_id
  ) returning id into v_action_id;

  return jsonb_build_object(
    'policy_action_id',v_action_id,'policy_action_status',v_action_status,'appointment_id',p_appointment_id,
    'original_start_at',v_appointment.start_at,
    'new_slot',jsonb_build_object('checkout_hold_id',v_hold_id,'expires_at',v_hold->'expires_at','slot_start_at',v_hold->'slot_start_at','slot_end_at',v_hold->'slot_end_at','core_start_at',v_hold->'core_start_at','core_end_at',v_hold->'core_end_at'),
    'penalty_type',v_preview->'penalty_type','penalty_value',v_preview->'penalty_value','penalty_due_now',v_preview->'penalty_due_now',
    'package_reconciliation',v_package_quote
  );
end;
$$;

create or replace function public.service_admin_apply_reschedule(
  p_policy_action_id uuid,
  p_admin_id uuid default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_action public.appointment_policy_actions%rowtype;
  v_appointment public.appointments%rowtype;
  v_hold public.checkout_holds%rowtype;
  v_package_reconciliation jsonb;
  v_new_version integer; v_old_start timestamptz; v_old_end timestamptz;
begin
  select * into v_action from public.appointment_policy_actions where id=p_policy_action_id for update;
  if not found or v_action.action_type<>'RESCHEDULE' then raise exception using errcode='P0001', message='INVALID_RESCHEDULE_ACTION'; end if;
  if v_action.status='APPLIED' then
    select * into v_appointment from public.appointments where id=v_action.appointment_id;
    return jsonb_build_object('policy_action_id',v_action.id,'appointment_id',v_action.appointment_id,'status','APPLIED','appointment_version',v_appointment.version,'already_applied',true);
  end if;
  if v_action.status='AWAITING_PENALTY_PAYMENT' then raise exception using errcode='P0001', message='RESCHEDULE_PENALTY_PAYMENT_REQUIRED'; end if;
  if v_action.status<>'PREVIEW' then raise exception using errcode='P0001', message='RESCHEDULE_ACTION_NOT_APPLICABLE'; end if;
  if coalesce(v_action.penalty_due_now,0)>0 and v_action.penalty_payment_transaction_id is null then raise exception using errcode='P0001', message='RESCHEDULE_PENALTY_PAYMENT_REQUIRED'; end if;

  select * into v_appointment from public.appointments where id=v_action.appointment_id for update;
  if not found or v_appointment.status<>'CONFIRMED' then raise exception using errcode='P0001', message='APPOINTMENT_NOT_RESCHEDULABLE'; end if;
  select * into v_hold from public.checkout_holds where id=v_action.reschedule_checkout_hold_id for update;
  if not found or v_hold.status<>'ACTIVE' or v_hold.expires_at<=now() then raise exception using errcode='P0001', message='RESCHEDULE_HOLD_EXPIRED'; end if;
  if v_hold.service_id<>v_appointment.service_id or v_hold.service_employee_id<>v_appointment.service_employee_id or v_hold.primary_customer_id is distinct from v_appointment.primary_customer_id then
    raise exception using errcode='P0001', message='RESCHEDULE_HOLD_MISMATCH';
  end if;

  -- Reconcile package before any schedule mutation. Failure rolls back the whole apply.
  v_package_reconciliation:=public.service_reconcile_reschedule_package(v_appointment.id,v_hold.id,p_admin_id);
  v_old_start:=v_appointment.start_at; v_old_end:=v_appointment.end_at;

  update public.resource_allocations set status='RELEASED',updated_at=now()
  where appointment_id=v_appointment.id and allocation_type='APPOINTMENT' and status in ('HELD','AWAITING_PAYMENT','CONFIRMED','BLOCKED');
  update public.resource_allocations set appointment_id=v_appointment.id,checkout_hold_id=null,allocation_type='APPOINTMENT',status='CONFIRMED',updated_at=now()
  where checkout_hold_id=v_hold.id and allocation_type='CHECKOUT_HOLD' and status='HELD';

  update public.appointments set start_at=v_hold.requested_start_at,end_at=v_hold.requested_end_at,core_start_at=v_hold.core_start_at,core_end_at=v_hold.core_end_at,
    pre_service_minutes=v_hold.pre_service_minutes,post_service_minutes=v_hold.post_service_minutes,schedule_profile_snapshot=v_hold.schedule_profile,
    duration_minutes=v_hold.duration_minutes,duration_blocks=v_hold.duration_blocks,contracted_minutes=v_hold.contracted_minutes,
    version=version+1,updated_at=now()
  where id=v_appointment.id returning version into v_new_version;
  update public.checkout_holds set status='PROMOTED',promoted_appointment_id=v_appointment.id,updated_at=now() where id=v_hold.id;
  update public.appointment_policy_actions set status='APPLIED',updated_at=now() where id=v_action.id;

  insert into public.integration_jobs(job_type,entity_type,entity_id,entity_version,payload_json,idempotency_key)
  values('GOOGLE_APPOINTMENT_SYNC','APPOINTMENT',v_appointment.id,v_new_version,jsonb_build_object('reason','APPOINTMENT_RESCHEDULED'),'google-appointment-sync:'||v_appointment.id::text||':'||v_new_version::text)
  on conflict(idempotency_key) do nothing;
  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
  values(p_admin_id,'APPOINTMENT',v_appointment.id,'APPOINTMENT_RESCHEDULED',jsonb_build_object('start_at',v_old_start,'end_at',v_old_end,'version',v_appointment.version),
    jsonb_build_object('start_at',v_hold.requested_start_at,'end_at',v_hold.requested_end_at,'version',v_new_version,'policy_action_id',v_action.id,'penalty_amount',v_action.penalty_amount,'package_reconciliation',v_package_reconciliation),'ADMIN');

  return jsonb_build_object('policy_action_id',v_action.id,'appointment_id',v_appointment.id,'status','APPLIED','old_start_at',v_old_start,'new_start_at',v_hold.requested_start_at,'new_end_at',v_hold.requested_end_at,'appointment_version',v_new_version,'package_reconciliation',v_package_reconciliation,'google_sync_enqueued',true,'already_applied',false);
end;
$$;

revoke all on function public.service_quote_reschedule_package_hold(uuid,uuid) from public,anon,authenticated;
revoke all on function public.service_reconcile_reschedule_package(uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function public.service_quote_reschedule_package_hold(uuid,uuid) to service_role;
grant execute on function public.service_reconcile_reschedule_package(uuid,uuid,uuid) to service_role;
-- END RC MIGRATION 20260821217000_reschedule_package_reconciliation.sql

-- BEGIN RC MIGRATION 20260822110000_client_prebook_invoice_terms.sql
-- Commercial terms for selected recurring/corporate customers.
-- No customer is enabled by default; production values are explicitly configured per customer.

create table public.customer_commercial_terms (
  customer_id uuid primary key references public.customers(id) on delete cascade,
  can_prebook boolean not null default false,
  prebook_hold_minutes integer not null default 1440 check (prebook_hold_minutes > 0),
  max_active_prebooks integer not null default 1 check (max_active_prebooks > 0),
  requires_manual_confirmation boolean not null default true,
  billing_mode text not null default 'CHECKOUT'
    check (billing_mode in ('CHECKOUT','INVOICE')),
  invoice_due_days integer check (
    (billing_mode = 'CHECKOUT' and invoice_due_days is null)
    or (billing_mode = 'INVOICE' and invoice_due_days is not null and invoice_due_days >= 0)
  ),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.customer_prebook_authorized_services (
  customer_id uuid not null references public.customers(id) on delete cascade,
  service_id uuid not null references public.services(id) on delete cascade,
  primary key (customer_id, service_id)
);

create table public.pre_reservations (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customers(id) on delete restrict,
  service_id uuid not null references public.services(id) on delete restrict,
  employee_id uuid references public.employees(id) on delete restrict,
  start_at timestamptz not null,
  end_at timestamptz not null,
  expires_at timestamptz not null,
  status text not null default 'ACTIVE'
    check (status in ('ACTIVE','CONFIRMED','CANCELLED','EXPIRED')),
  converted_appointment_id uuid references public.appointments(id) on delete restrict,
  created_by_admin_id uuid,
  confirmed_by_admin_id uuid,
  cancelled_by_admin_id uuid,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  confirmed_at timestamptz,
  cancelled_at timestamptz,
  check (end_at > start_at),
  check (expires_at > created_at)
);

create index pre_reservations_customer_status_idx
  on public.pre_reservations (customer_id, status, expires_at);

create index pre_reservations_active_time_idx
  on public.pre_reservations (start_at, end_at)
  where status = 'ACTIVE';

alter table public.appointments
  add column billing_mode_snapshot text not null default 'CHECKOUT'
    check (billing_mode_snapshot in ('CHECKOUT','INVOICE')),
  add column invoice_due_at timestamptz,
  add column invoice_authorized_by_admin_id uuid,
  add column source_pre_reservation_id uuid references public.pre_reservations(id) on delete restrict;

alter table public.pre_reservations
  add constraint pre_reservations_converted_appointment_uq unique (converted_appointment_id);

create unique index appointments_source_pre_reservation_uq
  on public.appointments (source_pre_reservation_id)
  where source_pre_reservation_id is not null;

create unique index pre_reservations_idempotency_shape_uq
  on public.pre_reservations (customer_id, service_id, start_at, end_at)
  where status = 'ACTIVE';

create or replace function public.service_get_customer_commercial_terms(p_customer_id uuid)
returns table (
  customer_id uuid,
  can_prebook boolean,
  prebook_hold_minutes integer,
  max_active_prebooks integer,
  requires_manual_confirmation boolean,
  billing_mode text,
  invoice_due_days integer
)
language sql
security definer
set search_path = public
as $$
  select t.customer_id, t.can_prebook, t.prebook_hold_minutes,
         t.max_active_prebooks, t.requires_manual_confirmation,
         t.billing_mode, t.invoice_due_days
    from public.customer_commercial_terms t
   where t.customer_id = p_customer_id
     and t.is_active = true;
$$;

create or replace function public.service_expire_pre_reservations()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
begin
  update public.pre_reservations
     set status = 'EXPIRED', updated_at = now()
   where status = 'ACTIVE'
     and expires_at <= now();
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

create or replace function public.service_admin_authorize_invoiced_appointment(
  p_appointment_id uuid,
  p_admin_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_appt public.appointments%rowtype;
  v_terms public.customer_commercial_terms%rowtype;
  v_due_at timestamptz;
begin
  select * into v_appt
    from public.appointments
   where id = p_appointment_id
   for update;

  if not found then
    raise exception 'APPOINTMENT_NOT_FOUND';
  end if;

  select * into v_terms
    from public.customer_commercial_terms
   where customer_id = v_appt.primary_customer_id
     and is_active = true;

  if not found or v_terms.billing_mode <> 'INVOICE' then
    raise exception 'CUSTOMER_NOT_AUTHORIZED_FOR_INVOICE';
  end if;

  v_due_at := coalesce(v_appt.start_at, now()) + make_interval(days => v_terms.invoice_due_days);

  update public.appointments
     set billing_mode_snapshot = 'INVOICE',
         invoice_due_at = v_due_at,
         invoice_authorized_by_admin_id = p_admin_id,
         financial_status = 'UNPAID_AUTHORIZED',
         updated_at = now()
   where id = p_appointment_id;

  insert into public.audit_logs (
    admin_user_id, entity_type, entity_id, action, after_json, origin
  ) values (
    p_admin_id, 'APPOINTMENT', p_appointment_id, 'AUTHORIZE_INVOICE',
    jsonb_build_object(
      'billing_mode', 'INVOICE',
      'invoice_due_days', v_terms.invoice_due_days,
      'invoice_due_at', v_due_at,
      'customer_id', v_appt.primary_customer_id
    ),
    'ADMIN'
  );

  return jsonb_build_object(
    'appointment_id', p_appointment_id,
    'billing_mode', 'INVOICE',
    'financial_status', 'UNPAID_AUTHORIZED',
    'invoice_due_at', v_due_at
  );
end;
$$;
-- END RC MIGRATION 20260822110000_client_prebook_invoice_terms.sql

-- BEGIN RC MIGRATION 20260822113000_admin_customer_commercial_terms.sql
-- Administrative read/write model for customer commercial terms.
-- Keeps special rules (pre-booking, invoicing) in the Agenda backend and audits every change.

create or replace function public.service_admin_list_customers(
  p_search text default null,
  p_limit integer default 50
)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'customers',
    coalesce(jsonb_agg(
      jsonb_build_object(
        'id', c.id,
        'customer_type', c.customer_type,
        'name', c.name,
        'legal_name', c.legal_name,
        'cpf_cnpj', c.cpf_cnpj,
        'email', c.email,
        'phone', c.phone,
        'commercial_terms', case when t.customer_id is null then null else jsonb_build_object(
          'can_prebook', t.can_prebook,
          'prebook_hold_minutes', t.prebook_hold_minutes,
          'max_active_prebooks', t.max_active_prebooks,
          'requires_manual_confirmation', t.requires_manual_confirmation,
          'billing_mode', t.billing_mode,
          'invoice_due_days', t.invoice_due_days,
          'is_active', t.is_active
        ) end
      ) order by c.name, c.id
    ), '[]'::jsonb)
  )
  from (
    select *
    from public.customers c0
    where p_search is null
       or btrim(p_search) = ''
       or lower(c0.name) like '%' || lower(btrim(p_search)) || '%'
       or lower(coalesce(c0.legal_name, '')) like '%' || lower(btrim(p_search)) || '%'
       or lower(coalesce(c0.email, '')) like '%' || lower(btrim(p_search)) || '%'
       or coalesce(c0.phone, '') like '%' || btrim(p_search) || '%'
       or coalesce(c0.cpf_cnpj, '') like '%' || btrim(p_search) || '%'
    order by c0.name, c0.id
    limit greatest(1, least(coalesce(p_limit, 50), 100))
  ) c
  left join public.customer_commercial_terms t on t.customer_id = c.id;
$$;

create or replace function public.service_admin_get_customer_commercial_profile(p_customer_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'customer', jsonb_build_object(
      'id', c.id,
      'customer_type', c.customer_type,
      'name', c.name,
      'legal_name', c.legal_name,
      'cpf_cnpj', c.cpf_cnpj,
      'email', c.email,
      'phone', c.phone,
      'notes', c.notes
    ),
    'terms', case when t.customer_id is null then null else jsonb_build_object(
      'can_prebook', t.can_prebook,
      'prebook_hold_minutes', t.prebook_hold_minutes,
      'max_active_prebooks', t.max_active_prebooks,
      'requires_manual_confirmation', t.requires_manual_confirmation,
      'billing_mode', t.billing_mode,
      'invoice_due_days', t.invoice_due_days,
      'is_active', t.is_active
    ) end,
    'authorized_services', coalesce((
      select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'slug', s.slug) order by s.sort_order, s.name)
      from public.customer_prebook_authorized_services cas
      join public.services s on s.id = cas.service_id
      where cas.customer_id = c.id
    ), '[]'::jsonb),
    'active_pre_reservations', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', pr.id,
        'service_id', pr.service_id,
        'service_name', s.name,
        'start_at', pr.start_at,
        'end_at', pr.end_at,
        'expires_at', pr.expires_at,
        'status', pr.status,
        'converted_appointment_id', pr.converted_appointment_id
      ) order by pr.start_at)
      from public.pre_reservations pr
      join public.services s on s.id = pr.service_id
      where pr.customer_id = c.id
        and pr.status = 'ACTIVE'
    ), '[]'::jsonb)
  )
  from public.customers c
  left join public.customer_commercial_terms t on t.customer_id = c.id
  where c.id = p_customer_id;
$$;

create or replace function public.service_admin_set_customer_commercial_terms(
  p_customer_id uuid,
  p_can_prebook boolean,
  p_prebook_hold_minutes integer,
  p_max_active_prebooks integer,
  p_requires_manual_confirmation boolean,
  p_billing_mode text,
  p_invoice_due_days integer,
  p_is_active boolean,
  p_authorized_service_ids uuid[],
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
  v_mode text := upper(btrim(coalesce(p_billing_mode, '')));
begin
  if not exists (select 1 from public.customers where id = p_customer_id) then
    raise exception using errcode = 'P0001', message = 'CUSTOMER_NOT_FOUND';
  end if;

  if coalesce(p_prebook_hold_minutes, 0) <= 0 then
    raise exception using errcode = 'P0001', message = 'PREBOOK_HOLD_MINUTES_INVALID';
  end if;
  if coalesce(p_max_active_prebooks, 0) <= 0 then
    raise exception using errcode = 'P0001', message = 'MAX_ACTIVE_PREBOOKS_INVALID';
  end if;
  if v_mode not in ('CHECKOUT','INVOICE') then
    raise exception using errcode = 'P0001', message = 'BILLING_MODE_INVALID';
  end if;
  if v_mode = 'INVOICE' and (p_invoice_due_days is null or p_invoice_due_days < 0) then
    raise exception using errcode = 'P0001', message = 'INVOICE_DUE_DAYS_INVALID';
  end if;
  if v_mode = 'CHECKOUT' and p_invoice_due_days is not null then
    raise exception using errcode = 'P0001', message = 'INVOICE_DUE_DAYS_NOT_ALLOWED';
  end if;

  select public.service_admin_get_customer_commercial_profile(p_customer_id) into v_before;

  insert into public.customer_commercial_terms(
    customer_id, can_prebook, prebook_hold_minutes, max_active_prebooks,
    requires_manual_confirmation, billing_mode, invoice_due_days, is_active, updated_at
  ) values (
    p_customer_id, coalesce(p_can_prebook, false), p_prebook_hold_minutes, p_max_active_prebooks,
    coalesce(p_requires_manual_confirmation, true), v_mode,
    case when v_mode = 'INVOICE' then p_invoice_due_days else null end,
    coalesce(p_is_active, true), now()
  )
  on conflict (customer_id) do update set
    can_prebook = excluded.can_prebook,
    prebook_hold_minutes = excluded.prebook_hold_minutes,
    max_active_prebooks = excluded.max_active_prebooks,
    requires_manual_confirmation = excluded.requires_manual_confirmation,
    billing_mode = excluded.billing_mode,
    invoice_due_days = excluded.invoice_due_days,
    is_active = excluded.is_active,
    updated_at = now();

  delete from public.customer_prebook_authorized_services where customer_id = p_customer_id;

  if coalesce(array_length(p_authorized_service_ids, 1), 0) > 0 then
    if exists (
      select 1 from unnest(p_authorized_service_ids) x(service_id)
      left join public.services s on s.id = x.service_id and s.is_active
      where s.id is null
    ) then
      raise exception using errcode = 'P0001', message = 'AUTHORIZED_SERVICE_INVALID';
    end if;

    insert into public.customer_prebook_authorized_services(customer_id, service_id)
    select p_customer_id, service_id
    from unnest(p_authorized_service_ids) x(service_id)
    on conflict do nothing;
  end if;

  select public.service_admin_get_customer_commercial_profile(p_customer_id) into v_after;

  insert into public.audit_logs(admin_user_id, entity_type, entity_id, action, before_json, after_json, origin)
  values (p_admin_id, 'CUSTOMER', p_customer_id, 'COMMERCIAL_TERMS_CHANGED', v_before, v_after, 'ADMIN');

  return v_after;
end;
$$;

revoke all on function public.service_admin_list_customers(text,integer) from public, anon, authenticated;
grant execute on function public.service_admin_list_customers(text,integer) to service_role;
revoke all on function public.service_admin_get_customer_commercial_profile(uuid) from public, anon, authenticated;
grant execute on function public.service_admin_get_customer_commercial_profile(uuid) to service_role;
revoke all on function public.service_admin_set_customer_commercial_terms(uuid,boolean,integer,integer,boolean,text,integer,boolean,uuid[],uuid) from public, anon, authenticated;
grant execute on function public.service_admin_set_customer_commercial_terms(uuid,boolean,integer,integer,boolean,text,integer,boolean,uuid[],uuid) to service_role;
-- END RC MIGRATION 20260822113000_admin_customer_commercial_terms.sql

-- BEGIN RC MIGRATION 20260822114000_admin_rbac.sql
-- Backend-enforced permissions for the unified BlackSheep + Sabrina admin hub.

alter table public.admin_users drop constraint if exists admin_users_role_check;
alter table public.admin_users
  add constraint admin_users_role_check
  check (role in ('OWNER','ADMIN','OPERATION','FINANCE'));

create table public.admin_user_permissions (
  admin_user_id uuid not null references public.admin_users(id) on delete cascade,
  permission text not null check (permission in (
    'DASHBOARD_VIEW',
    'AGENDA_VIEW','AGENDA_MANAGE',
    'CUSTOMERS_VIEW','CUSTOMERS_MANAGE',
    'FINANCE_VIEW','FINANCE_MANAGE',
    'PACKAGES_VIEW','PACKAGES_MANAGE',
    'SERVICES_VIEW','SERVICES_MANAGE',
    'INTEGRATIONS_VIEW','INTEGRATIONS_MANAGE',
    'AUDIT_VIEW','TEAM_MANAGE'
  )),
  is_granted boolean not null,
  updated_by_admin_id uuid references public.admin_users(id) on delete set null,
  updated_at timestamptz not null default now(),
  primary key (admin_user_id, permission)
);

alter table public.admin_user_permissions enable row level security;

create or replace function public.service_admin_role_default_permission(p_role text, p_permission text)
returns boolean
language sql
immutable
set search_path = public
as $$
  select case upper(p_role)
    when 'OWNER' then true
    when 'ADMIN' then true
    when 'OPERATION' then p_permission in (
      'DASHBOARD_VIEW','AGENDA_VIEW','AGENDA_MANAGE',
      'CUSTOMERS_VIEW','CUSTOMERS_MANAGE','PACKAGES_VIEW'
    )
    when 'FINANCE' then p_permission in (
      'DASHBOARD_VIEW','AGENDA_VIEW','CUSTOMERS_VIEW',
      'FINANCE_VIEW','FINANCE_MANAGE','PACKAGES_VIEW'
    )
    else false
  end;
$$;

create or replace function public.service_admin_has_permission(p_admin_id uuid, p_permission text)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_admin public.admin_users%rowtype;
  v_override boolean;
begin
  select * into v_admin
  from public.admin_users
  where id = p_admin_id and is_active = true;

  if not found then return false; end if;

  select aup.is_granted into v_override
  from public.admin_user_permissions aup
  where aup.admin_user_id = p_admin_id
    and aup.permission = p_permission;

  if found then return v_override; end if;
  return public.service_admin_role_default_permission(v_admin.role, p_permission);
end;
$$;

create or replace function public.service_admin_get_access_profile(p_admin_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'admin_user_id', a.id,
    'display_name', a.display_name,
    'role', a.role,
    'permissions', (
      select jsonb_object_agg(p.permission, public.service_admin_has_permission(a.id, p.permission))
      from (values
        ('DASHBOARD_VIEW'),('AGENDA_VIEW'),('AGENDA_MANAGE'),
        ('CUSTOMERS_VIEW'),('CUSTOMERS_MANAGE'),
        ('FINANCE_VIEW'),('FINANCE_MANAGE'),
        ('PACKAGES_VIEW'),('PACKAGES_MANAGE'),
        ('SERVICES_VIEW'),('SERVICES_MANAGE'),
        ('INTEGRATIONS_VIEW'),('INTEGRATIONS_MANAGE'),
        ('AUDIT_VIEW'),('TEAM_MANAGE')
      ) p(permission)
    )
  )
  from public.admin_users a
  where a.id = p_admin_id and a.is_active = true;
$$;

create or replace function public.service_admin_set_permission(
  p_target_admin_id uuid,
  p_permission text,
  p_is_granted boolean,
  p_actor_admin_id uuid
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
begin
  if not public.service_admin_has_permission(p_actor_admin_id, 'TEAM_MANAGE') then
    raise exception using errcode = 'P0001', message = 'ADMIN_PERMISSION_DENIED';
  end if;
  if not exists (select 1 from public.admin_users where id = p_target_admin_id) then
    raise exception using errcode = 'P0001', message = 'ADMIN_USER_NOT_FOUND';
  end if;
  if p_permission not in (
    'DASHBOARD_VIEW','AGENDA_VIEW','AGENDA_MANAGE','CUSTOMERS_VIEW','CUSTOMERS_MANAGE',
    'FINANCE_VIEW','FINANCE_MANAGE','PACKAGES_VIEW','PACKAGES_MANAGE','SERVICES_VIEW','SERVICES_MANAGE',
    'INTEGRATIONS_VIEW','INTEGRATIONS_MANAGE','AUDIT_VIEW','TEAM_MANAGE'
  ) then
    raise exception using errcode = 'P0001', message = 'ADMIN_PERMISSION_INVALID';
  end if;

  select public.service_admin_get_access_profile(p_target_admin_id) into v_before;

  insert into public.admin_user_permissions(admin_user_id, permission, is_granted, updated_by_admin_id, updated_at)
  values (p_target_admin_id, p_permission, p_is_granted, p_actor_admin_id, now())
  on conflict (admin_user_id, permission) do update set
    is_granted = excluded.is_granted,
    updated_by_admin_id = excluded.updated_by_admin_id,
    updated_at = now();

  select public.service_admin_get_access_profile(p_target_admin_id) into v_after;

  insert into public.audit_logs(admin_user_id, entity_type, entity_id, action, before_json, after_json, origin)
  values (p_actor_admin_id, 'ADMIN_USER', p_target_admin_id, 'PERMISSION_CHANGED', v_before, v_after, 'ADMIN');

  return v_after;
end;
$$;

revoke all on function public.service_admin_role_default_permission(text,text) from public, anon, authenticated;
grant execute on function public.service_admin_role_default_permission(text,text) to service_role;
revoke all on function public.service_admin_has_permission(uuid,text) from public, anon, authenticated;
grant execute on function public.service_admin_has_permission(uuid,text) to service_role;
revoke all on function public.service_admin_get_access_profile(uuid) from public, anon, authenticated;
grant execute on function public.service_admin_get_access_profile(uuid) to service_role;
revoke all on function public.service_admin_set_permission(uuid,text,boolean,uuid) from public, anon, authenticated;
grant execute on function public.service_admin_set_permission(uuid,text,boolean,uuid) to service_role;
-- END RC MIGRATION 20260822114000_admin_rbac.sql

-- BEGIN RC MIGRATION 20260822133000_reschedule_paid_proposal_guard.sql
-- A paid reschedule penalty must never be orphaned by replacing its protected slot.
-- The existing implementation is retained as an internal helper; the public service RPC
-- adds the invariant before delegating to it.

alter function public.service_admin_create_reschedule_hold(uuid,timestamptz,timestamptz,uuid)
  rename to service_admin_create_reschedule_hold_unchecked;

revoke all on function public.service_admin_create_reschedule_hold_unchecked(uuid,timestamptz,timestamptz,uuid)
  from public, anon, authenticated, service_role;

create or replace function public.service_admin_create_reschedule_hold(
  p_appointment_id uuid,
  p_requested_start_at timestamptz,
  p_requested_at timestamptz default now(),
  p_admin_id uuid default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
begin
  if exists (
    select 1
    from public.appointment_policy_actions a
    join public.payment_transactions pt
      on pt.id = a.penalty_payment_transaction_id
    where a.appointment_id = p_appointment_id
      and a.action_type = 'RESCHEDULE'
      and a.status in ('PREVIEW','AWAITING_PENALTY_PAYMENT')
      and a.penalty_payment_transaction_id is not null
      and pt.payment_purpose = 'RESCHEDULE_PENALTY'
      and pt.status = 'APPROVED'
  ) then
    raise exception using
      errcode = 'P0001',
      message = 'RESCHEDULE_PAID_PROPOSAL_MUST_BE_APPLIED_OR_REVERSED';
  end if;

  return public.service_admin_create_reschedule_hold_unchecked(
    p_appointment_id,
    p_requested_start_at,
    p_requested_at,
    p_admin_id
  );
end;
$$;

revoke all on function public.service_admin_create_reschedule_hold(uuid,timestamptz,timestamptz,uuid)
  from public, anon, authenticated;
grant execute on function public.service_admin_create_reschedule_hold(uuid,timestamptz,timestamptz,uuid)
  to service_role;
-- END RC MIGRATION 20260822133000_reschedule_paid_proposal_guard.sql

-- BEGIN RC MIGRATION 20260822134000_cancellation_financial_settlement_guard.sql
-- Choosing refund or credit is a financial decision, even when cancellation itself
-- is operational. Enforce this invariant at the database boundary so a caller cannot
-- bypass the UI or Edge Function permission split.

create or replace function public.service_admin_assert_financial_settlement_permission(
  p_admin_id uuid
)
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  -- Null actors are reserved for trusted internal/test service-role calls. User-facing
  -- Edge Functions always resolve and pass a concrete admin id.
  if p_admin_id is null then return; end if;

  if not public.service_admin_has_permission(p_admin_id, 'FINANCE_MANAGE') then
    raise exception using errcode = 'P0001', message = 'ADMIN_PERMISSION_DENIED';
  end if;
end;
$$;

create or replace function public.enforce_cancellation_financial_settlement_permission()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.action_type = 'CANCEL'
     and new.settlement_choice in ('REFUND','CREDIT') then
    perform public.service_admin_assert_financial_settlement_permission(new.created_by_admin_id);
  end if;
  return new;
end;
$$;

drop trigger if exists appointment_policy_actions_financial_settlement_guard
  on public.appointment_policy_actions;
create trigger appointment_policy_actions_financial_settlement_guard
before insert or update of settlement_choice, created_by_admin_id
on public.appointment_policy_actions
for each row
execute function public.enforce_cancellation_financial_settlement_permission();

revoke all on function public.service_admin_assert_financial_settlement_permission(uuid)
  from public, anon, authenticated;
grant execute on function public.service_admin_assert_financial_settlement_permission(uuid)
  to service_role;

revoke all on function public.enforce_cancellation_financial_settlement_permission()
  from public, anon, authenticated;
-- END RC MIGRATION 20260822134000_cancellation_financial_settlement_guard.sql
