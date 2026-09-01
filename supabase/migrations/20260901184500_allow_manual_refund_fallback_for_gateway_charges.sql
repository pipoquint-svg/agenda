create or replace function public.service_admin_record_cancellation_manual_refund(p_policy_action_id uuid, p_method text, p_cash_amount numeric, p_reference text, p_paid_at timestamp with time zone, p_admin_id uuid, p_ip inet, p_user_agent text, p_request_id text)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_action public.appointment_policy_actions%rowtype;
  v_plan jsonb;
  v_after jsonb;
  v_method text:=upper(btrim(coalesce(p_method,'')));
  v_amount numeric(12,2):=round(coalesce(p_cash_amount,0),2);
  v_left numeric(12,2);
  v_parent public.payment_transactions%rowtype;
  v_refunded_cash numeric(12,2);
  v_refunded_contract numeric(12,2);
  v_cash_remaining numeric(12,2);
  v_contract_remaining numeric(12,2);
  v_take numeric(12,2);
  v_contract_take numeric(12,2);
  v_total_recorded numeric(12,2);
  v_first_id uuid;
  v_refund_id uuid;
  v_paid_at timestamptz:=coalesce(p_paid_at,now());
  v_request_prefix text;
begin
  if not public.service_admin_has_permission(p_admin_id,'FINANCE_MANAGE') then
    raise exception using errcode='P0001',message='ADMIN_PERMISSION_DENIED';
  end if;
  if v_method not in('CASH','PIX') then
    raise exception using errcode='P0001',message='MANUAL_REFUND_METHOD_INVALID';
  end if;
  if v_amount<=0 then
    raise exception using errcode='P0001',message='MANUAL_REFUND_AMOUNT_INVALID';
  end if;
  if nullif(btrim(coalesce(p_reference,'')),'') is null or p_ip is null or nullif(btrim(coalesce(p_user_agent,'')),'') is null or nullif(btrim(coalesce(p_request_id,'')),'') is null then
    raise exception using errcode='P0001',message='MANUAL_REFUND_EVIDENCE_REQUIRED';
  end if;

  select * into v_action
  from public.appointment_policy_actions
  where id=p_policy_action_id
  for update;

  if not found or v_action.action_type<>'CANCEL' or v_action.settlement_choice<>'REFUND' then
    raise exception using errcode='P0001',message='CANCELLATION_REFUND_NOT_PENDING';
  end if;

  v_request_prefix:='manual-cancel-refund:'||p_policy_action_id::text||':'||p_request_id||':';

  select id into v_first_id
  from public.payment_transactions
  where policy_action_id=p_policy_action_id
    and transaction_type='REFUND'
    and idempotency_key like v_request_prefix||'%'
  order by created_at,id
  limit 1;

  if v_first_id is not null then
    v_after:=public.service_get_cancellation_refund_plan(p_policy_action_id);
    return v_after||jsonb_build_object(
      'refund_transaction_id',v_first_id,
      'manual_refund_recorded',v_amount,
      'method',v_method,
      'paid_at',v_paid_at,
      'idempotent_replay',true
    );
  end if;

  if v_action.status<>'PENDING_REFUND' then
    raise exception using errcode='P0001',message='CANCELLATION_REFUND_NOT_PENDING';
  end if;

  v_plan:=public.service_get_cancellation_refund_plan(p_policy_action_id);
  if v_amount>coalesce((v_plan->>'remaining_refund_cash')::numeric,0)+0.009 then
    raise exception using errcode='P0001',message='MANUAL_REFUND_EXCEEDS_REMAINING_AMOUNT';
  end if;

  v_left:=v_amount;
  for v_parent in
    select *
    from public.payment_transactions
    where appointment_id=v_action.appointment_id
      and transaction_type='CHARGE'
      and payment_purpose='CONTRACT'
      and status in('APPROVED','PARTIALLY_REFUNDED','REFUNDED')
      and cash_amount>0
    order by (provider='MERCADO_PAGO' and provider_payment_id is not null), paid_at nulls last,created_at,id
    for update
  loop
    exit when v_left<=0.009;

    select coalesce(sum(cash_amount),0),coalesce(sum(contract_amount_settled),0)
    into v_refunded_cash,v_refunded_contract
    from public.payment_transactions
    where parent_transaction_id=v_parent.id
      and transaction_type='REFUND'
      and status in('APPROVED','REFUNDED');

    v_cash_remaining:=greatest(v_parent.cash_amount-v_refunded_cash,0);
    v_contract_remaining:=greatest(v_parent.contract_amount_settled-v_refunded_contract,0);
    if v_cash_remaining<=0.009 then
      continue;
    end if;

    v_take:=least(v_left,v_cash_remaining);
    v_contract_take:=case
      when v_cash_remaining>0 then least(v_contract_remaining,round(v_take*v_contract_remaining/v_cash_remaining,2))
      else 0
    end;

    insert into public.payment_transactions(
      appointment_id,transaction_type,method,provider,status,contract_amount_settled,cash_amount,
      parent_transaction_id,paid_at,created_by_admin_id,notes,idempotency_key,policy_action_id,payment_purpose
    ) values (
      v_action.appointment_id,'REFUND',v_method,'MANUAL','APPROVED',v_contract_take,v_take,
      v_parent.id,v_paid_at,p_admin_id,btrim(p_reference),v_request_prefix||v_parent.id::text,p_policy_action_id,'CONTRACT'
    ) returning id into v_refund_id;

    if v_first_id is null then
      v_first_id:=v_refund_id;
    end if;

    select coalesce(sum(cash_amount),0)
    into v_refunded_cash
    from public.payment_transactions
    where parent_transaction_id=v_parent.id
      and transaction_type='REFUND'
      and status in('APPROVED','REFUNDED');

    update public.payment_transactions
    set status=case when v_refunded_cash>=cash_amount-0.009 then 'REFUNDED' else 'PARTIALLY_REFUNDED' end,
        updated_at=now()
    where id=v_parent.id;

    v_left:=v_left-v_take;
  end loop;

  if v_left>0.009 then
    raise exception using errcode='P0001',message='MANUAL_REFUND_ALLOCATION_FAILED';
  end if;

  select coalesce(sum(cash_amount),0)::numeric(12,2)
  into v_total_recorded
  from public.payment_transactions
  where policy_action_id=p_policy_action_id
    and transaction_type='REFUND'
    and status in('APPROVED','REFUNDED');

  if v_total_recorded>=v_action.refundable_amount-0.009 then
    update public.appointment_policy_actions
    set status='REFUNDED',updated_at=now()
    where id=p_policy_action_id;
  end if;

  perform public.refresh_appointment_financial_status(v_action.appointment_id);

  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,after_json,origin)
  values(
    p_admin_id,'APPOINTMENT',v_action.appointment_id,'MANUAL_CANCELLATION_REFUND_RECORDED',
    jsonb_build_object(
      'policy_action_id',p_policy_action_id,
      'refund_transaction_id',v_first_id,
      'method',v_method,
      'cash_amount',v_amount,
      'reference',btrim(p_reference),
      'paid_at',v_paid_at,
      'request_id',p_request_id
    ),
    'ADMIN'
  );

  v_after:=public.service_get_cancellation_refund_plan(p_policy_action_id);
  return v_after||jsonb_build_object(
    'refund_transaction_id',v_first_id,
    'manual_refund_recorded',v_amount,
    'method',v_method,
    'paid_at',v_paid_at,
    'idempotent_replay',false
  );
end;
$function$;