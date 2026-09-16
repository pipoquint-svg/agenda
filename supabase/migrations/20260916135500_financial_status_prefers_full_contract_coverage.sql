-- Appointment financial status represents the reservation's current contract coverage.
-- A refund/reversal transaction must not force PARTIALLY_REFUNDED when other
-- approved funds still cover the commercial value in full. Transaction history
-- continues to preserve the refund/reversal itself.

create or replace function public.refresh_appointment_financial_status(p_appointment_id uuid)
returns public.financial_status
language plpgsql
set search_path to 'public'
as $function$
declare
  v_appointment public.appointments%rowtype;
  v_gross_contract numeric(12,2);
  v_gross_cash numeric(12,2);
  v_refunded_contract numeric(12,2);
  v_refunded_cash numeric(12,2);
  v_pending_count integer;
  v_net_contract numeric(12,2);
  v_net_cash numeric(12,2);
  v_contract_coverage numeric(12,2);
  v_new_status public.financial_status;
begin
  select * into v_appointment
  from public.appointments
  where id=p_appointment_id
  for update;

  if not found then
    raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND';
  end if;

  select
    coalesce(sum(contract_amount_settled) filter(
      where payment_purpose='CONTRACT'
        and transaction_type='CHARGE'
        and status in('APPROVED','PARTIALLY_REFUNDED','REFUNDED')
    ),0)::numeric(12,2),
    coalesce(sum(cash_amount) filter(
      where payment_purpose='CONTRACT'
        and transaction_type='CHARGE'
        and status in('APPROVED','PARTIALLY_REFUNDED','REFUNDED')
    ),0)::numeric(12,2),
    coalesce(sum(contract_amount_settled) filter(
      where payment_purpose='CONTRACT'
        and transaction_type='REFUND'
        and status in('APPROVED','REFUNDED')
    ),0)::numeric(12,2),
    coalesce(sum(cash_amount) filter(
      where payment_purpose='CONTRACT'
        and transaction_type='REFUND'
        and status in('APPROVED','REFUNDED')
    ),0)::numeric(12,2),
    count(*) filter(
      where payment_purpose='CONTRACT'
        and transaction_type='CHARGE'
        and status='PENDING'
    )::integer
  into v_gross_contract,v_gross_cash,v_refunded_contract,v_refunded_cash,v_pending_count
  from public.payment_transactions
  where appointment_id=p_appointment_id;

  v_net_contract:=round(greatest(v_gross_contract-v_refunded_contract,0),2);
  v_net_cash:=round(greatest(v_gross_cash-v_refunded_cash,0),2);
  v_contract_coverage:=public.appointment_contract_coverage_amount(p_appointment_id);

  -- A true full refund still wins when no customer cash remains.
  if v_refunded_cash>0 and v_gross_cash>0 and v_net_cash<=0.01 then
    v_new_status:='REFUNDED';
  -- If the contract remains fully covered after a refund/reversal, the reservation
  -- itself is paid. The refund remains visible in payment transaction history.
  elsif v_contract_coverage>=coalesce(v_appointment.commercial_value,0)
    and coalesce(v_appointment.commercial_value,0)>0 then
    v_new_status:='PAID';
  elsif v_refunded_cash>0 then
    v_new_status:='PARTIALLY_REFUNDED';
  elsif v_contract_coverage>0 then
    v_new_status:='PARTIALLY_PAID';
  elsif v_appointment.financial_status='UNPAID_AUTHORIZED' then
    v_new_status:='UNPAID_AUTHORIZED';
  elsif v_pending_count>0 then
    v_new_status:='PENDING';
  elsif v_appointment.status='EXPIRED' then
    v_new_status:='EXPIRED';
  else
    v_new_status:='NOT_STARTED';
  end if;

  update public.appointments
  set financial_status=v_new_status,updated_at=now()
  where id=p_appointment_id;

  return v_new_status;
end;
$function$;

-- Re-evaluate only rows that can be affected by the precedence change.
do $repair$
declare
  v_appointment_id uuid;
begin
  for v_appointment_id in
    select a.id
    from public.appointments a
    where a.deleted_at is null
      and a.financial_status='PARTIALLY_REFUNDED'
      and coalesce(a.commercial_value,0)>0
      and public.appointment_contract_coverage_amount(a.id)>=a.commercial_value
  loop
    perform public.refresh_appointment_financial_status(v_appointment_id);
  end loop;
end;
$repair$;
