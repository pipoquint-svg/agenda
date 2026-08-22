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
