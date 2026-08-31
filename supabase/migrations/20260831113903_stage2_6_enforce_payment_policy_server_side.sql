create or replace function public.create_payment_intent_v2(
  p_appointment_id uuid,p_payment_kind text,p_method text,p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_appointment public.appointments%rowtype;
  v_existing public.payment_transactions%rowtype;
  v_summary jsonb;
  v_balance numeric(12,2);
  v_settled_before numeric(12,2);
  v_rule_type text;
  v_rule_value numeric(12,2);
  v_minimum_target numeric(12,2);
  v_contract_amount numeric(12,2);
  v_discount_percent numeric(5,2);
  v_discount numeric(12,2);
  v_cash_amount numeric(12,2);
  v_amounts jsonb;
  v_transaction_id uuid;
  v_existing_kind text;
  v_requested_percentage numeric(5,2);
  v_payment_mode text;
begin
  if p_payment_kind not in ('MINIMUM','FULL') then raise exception using errcode='P0001',message='INVALID_PAYMENT_KIND'; end if;
  if p_method not in ('PIX','CARD') then raise exception using errcode='P0001',message='PUBLIC_PAYMENT_METHOD_NOT_ALLOWED'; end if;
  if p_idempotency_key is null or btrim(p_idempotency_key)='' then raise exception using errcode='P0001',message='IDEMPOTENCY_KEY_REQUIRED'; end if;

  select * into v_existing from public.payment_transactions where idempotency_key=p_idempotency_key;
  if found then
    v_existing_kind:=coalesce(v_existing.requested_payment_kind,case when v_existing.requested_percentage=100 then 'FULL' else 'MINIMUM' end);
    if v_existing.appointment_id<>p_appointment_id or v_existing.method<>p_method or v_existing_kind<>p_payment_kind then raise exception using errcode='P0001',message='IDEMPOTENCY_KEY_CONFLICT'; end if;
    return jsonb_build_object(
      'transaction_id',v_existing.id,'appointment_id',v_existing.appointment_id,'status',v_existing.status,
      'payment_kind',case when p_payment_kind='FULL' then 'FULL_BALANCE' else 'CONFIRMATION_MINIMUM' end,
      'payment_percentage',v_existing.requested_percentage,'contract_amount_settled',v_existing.contract_amount_settled,
      'payment_discount_amount',v_existing.payment_discount_amount,'cash_amount',v_existing.cash_amount,'method',v_existing.method,'idempotent_replay',true
    );
  end if;

  perform public.expire_due_appointment_holds();
  select * into v_appointment from public.appointments where id=p_appointment_id for update;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if;
  if v_appointment.status not in ('AWAITING_PAYMENT','CONFIRMED') then raise exception using errcode='P0001',message='APPOINTMENT_NOT_PAYABLE'; end if;
  if v_appointment.status='AWAITING_PAYMENT' and (v_appointment.hold_expires_at is null or v_appointment.hold_expires_at<=now()) then raise exception using errcode='P0001',message='PAYMENT_HOLD_EXPIRED'; end if;

  v_payment_mode:=coalesce(v_appointment.payment_mode_snapshot,(select s.payment_mode from public.services s where s.id=v_appointment.service_id),'MINIMUM_OR_FULL');
  if p_payment_kind='FULL' and v_payment_mode='MINIMUM_ONLY' then
    raise exception using errcode='P0001',message='PAYMENT_POLICY_FULL_NOT_ALLOWED:Este serviço permite online apenas o sinal. Escolha pagar o sinal; o saldo deve ser quitado presencialmente pela Gestão.';
  end if;
  if p_payment_kind='MINIMUM' and v_payment_mode='FULL_ONLY' then
    raise exception using errcode='P0001',message='PAYMENT_POLICY_MINIMUM_NOT_ALLOWED:Este serviço exige pagamento integral online. Escolha o valor integral para continuar.';
  end if;

  v_rule_type:=coalesce(v_appointment.checkout_minimum_payment_type_snapshot,'PERCENT');
  v_rule_value:=coalesce(v_appointment.checkout_minimum_payment_value_snapshot,v_appointment.confirmation_percentage_snapshot);
  if v_rule_value is null then raise exception using errcode='P0001',message='APPOINTMENT_CONFIRMATION_SNAPSHOT_MISSING'; end if;
  v_discount_percent:=public.service_resolve_appointment_pix_discount(p_appointment_id);
  v_summary:=public.get_appointment_financial_summary(p_appointment_id);
  v_balance:=(v_summary->>'contract_balance')::numeric;
  v_settled_before:=(v_summary->>'contract_settled')::numeric;
  if v_balance<=0 then raise exception using errcode='P0001',message='APPOINTMENT_ALREADY_PAID'; end if;

  v_minimum_target:=public.service_checkout_minimum_target(v_appointment.commercial_value,v_rule_type,v_rule_value);
  if p_payment_kind='FULL' then
    v_contract_amount:=v_balance;
    v_requested_percentage:=100;
  else
    v_contract_amount:=round(greatest(v_minimum_target-v_settled_before,0),2);
    if v_contract_amount<=0 then raise exception using errcode='P0001',message='CONFIRMATION_PAYMENT_ALREADY_SATISFIED'; end if;
    v_contract_amount:=least(v_contract_amount,v_balance);
    v_requested_percentage:=case when v_rule_type='PERCENT' then v_rule_value else null end;
  end if;

  v_amounts:=public.service_calculate_payment_cash_amount(v_contract_amount,p_method,v_discount_percent);
  v_discount:=(v_amounts->>'payment_discount_amount')::numeric;
  v_cash_amount:=(v_amounts->>'cash_amount')::numeric;

  insert into public.payment_transactions(
    appointment_id,transaction_type,method,provider,status,contract_amount_settled,payment_discount_amount,cash_amount,
    idempotency_key,requested_percentage,requested_payment_kind
  ) values(
    p_appointment_id,'CHARGE',p_method,'MERCADO_PAGO','PENDING',v_contract_amount,v_discount,v_cash_amount,
    p_idempotency_key,v_requested_percentage,p_payment_kind
  ) returning id into v_transaction_id;

  if v_appointment.financial_status not in ('PARTIALLY_PAID','PAID','UNPAID_AUTHORIZED') then update public.appointments set financial_status='PENDING',updated_at=now() where id=p_appointment_id; end if;

  return jsonb_build_object(
    'transaction_id',v_transaction_id,'appointment_id',p_appointment_id,'status','PENDING',
    'payment_kind',case when p_payment_kind='FULL' then 'FULL_BALANCE' else 'CONFIRMATION_MINIMUM' end,
    'payment_percentage',v_requested_percentage,'payment_mode',v_payment_mode,
    'minimum_payment_type',v_rule_type,'minimum_payment_value',v_rule_value,'confirmation_target_amount',v_minimum_target,
    'contract_settled_before',v_settled_before,'contract_balance_before',v_balance,
    'contract_amount_settled',v_contract_amount,'payment_discount_amount',v_discount,'cash_amount',v_cash_amount,
    'method',p_method,'provider','MERCADO_PAGO','idempotent_replay',false
  );
end;
$function$;

create or replace function public.service_create_payment_intent_by_token(
  p_access_token text,p_payment_kind text,p_method text,p_request_key text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public','extensions'
as $function$
declare
  v_appointment_id uuid;
  v_appointment public.appointments%rowtype;
  v_idempotency_key text;
  v_result jsonb;
  v_transaction_id uuid;
  v_hash text;
  v_collection_id uuid;
  v_collection public.appointment_balance_collections%rowtype;
  v_existing public.payment_transactions%rowtype;
  v_balance numeric(12,2);
  v_discount_percent numeric(5,2);
  v_amounts jsonb;
  v_discount numeric(12,2);
  v_cash_amount numeric(12,2);
  v_payment_mode text;
begin
  if p_payment_kind not in ('MINIMUM','FULL') then raise exception using errcode='P0001',message='INVALID_PAYMENT_KIND'; end if;
  if p_method not in ('PIX','CARD') then raise exception using errcode='P0001',message='PUBLIC_PAYMENT_METHOD_NOT_ALLOWED'; end if;
  if p_request_key is null or p_request_key !~ '^[A-Za-z0-9_-]{12,100}$' then raise exception using errcode='P0001',message='PAYMENT_REQUEST_KEY_INVALID'; end if;

  v_hash:=encode(digest(p_access_token,'sha256'),'hex');
  select appointment_id,balance_collection_id into v_appointment_id,v_collection_id
  from public.appointment_access_tokens
  where token_hash=v_hash and revoked_at is null and consumed_at is null and (expires_at is null or expires_at>now())
  order by created_at desc limit 1;
  if v_appointment_id is null then v_appointment_id:=public.resolve_appointment_access_token(p_access_token,'PAY'); else perform public.resolve_appointment_access_token(p_access_token,'PAY'); end if;
  select * into v_appointment from public.appointments where id=v_appointment_id;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if;
  v_idempotency_key:='public:'||v_appointment_id::text||':'||p_request_key;
  v_payment_mode:=coalesce(v_appointment.payment_mode_snapshot,(select s.payment_mode from public.services s where s.id=v_appointment.service_id),'MINIMUM_OR_FULL');

  if v_collection_id is not null then
    if v_payment_mode='MINIMUM_ONLY' then
      raise exception using errcode='P0001',message='BALANCE_COLLECTION_POLICY_DENIED:Esta reserva permite online apenas o sinal. Quite o saldo presencialmente e registre a baixa manual na Gestão.';
    end if;

    perform public.expire_due_balance_collections();
    select * into v_collection from public.appointment_balance_collections where id=v_collection_id for update;
    if not found or v_collection.status<>'PENDING' or v_collection.expires_at<=public.balance_collection_clock() then raise exception using errcode='P0001',message='BALANCE_COLLECTION_INVALID_OR_EXPIRED'; end if;
    if v_collection.appointment_id<>v_appointment_id then raise exception using errcode='P0001',message='BALANCE_COLLECTION_APPOINTMENT_MISMATCH'; end if;
    if v_appointment.status not in ('CONFIRMED','COMPLETED','NO_SHOW') then raise exception using errcode='P0001',message='BALANCE_COLLECTION_APPOINTMENT_NOT_PAYABLE'; end if;
    if coalesce(v_appointment.billing_mode_snapshot,'CHECKOUT')='INVOICE' then raise exception using errcode='P0001',message='BALANCE_COLLECTION_INVOICE_DENIED'; end if;
    if p_payment_kind<>'FULL' then raise exception using errcode='P0001',message='BALANCE_COLLECTION_FULL_PAYMENT_REQUIRED'; end if;

    select * into v_existing from public.payment_transactions where idempotency_key=v_idempotency_key;
    if found then
      if v_existing.appointment_id<>v_appointment_id or v_existing.method<>p_method
         or coalesce(v_existing.requested_payment_kind,case when v_existing.requested_percentage=100 then 'FULL' else null end)<>'FULL'
         or v_existing.balance_collection_id is distinct from v_collection_id then raise exception using errcode='P0001',message='IDEMPOTENCY_KEY_CONFLICT'; end if;
      return jsonb_build_object(
        'transaction_id',v_existing.id,'appointment_id',v_existing.appointment_id,'status',v_existing.status,
        'payment_kind','FULL_BALANCE','payment_percentage',v_existing.requested_percentage,'contract_amount_settled',v_existing.contract_amount_settled,
        'payment_discount_amount',v_existing.payment_discount_amount,'cash_amount',v_existing.cash_amount,'method',v_existing.method,
        'provider',v_existing.provider,'balance_collection_id',v_collection_id,'idempotent_replay',true
      );
    end if;

    perform 1 from public.appointments where id=v_appointment_id for update;
    v_balance:=round(greatest(coalesce((public.get_appointment_financial_summary(v_appointment_id)->>'contract_balance')::numeric,0),0),2);
    if v_balance<=0.005 then raise exception using errcode='P0001',message='APPOINTMENT_ALREADY_PAID'; end if;
    v_discount_percent:=public.service_resolve_appointment_pix_discount(v_appointment_id);
    v_amounts:=public.service_calculate_payment_cash_amount(v_balance,p_method,v_discount_percent);
    v_discount:=(v_amounts->>'payment_discount_amount')::numeric;
    v_cash_amount:=(v_amounts->>'cash_amount')::numeric;

    insert into public.payment_transactions(
      appointment_id,transaction_type,method,provider,status,contract_amount_settled,payment_discount_amount,cash_amount,
      idempotency_key,requested_percentage,requested_payment_kind,payment_purpose,balance_collection_id
    ) values(
      v_appointment_id,'CHARGE',p_method,'MERCADO_PAGO','PENDING',v_balance,v_discount,v_cash_amount,
      v_idempotency_key,100,'FULL','CONTRACT',v_collection_id
    ) returning id into v_transaction_id;

    return jsonb_build_object(
      'transaction_id',v_transaction_id,'appointment_id',v_appointment_id,'status','PENDING',
      'payment_kind','FULL_BALANCE','payment_percentage',100,'payment_mode',v_payment_mode,
      'contract_balance_before',v_balance,'contract_amount_settled',v_balance,
      'payment_discount_amount',v_discount,'cash_amount',v_cash_amount,'method',p_method,'provider','MERCADO_PAGO',
      'balance_collection_id',v_collection_id,'idempotent_replay',false
    );
  end if;

  v_result:=public.create_payment_intent_v2(v_appointment_id,p_payment_kind,p_method,v_idempotency_key);
  return v_result||jsonb_build_object('balance_collection_id',null);
end;
$function$;