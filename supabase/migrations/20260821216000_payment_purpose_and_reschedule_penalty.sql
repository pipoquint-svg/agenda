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
