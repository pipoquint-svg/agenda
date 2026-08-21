create or replace function public.service_fail_payment_intent(
  p_transaction_id uuid,
  p_reason text,
  p_payload_json jsonb default '{}'::jsonb
)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_tx public.payment_transactions%rowtype;
begin
  select * into v_tx
  from public.payment_transactions
  where id = p_transaction_id
  for update;

  if not found or v_tx.provider <> 'MERCADO_PAGO' or v_tx.transaction_type <> 'CHARGE' then
    raise exception using errcode = 'P0001', message = 'PAYMENT_TRANSACTION_NOT_FOUND';
  end if;

  if v_tx.status = 'APPROVED' then
    raise exception using errcode = 'P0001', message = 'APPROVED_PAYMENT_CANNOT_FAIL';
  end if;

  update public.payment_transactions
  set status = 'REJECTED',
      provider_payload_json = coalesce(p_payload_json, '{}'::jsonb),
      notes = concat_ws(E'\n', nullif(notes, ''), nullif(left(p_reason, 500), '')),
      updated_at = now()
  where id = p_transaction_id;

  if not exists (
    select 1 from public.payment_transactions pt
    where pt.appointment_id = v_tx.appointment_id
      and pt.transaction_type = 'CHARGE'
      and pt.status = 'APPROVED'
  ) then
    update public.appointments
    set financial_status = 'REJECTED',
        updated_at = now()
    where id = v_tx.appointment_id
      and status = 'AWAITING_PAYMENT';
  else
    perform public.refresh_appointment_financial_status(v_tx.appointment_id);
  end if;

  insert into public.audit_logs (
    entity_type, entity_id, action, after_json, origin
  ) values (
    'APPOINTMENT',
    v_tx.appointment_id,
    'PAYMENT_INTENT_PROVIDER_REJECTED',
    jsonb_build_object('payment_transaction_id', p_transaction_id, 'reason', left(p_reason,500)),
    'MERCADO_PAGO'
  );
end;
$$;

revoke all on function public.service_fail_payment_intent(uuid,text,jsonb) from public, anon, authenticated;
grant execute on function public.service_fail_payment_intent(uuid,text,jsonb) to service_role;
