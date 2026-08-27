
-- BEGIN RC MIGRATION 20260822163100_change_workflows_retained_settlement.sql
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
-- END RC MIGRATION 20260822163100_change_workflows_retained_settlement.sql

-- BEGIN RC MIGRATION 20260822163200_final_excess_and_balance_reporting.sql
-- Final settlement of customer-owned excess and accounting-facing balance report.

create table public.appointment_final_settlements (
  id uuid primary key default gen_random_uuid(),
  appointment_id uuid not null unique references public.appointments(id) on delete restrict,
  customer_id uuid not null references public.customers(id) on delete restrict,
  excess_amount numeric(12,2) not null check (excess_amount>0),
  settlement_choice text not null check (settlement_choice in ('REFUND','CUSTOMER_BALANCE')),
  status text not null check (status in ('PENDING_REFUND','BALANCE_CREDITED','REFUNDED','FAILED')),
  balance_movement_id uuid references public.customer_balance_movements(id) on delete restrict,
  choice_origin text check (choice_origin is null or choice_origin in ('CLIENT_TOKEN','ADMIN_UI')),
  admin_user_id uuid references public.admin_users(id) on delete restrict,
  admin_request_reference text,
  ip_address inet,
  user_agent text,
  request_id text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (
    settlement_choice='REFUND'
    or (
      balance_movement_id is not null and choice_origin is not null and ip_address is not null
      and nullif(btrim(user_agent),'') is not null and nullif(btrim(request_id),'') is not null
    )
  )
);
alter table public.appointment_final_settlements enable row level security;
revoke all on public.appointment_final_settlements from public,anon,authenticated;
grant select on public.appointment_final_settlements to service_role;

create or replace function public.appointment_returnable_excess(p_appointment_id uuid)
returns numeric(12,2)
language plpgsql stable set search_path=public as $$
declare v_appointment public.appointments%rowtype; v_funds numeric(12,2);
begin
  select * into v_appointment from public.appointments where id=p_appointment_id;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if;
  v_funds:=public.appointment_customer_funds_amount(p_appointment_id);
  return round(greatest(v_funds-coalesce(v_appointment.commercial_value,0),0),2);
end;
$$;

-- Explicit customer-balance conversion from a cancellation return. Excess from a
-- completed service uses service_finalize_appointment_excess instead.
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
  if not found or v_action.action_type<>'CANCEL' then raise exception using errcode='P0001',message='CANCELLATION_ACTION_REQUIRED_FOR_BALANCE_RETURN'; end if;
  select * into v_settlement from public.appointment_change_settlements where policy_action_id=v_action.id;
  if not found then raise exception using errcode='P0001',message='CHANGE_SETTLEMENT_NOT_FOUND'; end if;
  v_amount:=v_settlement.refund_due;
  if v_amount<=0 then raise exception using errcode='P0001',message='NO_RETURNABLE_AMOUNT'; end if;
  v_key:='balance-credit:'||p_appointment_id::text||':'||p_policy_action_id::text;
  insert into public.customer_balance_movements(customer_id,movement_type,direction,amount,appointment_id,policy_action_id,choice_origin,admin_user_id,admin_request_reference,ip_address,user_agent,request_id,idempotency_key)
  values(v_appointment.primary_customer_id,'CREDIT_FROM_RETURN','CREDIT',v_amount,p_appointment_id,p_policy_action_id,p_choice_origin,p_admin_id,nullif(btrim(p_admin_request_reference),''),p_ip,p_user_agent,p_request_id,v_key)
  on conflict(idempotency_key) do update set idempotency_key=excluded.idempotency_key returning id into v_id;
  update public.appointment_policy_actions set settlement_choice='CUSTOMER_BALANCE',status='APPLIED',updated_at=now() where id=v_action.id;
  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,after_json,origin)
  values(p_admin_id,'APPOINTMENT',p_appointment_id,'CUSTOMER_BALANCE_CREATED',jsonb_build_object('policy_action_id',v_action.id,'amount',v_amount,'customer_id',v_appointment.primary_customer_id,'choice_origin',p_choice_origin,'request_id',p_request_id),case when p_choice_origin='ADMIN_UI' then 'ADMIN' else 'CLIENT' end);
  return jsonb_build_object('movement_id',v_id,'customer_id',v_appointment.primary_customer_id,'amount',v_amount,'balance_available',public.customer_balance_available(v_appointment.primary_customer_id));
end;
$$;

create or replace function public.service_finalize_appointment_excess(
  p_appointment_id uuid,p_settlement_choice text,p_choice_origin text,p_admin_id uuid,
  p_ip inet,p_user_agent text,p_request_id text,p_admin_request_reference text
)
returns jsonb
language plpgsql volatile security definer set search_path=public as $$
declare
  v_appointment public.appointments%rowtype; v_amount numeric(12,2); v_choice text; v_existing public.appointment_final_settlements%rowtype;
  v_movement uuid; v_key text; v_final_id uuid;
begin
  select * into v_appointment from public.appointments where id=p_appointment_id for update;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if;
  if v_appointment.status<>'COMPLETED' then raise exception using errcode='P0001',message='FINAL_EXCESS_ONLY_AFTER_SERVICE_COMPLETED'; end if;
  if v_appointment.primary_customer_id is null then raise exception using errcode='P0001',message='APPOINTMENT_CUSTOMER_REQUIRED'; end if;

  select * into v_existing from public.appointment_final_settlements where appointment_id=p_appointment_id;
  if found then return jsonb_build_object('final_settlement_id',v_existing.id,'appointment_id',p_appointment_id,'excess_amount',v_existing.excess_amount,'settlement_choice',v_existing.settlement_choice,'status',v_existing.status,'idempotent_replay',true); end if;

  v_amount:=public.appointment_returnable_excess(p_appointment_id);
  if v_amount<=0 then raise exception using errcode='P0001',message='NO_FINAL_EXCESS_TO_SETTLE'; end if;
  v_choice:=coalesce(nullif(upper(btrim(coalesce(p_settlement_choice,''))),''),'REFUND');
  if v_choice='CREDIT' then raise exception using errcode='P0001',message='LEGACY_CANCELLATION_CREDIT_REMOVED'; end if;
  if v_choice not in ('REFUND','CUSTOMER_BALANCE') then raise exception using errcode='P0001',message='INVALID_FINAL_SETTLEMENT_CHOICE'; end if;

  if v_choice='CUSTOMER_BALANCE' then
    if p_choice_origin not in ('CLIENT_TOKEN','ADMIN_UI') or p_ip is null or nullif(btrim(p_user_agent),'') is null or nullif(btrim(p_request_id),'') is null then raise exception using errcode='P0001',message='BALANCE_AUTHORSHIP_EVIDENCE_REQUIRED'; end if;
    if p_choice_origin='ADMIN_UI' and (p_admin_id is null or nullif(btrim(p_admin_request_reference),'') is null) then raise exception using errcode='P0001',message='BALANCE_ADMIN_REQUEST_EVIDENCE_REQUIRED'; end if;
    v_key:='balance-final-excess:'||p_appointment_id::text;
    insert into public.customer_balance_movements(customer_id,movement_type,direction,amount,appointment_id,policy_action_id,choice_origin,admin_user_id,admin_request_reference,ip_address,user_agent,request_id,idempotency_key)
    values(v_appointment.primary_customer_id,'CREDIT_FROM_RETURN','CREDIT',v_amount,p_appointment_id,null,p_choice_origin,p_admin_id,nullif(btrim(p_admin_request_reference),''),p_ip,p_user_agent,p_request_id,v_key)
    returning id into v_movement;
  end if;

  insert into public.appointment_final_settlements(appointment_id,customer_id,excess_amount,settlement_choice,status,balance_movement_id,choice_origin,admin_user_id,admin_request_reference,ip_address,user_agent,request_id)
  values(p_appointment_id,v_appointment.primary_customer_id,v_amount,v_choice,case when v_choice='REFUND' then 'PENDING_REFUND' else 'BALANCE_CREDITED' end,v_movement,
    case when v_choice='CUSTOMER_BALANCE' then p_choice_origin else null end,case when v_choice='CUSTOMER_BALANCE' then p_admin_id else null end,
    case when v_choice='CUSTOMER_BALANCE' then nullif(btrim(p_admin_request_reference),'') else null end,
    case when v_choice='CUSTOMER_BALANCE' then p_ip else null end,case when v_choice='CUSTOMER_BALANCE' then p_user_agent else null end,
    case when v_choice='CUSTOMER_BALANCE' then p_request_id else null end)
  returning id into v_final_id;

  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,after_json,origin)
  values(p_admin_id,'APPOINTMENT',p_appointment_id,'APPOINTMENT_FINAL_EXCESS_SETTLED',jsonb_build_object('final_settlement_id',v_final_id,'excess_amount',v_amount,'settlement_choice',v_choice,'balance_movement_id',v_movement),case when p_choice_origin='CLIENT_TOKEN' then 'CLIENT' else 'ADMIN' end);
  return jsonb_build_object('final_settlement_id',v_final_id,'appointment_id',p_appointment_id,'excess_amount',v_amount,'settlement_choice',v_choice,'status',case when v_choice='REFUND' then 'PENDING_REFUND' else 'BALANCE_CREDITED' end,'balance_movement_id',v_movement,'idempotent_replay',false);
end;
$$;

-- Financial summary now separates penalties, customer balance and customer-owned excess.
create or replace function public.get_appointment_financial_summary(p_appointment_id uuid)
returns jsonb
language plpgsql stable set search_path=public as $$
declare
  v_appointment public.appointments%rowtype; v_cash numeric(12,2); v_balance_applied numeric(12,2); v_penalties numeric(12,2);
  v_funds numeric(12,2); v_contract_applied numeric(12,2); v_excess numeric(12,2); v_pending integer;
begin
  select * into v_appointment from public.appointments where id=p_appointment_id;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if;
  v_cash:=public.appointment_net_paid_amount(p_appointment_id);
  select coalesce(sum(amount),0)::numeric(12,2) into v_balance_applied from public.customer_balance_movements where appointment_id=p_appointment_id and movement_type='APPLY_TO_APPOINTMENT';
  select coalesce(sum(acs.penalty_retained),0)::numeric(12,2) into v_penalties
  from public.appointment_change_settlements acs join public.appointment_policy_actions apa on apa.id=acs.policy_action_id
  where acs.appointment_id=p_appointment_id and ((acs.action_type='RESCHEDULE' and apa.status='APPLIED') or acs.action_type='CANCEL');
  v_funds:=public.appointment_customer_funds_amount(p_appointment_id);
  v_contract_applied:=round(least(v_funds,coalesce(v_appointment.commercial_value,0)),2);
  v_excess:=round(greatest(v_funds-coalesce(v_appointment.commercial_value,0),0),2);
  select count(*)::integer into v_pending from public.payment_transactions where appointment_id=p_appointment_id and payment_purpose='CONTRACT' and transaction_type='CHARGE' and status='PENDING';
  return jsonb_build_object('appointment_id',p_appointment_id,'commercial_value',coalesce(v_appointment.commercial_value,0),
    'cash_contract_net',v_cash,'customer_balance_applied',v_balance_applied,'penalties_retained',v_penalties,
    'customer_funds_under_reservation',v_funds,'contract_applied',v_contract_applied,'customer_excess_held',v_excess,
    'contract_balance',round(greatest(coalesce(v_appointment.commercial_value,0)-v_contract_applied,0),2),
    'pending_charge_count',v_pending,'financial_status',v_appointment.financial_status);
end;
$$;

create or replace function public.service_finance_customer_balance_report(p_from timestamptz,p_to timestamptz)
returns jsonb
language plpgsql stable security definer set search_path=public as $$
declare v_open numeric(12,2); v_credits numeric(12,2); v_applied numeric(12,2); v_refunds numeric(12,2);
begin
  if p_from is null or p_to is null or p_to<=p_from then raise exception using errcode='P0001',message='INVALID_REPORT_PERIOD'; end if;
  select coalesce(sum(public.customer_balance_available(c.id)),0)::numeric(12,2) into v_open from public.customers c;
  select coalesce(sum(amount) filter(where movement_type='CREDIT_FROM_RETURN'),0)::numeric(12,2),coalesce(sum(amount) filter(where movement_type='APPLY_TO_APPOINTMENT'),0)::numeric(12,2)
  into v_credits,v_applied from public.customer_balance_movements where created_at>=p_from and created_at<p_to;
  select coalesce(sum(amount),0)::numeric(12,2) into v_refunds from public.customer_balance_refund_requests where requested_at>=p_from and requested_at<p_to;
  return jsonb_build_object('period_from',p_from,'period_to',p_to,'customer_balance_open_liability',v_open,'balance_credited_in_period',v_credits,'balance_applied_to_reservations_in_period',v_applied,'balance_refund_requests_in_period',v_refunds,'accounting_classification','LIABILITY_NOT_REVENUE');
end;
$$;

revoke all on function public.appointment_returnable_excess(uuid) from public,anon,authenticated;
revoke all on function public.service_finalize_appointment_excess(uuid,text,text,uuid,inet,text,text,text) from public,anon,authenticated;
revoke all on function public.service_finance_customer_balance_report(timestamptz,timestamptz) from public,anon,authenticated;
grant execute on function public.appointment_returnable_excess(uuid) to service_role;
grant execute on function public.service_finalize_appointment_excess(uuid,text,text,uuid,inet,text,text,text) to service_role;
grant execute on function public.service_finance_customer_balance_report(timestamptz,timestamptz) to service_role;
-- END RC MIGRATION 20260822163200_final_excess_and_balance_reporting.sql

-- BEGIN RC MIGRATION 20260822163300_refund_default_finance_guard.sql
-- Refund is the safe automatic default, not an admin settlement choice.
-- Only diverting customer money to CUSTOMER_BALANCE is an explicit financial
-- decision at cancellation time. Executing the provider/manual refund remains
-- separately protected by FINANCE_MANAGE in the Edge/API layer.

create or replace function public.enforce_cancellation_financial_settlement_permission()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
begin
  if new.action_type='CANCEL' and new.settlement_choice='CUSTOMER_BALANCE' then
    perform public.service_admin_assert_financial_settlement_permission(new.created_by_admin_id);
  end if;
  return new;
end;
$$;

comment on function public.enforce_cancellation_financial_settlement_permission() is
'Allows REFUND as automatic safe default. CUSTOMER_BALANCE requires a finance-authorized actor; provider/manual refund execution is permission-gated separately.';
-- END RC MIGRATION 20260822163300_refund_default_finance_guard.sql

-- BEGIN RC MIGRATION 20260822163400_customer_owned_cash_basis.sql
-- Customer-owned money is actual cash received plus customer balance applied.
-- Contract settlement may be larger because of payment discounts; that difference is
-- not customer property and must never be refunded or converted into customer balance.

create or replace function public.appointment_net_cash_received_amount(p_appointment_id uuid)
returns numeric(12,2)
language sql
stable
set search_path=public
as $$
  select round(greatest(
    coalesce(sum(pt.cash_amount) filter (
      where pt.payment_purpose='CONTRACT'
        and pt.transaction_type='CHARGE'
        and pt.status in ('APPROVED','PARTIALLY_REFUNDED','REFUNDED')
    ),0)
    - coalesce(sum(pt.cash_amount) filter (
      where pt.payment_purpose='CONTRACT'
        and pt.transaction_type='REFUND'
        and pt.status in ('APPROVED','REFUNDED')
    ),0),
    0
  ),2)::numeric(12,2)
  from public.payment_transactions pt
  where pt.appointment_id=p_appointment_id;
$$;

create or replace function public.appointment_customer_funds_amount(p_appointment_id uuid)
returns numeric(12,2)
language sql
stable
set search_path=public
as $$
  select round(greatest(
    public.appointment_net_cash_received_amount(p_appointment_id)
    + coalesce((
      select sum(cbm.amount)
      from public.customer_balance_movements cbm
      where cbm.appointment_id=p_appointment_id
        and cbm.movement_type='APPLY_TO_APPOINTMENT'
        and cbm.direction='DEBIT'
    ),0)
    - coalesce((
      select sum(acs.penalty_retained)
      from public.appointment_change_settlements acs
      join public.appointment_policy_actions apa on apa.id=acs.policy_action_id
      where acs.appointment_id=p_appointment_id
        and acs.action_type='RESCHEDULE'
        and apa.status='APPLIED'
    ),0),
    0
  ),2)::numeric(12,2);
$$;

create or replace function public.get_appointment_financial_summary(p_appointment_id uuid)
returns jsonb
language plpgsql
stable
set search_path=public
as $$
declare
  v_appointment public.appointments%rowtype;
  v_contract_settled numeric(12,2);
  v_cash numeric(12,2);
  v_balance_applied numeric(12,2);
  v_penalties numeric(12,2);
  v_funds numeric(12,2);
  v_customer_contract_cover numeric(12,2);
  v_excess numeric(12,2);
  v_pending integer;
begin
  select * into v_appointment from public.appointments where id=p_appointment_id;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if;

  v_contract_settled:=public.appointment_net_paid_amount(p_appointment_id);
  v_cash:=public.appointment_net_cash_received_amount(p_appointment_id);
  select coalesce(sum(amount),0)::numeric(12,2)
    into v_balance_applied
  from public.customer_balance_movements
  where appointment_id=p_appointment_id and movement_type='APPLY_TO_APPOINTMENT';

  select coalesce(sum(acs.penalty_retained),0)::numeric(12,2)
    into v_penalties
  from public.appointment_change_settlements acs
  join public.appointment_policy_actions apa on apa.id=acs.policy_action_id
  where acs.appointment_id=p_appointment_id
    and ((acs.action_type='RESCHEDULE' and apa.status='APPLIED') or acs.action_type='CANCEL');

  v_funds:=public.appointment_customer_funds_amount(p_appointment_id);
  v_customer_contract_cover:=round(least(v_funds,coalesce(v_appointment.commercial_value,0)),2);
  v_excess:=round(greatest(v_funds-coalesce(v_appointment.commercial_value,0),0),2);

  select count(*)::integer into v_pending
  from public.payment_transactions
  where appointment_id=p_appointment_id
    and payment_purpose='CONTRACT'
    and transaction_type='CHARGE'
    and status='PENDING';

  return jsonb_build_object(
    'appointment_id',p_appointment_id,
    'commercial_value',coalesce(v_appointment.commercial_value,0),
    'contract_settled',v_contract_settled,
    'cash_received',v_cash,
    'cash_contract_net',v_cash,
    'customer_balance_applied',v_balance_applied,
    'penalties_retained',v_penalties,
    'customer_funds_under_reservation',v_funds,
    'customer_cash_cover_of_contract',v_customer_contract_cover,
    'customer_excess_held',v_excess,
    'contract_balance',round(greatest(coalesce(v_appointment.commercial_value,0)-v_contract_settled-v_balance_applied,0),2),
    'pending_charge_count',v_pending,
    'financial_status',v_appointment.financial_status
  );
end;
$$;

revoke all on function public.appointment_net_cash_received_amount(uuid) from public,anon,authenticated;
grant execute on function public.appointment_net_cash_received_amount(uuid) to service_role;

comment on function public.appointment_customer_funds_amount(uuid) is
'Actual customer-owned money under the reservation: net contract cash plus customer balance applied, less already-applied reschedule penalties. Payment discounts are excluded.';
-- END RC MIGRATION 20260822163400_customer_owned_cash_basis.sql

-- BEGIN RC MIGRATION 20260822163500_dashboard_change_pending_semantics.sql
-- Dashboard pending-center semantics after retained-penalty migration.
-- Patch the authoritative read model without duplicating the large function body.
do $$
declare
  v_definition text;
begin
  select pg_get_functiondef('public.service_admin_get_dashboard(timestamptz,timestamptz,text)'::regprocedure)
    into v_definition;
  if v_definition is null then
    raise exception using errcode='P0001',message='ADMIN_DASHBOARD_FUNCTION_MISSING';
  end if;
  if position('RESCHEDULE_PENALTY_PENDING' in v_definition)=0
     or position('AWAITING_PENALTY_PAYMENT' in v_definition)=0 then
    raise exception using errcode='P0001',message='ADMIN_DASHBOARD_LEGACY_PENDING_SIGNATURE_NOT_FOUND';
  end if;
  v_definition:=replace(v_definition,'RESCHEDULE_PENALTY_PENDING','RESCHEDULE_DIFFERENCE_PENDING');
  v_definition:=replace(v_definition,'AWAITING_PENALTY_PAYMENT','AWAITING_DIFFERENCE_PAYMENT');
  execute v_definition;
end;
$$;

comment on function public.service_admin_get_dashboard(timestamptz,timestamptz,text) is
'Dashboard V1 read model. Reschedule pending items represent contractual difference still due, never a separate penalty charge.';
-- END RC MIGRATION 20260822163500_dashboard_change_pending_semantics.sql

-- BEGIN RC MIGRATION 20260822163600_reschedule_commitment_and_contract_coverage.sql
-- Preserve the reservation's effective payment commitment across reschedules.
-- Contract settlement and customer-owned cash are intentionally different:
-- PIX discounts settle contract value but are never refundable customer money.

create or replace function public.appointment_net_contract_settled_amount(p_appointment_id uuid)
returns numeric(12,2)
language sql
stable
set search_path=public
as $$
  select round(greatest(
    coalesce(sum(pt.contract_amount_settled) filter (
      where pt.payment_purpose='CONTRACT'
        and pt.transaction_type='CHARGE'
        and pt.status in ('APPROVED','PARTIALLY_REFUNDED','REFUNDED')
    ),0)
    - coalesce(sum(pt.contract_amount_settled) filter (
      where pt.payment_purpose='CONTRACT'
        and pt.transaction_type='REFUND'
        and pt.status in ('APPROVED','REFUNDED')
    ),0),
    0
  ),2)::numeric(12,2)
  from public.payment_transactions pt
  where pt.appointment_id=p_appointment_id;
$$;

create or replace function public.appointment_contract_coverage_amount(p_appointment_id uuid)
returns numeric(12,2)
language sql
stable
set search_path=public
as $$
  select round(greatest(
    public.appointment_net_contract_settled_amount(p_appointment_id)
    + coalesce((
      select sum(cbm.amount)
      from public.customer_balance_movements cbm
      where cbm.appointment_id=p_appointment_id
        and cbm.movement_type='APPLY_TO_APPOINTMENT'
        and cbm.direction='DEBIT'
    ),0)
    - coalesce((
      select sum(acs.penalty_retained)
      from public.appointment_change_settlements acs
      join public.appointment_policy_actions apa on apa.id=acs.policy_action_id
      where acs.appointment_id=p_appointment_id
        and acs.action_type='RESCHEDULE'
        and apa.status='APPLIED'
    ),0),
    0
  ),2)::numeric(12,2);
$$;

create or replace function public.get_appointment_financial_summary(p_appointment_id uuid)
returns jsonb
language plpgsql
stable
set search_path=public
as $$
declare
  v_appointment public.appointments%rowtype;
  v_contract_payment numeric(12,2);
  v_contract_coverage numeric(12,2);
  v_cash numeric(12,2);
  v_balance_applied numeric(12,2);
  v_penalties numeric(12,2);
  v_funds numeric(12,2);
  v_customer_contract_cover numeric(12,2);
  v_excess numeric(12,2);
  v_pending integer;
begin
  select * into v_appointment from public.appointments where id=p_appointment_id;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if;

  v_contract_payment:=public.appointment_net_contract_settled_amount(p_appointment_id);
  v_contract_coverage:=public.appointment_contract_coverage_amount(p_appointment_id);
  v_cash:=public.appointment_net_cash_received_amount(p_appointment_id);

  select coalesce(sum(amount),0)::numeric(12,2)
    into v_balance_applied
  from public.customer_balance_movements
  where appointment_id=p_appointment_id and movement_type='APPLY_TO_APPOINTMENT';

  select coalesce(sum(acs.penalty_retained),0)::numeric(12,2)
    into v_penalties
  from public.appointment_change_settlements acs
  join public.appointment_policy_actions apa on apa.id=acs.policy_action_id
  where acs.appointment_id=p_appointment_id
    and ((acs.action_type='RESCHEDULE' and apa.status='APPLIED') or acs.action_type='CANCEL');

  v_funds:=public.appointment_customer_funds_amount(p_appointment_id);
  v_customer_contract_cover:=round(least(v_funds,coalesce(v_appointment.commercial_value,0)),2);
  v_excess:=round(greatest(v_funds-coalesce(v_appointment.commercial_value,0),0),2);

  select count(*)::integer into v_pending
  from public.payment_transactions
  where appointment_id=p_appointment_id
    and payment_purpose='CONTRACT'
    and transaction_type='CHARGE'
    and status='PENDING';

  return jsonb_build_object(
    'appointment_id',p_appointment_id,
    'commercial_value',coalesce(v_appointment.commercial_value,0),
    'contract_payment_settled',v_contract_payment,
    'contract_settled',v_contract_coverage,
    'contract_coverage',v_contract_coverage,
    'cash_received',v_cash,
    'cash_contract_net',v_cash,
    'customer_balance_applied',v_balance_applied,
    'penalties_retained',v_penalties,
    'customer_funds_under_reservation',v_funds,
    'customer_cash_cover_of_contract',v_customer_contract_cover,
    'customer_excess_held',v_excess,
    'contract_balance',round(greatest(coalesce(v_appointment.commercial_value,0)-v_contract_coverage,0),2),
    'pending_charge_count',v_pending,
    'financial_status',v_appointment.financial_status
  );
end;
$$;

alter table public.appointment_change_settlements
  add column contract_coverage_before numeric(12,2),
  add column payment_commitment_percent numeric(5,2),
  add column confirmation_target_amount numeric(12,2);

update public.appointment_change_settlements
set contract_coverage_before=contract_applied_before,
    payment_commitment_percent=case when contract_value<=0 then 100 else 50 end,
    confirmation_target_amount=case when contract_value<=0 then 0 else round(contract_value*0.50,2) end
where contract_coverage_before is null;

alter table public.appointment_change_settlements
  alter column contract_coverage_before set not null,
  alter column payment_commitment_percent set not null,
  alter column confirmation_target_amount set not null,
  add constraint appointment_change_settlements_contract_coverage_check check (contract_coverage_before>=0),
  add constraint appointment_change_settlements_commitment_check check (payment_commitment_percent in (0,50,100)),
  add constraint appointment_change_settlements_confirmation_target_check check (confirmation_target_amount>=0);

create or replace function public.calculate_reservation_change(
  p_appointment_id uuid,
  p_action_type text,
  p_requested_at timestamptz,
  p_change_origin text,
  p_new_contract_value numeric
)
returns jsonb
language plpgsql
stable
set search_path=public
as $$
declare
  v_appointment public.appointments%rowtype;
  v_snapshot public.appointment_change_policy_snapshots%rowtype;
  v_policy jsonb; v_schema text; v_notice integer; v_seconds numeric; v_hours numeric(12,2); v_inside boolean;
  v_count integer; v_contract numeric(12,2); v_funds numeric(12,2); v_applied numeric(12,2); v_excess_before numeric(12,2);
  v_contract_coverage numeric(12,2); v_contract_coverage_after numeric(12,2); v_commitment numeric(5,2); v_target numeric(12,2);
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
  v_contract_coverage:=round(public.appointment_contract_coverage_amount(p_appointment_id),2);

  if v_appointment.billing_mode_snapshot='INVOICE' or v_appointment.financial_status='UNPAID_AUTHORIZED' then
    v_commitment:=0;
  elsif v_contract<=0 then
    v_commitment:=100;
  elsif v_contract_coverage>=v_contract then
    v_commitment:=100;
  else
    -- Normal checkout reservations are confirmed at exactly 50% or 100%.
    -- A partially paid confirmed reservation therefore preserves the 50% target.
    v_commitment:=50;
  end if;

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
    else v_percent:=0; v_theoretical:=round(v_legacy_value,2);
    end if;
  end if;

  if v_theoretical=0 then v_theoretical:=round(v_contract*v_percent/100,2); end if;
  v_retained:=case when p_change_origin='OPERATION' then 0 else round(least(v_theoretical,v_applied),2) end;
  v_after:=round(greatest(v_funds-v_retained,0),2);
  v_contract_coverage_after:=round(greatest(v_contract_coverage-v_retained,0),2);

  if p_action_type='RESCHEDULE' then
    v_target:=round(p_new_contract_value*v_commitment/100,2);
    v_applicable:=round(least(v_after,p_new_contract_value),2);
    v_excess_after:=round(greatest(v_after-p_new_contract_value,0),2);
    v_difference:=round(greatest(v_target-v_contract_coverage_after,0),2);
  else
    v_target:=0;
    v_applicable:=round(greatest(v_applied-v_retained,0),2);
    v_excess_after:=v_excess_before;
    v_refund:=round(v_applicable+v_excess_before,2);
  end if;

  return jsonb_build_object(
    'appointment_id',p_appointment_id,'service_id',v_appointment.service_id,'action_type',p_action_type,'change_origin',p_change_origin,
    'requested_at',p_requested_at,'original_start_at',v_appointment.start_at,'hours_before_start',v_hours,'notice_hours',v_notice,
    'inside_notice_window',v_inside,'prior_customer_reschedules',v_count,'max_customer_reschedules',v_snapshot.max_customer_reschedules,
    'contract_value',v_contract,'new_contract_value',p_new_contract_value,'customer_funds_before',v_funds,
    'contract_applied_before',v_applied,'excess_before',v_excess_before,'contract_coverage_before',v_contract_coverage,
    'payment_commitment_percent',v_commitment,'confirmation_target_amount',v_target,
    'penalty_percent',v_percent,'theoretical_penalty',v_theoretical,'penalty_retained',v_retained,'penalty_amount',v_retained,
    'customer_funds_after_penalty',v_after,'contract_coverage_after_penalty',v_contract_coverage_after,
    'applicable_amount',v_applicable,'excess_amount',v_excess_after,
    'difference_due',v_difference,'refund_due',v_refund,'refundable_amount',v_refund,
    'customer_reschedule_limit_reached',(p_action_type='RESCHEDULE' and p_change_origin='CLIENT' and v_count>=v_snapshot.max_customer_reschedules),
    'snapshot_schema_version',v_schema
  );
end;
$$;

create or replace function public.record_appointment_change_settlement(
  p_policy_action_id uuid,
  p_preview jsonb
)
returns uuid
language plpgsql
volatile
security definer
set search_path=public
as $$
declare v_action public.appointment_policy_actions%rowtype; v_customer uuid; v_id uuid;
begin
  select * into v_action from public.appointment_policy_actions where id=p_policy_action_id for update;
  if not found then raise exception using errcode='P0001',message='CHANGE_ACTION_NOT_FOUND'; end if;
  select primary_customer_id into v_customer from public.appointments where id=v_action.appointment_id;
  if v_customer is null then raise exception using errcode='P0001',message='APPOINTMENT_CUSTOMER_REQUIRED'; end if;

  insert into public.appointment_change_settlements(
    policy_action_id,appointment_id,customer_id,action_type,change_origin,contract_value,new_contract_value,
    customer_funds_before,contract_applied_before,excess_before,contract_coverage_before,payment_commitment_percent,confirmation_target_amount,
    penalty_percent,theoretical_penalty,penalty_retained,customer_funds_after_penalty,applicable_amount,excess_after,difference_due,refund_due
  ) values (
    p_policy_action_id,v_action.appointment_id,v_customer,v_action.action_type,v_action.change_origin,
    (p_preview->>'contract_value')::numeric,(p_preview->>'new_contract_value')::numeric,
    (p_preview->>'customer_funds_before')::numeric,(p_preview->>'contract_applied_before')::numeric,(p_preview->>'excess_before')::numeric,
    (p_preview->>'contract_coverage_before')::numeric,(p_preview->>'payment_commitment_percent')::numeric,(p_preview->>'confirmation_target_amount')::numeric,
    (p_preview->>'penalty_percent')::numeric,(p_preview->>'theoretical_penalty')::numeric,(p_preview->>'penalty_retained')::numeric,
    (p_preview->>'customer_funds_after_penalty')::numeric,(p_preview->>'applicable_amount')::numeric,(p_preview->>'excess_amount')::numeric,
    (p_preview->>'difference_due')::numeric,(p_preview->>'refund_due')::numeric
  ) returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.service_apply_customer_balance_to_appointment(
  p_appointment_id uuid,p_policy_action_id uuid,p_choice_origin text,p_admin_id uuid,
  p_ip inet,p_user_agent text,p_request_id text,p_admin_request_reference text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path=public
as $$
declare
  v_appointment public.appointments%rowtype; v_balance numeric(12,2); v_due numeric(12,2); v_coverage numeric(12,2);
  v_settlement public.appointment_change_settlements%rowtype; v_key text; v_id uuid;
begin
  if p_choice_origin not in ('CLIENT_TOKEN','ADMIN_UI') or p_ip is null or nullif(btrim(p_user_agent),'') is null or nullif(btrim(p_request_id),'') is null then
    raise exception using errcode='P0001',message='BALANCE_AUTHORSHIP_EVIDENCE_REQUIRED';
  end if;
  if p_choice_origin='ADMIN_UI' and (p_admin_id is null or nullif(btrim(p_admin_request_reference),'') is null) then
    raise exception using errcode='P0001',message='BALANCE_ADMIN_REQUEST_EVIDENCE_REQUIRED';
  end if;
  select * into v_appointment from public.appointments where id=p_appointment_id for update;
  if not found or v_appointment.primary_customer_id is null then raise exception using errcode='P0001',message='APPOINTMENT_CUSTOMER_REQUIRED'; end if;
  v_balance:=public.customer_balance_available(v_appointment.primary_customer_id);
  if v_balance<=0 then raise exception using errcode='P0001',message='CUSTOMER_BALANCE_EMPTY'; end if;

  if p_policy_action_id is null then
    v_due:=round(greatest(coalesce(v_appointment.commercial_value,0)-public.appointment_contract_coverage_amount(p_appointment_id),0),2);
  else
    select * into v_settlement from public.appointment_change_settlements
    where policy_action_id=p_policy_action_id and appointment_id=p_appointment_id;
    if not found or v_settlement.action_type<>'RESCHEDULE' then raise exception using errcode='P0001',message='CHANGE_SETTLEMENT_NOT_FOUND'; end if;
    v_coverage:=round(greatest(public.appointment_contract_coverage_amount(p_appointment_id)-v_settlement.penalty_retained,0),2);
    v_due:=round(greatest(v_settlement.confirmation_target_amount-v_coverage,0),2);
  end if;
  if v_due<=0 then raise exception using errcode='P0001',message='NO_AMOUNT_DUE_FOR_BALANCE_APPLICATION'; end if;

  v_key:='balance-apply:'||p_appointment_id::text||':'||coalesce(p_policy_action_id::text,'BOOKING');
  insert into public.customer_balance_movements(
    customer_id,movement_type,direction,amount,appointment_id,policy_action_id,choice_origin,admin_user_id,
    admin_request_reference,ip_address,user_agent,request_id,idempotency_key
  ) values (
    v_appointment.primary_customer_id,'APPLY_TO_APPOINTMENT','DEBIT',v_balance,p_appointment_id,p_policy_action_id,p_choice_origin,p_admin_id,
    nullif(btrim(p_admin_request_reference),''),p_ip,p_user_agent,p_request_id,v_key
  )
  on conflict(idempotency_key) do update set idempotency_key=excluded.idempotency_key
  returning id into v_id;

  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,after_json,origin)
  values(p_admin_id,'APPOINTMENT',p_appointment_id,'CUSTOMER_BALANCE_APPLIED',
    jsonb_build_object('movement_id',v_id,'policy_action_id',p_policy_action_id,'amount',v_balance,'amount_due_before',v_due,'request_id',p_request_id),
    case when p_choice_origin='ADMIN_UI' then 'ADMIN' else 'CLIENT' end);

  return jsonb_build_object(
    'movement_id',v_id,'appointment_id',p_appointment_id,'policy_action_id',p_policy_action_id,
    'amount_applied',v_balance,'amount_due_before',v_due,
    'balance_available',public.customer_balance_available(v_appointment.primary_customer_id),
    'customer_funds_under_reservation',public.appointment_customer_funds_amount(p_appointment_id),
    'contract_coverage',public.appointment_contract_coverage_amount(p_appointment_id)
  );
end;
$$;

create or replace function public.service_create_reschedule_difference_payment_intent(
  p_policy_action_id uuid,
  p_method text,
  p_idempotency_key text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path=public
as $$
declare
  v_action public.appointment_policy_actions%rowtype;
  v_settlement public.appointment_change_settlements%rowtype;
  v_existing public.payment_transactions%rowtype;
  v_coverage numeric(12,2); v_outstanding numeric(12,2); v_discount_percent numeric(5,2); v_discount numeric(12,2); v_cash numeric(12,2); v_id uuid;
  v_method text:=upper(btrim(coalesce(p_method,'')));
begin
  if v_method not in ('PIX','CARD') then raise exception using errcode='P0001',message='PUBLIC_PAYMENT_METHOD_NOT_ALLOWED'; end if;
  if nullif(btrim(p_idempotency_key),'') is null then raise exception using errcode='P0001',message='IDEMPOTENCY_KEY_REQUIRED'; end if;

  select * into v_existing from public.payment_transactions where idempotency_key=p_idempotency_key;
  if found then
    if v_existing.policy_action_id is distinct from p_policy_action_id or v_existing.method<>v_method then
      raise exception using errcode='P0001',message='IDEMPOTENCY_KEY_CONFLICT';
    end if;
    return jsonb_build_object(
      'transaction_id',v_existing.id,'policy_action_id',p_policy_action_id,'appointment_id',v_existing.appointment_id,
      'status',v_existing.status,'contract_amount_settled',v_existing.contract_amount_settled,
      'payment_discount_amount',v_existing.payment_discount_amount,'cash_amount',v_existing.cash_amount,
      'method',v_existing.method,'provider',v_existing.provider,'idempotent_replay',true
    );
  end if;

  select * into v_action from public.appointment_policy_actions where id=p_policy_action_id for update;
  if not found or v_action.action_type<>'RESCHEDULE' or v_action.status not in ('AWAITING_DIFFERENCE_PAYMENT','PREVIEW') then
    raise exception using errcode='P0001',message='RESCHEDULE_ACTION_NOT_PAYABLE';
  end if;
  select * into v_settlement from public.appointment_change_settlements where policy_action_id=v_action.id;
  if not found then raise exception using errcode='P0001',message='CHANGE_SETTLEMENT_NOT_FOUND'; end if;

  v_coverage:=round(greatest(public.appointment_contract_coverage_amount(v_action.appointment_id)-v_settlement.penalty_retained,0),2);
  v_outstanding:=round(greatest(v_settlement.confirmation_target_amount-v_coverage,0),2);
  if v_outstanding<=0 then raise exception using errcode='P0001',message='RESCHEDULE_DIFFERENCE_ALREADY_SATISFIED'; end if;

  select pix_discount_percent into v_discount_percent from public.operation_settings where id=1;
  v_discount:=case when v_method='PIX' then round(v_outstanding*v_discount_percent/100,2) else 0 end;
  v_cash:=round(v_outstanding-v_discount,2);

  insert into public.payment_transactions(
    appointment_id,transaction_type,method,provider,status,contract_amount_settled,payment_discount_amount,cash_amount,
    idempotency_key,requested_percentage,payment_purpose,policy_action_id
  ) values (
    v_action.appointment_id,'CHARGE',v_method,'MERCADO_PAGO','PENDING',v_outstanding,v_discount,v_cash,
    p_idempotency_key,null,'CONTRACT',v_action.id
  ) returning id into v_id;

  return jsonb_build_object(
    'transaction_id',v_id,'policy_action_id',v_action.id,'appointment_id',v_action.appointment_id,
    'status','PENDING','payment_kind','RESCHEDULE_DIFFERENCE','contract_amount_settled',v_outstanding,
    'payment_discount_amount',v_discount,'cash_amount',v_cash,'method',v_method,'provider','MERCADO_PAGO','idempotent_replay',false
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
set search_path=public
as $$
declare
  v_action public.appointment_policy_actions%rowtype;
  v_settlement public.appointment_change_settlements%rowtype;
  v_appointment public.appointments%rowtype;
  v_hold public.checkout_holds%rowtype;
  v_package_reconciliation jsonb;
  v_coverage numeric(12,2); v_after_penalty numeric(12,2); v_outstanding numeric(12,2); v_customer_after_penalty numeric(12,2);
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

  v_coverage:=public.appointment_contract_coverage_amount(v_appointment.id);
  v_after_penalty:=round(greatest(v_coverage-v_settlement.penalty_retained,0),2);
  v_outstanding:=round(greatest(v_settlement.confirmation_target_amount-v_after_penalty,0),2);
  if v_outstanding>0 then
    update public.appointment_policy_actions set status='AWAITING_DIFFERENCE_PAYMENT',difference_due=v_outstanding,updated_at=now() where id=v_action.id;
    raise exception using errcode='P0001',message='RESCHEDULE_DIFFERENCE_PAYMENT_REQUIRED',detail=jsonb_build_object('outstanding',v_outstanding)::text;
  end if;

  v_package_reconciliation:=public.service_reconcile_reschedule_package(v_appointment.id,v_hold.id,p_admin_id);
  v_old_start:=v_appointment.start_at; v_old_end:=v_appointment.end_at; v_old_value:=v_appointment.commercial_value;
  v_customer_after_penalty:=round(greatest(public.appointment_customer_funds_amount(v_appointment.id)-v_settlement.penalty_retained,0),2);

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

  perform public.refresh_appointment_financial_status(v_appointment.id);

  insert into public.integration_jobs(job_type,entity_type,entity_id,entity_version,payload_json,idempotency_key)
  values('GOOGLE_APPOINTMENT_SYNC','APPOINTMENT',v_appointment.id,v_new_version,jsonb_build_object('reason','APPOINTMENT_RESCHEDULED'),'google-appointment-sync:'||v_appointment.id::text||':'||v_new_version::text)
  on conflict(idempotency_key) do nothing;

  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
  values(p_admin_id,'APPOINTMENT',v_appointment.id,'APPOINTMENT_RESCHEDULED',
    jsonb_build_object('start_at',v_old_start,'end_at',v_old_end,'commercial_value',v_old_value,'version',v_appointment.version),
    jsonb_build_object('start_at',v_hold.requested_start_at,'end_at',v_hold.requested_end_at,'commercial_value',v_settlement.new_contract_value,
      'version',v_new_version,'policy_action_id',v_action.id,'change_origin',v_action.change_origin,
      'payment_commitment_percent',v_settlement.payment_commitment_percent,'confirmation_target_amount',v_settlement.confirmation_target_amount,
      'penalty_retained',v_settlement.penalty_retained,'excess_amount',greatest(v_customer_after_penalty-v_settlement.new_contract_value,0),
      'package_reconciliation',v_package_reconciliation),'ADMIN');

  return jsonb_build_object(
    'policy_action_id',v_action.id,'appointment_id',v_appointment.id,'status','APPLIED',
    'old_start_at',v_old_start,'new_start_at',v_hold.requested_start_at,'new_end_at',v_hold.requested_end_at,
    'old_contract_value',v_old_value,'new_contract_value',v_settlement.new_contract_value,
    'payment_commitment_percent',v_settlement.payment_commitment_percent,'confirmation_target_amount',v_settlement.confirmation_target_amount,
    'penalty_retained',v_settlement.penalty_retained,'difference_due',0,
    'excess_amount',greatest(v_customer_after_penalty-v_settlement.new_contract_value,0),
    'appointment_version',v_new_version,'google_sync_enqueued',true,'already_applied',false,'package_reconciliation',v_package_reconciliation
  );
end;
$$;

revoke all on function public.appointment_net_contract_settled_amount(uuid) from public,anon,authenticated;
revoke all on function public.appointment_contract_coverage_amount(uuid) from public,anon,authenticated;
revoke all on function public.service_create_reschedule_difference_payment_intent(uuid,text,text) from public,anon,authenticated;
grant execute on function public.appointment_net_contract_settled_amount(uuid) to service_role;
grant execute on function public.appointment_contract_coverage_amount(uuid) to service_role;
grant execute on function public.service_create_reschedule_difference_payment_intent(uuid,text,text) to service_role;

comment on function public.appointment_net_contract_settled_amount(uuid) is
'Net contractual settlement including payment discounts, but excluding customer-balance liability and retained penalties.';
comment on function public.appointment_contract_coverage_amount(uuid) is
'Effective contract coverage: contractual payments plus customer balance applied, less penalties consumed by applied reschedules.';
comment on function public.service_create_reschedule_difference_payment_intent(uuid,text,text) is
'Creates the exact idempotent Mercado Pago intent needed to restore the reservation payment commitment after a reschedule. It never charges the retained penalty separately.';
-- END RC MIGRATION 20260822163600_reschedule_commitment_and_contract_coverage.sql

-- BEGIN RC MIGRATION 20260822163700_package_reschedule_cash_contract.sql
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
-- END RC MIGRATION 20260822163700_package_reschedule_cash_contract.sql

-- BEGIN RC MIGRATION 20260822163800_mercado_pago_mismatch_quarantine.sql
-- A provider-accepted payment that does not match the internal intent must never
-- confirm a reservation, but it also must not be discarded as a normal rejection.
-- Keep the internal charge PENDING, link the observed provider payment only when
-- that identifier is not already owned elsewhere, and open an incident for review.

alter table public.payment_incidents
  drop constraint if exists payment_incidents_incident_type_check;

alter table public.payment_incidents
  add constraint payment_incidents_incident_type_check
  check (incident_type in ('PAYMENT_AFTER_EXPIRATION','PROVIDER_INTENT_MISMATCH'));

create or replace function public.service_quarantine_provider_payment_mismatch(
  p_transaction_id uuid,
  p_provider_payment_id text,
  p_reason text,
  p_payload_json jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_tx public.payment_transactions%rowtype;
  v_incident_id uuid;
  v_observed_provider_id text;
  v_linked_provider_id text;
  v_provider_id_owned_elsewhere boolean := false;
begin
  if p_reason not in (
    'MERCADO_PAGO_PAYMENT_ID_MISSING',
    'MERCADO_PAGO_PAYMENT_ID_MISMATCH',
    'MERCADO_PAGO_EXTERNAL_REFERENCE_MISMATCH',
    'MERCADO_PAGO_PAYMENT_AMOUNT_MISMATCH',
    'MERCADO_PAGO_PAYMENT_METHOD_MISMATCH',
    'MERCADO_PAGO_PAYMENT_AMOUNT_INVALID'
  ) then
    raise exception using errcode='P0001', message='PROVIDER_INTENT_MISMATCH_REASON_INVALID';
  end if;

  v_observed_provider_id := nullif(btrim(coalesce(p_provider_payment_id,'')),'');

  select * into v_tx
  from public.payment_transactions
  where id = p_transaction_id
  for update;

  if not found then
    raise exception using errcode='P0001', message='PAYMENT_TRANSACTION_NOT_FOUND';
  end if;
  if v_tx.provider <> 'MERCADO_PAGO' or v_tx.transaction_type <> 'CHARGE' then
    raise exception using errcode='P0001', message='PAYMENT_TRANSACTION_NOT_MERCADO_PAGO_CHARGE';
  end if;

  if v_observed_provider_id is not null then
    select exists(
      select 1
      from public.payment_transactions pt
      where pt.provider='MERCADO_PAGO'
        and pt.transaction_type='CHARGE'
        and pt.provider_payment_id=v_observed_provider_id
        and pt.id<>v_tx.id
    ) into v_provider_id_owned_elsewhere;
  end if;

  v_linked_provider_id := v_tx.provider_payment_id;
  if v_linked_provider_id is null and v_observed_provider_id is not null and not v_provider_id_owned_elsewhere then
    v_linked_provider_id := v_observed_provider_id;
  end if;

  update public.payment_transactions
  set provider_payment_id = v_linked_provider_id,
      provider_payload_json = coalesce(p_payload_json, '{}'::jsonb),
      updated_at = now()
  where id = v_tx.id;

  insert into public.payment_incidents(
    appointment_id,
    payment_transaction_id,
    incident_type,
    status,
    details_json
  ) values (
    v_tx.appointment_id,
    v_tx.id,
    'PROVIDER_INTENT_MISMATCH',
    'OPEN',
    jsonb_build_object(
      'provider','MERCADO_PAGO',
      'observed_provider_payment_id',v_observed_provider_id,
      'linked_provider_payment_id',v_linked_provider_id,
      'provider_payment_id_owned_elsewhere',v_provider_id_owned_elsewhere,
      'reason',p_reason,
      'provider_snapshot',coalesce(p_payload_json,'{}'::jsonb)
    )
  )
  on conflict(payment_transaction_id,incident_type)
  do update set
    status='OPEN',
    details_json=excluded.details_json,
    detected_at=now(),
    resolved_at=null,
    resolved_by_admin_id=null,
    resolution_notes=null
  returning id into v_incident_id;

  insert into public.audit_logs(
    entity_type,entity_id,action,before_json,after_json,origin
  ) values (
    'PAYMENT_TRANSACTION',
    v_tx.id,
    'MERCADO_PAGO_PAYMENT_QUARANTINED',
    jsonb_build_object(
      'status',v_tx.status,
      'provider_payment_id',v_tx.provider_payment_id
    ),
    jsonb_build_object(
      'status',v_tx.status,
      'provider_payment_id',v_linked_provider_id,
      'observed_provider_payment_id',v_observed_provider_id,
      'provider_payment_id_owned_elsewhere',v_provider_id_owned_elsewhere,
      'incident_id',v_incident_id,
      'reason',p_reason
    ),
    'SYSTEM'
  );

  return jsonb_build_object(
    'transaction_id',v_tx.id,
    'appointment_id',v_tx.appointment_id,
    'transaction_status',v_tx.status,
    'provider_payment_id',v_linked_provider_id,
    'observed_provider_payment_id',v_observed_provider_id,
    'provider_payment_id_owned_elsewhere',v_provider_id_owned_elsewhere,
    'incident_id',v_incident_id,
    'incident_status','OPEN',
    'reason',p_reason
  );
end;
$$;

revoke all on function public.service_quarantine_provider_payment_mismatch(uuid,text,text,jsonb)
  from public, anon, authenticated;
grant execute on function public.service_quarantine_provider_payment_mismatch(uuid,text,text,jsonb)
  to service_role;
-- END RC MIGRATION 20260822163800_mercado_pago_mismatch_quarantine.sql

-- BEGIN RC MIGRATION 20260823043000_security_advisor_hardening.sql
-- Security advisor hardening: eliminate direct exposure of sensitive SECURITY DEFINER views,
-- remove public execution from internal/admin helpers, and pin search_path on helper functions.

-- Hour-package reporting views are internal read models. They must never be queried
-- directly by anon/authenticated, and they must execute with the caller's privileges.
alter view public.hour_package_balances set (security_invoker = true);
alter view public.hour_package_statement_entries set (security_invoker = true);

revoke all on table public.hour_package_balances from public, anon, authenticated;
revoke all on table public.hour_package_statement_entries from public, anon, authenticated;
grant select on table public.hour_package_balances to service_role;
grant select on table public.hour_package_statement_entries to service_role;

-- Trigger/internal helpers are not API surface.
revoke execute on function public.copy_checkout_attribution_to_appointment() from public, anon, authenticated;

-- `rls_auto_enable()` can exist in the hosted project as an environment-level helper
-- without being part of a clean migration rebuild. Harden it when present, but do not
-- make local/CI reconstruction depend on a remote-only object.
do $$
begin
  if to_regprocedure('public.rls_auto_enable()') is not null then
    execute 'revoke execute on function public.rls_auto_enable() from public, anon, authenticated';
  end if;
end;
$$;

-- Legacy admin overloads remain only for internal compatibility and must not be callable
-- through PostgREST by anonymous or ordinary authenticated users.
revoke execute on function public.service_admin_cancel_appointment(uuid,text,text,timestamptz,uuid) from public, anon, authenticated;
revoke execute on function public.service_admin_create_reschedule_hold(uuid,timestamptz,timestamptz,uuid) from public, anon, authenticated;

-- Commercial terms contain operational/financial configuration and are read through
-- authenticated admin surfaces using service_role, never directly by client roles.
revoke execute on function public.service_get_customer_commercial_terms(uuid) from public, anon, authenticated;

-- Pin helper search paths to prevent role-controlled object shadowing.
alter function public.prevent_hour_package_movement_mutation() set search_path = public, pg_temp;
alter function public.format_duration_seconds(bigint) set search_path = public, pg_temp;
alter function public.is_valid_cpf(text) set search_path = public, pg_temp;
alter function public.is_valid_cnpj(text) set search_path = public, pg_temp;
alter function public.is_valid_tax_id(text) set search_path = public, pg_temp;
-- END RC MIGRATION 20260823043000_security_advisor_hardening.sql

-- BEGIN RC MIGRATION 20260823043100_rls_and_fk_performance_hardening.sql
-- Performance hardening for hot operational paths.
-- 1) Evaluate auth.uid() once per statement in RLS policies.
-- 2) Add covering indexes for foreign keys used in booking/payment/change workflows.

alter policy admin_users_self_select on public.admin_users
  using ((select auth.uid()) = auth_user_id);

alter policy legacy_amelia_import_batches_admin_select on public.legacy_amelia_import_batches
  using (exists (
    select 1
    from public.admin_users au
    where au.auth_user_id = (select auth.uid())
      and au.is_active
  ));

alter policy legacy_amelia_bookings_admin_select on public.legacy_amelia_bookings
  using (exists (
    select 1
    from public.admin_users au
    where au.auth_user_id = (select auth.uid())
      and au.is_active
  ));

create index if not exists appointments_service_id_idx
  on public.appointments(service_id);
create index if not exists appointments_service_employee_id_idx
  on public.appointments(service_employee_id);

create index if not exists checkout_holds_service_id_idx
  on public.checkout_holds(service_id);
create index if not exists checkout_holds_service_employee_id_idx
  on public.checkout_holds(service_employee_id);
create index if not exists checkout_holds_primary_customer_id_idx
  on public.checkout_holds(primary_customer_id);
create index if not exists checkout_holds_promoted_appointment_id_idx
  on public.checkout_holds(promoted_appointment_id);

create index if not exists pre_reservations_service_id_idx
  on public.pre_reservations(service_id);
create index if not exists pre_reservations_employee_id_idx
  on public.pre_reservations(employee_id);
create index if not exists pre_reservations_service_employee_id_idx
  on public.pre_reservations(service_employee_id);

create index if not exists payment_incidents_appointment_id_idx
  on public.payment_incidents(appointment_id);
create index if not exists payment_transactions_parent_transaction_id_idx
  on public.payment_transactions(parent_transaction_id);

create index if not exists appointment_participants_customer_id_idx
  on public.appointment_participants(customer_id);
create index if not exists appointment_answers_service_field_id_idx
  on public.appointment_answers(service_field_id);
create index if not exists appointment_extras_extra_id_idx
  on public.appointment_extras(extra_id);
create index if not exists appointment_discounts_coupon_id_idx
  on public.appointment_discounts(coupon_id);
create index if not exists appointment_term_acceptances_terms_version_id_idx
  on public.appointment_term_acceptances(terms_version_id);

create index if not exists appointment_change_policy_snapshots_service_id_idx
  on public.appointment_change_policy_snapshots(service_id);
create index if not exists appointment_change_policy_snapshot_terms_terms_version_id_idx
  on public.appointment_change_policy_snapshot_terms(terms_version_id);
create index if not exists appointment_change_settlements_customer_id_idx
  on public.appointment_change_settlements(customer_id);
create index if not exists appointment_final_settlements_customer_id_idx
  on public.appointment_final_settlements(customer_id);
create index if not exists appointment_final_settlements_balance_movement_id_idx
  on public.appointment_final_settlements(balance_movement_id);

create index if not exists customer_balance_movements_appointment_id_idx
  on public.customer_balance_movements(appointment_id);
create index if not exists customer_balance_movements_policy_action_id_idx
  on public.customer_balance_movements(policy_action_id);
create index if not exists customer_balance_refund_requests_customer_id_idx
  on public.customer_balance_refund_requests(customer_id);

create index if not exists appointment_package_usage_hour_package_id_idx
  on public.appointment_package_usage(hour_package_id);
create index if not exists appointment_package_usage_debit_movement_id_idx
  on public.appointment_package_usage(debit_movement_id);
create index if not exists appointment_package_usage_reversal_movement_id_idx
  on public.appointment_package_usage(reversal_movement_id);
create index if not exists hour_package_movements_appointment_id_idx
  on public.hour_package_movements(appointment_id);

create index if not exists schedule_divergences_resource_id_idx
  on public.schedule_divergences(resource_id);
create index if not exists schedule_divergences_appointment_id_idx
  on public.schedule_divergences(appointment_id);

create index if not exists services_category_id_idx
  on public.services(category_id);
create index if not exists service_employees_employee_id_idx
  on public.service_employees(employee_id);
create index if not exists service_extras_extra_id_idx
  on public.service_extras(extra_id);
create index if not exists service_resources_resource_id_idx
  on public.service_resources(resource_id);
-- END RC MIGRATION 20260823043100_rls_and_fk_performance_hardening.sql
