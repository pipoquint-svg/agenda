-- Transactional workflows for the consolidated retained-settlement model.

create or replace function public.service_admin_create_reschedule_hold(
  p_appointment_id uuid,
  p_requested_start_at timestamptz,
  p_requested_at timestamptz,
  p_change_origin text,
  p_admin_id uuid default null
)
returns jsonb
language plpgsql volatile security definer set search_path=public as $$
declare
  v_appointment public.appointments%rowtype;
  v_preview jsonb; v_extras jsonb; v_hold jsonb; v_package_quote jsonb;
  v_hold_row public.checkout_holds%rowtype;
  v_hold_id uuid; v_action_id uuid; v_action_status text; v_previous record; v_settlement_id uuid;
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
  v_preview:=public.calculate_reservation_change(
    p_appointment_id,'RESCHEDULE',p_requested_at,p_change_origin,v_hold_row.commercial_value
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
      'new_contract_value',v_hold_row.commercial_value,'difference_due',v_preview->'difference_due','excess_amount',v_preview->'excess_amount'),
    case when p_change_origin='CLIENT' then 'CLIENT' else 'ADMIN' end);

  return jsonb_build_object(
    'policy_action_id',v_action_id,'settlement_id',v_settlement_id,'policy_action_status',v_action_status,
    'appointment_id',p_appointment_id,'change_origin',p_change_origin,'original_start_at',v_appointment.start_at,
    'new_slot',jsonb_build_object('checkout_hold_id',v_hold_id,'expires_at',v_hold_row.expires_at,
      'slot_start_at',v_hold_row.requested_start_at,'slot_end_at',v_hold_row.requested_end_at,
      'core_start_at',v_hold_row.core_start_at,'core_end_at',v_hold_row.core_end_at),
    'contract_value',v_preview->'contract_value','new_contract_value',v_hold_row.commercial_value,
    'penalty_percent',v_preview->'penalty_percent','penalty_retained',v_preview->'penalty_retained',
    'applicable_amount',v_preview->'applicable_amount','difference_due',v_preview->'difference_due',
    'excess_amount',v_preview->'excess_amount','prior_customer_reschedules',v_preview->'prior_customer_reschedules',
    'max_customer_reschedules',v_preview->'max_customer_reschedules','package_reconciliation',v_package_quote
  );
end;
$$;

-- Old admin signature may not infer whether staff is acting for the client or for
-- the operation. Force callers to migrate to the explicit-origin overload.
create or replace function public.service_admin_create_reschedule_hold(uuid,timestamptz,timestamptz,uuid)
returns jsonb language plpgsql volatile security definer set search_path=public as $$
begin raise exception using errcode='P0001',message='CHANGE_ORIGIN_REQUIRED'; end;
$$;

create or replace function public.service_admin_apply_reschedule(
  p_policy_action_id uuid,
  p_admin_id uuid default null
)
returns jsonb
language plpgsql volatile security definer set search_path=public as $$
declare
  v_action public.appointment_policy_actions%rowtype;
  v_settlement public.appointment_change_settlements%rowtype;
  v_appointment public.appointments%rowtype;
  v_hold public.checkout_holds%rowtype;
  v_package_reconciliation jsonb;
  v_current_funds numeric(12,2); v_after_penalty numeric(12,2); v_outstanding numeric(12,2);
  v_new_version integer; v_old_start timestamptz; v_old_end timestamptz; v_old_value numeric(12,2);
begin
  select * into v_action from public.appointment_policy_actions where id=p_policy_action_id for update;
  if not found or v_action.action_type<>'RESCHEDULE' then raise exception using errcode='P0001',message='INVALID_RESCHEDULE_ACTION'; end if;
  if v_action.status='APPLIED' then
    select * into v_appointment from public.appointments where id=v_action.appointment_id;
    return jsonb_build_object('policy_action_id',v_action.id,'appointment_id',v_action.appointment_id,'status','APPLIED','appointment_version',v_appointment.version,'already_applied',true);
  end if;
  if v_action.status not in ('PREVIEW','AWAITING_DIFFERENCE_PAYMENT') then raise exception using errcode='P0001',message='RESCHEDULE_ACTION_NOT_APPLICABLE'; end if;
  select * into v_settlement from public.appointment_change_settlements where policy_action_id=v_action.id;
  if not found then raise exception using errcode='P0001',message='CHANGE_SETTLEMENT_NOT_FOUND'; end if;

  select * into v_appointment from public.appointments where id=v_action.appointment_id for update;
  if not found or v_appointment.status<>'CONFIRMED' then raise exception using errcode='P0001',message='APPOINTMENT_NOT_RESCHEDULABLE'; end if;
  select * into v_hold from public.checkout_holds where id=v_action.reschedule_checkout_hold_id for update;
  if not found or v_hold.status<>'ACTIVE' or v_hold.expires_at<=now() then raise exception using errcode='P0001',message='RESCHEDULE_HOLD_EXPIRED'; end if;
  if v_hold.service_id<>v_appointment.service_id or v_hold.service_employee_id<>v_appointment.service_employee_id then raise exception using errcode='P0001',message='RESCHEDULE_HOLD_MISMATCH'; end if;

  -- Any contract payment or integral customer-balance application made after the
  -- preview can satisfy the difference. The penalty itself is never charged again.
  v_current_funds:=public.appointment_customer_funds_amount(v_appointment.id);
  v_after_penalty:=round(greatest(v_current_funds-v_settlement.penalty_retained,0),2);
  v_outstanding:=round(greatest(v_settlement.new_contract_value-v_after_penalty,0),2);
  if v_outstanding>0 then
    update public.appointment_policy_actions set status='AWAITING_DIFFERENCE_PAYMENT',difference_due=v_outstanding,updated_at=now() where id=v_action.id;
    raise exception using errcode='P0001',message='RESCHEDULE_DIFFERENCE_PAYMENT_REQUIRED',detail=jsonb_build_object('outstanding',v_outstanding)::text;
  end if;

  v_package_reconciliation:=public.service_reconcile_reschedule_package(v_appointment.id,v_hold.id,p_admin_id);
  v_old_start:=v_appointment.start_at; v_old_end:=v_appointment.end_at; v_old_value:=v_appointment.commercial_value;

  update public.resource_allocations set status='RELEASED',updated_at=now()
  where appointment_id=v_appointment.id and allocation_type='APPOINTMENT' and status in ('HELD','AWAITING_PAYMENT','CONFIRMED','BLOCKED');
  update public.resource_allocations set appointment_id=v_appointment.id,checkout_hold_id=null,allocation_type='APPOINTMENT',status='CONFIRMED',updated_at=now()
  where checkout_hold_id=v_hold.id and allocation_type='CHECKOUT_HOLD' and status='HELD';

  update public.appointments set
    start_at=v_hold.requested_start_at,end_at=v_hold.requested_end_at,core_start_at=v_hold.core_start_at,core_end_at=v_hold.core_end_at,
    pre_service_minutes=v_hold.pre_service_minutes,post_service_minutes=v_hold.post_service_minutes,schedule_profile_snapshot=v_hold.schedule_profile,
    duration_minutes=v_hold.duration_minutes,duration_blocks=v_hold.duration_blocks,contracted_minutes=v_hold.contracted_minutes,
    commercial_value=v_settlement.new_contract_value,version=version+1,updated_at=now()
  where id=v_appointment.id returning version into v_new_version;
  update public.checkout_holds set status='PROMOTED',promoted_appointment_id=v_appointment.id,updated_at=now() where id=v_hold.id;
  update public.appointment_policy_actions set status='APPLIED',difference_due=0,updated_at=now() where id=v_action.id;

  insert into public.integration_jobs(job_type,entity_type,entity_id,entity_version,payload_json,idempotency_key)
  values('GOOGLE_APPOINTMENT_SYNC','APPOINTMENT',v_appointment.id,v_new_version,jsonb_build_object('reason','APPOINTMENT_RESCHEDULED'),'google-appointment-sync:'||v_appointment.id::text||':'||v_new_version::text)
  on conflict(idempotency_key) do nothing;

  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
  values(p_admin_id,'APPOINTMENT',v_appointment.id,'APPOINTMENT_RESCHEDULED',
    jsonb_build_object('start_at',v_old_start,'end_at',v_old_end,'commercial_value',v_old_value,'version',v_appointment.version),
    jsonb_build_object('start_at',v_hold.requested_start_at,'end_at',v_hold.requested_end_at,'commercial_value',v_settlement.new_contract_value,
      'version',v_new_version,'policy_action_id',v_action.id,'change_origin',v_action.change_origin,
      'penalty_retained',v_settlement.penalty_retained,'excess_amount',greatest(v_after_penalty-v_settlement.new_contract_value,0),
      'package_reconciliation',v_package_reconciliation),'ADMIN');

  return jsonb_build_object('policy_action_id',v_action.id,'appointment_id',v_appointment.id,'status','APPLIED',
    'old_start_at',v_old_start,'new_start_at',v_hold.requested_start_at,'new_end_at',v_hold.requested_end_at,
    'old_contract_value',v_old_value,'new_contract_value',v_settlement.new_contract_value,
    'penalty_retained',v_settlement.penalty_retained,'difference_due',0,
    'excess_amount',round(greatest(v_after_penalty-v_settlement.new_contract_value,0),2),
    'appointment_version',v_new_version,'package_reconciliation',v_package_reconciliation,'google_sync_enqueued',true,'already_applied',false);
end;
$$;

create or replace function public.service_admin_cancel_appointment(
  p_appointment_id uuid,
  p_settlement_choice text,
  p_reason text,
  p_requested_at timestamptz,
  p_change_origin text,
  p_admin_id uuid default null
)
returns jsonb
language plpgsql volatile security definer set search_path=public as $$
declare
  v_appointment public.appointments%rowtype; v_preview jsonb; v_action_id uuid; v_settlement_id uuid; v_new_version integer;
  v_choice text:=nullif(upper(btrim(coalesce(p_settlement_choice,''))),''); v_status text; v_refund numeric(12,2); v_package_reversal_id uuid;
  v_existing public.appointment_policy_actions%rowtype;
begin
  if p_requested_at is null then raise exception using errcode='P0001',message='CANCELLATION_REQUESTED_AT_REQUIRED'; end if;
  if p_change_origin not in ('CLIENT','OPERATION') then raise exception using errcode='P0001',message='CHANGE_ORIGIN_REQUIRED'; end if;
  if v_choice='CREDIT' then raise exception using errcode='P0001',message='LEGACY_CANCELLATION_CREDIT_REMOVED'; end if;
  if v_choice='CUSTOMER_BALANCE' then raise exception using errcode='P0001',message='CUSTOMER_BALANCE_CHOICE_REQUIRES_AUTHORSHIP_RECORD'; end if;
  if v_choice is not null and v_choice<>'REFUND' then raise exception using errcode='P0001',message='INVALID_CANCELLATION_SETTLEMENT'; end if;

  select * into v_appointment from public.appointments where id=p_appointment_id and deleted_at is null for update;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if;
  if v_appointment.status='CANCELLED' then
    select * into v_existing from public.appointment_policy_actions where appointment_id=p_appointment_id and action_type='CANCEL' and status<>'VOIDED' order by created_at desc limit 1;
    return jsonb_build_object('appointment_id',p_appointment_id,'status','CANCELLED','already_cancelled',true,
      'policy_action_id',v_existing.id,'policy_action_status',v_existing.status,'settlement_choice',v_existing.settlement_choice,
      'refund_amount',v_existing.refundable_amount);
  end if;
  if v_appointment.status not in ('HELD','AWAITING_PAYMENT','CONFIRMED') then raise exception using errcode='P0001',message='APPOINTMENT_NOT_CANCELLABLE'; end if;

  v_preview:=public.calculate_reservation_change(p_appointment_id,'CANCEL',p_requested_at,p_change_origin,null);
  v_refund:=coalesce((v_preview->>'refund_due')::numeric,0);
  -- Refund is always the default. Customer balance is a later explicit financial
  -- choice carrying authorship evidence; if that choice fails, refund remains.
  v_choice:=case when v_refund>0 then 'REFUND' else null end;
  v_status:=case when v_refund>0 then 'PENDING_REFUND' else 'APPLIED' end;

  insert into public.appointment_policy_actions(
    appointment_id,action_type,status,settlement_choice,requested_at,original_start_at,
    hours_before_start,notice_hours_snapshot,is_inside_notice_window,prior_customer_reschedules,
    contract_value_snapshot,net_paid_snapshot,penalty_type,penalty_value,penalty_amount,
    refundable_amount,created_by_admin_id,change_origin,policy_schema_version,
    contract_applied_before,excess_before,applicable_amount,excess_amount,difference_due,refund_due
  ) values (
    p_appointment_id,'CANCEL',v_status,v_choice,p_requested_at,v_appointment.start_at,
    (v_preview->>'hours_before_start')::numeric,(v_preview->>'notice_hours')::integer,(v_preview->>'inside_notice_window')::boolean,
    (v_preview->>'prior_customer_reschedules')::integer,(v_preview->>'contract_value')::numeric,(v_preview->>'customer_funds_before')::numeric,
    'PERCENT'::public.change_penalty_type,(v_preview->>'penalty_percent')::numeric,(v_preview->>'penalty_retained')::numeric,
    v_refund,p_admin_id,p_change_origin,v_preview->>'snapshot_schema_version',
    (v_preview->>'contract_applied_before')::numeric,(v_preview->>'excess_before')::numeric,(v_preview->>'applicable_amount')::numeric,
    (v_preview->>'excess_amount')::numeric,0,v_refund
  ) returning id into v_action_id;
  v_settlement_id:=public.record_appointment_change_settlement(v_action_id,v_preview);

  update public.appointments set status='CANCELLED',cancelled_at=coalesce(cancelled_at,p_requested_at),
    cancel_reason=nullif(btrim(coalesce(p_reason,'')),''),hold_expires_at=null,version=version+1,updated_at=now()
  where id=p_appointment_id returning version into v_new_version;
  update public.resource_allocations set status='CANCELLED',updated_at=now()
  where appointment_id=p_appointment_id and allocation_type='APPOINTMENT' and status in ('HELD','AWAITING_PAYMENT','CONFIRMED','BLOCKED');
  update public.payment_transactions set status='EXPIRED',updated_at=now(),notes=concat_ws(' | ',nullif(notes,''),'APPOINTMENT_CANCELLED_BEFORE_PAYMENT_COMPLETION')
  where appointment_id=p_appointment_id and transaction_type='CHARGE' and status='PENDING';

  if exists(select 1 from public.appointment_package_usage apu where apu.appointment_id=p_appointment_id and apu.reversal_movement_id is null) then
    v_package_reversal_id:=public.reverse_hour_package_usage(p_appointment_id,'APPOINTMENT_CANCELLED',p_admin_id);
  end if;
  perform public.release_appointment_coupon_usage(p_appointment_id);
  insert into public.integration_jobs(job_type,entity_type,entity_id,entity_version,payload_json,idempotency_key)
  values('GOOGLE_APPOINTMENT_SYNC','APPOINTMENT',p_appointment_id,v_new_version,jsonb_build_object('reason','APPOINTMENT_CANCELLED'),'google-appointment-sync:'||p_appointment_id::text||':'||v_new_version::text)
  on conflict(idempotency_key) do nothing;

  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
  values(p_admin_id,'APPOINTMENT',p_appointment_id,'APPOINTMENT_CANCELLED',
    jsonb_build_object('status',v_appointment.status,'version',v_appointment.version,'start_at',v_appointment.start_at,'end_at',v_appointment.end_at),
    jsonb_build_object('status','CANCELLED','version',v_new_version,'policy_action_id',v_action_id,'settlement_id',v_settlement_id,
      'change_origin',p_change_origin,'penalty_retained',v_preview->'penalty_retained','refund_amount',v_refund,
      'excess_before',v_preview->'excess_before','settlement_choice',v_choice,'package_reversal_movement_id',v_package_reversal_id,
      'reason',nullif(btrim(coalesce(p_reason,'')),'')),'ADMIN');

  return jsonb_build_object('appointment_id',p_appointment_id,'status','CANCELLED','version',v_new_version,
    'policy_action_id',v_action_id,'settlement_id',v_settlement_id,'policy_action_status',v_status,'change_origin',p_change_origin,
    'settlement_choice',v_choice,'penalty_retained',v_preview->'penalty_retained','refund_amount',v_refund,
    'excess_refunded',v_preview->'excess_before','package_reversal_movement_id',v_package_reversal_id,
    'google_sync_enqueued',true,'already_cancelled',false);
end;
$$;

-- Old cancellation signature cannot infer CLIENT vs OPERATION.
create or replace function public.service_admin_cancel_appointment(uuid,text,text,timestamptz,uuid)
returns jsonb language plpgsql volatile security definer set search_path=public as $$
begin raise exception using errcode='P0001',message='CHANGE_ORIGIN_REQUIRED'; end;
$$;

revoke all on function public.service_admin_create_reschedule_hold(uuid,timestamptz,timestamptz,text,uuid) from public,anon,authenticated;
revoke all on function public.service_admin_apply_reschedule(uuid,uuid) from public,anon,authenticated;
revoke all on function public.service_admin_cancel_appointment(uuid,text,text,timestamptz,text,uuid) from public,anon,authenticated;
grant execute on function public.service_admin_create_reschedule_hold(uuid,timestamptz,timestamptz,text,uuid) to service_role;
grant execute on function public.service_admin_apply_reschedule(uuid,uuid) to service_role;
grant execute on function public.service_admin_cancel_appointment(uuid,text,text,timestamptz,text,uuid) to service_role;
