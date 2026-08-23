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
