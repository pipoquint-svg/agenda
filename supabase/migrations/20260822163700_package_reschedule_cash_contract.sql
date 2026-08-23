-- Package-backed appointments store commercial_value as cash actually due after
-- package coverage. Rescheduling must preserve that semantic instead of replacing
-- it with the gross checkout quote used only to reserve the slot.

create or replace function public.service_admin_create_reschedule_hold(
  p_appointment_id uuid,
  p_requested_start_at timestamptz,
  p_requested_at timestamptz,
  p_change_origin text,
  p_admin_id uuid default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path=public
as $$
declare
  v_appointment public.appointments%rowtype;
  v_preview jsonb; v_extras jsonb; v_hold jsonb; v_package_quote jsonb;
  v_hold_row public.checkout_holds%rowtype;
  v_hold_id uuid; v_action_id uuid; v_action_status text; v_previous record; v_settlement_id uuid;
  v_new_contract_value numeric(12,2); v_package_cash_due numeric(12,2);
begin
  if p_requested_start_at is null or p_requested_at is null then raise exception using errcode='P0001',message='RESCHEDULE_TIME_REQUIRED'; end if;
  if p_change_origin not in ('CLIENT','OPERATION') then raise exception using errcode='P0001',message='CHANGE_ORIGIN_REQUIRED'; end if;
  select * into v_appointment from public.appointments where id=p_appointment_id and deleted_at is null for update;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if;
  if v_appointment.status<>'CONFIRMED' then raise exception using errcode='P0001',message='APPOINTMENT_NOT_RESCHEDULABLE'; end if;
  perform public.enforce_appointment_reschedule_limit(p_appointment_id,p_change_origin);

  for v_previous in
    select id,reschedule_checkout_hold_id from public.appointment_policy_actions
    where appointment_id=p_appointment_id and action_type='RESCHEDULE'
      and status in ('PREVIEW','AWAITING_DIFFERENCE_PAYMENT')
    for update
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

  v_hold:=public.create_checkout_hold_for_duration(
    v_appointment.service_id,v_appointment.service_employee_id,v_appointment.duration_blocks,
    v_extras,v_appointment.people_count,p_requested_start_at
  );
  v_hold_id:=(v_hold->>'checkout_hold_id')::uuid;
  update public.checkout_holds set primary_customer_id=v_appointment.primary_customer_id,updated_at=now() where id=v_hold_id;
  select * into v_hold_row from public.checkout_holds where id=v_hold_id;

  v_package_quote:=public.service_quote_reschedule_package_hold(p_appointment_id,v_hold_id);
  if coalesce((v_package_quote->>'uses_package')::boolean,false) then
    select apu.cash_due into v_package_cash_due
    from public.appointment_package_usage apu
    where apu.appointment_id=p_appointment_id and apu.reversal_movement_id is null;
    if v_package_cash_due is null then raise exception using errcode='P0001',message='RESCHEDULE_PACKAGE_USAGE_MISSING'; end if;
    v_new_contract_value:=round(v_package_cash_due,2);
  else
    v_new_contract_value:=round(v_hold_row.commercial_value,2);
  end if;

  v_preview:=public.calculate_reservation_change(
    p_appointment_id,'RESCHEDULE',p_requested_at,p_change_origin,v_new_contract_value
  );
  if coalesce((v_preview->>'customer_reschedule_limit_reached')::boolean,false) then
    raise exception using errcode='P0001',message='CLIENT_RESCHEDULE_LIMIT_REACHED';
  end if;
  v_action_status:=case when coalesce((v_preview->>'difference_due')::numeric,0)>0 then 'AWAITING_DIFFERENCE_PAYMENT' else 'PREVIEW' end;

  insert into public.appointment_policy_actions(
    appointment_id,action_type,status,requested_at,original_start_at,requested_new_start_at,
    hours_before_start,notice_hours_snapshot,is_inside_notice_window,prior_customer_reschedules,
    contract_value_snapshot,net_paid_snapshot,penalty_type,penalty_value,penalty_amount,
    refundable_amount,reschedule_checkout_hold_id,created_by_admin_id,change_origin,policy_schema_version,
    contract_applied_before,excess_before,applicable_amount,excess_amount,difference_due,refund_due
  ) values (
    p_appointment_id,'RESCHEDULE',v_action_status,p_requested_at,v_appointment.start_at,v_hold_row.requested_start_at,
    (v_preview->>'hours_before_start')::numeric,(v_preview->>'notice_hours')::integer,(v_preview->>'inside_notice_window')::boolean,
    (v_preview->>'prior_customer_reschedules')::integer,(v_preview->>'contract_value')::numeric,(v_preview->>'customer_funds_before')::numeric,
    'PERCENT'::public.change_penalty_type,(v_preview->>'penalty_percent')::numeric,(v_preview->>'penalty_retained')::numeric,
    0,v_hold_id,p_admin_id,p_change_origin,v_preview->>'snapshot_schema_version',
    (v_preview->>'contract_applied_before')::numeric,(v_preview->>'excess_before')::numeric,(v_preview->>'applicable_amount')::numeric,
    (v_preview->>'excess_amount')::numeric,(v_preview->>'difference_due')::numeric,0
  ) returning id into v_action_id;

  v_settlement_id:=public.record_appointment_change_settlement(v_action_id,v_preview);

  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,after_json,origin)
  values(p_admin_id,'APPOINTMENT',p_appointment_id,'RESCHEDULE_PREVIEW_CREATED',
    jsonb_build_object('policy_action_id',v_action_id,'settlement_id',v_settlement_id,'change_origin',p_change_origin,
      'penalty_retained',v_preview->'penalty_retained','applicable_amount',v_preview->'applicable_amount',
      'new_contract_value',v_new_contract_value,'difference_due',v_preview->'difference_due','excess_amount',v_preview->'excess_amount',
      'package_reconciliation',v_package_quote),
    case when p_change_origin='CLIENT' then 'CLIENT' else 'ADMIN' end);

  return jsonb_build_object(
    'policy_action_id',v_action_id,'settlement_id',v_settlement_id,'policy_action_status',v_action_status,
    'appointment_id',p_appointment_id,'change_origin',p_change_origin,'original_start_at',v_appointment.start_at,
    'new_slot',jsonb_build_object('checkout_hold_id',v_hold_id,'expires_at',v_hold_row.expires_at,
      'slot_start_at',v_hold_row.requested_start_at,'slot_end_at',v_hold_row.requested_end_at,
      'core_start_at',v_hold_row.core_start_at,'core_end_at',v_hold_row.core_end_at),
    'contract_value',v_preview->'contract_value','new_contract_value',v_new_contract_value,
    'payment_commitment_percent',v_preview->'payment_commitment_percent','confirmation_target_amount',v_preview->'confirmation_target_amount',
    'penalty_percent',v_preview->'penalty_percent','penalty_retained',v_preview->'penalty_retained',
    'applicable_amount',v_preview->'applicable_amount','difference_due',v_preview->'difference_due',
    'excess_amount',v_preview->'excess_amount','prior_customer_reschedules',v_preview->'prior_customer_reschedules',
    'max_customer_reschedules',v_preview->'max_customer_reschedules','package_reconciliation',v_package_quote
  );
end;
$$;
