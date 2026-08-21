-- Token-scoped payment access for the Mercado Pago adapter.

create or replace function public.resolve_appointment_access_token(
  p_access_token text,
  p_required_scope text default 'VIEW'
)
returns uuid
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_token public.appointment_access_tokens%rowtype;
  v_hash text;
  v_allowed boolean := false;
begin
  if p_access_token is null or length(btrim(p_access_token)) < 32 then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_TOKEN_INVALID';
  end if;

  if p_required_scope not in ('VIEW','MANAGE','PAY') then
    raise exception using errcode = 'P0001', message = 'TOKEN_SCOPE_DENIED';
  end if;

  v_hash := encode(digest(btrim(p_access_token), 'sha256'), 'hex');

  select * into v_token
  from public.appointment_access_tokens
  where token_hash = v_hash
  for update;

  if not found then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_TOKEN_INVALID';
  end if;

  if v_token.revoked_at is not null then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_TOKEN_REVOKED';
  end if;

  if v_token.expires_at is not null and v_token.expires_at <= now() then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_TOKEN_EXPIRED';
  end if;

  v_allowed := case p_required_scope
    when 'VIEW' then v_token.scope in ('VIEW','MANAGE','PAY')
    when 'PAY' then v_token.scope in ('PAY','MANAGE')
    when 'MANAGE' then v_token.scope = 'MANAGE'
    else false
  end;

  if not v_allowed then
    raise exception using errcode = 'P0001', message = 'TOKEN_SCOPE_DENIED';
  end if;

  update public.appointment_access_tokens
  set last_used_at = now()
  where id = v_token.id;

  return v_token.appointment_id;
end;
$$;

create or replace function public.service_get_public_payment_context(p_access_token text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_appointment_id uuid;
  v_appointment public.appointments%rowtype;
  v_customer public.customers%rowtype;
  v_service public.services%rowtype;
  v_summary jsonb;
  v_confirmation_percentage numeric(5,2);
  v_confirmation_target numeric(12,2);
  v_settled numeric(12,2);
  v_minimum_due numeric(12,2);
begin
  v_appointment_id := public.resolve_appointment_access_token(p_access_token, 'PAY');

  select * into v_appointment
  from public.appointments
  where id = v_appointment_id;

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

  select * into v_customer from public.customers where id = v_appointment.primary_customer_id;
  select * into v_service from public.services where id = v_appointment.service_id;

  if v_customer.id is null then
    raise exception using errcode = 'P0001', message = 'CUSTOMER_NOT_FOUND';
  end if;

  select coalesce(v_service.confirmation_percentage, os.default_confirmation_percentage)
  into v_confirmation_percentage
  from public.operation_settings os
  where os.id = 1;

  v_summary := public.get_appointment_financial_summary(v_appointment.id);
  v_settled := (v_summary->>'contract_settled')::numeric;
  v_confirmation_target := round(coalesce(v_appointment.commercial_value,0) * v_confirmation_percentage / 100, 2);
  v_minimum_due := round(greatest(v_confirmation_target - v_settled, 0), 2);

  return jsonb_build_object(
    'appointment_id', v_appointment.id,
    'public_code', v_appointment.public_code,
    'appointment_status', v_appointment.status,
    'financial_status', v_appointment.financial_status,
    'service_name', v_appointment.service_name_snapshot,
    'hold_expires_at', v_appointment.hold_expires_at,
    'commercial_value', coalesce(v_appointment.commercial_value,0),
    'contract_settled', v_settled,
    'contract_balance', (v_summary->>'contract_balance')::numeric,
    'confirmation_percentage', v_confirmation_percentage,
    'confirmation_target_amount', v_confirmation_target,
    'minimum_due_contract_amount', v_minimum_due,
    'minimum_available', v_minimum_due > 0,
    'full_available', (v_summary->>'contract_balance')::numeric > 0,
    'payer', jsonb_build_object(
      'name', v_customer.name,
      'email', v_customer.email,
      'tax_id', regexp_replace(coalesce(v_customer.cpf_cnpj,''), '\D', '', 'g')
    )
  );
end;
$$;

create or replace function public.service_create_payment_intent_by_token(
  p_access_token text,
  p_payment_kind text,
  p_method text,
  p_request_key text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_appointment_id uuid;
  v_appointment public.appointments%rowtype;
  v_service public.services%rowtype;
  v_percentage numeric(5,2);
  v_idempotency_key text;
begin
  if p_payment_kind not in ('MINIMUM','FULL') then
    raise exception using errcode = 'P0001', message = 'INVALID_PAYMENT_KIND';
  end if;

  if p_method not in ('PIX','CARD') then
    raise exception using errcode = 'P0001', message = 'PUBLIC_PAYMENT_METHOD_NOT_ALLOWED';
  end if;

  if p_request_key is null or p_request_key !~ '^[A-Za-z0-9_-]{12,100}$' then
    raise exception using errcode = 'P0001', message = 'PAYMENT_REQUEST_KEY_INVALID';
  end if;

  v_appointment_id := public.resolve_appointment_access_token(p_access_token, 'PAY');
  select * into v_appointment from public.appointments where id = v_appointment_id;
  select * into v_service from public.services where id = v_appointment.service_id;

  if p_payment_kind = 'FULL' then
    v_percentage := 100;
  else
    select coalesce(v_service.confirmation_percentage, os.default_confirmation_percentage)
    into v_percentage
    from public.operation_settings os where os.id = 1;
  end if;

  v_idempotency_key := 'public:' || v_appointment_id::text || ':' || p_request_key;

  return public.create_payment_intent(
    v_appointment_id,
    v_percentage,
    p_method,
    v_idempotency_key
  );
end;
$$;

create or replace function public.service_store_provider_payment_snapshot(
  p_transaction_id uuid,
  p_provider_payment_id text,
  p_payload_json jsonb
)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $$
begin
  if p_provider_payment_id is null or btrim(p_provider_payment_id) = '' then
    raise exception using errcode = 'P0001', message = 'PROVIDER_PAYMENT_ID_REQUIRED';
  end if;

  update public.payment_transactions
  set provider_payment_id = p_provider_payment_id,
      provider_payload_json = coalesce(p_payload_json, '{}'::jsonb),
      updated_at = now()
  where id = p_transaction_id
    and provider = 'MERCADO_PAGO'
    and transaction_type = 'CHARGE'
    and status = 'PENDING'
    and (provider_payment_id is null or provider_payment_id = p_provider_payment_id);

  if not found then
    raise exception using errcode = 'P0001', message = 'PAYMENT_TRANSACTION_NOT_PENDING';
  end if;
end;
$$;

revoke all on function public.resolve_appointment_access_token(text,text) from public, anon, authenticated;
revoke all on function public.service_get_public_payment_context(text) from public, anon, authenticated;
revoke all on function public.service_create_payment_intent_by_token(text,text,text,text) from public, anon, authenticated;
revoke all on function public.service_store_provider_payment_snapshot(uuid,text,jsonb) from public, anon, authenticated;

grant execute on function public.resolve_appointment_access_token(text,text) to service_role;
grant execute on function public.service_get_public_payment_context(text) to service_role;
grant execute on function public.service_create_payment_intent_by_token(text,text,text,text) to service_role;
grant execute on function public.service_store_provider_payment_snapshot(uuid,text,jsonb) to service_role;
