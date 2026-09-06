-- Gate 2: InfinitePay-only service RPCs.
-- Mercado Pago functions are intentionally not modified in this migration.

create or replace function public.service_create_infinitepay_payment_intent_by_token(
  p_access_token text,
  p_payment_kind text,
  p_request_key text
)
returns jsonb
language plpgsql
security definer
set search_path = 'public', 'extensions'
as $$
declare
  v_appointment_id uuid;
  v_appointment public.appointments%rowtype;
  v_idempotency_key text;
  v_transaction_id uuid;
  v_hash text;
  v_collection_id uuid;
  v_collection public.appointment_balance_collections%rowtype;
  v_existing public.payment_transactions%rowtype;
  v_summary jsonb;
  v_balance numeric(12,2);
  v_settled_before numeric(12,2);
  v_rule_type text;
  v_rule_value numeric(12,2);
  v_minimum_target numeric(12,2);
  v_contract_amount numeric(12,2);
  v_requested_percentage numeric(5,2);
  v_payment_mode text;
begin
  if p_payment_kind not in ('MINIMUM','FULL') then
    raise exception using errcode='P0001',message='INVALID_PAYMENT_KIND';
  end if;
  if p_request_key is null or p_request_key !~ '^[A-Za-z0-9_-]{12,100}$' then
    raise exception using errcode='P0001',message='PAYMENT_REQUEST_KEY_INVALID';
  end if;

  v_hash:=encode(digest(p_access_token,'sha256'),'hex');
  select appointment_id,balance_collection_id
    into v_appointment_id,v_collection_id
  from public.appointment_access_tokens
  where token_hash=v_hash
    and revoked_at is null
    and consumed_at is null
    and (expires_at is null or expires_at>now())
  order by created_at desc
  limit 1;

  if v_appointment_id is null then
    v_appointment_id:=public.resolve_appointment_access_token(p_access_token,'PAY');
  else
    perform public.resolve_appointment_access_token(p_access_token,'PAY');
  end if;

  select * into v_appointment
  from public.appointments
  where id=v_appointment_id;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if;
  if coalesce(v_appointment.payment_provider_snapshot,'MERCADO_PAGO') <> 'INFINITEPAY' then
    raise exception using errcode='P0001',message='PAYMENT_PROVIDER_MISMATCH';
  end if;

  v_idempotency_key:='public:infinitepay:'||v_appointment_id::text||':'||p_request_key;
  v_payment_mode:=coalesce(
    v_appointment.payment_mode_snapshot,
    (select s.payment_mode from public.services s where s.id=v_appointment.service_id),
    'MINIMUM_OR_FULL'
  );

  if p_payment_kind='FULL' and v_payment_mode='MINIMUM_ONLY' then
    raise exception using errcode='P0001',message='PAYMENT_POLICY_FULL_NOT_ALLOWED:Este serviço permite online apenas o sinal. Escolha pagar o sinal; o saldo deve ser quitado presencialmente pela Gestão.';
  end if;
  if p_payment_kind='MINIMUM' and v_payment_mode='FULL_ONLY' then
    raise exception using errcode='P0001',message='PAYMENT_POLICY_MINIMUM_NOT_ALLOWED:Este serviço exige pagamento integral online. Escolha o valor integral para continuar.';
  end if;

  if v_collection_id is not null then
    if v_payment_mode='MINIMUM_ONLY' then
      raise exception using errcode='P0001',message='BALANCE_COLLECTION_POLICY_DENIED:Esta reserva permite online apenas o sinal. Quite o saldo presencialmente e registre a baixa manual na Gestão.';
    end if;

    perform public.expire_due_balance_collections();
    select * into v_collection
    from public.appointment_balance_collections
    where id=v_collection_id
    for update;
    if not found or v_collection.status<>'PENDING' or v_collection.expires_at<=public.balance_collection_clock() then
      raise exception using errcode='P0001',message='BALANCE_COLLECTION_INVALID_OR_EXPIRED';
    end if;
    if v_collection.appointment_id<>v_appointment_id then
      raise exception using errcode='P0001',message='BALANCE_COLLECTION_APPOINTMENT_MISMATCH';
    end if;
    if v_appointment.status not in ('CONFIRMED','COMPLETED','NO_SHOW') then
      raise exception using errcode='P0001',message='BALANCE_COLLECTION_APPOINTMENT_NOT_PAYABLE';
    end if;
    if coalesce(v_appointment.billing_mode_snapshot,'CHECKOUT')='INVOICE' then
      raise exception using errcode='P0001',message='BALANCE_COLLECTION_INVOICE_DENIED';
    end if;
    if p_payment_kind<>'FULL' then
      raise exception using errcode='P0001',message='BALANCE_COLLECTION_FULL_PAYMENT_REQUIRED';
    end if;

    select * into v_existing
    from public.payment_transactions
    where idempotency_key=v_idempotency_key;
    if found then
      if v_existing.appointment_id<>v_appointment_id
         or v_existing.provider<>'INFINITEPAY'
         or v_existing.method<>'OTHER'
         or coalesce(v_existing.requested_payment_kind,case when v_existing.requested_percentage=100 then 'FULL' else null end)<>'FULL'
         or v_existing.balance_collection_id is distinct from v_collection_id then
        raise exception using errcode='P0001',message='IDEMPOTENCY_KEY_CONFLICT';
      end if;
      return jsonb_build_object(
        'transaction_id',v_existing.id,'appointment_id',v_existing.appointment_id,'status',v_existing.status,
        'payment_kind','FULL_BALANCE','payment_percentage',v_existing.requested_percentage,
        'contract_amount_settled',v_existing.contract_amount_settled,'payment_discount_amount',v_existing.payment_discount_amount,
        'cash_amount',v_existing.cash_amount,'method',v_existing.method,'provider',v_existing.provider,
        'balance_collection_id',v_collection_id,'idempotent_replay',true
      );
    end if;

    perform 1 from public.appointments where id=v_appointment_id for update;
    v_balance:=round(greatest(coalesce((public.get_appointment_financial_summary(v_appointment_id)->>'contract_balance')::numeric,0),0),2);
    if v_balance<=0.005 then raise exception using errcode='P0001',message='APPOINTMENT_ALREADY_PAID'; end if;

    insert into public.payment_transactions(
      appointment_id,transaction_type,method,provider,status,contract_amount_settled,payment_discount_amount,cash_amount,
      idempotency_key,requested_percentage,requested_payment_kind,payment_purpose,balance_collection_id
    ) values(
      v_appointment_id,'CHARGE','OTHER','INFINITEPAY','PENDING',v_balance,0,v_balance,
      v_idempotency_key,100,'FULL','CONTRACT',v_collection_id
    ) returning id into v_transaction_id;

    return jsonb_build_object(
      'transaction_id',v_transaction_id,'appointment_id',v_appointment_id,'status','PENDING',
      'payment_kind','FULL_BALANCE','payment_percentage',100,'payment_mode',v_payment_mode,
      'contract_balance_before',v_balance,'contract_amount_settled',v_balance,
      'payment_discount_amount',0,'cash_amount',v_balance,'method','OTHER','provider','INFINITEPAY',
      'balance_collection_id',v_collection_id,'idempotent_replay',false
    );
  end if;

  select * into v_existing
  from public.payment_transactions
  where idempotency_key=v_idempotency_key;
  if found then
    if v_existing.appointment_id<>v_appointment_id
       or v_existing.provider<>'INFINITEPAY'
       or v_existing.method<>'OTHER'
       or coalesce(v_existing.requested_payment_kind,case when v_existing.requested_percentage=100 then 'FULL' else 'MINIMUM' end)<>p_payment_kind then
      raise exception using errcode='P0001',message='IDEMPOTENCY_KEY_CONFLICT';
    end if;
    return jsonb_build_object(
      'transaction_id',v_existing.id,'appointment_id',v_existing.appointment_id,'status',v_existing.status,
      'payment_kind',case when p_payment_kind='FULL' then 'FULL_BALANCE' else 'CONFIRMATION_MINIMUM' end,
      'payment_percentage',v_existing.requested_percentage,'contract_amount_settled',v_existing.contract_amount_settled,
      'payment_discount_amount',v_existing.payment_discount_amount,'cash_amount',v_existing.cash_amount,
      'method',v_existing.method,'provider',v_existing.provider,'balance_collection_id',null,'idempotent_replay',true
    );
  end if;

  perform public.expire_due_appointment_holds();
  select * into v_appointment
  from public.appointments
  where id=v_appointment_id
  for update;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if;
  if v_appointment.status not in ('AWAITING_PAYMENT','CONFIRMED') then
    raise exception using errcode='P0001',message='APPOINTMENT_NOT_PAYABLE';
  end if;
  if v_appointment.status='AWAITING_PAYMENT' and (v_appointment.hold_expires_at is null or v_appointment.hold_expires_at<=now()) then
    raise exception using errcode='P0001',message='PAYMENT_HOLD_EXPIRED';
  end if;
  if coalesce(v_appointment.payment_provider_snapshot,'MERCADO_PAGO') <> 'INFINITEPAY' then
    raise exception using errcode='P0001',message='PAYMENT_PROVIDER_MISMATCH';
  end if;

  v_rule_type:=coalesce(v_appointment.checkout_minimum_payment_type_snapshot,'PERCENT');
  v_rule_value:=coalesce(v_appointment.checkout_minimum_payment_value_snapshot,v_appointment.confirmation_percentage_snapshot);
  if v_rule_value is null then raise exception using errcode='P0001',message='APPOINTMENT_CONFIRMATION_SNAPSHOT_MISSING'; end if;

  v_summary:=public.get_appointment_financial_summary(v_appointment_id);
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

  -- InfinitePay receives the table/base amount. There is no Agenda-side Pix
  -- discount and no Agenda-side card markup; provider financing is external.
  insert into public.payment_transactions(
    appointment_id,transaction_type,method,provider,status,contract_amount_settled,payment_discount_amount,cash_amount,
    idempotency_key,requested_percentage,requested_payment_kind
  ) values(
    v_appointment_id,'CHARGE','OTHER','INFINITEPAY','PENDING',v_contract_amount,0,v_contract_amount,
    v_idempotency_key,v_requested_percentage,p_payment_kind
  ) returning id into v_transaction_id;

  if v_appointment.financial_status not in ('PARTIALLY_PAID','PAID','UNPAID_AUTHORIZED') then
    update public.appointments set financial_status='PENDING',updated_at=now() where id=v_appointment_id;
  end if;

  return jsonb_build_object(
    'transaction_id',v_transaction_id,'appointment_id',v_appointment_id,'status','PENDING',
    'payment_kind',case when p_payment_kind='FULL' then 'FULL_BALANCE' else 'CONFIRMATION_MINIMUM' end,
    'payment_percentage',v_requested_percentage,'payment_mode',v_payment_mode,
    'minimum_payment_type',v_rule_type,'minimum_payment_value',v_rule_value,'confirmation_target_amount',v_minimum_target,
    'contract_settled_before',v_settled_before,'contract_balance_before',v_balance,
    'contract_amount_settled',v_contract_amount,'payment_discount_amount',0,'cash_amount',v_contract_amount,
    'method','OTHER','provider','INFINITEPAY','balance_collection_id',null,'idempotent_replay',false
  );
end;
$$;

revoke all on function public.service_create_infinitepay_payment_intent_by_token(text,text,text) from public, anon, authenticated;
grant execute on function public.service_create_infinitepay_payment_intent_by_token(text,text,text) to service_role;

create or replace function public.service_apply_infinitepay_payment_check(
  p_transaction_id uuid,
  p_order_nsu text,
  p_transaction_nsu text,
  p_slug text,
  p_amount_cents bigint,
  p_paid_amount_cents bigint,
  p_capture_method text,
  p_installments smallint,
  p_receipt_url text default null,
  p_payload_json jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  v_tx public.payment_transactions%rowtype;
  v_appointment public.appointments%rowtype;
  v_method text;
  v_expected_amount_cents bigint;
  v_event_key text;
  v_event_exists boolean;
  v_financial_status public.financial_status;
  v_late boolean := false;
begin
  if p_order_nsu is null or p_order_nsu !~ '^[A-Za-z0-9._:-]{1,160}$' then
    raise exception using errcode='P0001',message='INFINITEPAY_ORDER_NSU_INVALID';
  end if;
  if p_transaction_nsu is null or p_transaction_nsu !~ '^[A-Za-z0-9._:-]{1,160}$' then
    raise exception using errcode='P0001',message='INFINITEPAY_TRANSACTION_NSU_INVALID';
  end if;
  if p_slug is null or p_slug !~ '^[A-Za-z0-9._:-]{1,160}$' then
    raise exception using errcode='P0001',message='INFINITEPAY_SLUG_INVALID';
  end if;
  if p_capture_method not in ('pix','credit_card') then
    raise exception using errcode='P0001',message='INFINITEPAY_CAPTURE_METHOD_INVALID';
  end if;
  if p_installments is null or p_installments<1 or p_installments>12 then
    raise exception using errcode='P0001',message='INFINITEPAY_INSTALLMENTS_INVALID';
  end if;
  if p_amount_cents is null or p_amount_cents<=0 then
    raise exception using errcode='P0001',message='INFINITEPAY_PAYMENT_AMOUNT_INVALID';
  end if;
  if p_paid_amount_cents is null or p_paid_amount_cents<0 then
    raise exception using errcode='P0001',message='INFINITEPAY_PAID_AMOUNT_INVALID';
  end if;

  perform public.expire_due_appointment_holds();

  select * into v_tx
  from public.payment_transactions
  where id=p_transaction_id
  for update;
  if not found then raise exception using errcode='P0001',message='PAYMENT_TRANSACTION_NOT_FOUND'; end if;
  if v_tx.provider<>'INFINITEPAY' or v_tx.transaction_type<>'CHARGE' then
    raise exception using errcode='P0001',message='PAYMENT_PROVIDER_MISMATCH';
  end if;
  if p_order_nsu<>v_tx.id::text then
    raise exception using errcode='P0001',message='INFINITEPAY_ORDER_NSU_MISMATCH';
  end if;

  v_expected_amount_cents:=round(v_tx.cash_amount*100)::bigint;
  if p_amount_cents<>v_expected_amount_cents then
    raise exception using errcode='P0001',message='INFINITEPAY_PAYMENT_AMOUNT_MISMATCH';
  end if;
  if v_tx.provider_payment_id is not null and v_tx.provider_payment_id<>p_transaction_nsu then
    raise exception using errcode='P0001',message='PROVIDER_PAYMENT_ID_MISMATCH';
  end if;

  v_method:=case when p_capture_method='pix' then 'PIX' else 'CARD' end;
  v_event_key:='payment_check:'||p_transaction_nsu||':'||p_slug;

  select exists(
    select 1 from public.payment_provider_events
    where provider='INFINITEPAY' and event_key=v_event_key
  ) into v_event_exists;

  if v_event_exists then
    return jsonb_build_object(
      'transaction_id',v_tx.id,
      'appointment_id',v_tx.appointment_id,
      'transaction_status',v_tx.status,
      'financial_status',(select financial_status from public.appointments where id=v_tx.appointment_id),
      'idempotent_replay',true
    );
  end if;

  select * into v_appointment
  from public.appointments
  where id=v_tx.appointment_id
  for update;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if;

  insert into public.payment_provider_events(
    provider,event_key,transaction_id,provider_payment_id,normalized_status,payload_json
  ) values(
    'INFINITEPAY',v_event_key,v_tx.id,p_transaction_nsu,'APPROVED',coalesce(p_payload_json,'{}'::jsonb)
  );

  update public.payment_transactions
  set provider_payment_id=p_transaction_nsu,
      status='APPROVED',
      method=v_method,
      installments=p_installments,
      provider_payload_json=coalesce(provider_payload_json,'{}'::jsonb) || jsonb_build_object(
        'order_nsu',p_order_nsu,
        'transaction_nsu',p_transaction_nsu,
        'slug',p_slug,
        'receipt_url',nullif(btrim(coalesce(p_receipt_url,'')),''),
        'capture_method',p_capture_method,
        'amount',p_amount_cents,
        'paid_amount',p_paid_amount_cents,
        'installments',p_installments,
        'payment_check',coalesce(p_payload_json,'{}'::jsonb)
      ),
      paid_at=coalesce(paid_at,now()),
      updated_at=now()
  where id=v_tx.id;

  v_financial_status:=public.refresh_appointment_financial_status(v_appointment.id);

  select * into v_appointment
  from public.appointments
  where id=v_appointment.id
  for update;

  if v_appointment.status='EXPIRED'
     or (v_appointment.status='AWAITING_PAYMENT'
         and (v_appointment.hold_expires_at is null or v_appointment.hold_expires_at<=now())) then
    v_late:=true;

    insert into public.payment_incidents(
      appointment_id,payment_transaction_id,incident_type,details_json
    ) values(
      v_appointment.id,v_tx.id,'PAYMENT_AFTER_EXPIRATION',jsonb_build_object(
        'provider','INFINITEPAY',
        'provider_payment_id',p_transaction_nsu,
        'cash_amount',v_tx.cash_amount,
        'contract_amount_settled',v_tx.contract_amount_settled,
        'appointment_status',v_appointment.status
      )
    ) on conflict(payment_transaction_id,incident_type) do nothing;

    insert into public.audit_logs(entity_type,entity_id,action,after_json,origin)
    values(
      'APPOINTMENT',v_appointment.id,'PAYMENT_AFTER_EXPIRATION',
      jsonb_build_object('payment_transaction_id',v_tx.id),'INFINITEPAY'
    );
  elsif v_appointment.status='AWAITING_PAYMENT' then
    perform public.confirm_appointment_internal(v_appointment.id,'PAYMENT_CONFIRMED');
    v_financial_status:=public.refresh_appointment_financial_status(v_appointment.id);
  end if;

  select * into v_appointment
  from public.appointments
  where id=v_tx.appointment_id;

  return jsonb_build_object(
    'transaction_id',v_tx.id,
    'appointment_id',v_tx.appointment_id,
    'transaction_status','APPROVED',
    'financial_status',v_appointment.financial_status,
    'appointment_status',v_appointment.status,
    'payment_after_expiration',v_late,
    'idempotent_replay',false
  );
end;
$$;

revoke all on function public.service_apply_infinitepay_payment_check(uuid,text,text,text,bigint,bigint,text,smallint,text,jsonb) from public, anon, authenticated;
grant execute on function public.service_apply_infinitepay_payment_check(uuid,text,text,text,bigint,bigint,text,smallint,text,jsonb) to service_role;
