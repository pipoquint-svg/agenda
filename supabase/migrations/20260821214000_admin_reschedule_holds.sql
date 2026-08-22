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
