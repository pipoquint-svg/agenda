-- Preview autoritativo dos valores por método de pagamento.
-- A UI nunca calcula desconto: recebe o valor líquido já calculado pelo banco.

create or replace function public.service_calculate_payment_cash_amount(
  p_contract_amount numeric,
  p_method text,
  p_pix_discount_percent numeric
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_contract numeric(12,2);
  v_discount_percent numeric(5,2);
  v_discount numeric(12,2);
  v_cash numeric(12,2);
begin
  if p_method not in ('PIX','CARD') then
    raise exception using errcode = 'P0001', message = 'PUBLIC_PAYMENT_METHOD_NOT_ALLOWED';
  end if;

  v_contract := round(coalesce(p_contract_amount, 0), 2);
  v_discount_percent := round(coalesce(p_pix_discount_percent, 0), 2);

  if v_contract < 0 then
    raise exception using errcode = '22023', message = 'PAYMENT_AMOUNT_INVALID';
  end if;
  if v_discount_percent < 0 or v_discount_percent > 100 then
    raise exception using errcode = '22023', message = 'PIX_DISCOUNT_PERCENT_INVALID';
  end if;

  v_discount := case
    when p_method = 'PIX' then round(v_contract * v_discount_percent / 100, 2)
    else 0
  end;
  v_cash := round(v_contract - v_discount, 2);

  return jsonb_build_object(
    'contract_amount', v_contract,
    'payment_discount_amount', v_discount,
    'cash_amount', v_cash,
    'method', p_method
  );
end;
$$;

revoke all on function public.service_calculate_payment_cash_amount(numeric,text,numeric) from public, anon, authenticated;
grant execute on function public.service_calculate_payment_cash_amount(numeric,text,numeric) to service_role;

create or replace function public.service_get_public_payment_method_preview(
  p_access_token text
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_context jsonb;
  v_minimum_contract numeric(12,2);
  v_full_contract numeric(12,2);
  v_discount_percent numeric(5,2);
  v_minimum_pix jsonb;
  v_full_pix jsonb;
begin
  -- Reusa toda a validação autoritativa de token/status/hold já existente.
  v_context := public.service_get_public_payment_context(p_access_token);

  v_minimum_contract := round(coalesce((v_context->>'minimum_due_contract_amount')::numeric, 0), 2);
  v_full_contract := round(coalesce((v_context->>'contract_balance')::numeric, 0), 2);

  select round(coalesce(os.pix_discount_percent, 0), 2)
  into v_discount_percent
  from public.operation_settings os
  where os.id = 1;

  if v_discount_percent is null then
    raise exception using errcode = 'P0001', message = 'PAYMENT_SETTINGS_LOAD_FAILED';
  end if;

  v_minimum_pix := public.service_calculate_payment_cash_amount(v_minimum_contract, 'PIX', v_discount_percent);
  v_full_pix := public.service_calculate_payment_cash_amount(v_full_contract, 'PIX', v_discount_percent);

  return jsonb_build_object(
    'pix_discount_percent', v_discount_percent,
    'confirmation_percentage', (v_context->>'confirmation_percentage')::numeric,
    'minimum_available', coalesce((v_context->>'minimum_available')::boolean, false),
    'full_available', coalesce((v_context->>'full_available')::boolean, false),
    'minimum_due_contract_amount', v_minimum_contract,
    'minimum_due_card_cash_amount', v_minimum_contract,
    'minimum_due_pix_cash_amount', (v_minimum_pix->>'cash_amount')::numeric,
    'full_due_contract_amount', v_full_contract,
    'full_due_card_cash_amount', v_full_contract,
    'full_due_pix_cash_amount', (v_full_pix->>'cash_amount')::numeric
  );
end;
$$;

revoke all on function public.service_get_public_payment_method_preview(text) from public, anon, authenticated;
grant execute on function public.service_get_public_payment_method_preview(text) to service_role;

-- Mantém create_payment_intent como fonte da cobrança e faz o cálculo usar o
-- mesmo helper do preview, eliminando divergência de arredondamento/regra.
create or replace function public.create_payment_intent(
  p_appointment_id uuid,
  p_payment_percentage numeric,
  p_method text,
  p_idempotency_key text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_appointment public.appointments%rowtype;
  v_service public.services%rowtype;
  v_existing public.payment_transactions%rowtype;
  v_summary jsonb;
  v_balance numeric(12,2);
  v_settled_before numeric(12,2);
  v_confirmation_percentage numeric(5,2);
  v_confirmation_target numeric(12,2);
  v_contract_amount numeric(12,2);
  v_discount_percent numeric(5,2);
  v_discount numeric(12,2);
  v_cash_amount numeric(12,2);
  v_amounts jsonb;
  v_transaction_id uuid;
  v_payment_kind text;
begin
  if p_method not in ('PIX','CARD') then
    raise exception using errcode = 'P0001', message = 'PUBLIC_PAYMENT_METHOD_NOT_ALLOWED';
  end if;

  if p_idempotency_key is null or btrim(p_idempotency_key) = '' then
    raise exception using errcode = 'P0001', message = 'IDEMPOTENCY_KEY_REQUIRED';
  end if;

  select * into v_existing
  from public.payment_transactions
  where idempotency_key = p_idempotency_key;

  if found then
    if v_existing.appointment_id <> p_appointment_id
       or v_existing.method <> p_method
       or v_existing.requested_percentage is distinct from p_payment_percentage then
      raise exception using errcode = 'P0001', message = 'IDEMPOTENCY_KEY_CONFLICT';
    end if;

    return jsonb_build_object(
      'transaction_id', v_existing.id,
      'appointment_id', v_existing.appointment_id,
      'status', v_existing.status,
      'payment_percentage', v_existing.requested_percentage,
      'contract_amount_settled', v_existing.contract_amount_settled,
      'payment_discount_amount', v_existing.payment_discount_amount,
      'cash_amount', v_existing.cash_amount,
      'method', v_existing.method,
      'idempotent_replay', true
    );
  end if;

  perform public.expire_due_appointment_holds();

  select * into v_appointment
  from public.appointments
  where id = p_appointment_id
  for update;

  if not found then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_NOT_FOUND';
  end if;

  if v_appointment.status not in ('AWAITING_PAYMENT','CONFIRMED') then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_NOT_PAYABLE';
  end if;

  if v_appointment.status = 'AWAITING_PAYMENT'
     and (v_appointment.hold_expires_at is null or v_appointment.hold_expires_at <= now()) then
    raise exception using errcode = 'P0001', message = 'PAYMENT_HOLD_EXPIRED';
  end if;

  select * into v_service
  from public.services
  where id = v_appointment.service_id;

  if not found then
    raise exception using errcode = 'P0001', message = 'SERVICE_NOT_FOUND';
  end if;

  select
    coalesce(v_service.confirmation_percentage, os.default_confirmation_percentage),
    os.pix_discount_percent
  into v_confirmation_percentage, v_discount_percent
  from public.operation_settings os
  where os.id = 1;

  if p_payment_percentage <> 100
     and p_payment_percentage <> v_confirmation_percentage then
    raise exception using errcode = 'P0001', message = 'INVALID_PAYMENT_PERCENTAGE';
  end if;

  v_summary := public.get_appointment_financial_summary(p_appointment_id);
  v_balance := (v_summary->>'contract_balance')::numeric;
  v_settled_before := (v_summary->>'contract_settled')::numeric;

  if v_balance <= 0 then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_ALREADY_PAID';
  end if;

  v_confirmation_target := round(
    coalesce(v_appointment.commercial_value, 0) * v_confirmation_percentage / 100,
    2
  );

  if p_payment_percentage = 100 then
    v_payment_kind := 'FULL_BALANCE';
    v_contract_amount := v_balance;
  else
    v_payment_kind := 'CONFIRMATION_MINIMUM';
    v_contract_amount := round(greatest(v_confirmation_target - v_settled_before, 0), 2);

    if v_contract_amount <= 0 then
      raise exception using errcode = 'P0001', message = 'CONFIRMATION_PAYMENT_ALREADY_SATISFIED';
    end if;

    v_contract_amount := least(v_contract_amount, v_balance);
  end if;

  v_amounts := public.service_calculate_payment_cash_amount(v_contract_amount, p_method, v_discount_percent);
  v_discount := (v_amounts->>'payment_discount_amount')::numeric;
  v_cash_amount := (v_amounts->>'cash_amount')::numeric;

  insert into public.payment_transactions (
    appointment_id,
    transaction_type,
    method,
    provider,
    status,
    contract_amount_settled,
    payment_discount_amount,
    cash_amount,
    idempotency_key,
    requested_percentage
  ) values (
    p_appointment_id,
    'CHARGE',
    p_method,
    'MERCADO_PAGO',
    'PENDING',
    v_contract_amount,
    v_discount,
    v_cash_amount,
    p_idempotency_key,
    p_payment_percentage
  ) returning id into v_transaction_id;

  if v_appointment.financial_status not in ('PARTIALLY_PAID','PAID','UNPAID_AUTHORIZED') then
    update public.appointments
    set financial_status = 'PENDING',
        updated_at = now()
    where id = p_appointment_id;
  end if;

  return jsonb_build_object(
    'transaction_id', v_transaction_id,
    'appointment_id', p_appointment_id,
    'status', 'PENDING',
    'payment_kind', v_payment_kind,
    'payment_percentage', p_payment_percentage,
    'confirmation_percentage', v_confirmation_percentage,
    'confirmation_target_amount', v_confirmation_target,
    'contract_settled_before', v_settled_before,
    'contract_balance_before', v_balance,
    'contract_amount_settled', v_contract_amount,
    'payment_discount_amount', v_discount,
    'cash_amount', v_cash_amount,
    'method', p_method,
    'provider', 'MERCADO_PAGO',
    'idempotent_replay', false
  );
end;
$$;
