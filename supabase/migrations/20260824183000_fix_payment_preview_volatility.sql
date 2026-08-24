-- payment-preview calls the token resolver, which records token usage and takes a row lock.
-- The wrapper therefore cannot be STABLE/read-only.

create or replace function public.service_get_public_payment_method_preview(
  p_access_token text
) returns jsonb
language plpgsql
volatile
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
