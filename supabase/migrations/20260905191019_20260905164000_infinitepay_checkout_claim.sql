-- Gate 2: fail-closed InfinitePay hosted-checkout link lifecycle.
-- The public HTTP boundary calls only these service-role RPCs; browser roles stay denied.

create or replace function public.service_claim_infinitepay_checkout_by_token(
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
  v_hash text;
  v_appointment_id uuid;
  v_collection_id uuid;
  v_appointment public.appointments%rowtype;
  v_tx public.payment_transactions%rowtype;
  v_intent jsonb;
  v_payload jsonb;
  v_link_state text;
  v_checkout_url text;
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
  where id=v_appointment_id
  for update;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if;
  if coalesce(v_appointment.payment_provider_snapshot,'MERCADO_PAGO')<>'INFINITEPAY' then
    raise exception using errcode='P0001',message='PAYMENT_PROVIDER_MISMATCH';
  end if;

  -- One unresolved hosted checkout per appointment/payment-kind/collection. This
  -- intentionally ignores the browser request key so a refreshed page cannot create
  -- a second InfinitePay link while the first provider request is still unresolved.
  select * into v_tx
  from public.payment_transactions
  where appointment_id=v_appointment_id
    and provider='INFINITEPAY'
    and transaction_type='CHARGE'
    and status='PENDING'
    and coalesce(requested_payment_kind,case when requested_percentage=100 then 'FULL' else 'MINIMUM' end)=p_payment_kind
    and balance_collection_id is not distinct from v_collection_id
  order by created_at desc
  limit 1
  for update;

  if found then
    v_payload:=coalesce(v_tx.provider_payload_json,'{}'::jsonb);
    v_link_state:=coalesce(v_payload->>'link_state','CREATE_STARTED');
    v_checkout_url:=nullif(v_payload->>'checkout_url','');
    return jsonb_build_object(
      'transaction_id',v_tx.id,
      'appointment_id',v_tx.appointment_id,
      'status',v_tx.status,
      'payment_kind',case when p_payment_kind='FULL' then 'FULL_BALANCE' else 'CONFIRMATION_MINIMUM' end,
      'payment_percentage',v_tx.requested_percentage,
      'contract_amount_settled',v_tx.contract_amount_settled,
      'payment_discount_amount',v_tx.payment_discount_amount,
      'cash_amount',v_tx.cash_amount,
      'method',v_tx.method,
      'provider',v_tx.provider,
      'balance_collection_id',v_tx.balance_collection_id,
      'idempotent_replay',true,
      'link_creation_claimed',false,
      'link_state',v_link_state,
      'checkout_url',v_checkout_url
    );
  end if;

  v_intent:=public.service_create_infinitepay_payment_intent_by_token(
    p_access_token,p_payment_kind,p_request_key
  );

  if coalesce(v_intent->>'status','')<>'PENDING' then
    raise exception using errcode='P0001',message='INFINITEPAY_INTENT_NOT_PENDING';
  end if;

  select * into v_tx
  from public.payment_transactions
  where id=(v_intent->>'transaction_id')::uuid
  for update;
  if not found or v_tx.provider<>'INFINITEPAY' or v_tx.transaction_type<>'CHARGE' or v_tx.status<>'PENDING' then
    raise exception using errcode='P0001',message='INFINITEPAY_INTENT_NOT_PENDING';
  end if;

  update public.payment_transactions
  set provider_payload_json=coalesce(provider_payload_json,'{}'::jsonb) || jsonb_build_object(
        'link_state','CREATE_STARTED',
        'link_started_at',now()
      ),
      updated_at=now()
  where id=v_tx.id;

  return v_intent || jsonb_build_object(
    'link_creation_claimed',true,
    'link_state','CREATE_STARTED',
    'checkout_url',null
  );
end;
$$;

revoke all on function public.service_claim_infinitepay_checkout_by_token(text,text,text) from public, anon, authenticated;
grant execute on function public.service_claim_infinitepay_checkout_by_token(text,text,text) to service_role;

create or replace function public.service_record_infinitepay_checkout_link_result(
  p_transaction_id uuid,
  p_outcome text,
  p_checkout_url text default null,
  p_payload_json jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  v_tx public.payment_transactions%rowtype;
  v_url text;
begin
  if p_outcome not in ('READY','REJECTED') then
    raise exception using errcode='P0001',message='INFINITEPAY_LINK_OUTCOME_INVALID';
  end if;

  select * into v_tx
  from public.payment_transactions
  where id=p_transaction_id
  for update;
  if not found or v_tx.provider<>'INFINITEPAY' or v_tx.transaction_type<>'CHARGE' then
    raise exception using errcode='P0001',message='INFINITEPAY_PAYMENT_TRANSACTION_NOT_FOUND';
  end if;
  if v_tx.status<>'PENDING' then
    raise exception using errcode='P0001',message='INFINITEPAY_PAYMENT_TRANSACTION_NOT_PENDING';
  end if;
  if coalesce(v_tx.provider_payload_json->>'link_state','')<>'CREATE_STARTED' then
    raise exception using errcode='P0001',message='INFINITEPAY_LINK_NOT_CLAIMED';
  end if;

  if p_outcome='READY' then
    v_url:=nullif(btrim(coalesce(p_checkout_url,'')),'');
    if v_url is null or v_url !~ '^https://checkout[.]infinitepay[.]com[.]br(?:/|$)' then
      raise exception using errcode='P0001',message='INFINITEPAY_CHECKOUT_URL_INVALID';
    end if;

    update public.payment_transactions
    set provider_payload_json=coalesce(provider_payload_json,'{}'::jsonb) || jsonb_build_object(
          'link_state','READY',
          'checkout_url',v_url,
          'link_ready_at',now(),
          'link_response',coalesce(p_payload_json,'{}'::jsonb)
        ),
        updated_at=now()
    where id=v_tx.id;

    return jsonb_build_object(
      'transaction_id',v_tx.id,
      'status','PENDING',
      'link_state','READY',
      'checkout_url',v_url
    );
  end if;

  update public.payment_transactions
  set status='REJECTED',
      provider_payload_json=coalesce(provider_payload_json,'{}'::jsonb) || jsonb_build_object(
        'link_state','REJECTED',
        'link_rejected_at',now(),
        'link_response',coalesce(p_payload_json,'{}'::jsonb)
      ),
      updated_at=now()
  where id=v_tx.id;

  if not exists(
    select 1 from public.payment_transactions pt
    where pt.appointment_id=v_tx.appointment_id
      and pt.transaction_type='CHARGE'
      and pt.status='APPROVED'
  ) then
    update public.appointments
    set financial_status='REJECTED',updated_at=now()
    where id=v_tx.appointment_id and status='AWAITING_PAYMENT';
  else
    perform public.refresh_appointment_financial_status(v_tx.appointment_id);
  end if;

  insert into public.audit_logs(entity_type,entity_id,action,after_json,origin)
  values(
    'APPOINTMENT',v_tx.appointment_id,'PAYMENT_INTENT_PROVIDER_REJECTED',
    jsonb_build_object('payment_transaction_id',v_tx.id,'provider','INFINITEPAY'),
    'INFINITEPAY'
  );

  return jsonb_build_object(
    'transaction_id',v_tx.id,
    'status','REJECTED',
    'link_state','REJECTED',
    'checkout_url',null
  );
end;
$$;

revoke all on function public.service_record_infinitepay_checkout_link_result(uuid,text,text,jsonb) from public, anon, authenticated;
grant execute on function public.service_record_infinitepay_checkout_link_result(uuid,text,text,jsonb) to service_role;
