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
