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
