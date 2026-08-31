create or replace function public.service_manual_contract_payment_suggestion(p_appointment_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public','pg_temp'
as $function$
declare
  v_appointment public.appointments%rowtype;
  v_service public.services%rowtype;
  v_summary jsonb;
  v_balance numeric(12,2);
  v_settled numeric(12,2);
  v_rule_type text;
  v_rule_value numeric(12,2);
  v_minimum_target numeric(12,2);
  v_minimum_due numeric(12,2);
  v_payment_mode text;
  v_suggested numeric(12,2);
  v_reason text;
begin
  select * into v_appointment from public.appointments where id=p_appointment_id;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if;

  select * into v_service from public.services where id=v_appointment.service_id;
  v_summary:=public.get_appointment_financial_summary(p_appointment_id);
  v_balance:=round(greatest(coalesce((v_summary->>'contract_balance')::numeric,0),0),2);
  v_settled:=round(greatest(coalesce((v_summary->>'contract_settled')::numeric,0),0),2);
  v_payment_mode:=coalesce(v_appointment.payment_mode_snapshot,v_service.payment_mode,'MINIMUM_OR_FULL');
  v_rule_type:=coalesce(v_appointment.checkout_minimum_payment_type_snapshot,v_service.checkout_minimum_payment_type,'PERCENT');
  v_rule_value:=coalesce(
    v_appointment.checkout_minimum_payment_value_snapshot,
    v_service.checkout_minimum_payment_value,
    v_service.confirmation_percentage,
    (select os.default_confirmation_percentage from public.operation_settings os where os.id=1),
    50
  );
  v_minimum_target:=public.service_checkout_minimum_target(coalesce(v_appointment.commercial_value,0),v_rule_type,v_rule_value);
  v_minimum_due:=round(greatest(v_minimum_target-v_settled,0),2);

  if v_payment_mode='FULL_ONLY' then
    v_suggested:=v_balance;
    v_reason:='FULL_BALANCE';
  elsif v_minimum_due>0.005 then
    v_suggested:=least(v_minimum_due,v_balance);
    v_reason:='CONFIRMATION_MINIMUM_REMAINING';
  else
    v_suggested:=v_balance;
    v_reason:='OUTSTANDING_BALANCE';
  end if;

  return jsonb_build_object(
    'appointment_id',p_appointment_id,
    'payment_mode',v_payment_mode,
    'contract_balance',v_balance,
    'contract_settled',v_settled,
    'minimum_payment_type',v_rule_type,
    'minimum_payment_value',v_rule_value,
    'confirmation_target_amount',v_minimum_target,
    'minimum_due_contract_amount',v_minimum_due,
    'suggested_contract_amount',round(greatest(coalesce(v_suggested,0),0),2),
    'suggestion_reason',v_reason,
    'automatic_pix_discount_applied',false
  );
end;
$function$;

revoke all on function public.service_manual_contract_payment_suggestion(uuid) from public,anon,authenticated;
grant execute on function public.service_manual_contract_payment_suggestion(uuid) to service_role;

create or replace function public.service_admin_get_manual_contract_payment_suggestion(p_appointment_id uuid,p_admin_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public','pg_temp'
as $function$
begin
  if not public.service_admin_has_permission(p_admin_id,'FINANCE_MANAGE') then
    raise exception using errcode='42501',message='ADMIN_PERMISSION_DENIED';
  end if;
  return public.service_manual_contract_payment_suggestion(p_appointment_id);
end;
$function$;

revoke all on function public.service_admin_get_manual_contract_payment_suggestion(uuid,uuid) from public,anon,authenticated;
grant execute on function public.service_admin_get_manual_contract_payment_suggestion(uuid,uuid) to service_role;

create or replace function public.register_manual_payment(
  p_appointment_id uuid,
  p_method text,
  p_contract_amount_settled numeric,
  p_notes text,
  p_created_by_admin_id uuid,
  p_confirm_if_pending boolean default false
)
returns jsonb
language plpgsql
set search_path to 'public'
as $function$
declare
  v_appointment public.appointments%rowtype;
  v_summary jsonb;
  v_balance numeric(12,2);
  v_discount numeric(12,2):=0;
  v_cash numeric(12,2);
  v_transaction_id uuid;
  v_financial_status public.financial_status;
  v_suggestion jsonb;
  v_suggested_amount numeric(12,2);
  v_amount_overridden boolean;
begin
  if p_method not in ('PIX','CARD','CASH','TRANSFER','CREDIT','COURTESY','OTHER') then raise exception using errcode='P0001',message='INVALID_MANUAL_PAYMENT_METHOD'; end if;
  if p_contract_amount_settled<=0 then raise exception using errcode='P0001',message='INVALID_MANUAL_PAYMENT_AMOUNT'; end if;

  select * into v_appointment from public.appointments where id=p_appointment_id for update;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if;
  if v_appointment.status in ('CANCELLED','EXPIRED') then raise exception using errcode='P0001',message='APPOINTMENT_NOT_PAYABLE'; end if;

  v_summary:=public.get_appointment_financial_summary(p_appointment_id);
  v_balance:=(v_summary->>'contract_balance')::numeric;
  if p_contract_amount_settled>v_balance then raise exception using errcode='P0001',message='PAYMENT_EXCEEDS_BALANCE'; end if;

  v_suggestion:=public.service_manual_contract_payment_suggestion(p_appointment_id);
  v_suggested_amount:=round(coalesce((v_suggestion->>'suggested_contract_amount')::numeric,0),2);
  v_amount_overridden:=abs(round(p_contract_amount_settled,2)-v_suggested_amount)>0.009;

  v_discount:=0;
  if p_method='COURTESY' then v_cash:=0; else v_cash:=round(p_contract_amount_settled,2); end if;

  insert into public.payment_transactions(
    appointment_id,transaction_type,method,provider,status,contract_amount_settled,payment_discount_amount,cash_amount,
    paid_at,created_by_admin_id,notes
  ) values(
    p_appointment_id,'CHARGE',p_method,'MANUAL','APPROVED',round(p_contract_amount_settled,2),0,v_cash,
    now(),p_created_by_admin_id,p_notes
  ) returning id into v_transaction_id;

  v_financial_status:=public.refresh_appointment_financial_status(p_appointment_id);
  if p_confirm_if_pending and v_appointment.status='AWAITING_PAYMENT' then
    perform public.confirm_appointment_internal(p_appointment_id,'MANUAL_PAYMENT_CONFIRMED');
    v_financial_status:=public.refresh_appointment_financial_status(p_appointment_id);
  end if;

  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,after_json,origin)
  values(
    p_created_by_admin_id,'APPOINTMENT',p_appointment_id,'MANUAL_PAYMENT_REGISTERED',
    jsonb_build_object(
      'transaction_id',v_transaction_id,'method',p_method,'contract_amount_settled',round(p_contract_amount_settled,2),
      'cash_amount',v_cash,'payment_discount_amount',0,'suggested_contract_amount',v_suggested_amount,
      'amount_overridden',v_amount_overridden,'suggestion_reason',v_suggestion->>'suggestion_reason','confirmed',p_confirm_if_pending
    ),'ADMIN'
  );

  return jsonb_build_object(
    'transaction_id',v_transaction_id,'appointment_id',p_appointment_id,
    'contract_amount_settled',round(p_contract_amount_settled,2),'payment_discount_amount',0,'cash_amount',v_cash,
    'suggested_contract_amount',v_suggested_amount,'amount_overridden',v_amount_overridden,
    'financial_status',v_financial_status,'appointment_status',(select status from public.appointments where id=p_appointment_id)
  );
end;
$function$;

create or replace function public.service_record_manual_contract_payment(
  p_appointment_id uuid,p_admin_id uuid,p_amount numeric,p_method text,p_ip text,p_user_agent text,p_request_id text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public','pg_temp'
as $function$
declare
  v_before numeric(12,2);
  v_after numeric(12,2);
  v_tx uuid;
  v_collection uuid;
  v_request_id uuid;
  v_method text:=upper(coalesce(btrim(p_method),''));
  v_customer_id uuid;
  v_suggestion jsonb;
  v_suggested_amount numeric(12,2);
  v_amount_overridden boolean;
begin
  if not public.service_admin_has_permission(p_admin_id,'FINANCE_MANAGE') then raise exception using errcode='42501',message='ADMIN_PERMISSION_DENIED'; end if;
  if p_amount is null or p_amount<=0 then raise exception using errcode='22023',message='MANUAL_PAYMENT_AMOUNT_INVALID'; end if;
  if v_method not in ('CASH','PIX') then raise exception using errcode='22023',message='MANUAL_PAYMENT_METHOD_INVALID'; end if;
  if coalesce(btrim(p_ip),'')='' or coalesce(btrim(p_user_agent),'')='' or coalesce(btrim(p_request_id),'')='' then raise exception using errcode='22023',message='AUTHORSHIP_ADMIN_EVIDENCE_REQUIRED'; end if;
  begin v_request_id:=p_request_id::uuid; exception when invalid_text_representation then raise exception using errcode='22023',message='REQUEST_ID_INVALID'; end;

  select primary_customer_id into v_customer_id from public.appointments where id=p_appointment_id for update;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if;
  if v_customer_id is null then raise exception using errcode='P0001',message='APPOINTMENT_CUSTOMER_REQUIRED'; end if;

  v_before:=round(greatest(coalesce((public.get_appointment_financial_summary(p_appointment_id)->>'contract_balance')::numeric,0),0),2);
  if v_before<=0.005 then raise exception using errcode='P0001',message='APPOINTMENT_ALREADY_SETTLED'; end if;
  if p_amount>v_before+0.005 then raise exception using errcode='22023',message='MANUAL_PAYMENT_EXCEEDS_BALANCE'; end if;

  v_suggestion:=public.service_manual_contract_payment_suggestion(p_appointment_id);
  v_suggested_amount:=round(coalesce((v_suggestion->>'suggested_contract_amount')::numeric,0),2);
  v_amount_overridden:=abs(round(p_amount,2)-v_suggested_amount)>0.009;

  insert into public.payment_transactions(
    appointment_id,transaction_type,method,provider,status,contract_amount_settled,payment_discount_amount,cash_amount,
    paid_at,created_by_admin_id,notes,payment_purpose
  ) values(
    p_appointment_id,'CHARGE',v_method,'MANUAL','APPROVED',round(p_amount,2),0,round(p_amount,2),now(),p_admin_id,
    'Recebimento manual registrado no painel','CONTRACT'
  ) returning id into v_tx;

  perform public.refresh_appointment_financial_status(p_appointment_id);
  v_after:=round(greatest(coalesce((public.get_appointment_financial_summary(p_appointment_id)->>'contract_balance')::numeric,0),0),2);
  select id into v_collection from public.appointment_balance_collections where appointment_id=p_appointment_id and status='PENDING' order by sequence desc limit 1;

  insert into public.audit_logs(entity_type,entity_id,action,after_json,origin,admin_user_id,request_id)
  values('APPOINTMENT',p_appointment_id,'MANUAL_CONTRACT_PAYMENT_RECORDED',jsonb_build_object(
    'payment_transaction_id',v_tx,'customer_id',v_customer_id,'method',v_method,'amount',round(p_amount,2),
    'suggested_contract_amount',v_suggested_amount,'amount_overridden',v_amount_overridden,
    'suggestion_reason',v_suggestion->>'suggestion_reason','balance_before',v_before,'balance_after',v_after,
    'ip_address',p_ip,'user_agent',p_user_agent
  ),'ADMIN_UI',p_admin_id,v_request_id);

  return jsonb_build_object(
    'payment_transaction_id',v_tx,'appointment_id',p_appointment_id,'customer_id',v_customer_id,
    'balance_before',v_before,'amount',round(p_amount,2),'balance_after',v_after,'settled',v_after<=0.005,
    'active_collection_id',v_collection,'suggested_contract_amount',v_suggested_amount,'amount_overridden',v_amount_overridden
  );
end;
$function$;

create or replace function public.service_admin_record_manual_receipt(
  p_appointment_id uuid,p_method text,p_amount numeric,p_paid_at timestamp with time zone,p_notes text,p_admin_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'public','pg_temp'
as $function$
declare
  v_appointment public.appointments%rowtype;
  v_method text:=upper(btrim(coalesce(p_method,'')));
  v_amount numeric(12,2):=round(coalesce(p_amount,0),2);
  v_paid_at timestamptz:=coalesce(p_paid_at,now());
  v_notes text:=nullif(btrim(coalesce(p_notes,'')),'');
  v_net_paid numeric(12,2);
  v_remaining numeric(12,2);
  v_tx public.payment_transactions%rowtype;
  v_financial_status public.financial_status;
  v_suggestion jsonb;
  v_suggested_amount numeric(12,2);
  v_amount_overridden boolean;
begin
  if not public.service_admin_has_permission(p_admin_id,'FINANCE_MANAGE') then raise exception 'ADMIN_PERMISSION_DENIED'; end if;
  if v_method not in ('CASH','PIX') then raise exception 'MANUAL_RECEIPT_METHOD_INVALID'; end if;
  if v_amount<=0 then raise exception 'MANUAL_RECEIPT_AMOUNT_INVALID'; end if;
  if v_paid_at>now()+interval '5 minutes' then raise exception 'MANUAL_RECEIPT_PAID_AT_FUTURE'; end if;
  if v_notes is not null and length(v_notes)>500 then raise exception 'MANUAL_RECEIPT_NOTES_TOO_LONG'; end if;

  select * into v_appointment from public.appointments where id=p_appointment_id for update;
  if not found then raise exception 'APPOINTMENT_NOT_FOUND'; end if;
  if v_appointment.primary_customer_id is null then raise exception 'MANUAL_RECEIPT_CUSTOMER_REQUIRED'; end if;
  if v_appointment.status::text in ('CANCELLED','EXPIRED') then raise exception 'MANUAL_RECEIPT_APPOINTMENT_CLOSED'; end if;
  if coalesce(v_appointment.commercial_value,0)<=0 then raise exception 'MANUAL_RECEIPT_CONTRACT_VALUE_REQUIRED'; end if;

  v_net_paid:=public.appointment_net_contract_settled_amount(p_appointment_id);
  v_remaining:=round(greatest(coalesce(v_appointment.commercial_value,0)-coalesce(v_net_paid,0),0),2);
  if v_amount>v_remaining+0.009 then raise exception 'MANUAL_RECEIPT_EXCEEDS_BALANCE'; end if;

  v_suggestion:=public.service_manual_contract_payment_suggestion(p_appointment_id);
  v_suggested_amount:=round(coalesce((v_suggestion->>'suggested_contract_amount')::numeric,0),2);
  v_amount_overridden:=abs(v_amount-v_suggested_amount)>0.009;

  insert into public.payment_transactions(
    appointment_id,transaction_type,method,provider,status,contract_amount_settled,payment_discount_amount,cash_amount,
    paid_at,created_by_admin_id,notes,payment_purpose
  ) values(
    p_appointment_id,'CHARGE',v_method,'MANUAL','APPROVED',v_amount,0,v_amount,v_paid_at,p_admin_id,v_notes,'CONTRACT'
  ) returning * into v_tx;

  v_financial_status:=public.refresh_appointment_financial_status(p_appointment_id);

  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
  values(
    p_admin_id,'PAYMENT_TRANSACTION',v_tx.id,'MANUAL_RECEIPT_RECORDED',null,
    jsonb_build_object(
      'appointment_id',p_appointment_id,'customer_id',v_appointment.primary_customer_id,'method',v_method,'amount',v_amount,
      'paid_at',v_paid_at,'financial_status',v_financial_status,'suggested_contract_amount',v_suggested_amount,
      'amount_overridden',v_amount_overridden,'suggestion_reason',v_suggestion->>'suggestion_reason'
    ),'ADMIN_UI'
  );

  return jsonb_build_object(
    'transaction',to_jsonb(v_tx),'appointment_id',p_appointment_id,'customer_id',v_appointment.primary_customer_id,
    'financial_status',v_financial_status,'net_paid',public.appointment_net_contract_settled_amount(p_appointment_id),
    'remaining_due',round(greatest(coalesce(v_appointment.commercial_value,0)-public.appointment_net_contract_settled_amount(p_appointment_id),0),2),
    'suggested_contract_amount',v_suggested_amount,'amount_overridden',v_amount_overridden
  );
end;
$function$;