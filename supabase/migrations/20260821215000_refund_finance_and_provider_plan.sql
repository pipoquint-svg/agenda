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
