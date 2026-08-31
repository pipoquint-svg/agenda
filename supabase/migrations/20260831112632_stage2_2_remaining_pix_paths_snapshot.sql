create or replace function public.service_resolve_appointment_pix_discount(p_appointment_id uuid)
returns numeric
language plpgsql
stable
security definer
set search_path to 'public','pg_temp'
as $function$
declare
  v_discount numeric(5,2);
begin
  select round(coalesce(
    a.pix_discount_percent_snapshot,
    s.pix_discount_percent,
    (select os.pix_discount_percent from public.operation_settings os where os.id=1),
    0
  ),2)
  into v_discount
  from public.appointments a
  left join public.services s on s.id=a.service_id
  where a.id=p_appointment_id;

  if not found then
    raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND';
  end if;
  if v_discount is null then
    raise exception using errcode='P0001',message='APPOINTMENT_PIX_DISCOUNT_CONFIGURATION_MISSING';
  end if;
  return v_discount;
end;
$function$;

revoke all on function public.service_resolve_appointment_pix_discount(uuid) from public,anon,authenticated;
grant execute on function public.service_resolve_appointment_pix_discount(uuid) to service_role;

create or replace function public.service_create_payment_intent_by_token(
  p_access_token text,
  p_payment_kind text,
  p_method text,
  p_request_key text
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
begin
  if p_payment_kind not in ('MINIMUM','FULL') then raise exception using errcode='P0001',message='INVALID_PAYMENT_KIND'; end if;
  if p_method not in ('PIX','CARD') then raise exception using errcode='P0001',message='PUBLIC_PAYMENT_METHOD_NOT_ALLOWED'; end if;
  if p_request_key is null or p_request_key !~ '^[A-Za-z0-9_-]{12,100}$' then raise exception using errcode='P0001',message='PAYMENT_REQUEST_KEY_INVALID'; end if;

  v_hash:=encode(digest(p_access_token,'sha256'),'hex');
  select appointment_id,balance_collection_id into v_appointment_id,v_collection_id
  from public.appointment_access_tokens
  where token_hash=v_hash and revoked_at is null and consumed_at is null and (expires_at is null or expires_at>now())
  order by created_at desc limit 1;
  if v_appointment_id is null then
    v_appointment_id:=public.resolve_appointment_access_token(p_access_token,'PAY');
  else
    perform public.resolve_appointment_access_token(p_access_token,'PAY');
  end if;
  select * into v_appointment from public.appointments where id=v_appointment_id;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if;
  v_idempotency_key:='public:'||v_appointment_id::text||':'||p_request_key;

  if v_collection_id is not null then
    perform public.expire_due_balance_collections();
    select * into v_collection from public.appointment_balance_collections where id=v_collection_id for update;
    if not found or v_collection.status<>'PENDING' or v_collection.expires_at<=public.balance_collection_clock() then
      raise exception using errcode='P0001',message='BALANCE_COLLECTION_INVALID_OR_EXPIRED';
    end if;
    if v_collection.appointment_id<>v_appointment_id then raise exception using errcode='P0001',message='BALANCE_COLLECTION_APPOINTMENT_MISMATCH'; end if;
    if v_appointment.status not in ('CONFIRMED','COMPLETED','NO_SHOW') then raise exception using errcode='P0001',message='BALANCE_COLLECTION_APPOINTMENT_NOT_PAYABLE'; end if;
    if coalesce(v_appointment.billing_mode_snapshot,'CHECKOUT')='INVOICE' then raise exception using errcode='P0001',message='BALANCE_COLLECTION_INVOICE_DENIED'; end if;
    if p_payment_kind<>'FULL' then raise exception using errcode='P0001',message='BALANCE_COLLECTION_FULL_PAYMENT_REQUIRED'; end if;

    select * into v_existing from public.payment_transactions where idempotency_key=v_idempotency_key;
    if found then
      if v_existing.appointment_id<>v_appointment_id or v_existing.method<>p_method
         or coalesce(v_existing.requested_payment_kind,case when v_existing.requested_percentage=100 then 'FULL' else null end)<>'FULL'
         or v_existing.balance_collection_id is distinct from v_collection_id then
        raise exception using errcode='P0001',message='IDEMPOTENCY_KEY_CONFLICT';
      end if;
      return jsonb_build_object('transaction_id',v_existing.id,'appointment_id',v_existing.appointment_id,'status',v_existing.status,
        'payment_kind','FULL_BALANCE','payment_percentage',v_existing.requested_percentage,'contract_amount_settled',v_existing.contract_amount_settled,
        'payment_discount_amount',v_existing.payment_discount_amount,'cash_amount',v_existing.cash_amount,'method',v_existing.method,
        'provider',v_existing.provider,'balance_collection_id',v_collection_id,'idempotent_replay',true);
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
    return jsonb_build_object('transaction_id',v_transaction_id,'appointment_id',v_appointment_id,'status','PENDING',
      'payment_kind','FULL_BALANCE','payment_percentage',100,'contract_balance_before',v_balance,'contract_amount_settled',v_balance,
      'payment_discount_amount',v_discount,'cash_amount',v_cash_amount,'method',p_method,'provider','MERCADO_PAGO',
      'balance_collection_id',v_collection_id,'idempotent_replay',false);
  end if;

  v_result:=public.create_payment_intent_v2(v_appointment_id,p_payment_kind,p_method,v_idempotency_key);
  return v_result||jsonb_build_object('balance_collection_id',null);
end;
$function$;

create or replace function public.service_create_reschedule_difference_payment_intent(
  p_policy_action_id uuid,
  p_method text,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_action public.appointment_policy_actions%rowtype;
  v_settlement public.appointment_change_settlements%rowtype;
  v_existing public.payment_transactions%rowtype;
  v_coverage numeric(12,2);
  v_outstanding numeric(12,2);
  v_discount_percent numeric(5,2);
  v_discount numeric(12,2);
  v_cash numeric(12,2);
  v_amounts jsonb;
  v_id uuid;
  v_method text:=upper(btrim(coalesce(p_method,'')));
begin
  if v_method not in ('PIX','CARD') then raise exception using errcode='P0001',message='PUBLIC_PAYMENT_METHOD_NOT_ALLOWED'; end if;
  if nullif(btrim(p_idempotency_key),'') is null then raise exception using errcode='P0001',message='IDEMPOTENCY_KEY_REQUIRED'; end if;
  select * into v_existing from public.payment_transactions where idempotency_key=p_idempotency_key;
  if found then
    if v_existing.policy_action_id is distinct from p_policy_action_id or v_existing.method<>v_method then raise exception using errcode='P0001',message='IDEMPOTENCY_KEY_CONFLICT'; end if;
    return jsonb_build_object('transaction_id',v_existing.id,'policy_action_id',p_policy_action_id,'appointment_id',v_existing.appointment_id,'status',v_existing.status,'contract_amount_settled',v_existing.contract_amount_settled,'payment_discount_amount',v_existing.payment_discount_amount,'cash_amount',v_existing.cash_amount,'method',v_existing.method,'provider',v_existing.provider,'idempotent_replay',true);
  end if;
  select * into v_action from public.appointment_policy_actions where id=p_policy_action_id for update;
  if not found or v_action.action_type<>'RESCHEDULE' or v_action.status not in ('AWAITING_DIFFERENCE_PAYMENT','PREVIEW') then raise exception using errcode='P0001',message='RESCHEDULE_ACTION_NOT_PAYABLE'; end if;
  select * into v_settlement from public.appointment_change_settlements where policy_action_id=v_action.id;
  if not found then raise exception using errcode='P0001',message='CHANGE_SETTLEMENT_NOT_FOUND'; end if;
  v_coverage:=round(greatest(public.appointment_contract_coverage_amount(v_action.appointment_id)-v_settlement.penalty_retained,0),2);
  v_outstanding:=round(greatest(v_settlement.confirmation_target_amount-v_coverage,0),2);
  if v_outstanding<=0 then raise exception using errcode='P0001',message='RESCHEDULE_DIFFERENCE_ALREADY_SATISFIED'; end if;
  v_discount_percent:=public.service_resolve_appointment_pix_discount(v_action.appointment_id);
  v_amounts:=public.service_calculate_payment_cash_amount(v_outstanding,v_method,v_discount_percent);
  v_discount:=(v_amounts->>'payment_discount_amount')::numeric;
  v_cash:=(v_amounts->>'cash_amount')::numeric;
  insert into public.payment_transactions(appointment_id,transaction_type,method,provider,status,contract_amount_settled,payment_discount_amount,cash_amount,idempotency_key,requested_percentage,payment_purpose,policy_action_id)
  values(v_action.appointment_id,'CHARGE',v_method,'MERCADO_PAGO','PENDING',v_outstanding,v_discount,v_cash,p_idempotency_key,null,'CONTRACT',v_action.id)
  returning id into v_id;
  return jsonb_build_object('transaction_id',v_id,'policy_action_id',v_action.id,'appointment_id',v_action.appointment_id,'status','PENDING','payment_kind','RESCHEDULE_DIFFERENCE','contract_amount_settled',v_outstanding,'payment_discount_amount',v_discount,'cash_amount',v_cash,'method',v_method,'provider','MERCADO_PAGO','idempotent_replay',false);
end;
$function$;

create or replace function public.service_get_public_payment_method_preview(p_access_token text)
returns jsonb
language plpgsql
security definer
set search_path to 'public','pg_temp'
as $function$
declare
  v_context jsonb;
  v_appointment_id uuid;
  v_minimum_contract numeric(12,2);
  v_full_contract numeric(12,2);
  v_discount_percent numeric(5,2);
  v_minimum_pix jsonb;
  v_full_pix jsonb;
begin
  v_context:=public.service_get_public_payment_context(p_access_token);
  v_appointment_id:=(v_context->>'appointment_id')::uuid;
  v_minimum_contract:=round(coalesce((v_context->>'minimum_due_contract_amount')::numeric,0),2);
  v_full_contract:=round(coalesce((v_context->>'contract_balance')::numeric,0),2);
  v_discount_percent:=public.service_resolve_appointment_pix_discount(v_appointment_id);
  v_minimum_pix:=public.service_calculate_payment_cash_amount(v_minimum_contract,'PIX',v_discount_percent);
  v_full_pix:=public.service_calculate_payment_cash_amount(v_full_contract,'PIX',v_discount_percent);
  return jsonb_build_object(
    'pix_discount_percent',v_discount_percent,
    'minimum_payment_type',v_context->>'minimum_payment_type',
    'minimum_payment_value',(v_context->>'minimum_payment_value')::numeric,
    'confirmation_percentage',(v_context->>'confirmation_percentage')::numeric,
    'minimum_available',coalesce((v_context->>'minimum_available')::boolean,false),
    'full_available',coalesce((v_context->>'full_available')::boolean,false),
    'minimum_due_contract_amount',v_minimum_contract,
    'minimum_due_card_cash_amount',v_minimum_contract,
    'minimum_due_pix_cash_amount',(v_minimum_pix->>'cash_amount')::numeric,
    'full_due_contract_amount',v_full_contract,
    'full_due_card_cash_amount',v_full_contract,
    'full_due_pix_cash_amount',(v_full_pix->>'cash_amount')::numeric
  );
end;
$function$;