create or replace function public.service_get_public_payment_context(p_access_token text)
returns jsonb
language plpgsql
security definer
set search_path to 'public','extensions'
as $function$
declare
  v_appointment_id uuid;
  v_appointment public.appointments%rowtype;
  v_service public.services%rowtype;
  v_customer public.customers%rowtype;
  v_summary jsonb;
  v_rule_type text;
  v_rule_value numeric(12,2);
  v_minimum_target numeric(12,2);
  v_settled numeric(12,2);
  v_minimum_due numeric(12,2);
  v_description text;
  v_provider_description text;
  v_payment_mode text;
  v_card_max_installments integer;
  v_pix_discount_percent numeric(5,2);
  v_policy_allows_minimum boolean;
  v_policy_allows_full boolean;
begin
  v_appointment_id:=public.resolve_appointment_access_token(p_access_token,'PAY');
  select * into v_appointment from public.appointments where id=v_appointment_id;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if;
  if v_appointment.status not in ('AWAITING_PAYMENT','CONFIRMED') then raise exception using errcode='P0001',message='APPOINTMENT_NOT_PAYABLE'; end if;
  if v_appointment.status='AWAITING_PAYMENT' and (v_appointment.hold_expires_at is null or v_appointment.hold_expires_at<=now()) then
    raise exception using errcode='P0001',message='PAYMENT_HOLD_EXPIRED';
  end if;

  select * into v_service from public.services where id=v_appointment.service_id;
  select * into v_customer from public.customers where id=v_appointment.primary_customer_id;
  if v_customer.id is null then raise exception using errcode='P0001',message='CUSTOMER_NOT_FOUND'; end if;

  v_rule_type:=coalesce(v_appointment.checkout_minimum_payment_type_snapshot,v_service.checkout_minimum_payment_type,'PERCENT');
  v_rule_value:=coalesce(v_appointment.checkout_minimum_payment_value_snapshot,v_service.checkout_minimum_payment_value,v_appointment.confirmation_percentage_snapshot,v_service.confirmation_percentage);
  if v_rule_value is null then raise exception using errcode='P0001',message='APPOINTMENT_CONFIRMATION_SNAPSHOT_MISSING'; end if;

  v_payment_mode:=coalesce(v_appointment.payment_mode_snapshot,v_service.payment_mode,'MINIMUM_OR_FULL');
  v_card_max_installments:=coalesce(v_appointment.card_max_installments_snapshot,v_service.card_max_installments,6);
  v_pix_discount_percent:=public.service_resolve_appointment_pix_discount(v_appointment.id);
  v_policy_allows_minimum:=v_payment_mode in ('MINIMUM_ONLY','MINIMUM_OR_FULL');
  v_policy_allows_full:=v_payment_mode in ('FULL_ONLY','MINIMUM_OR_FULL');

  v_summary:=public.get_appointment_financial_summary(v_appointment.id);
  v_settled:=(v_summary->>'contract_settled')::numeric;
  v_minimum_target:=public.service_checkout_minimum_target(v_appointment.commercial_value,v_rule_type,v_rule_value);
  v_minimum_due:=round(greatest(v_minimum_target-v_settled,0),2);
  v_description:=public.appointment_commercial_description(v_appointment.id);
  v_provider_description:=public.appointment_provider_commercial_description(v_appointment.id);

  return jsonb_build_object(
    'appointment_id',v_appointment.id,'public_code',v_appointment.public_code,'appointment_status',v_appointment.status,
    'financial_status',v_appointment.financial_status,'service_name',v_appointment.service_name_snapshot,
    'commercial_description',v_description,'provider_commercial_description',v_provider_description,
    'contracted_minutes',coalesce(v_appointment.contracted_minutes,v_appointment.base_duration_snapshot,v_appointment.duration_minutes),
    'hold_expires_at',v_appointment.hold_expires_at,'commercial_value',coalesce(v_appointment.commercial_value,0),
    'contract_settled',v_settled,'contract_balance',(v_summary->>'contract_balance')::numeric,
    'minimum_payment_type',v_rule_type,'minimum_payment_value',v_rule_value,
    'confirmation_percentage',v_appointment.confirmation_percentage_snapshot,
    'confirmation_target_amount',v_minimum_target,'minimum_due_contract_amount',v_minimum_due,
    'minimum_available',v_minimum_due>0,'full_available',(v_summary->>'contract_balance')::numeric>0,
    'payment_mode',v_payment_mode,'policy_allows_minimum',v_policy_allows_minimum,'policy_allows_full',v_policy_allows_full,
    'pix_discount_percent',v_pix_discount_percent,'card_max_installments',v_card_max_installments,
    'payer',jsonb_build_object('name',v_customer.name,'email',v_customer.email,'tax_id',regexp_replace(coalesce(v_customer.cpf_cnpj,''),'\\D','','g'))
  );
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
    'payment_mode',v_context->>'payment_mode',
    'policy_allows_minimum',coalesce((v_context->>'policy_allows_minimum')::boolean,false),
    'policy_allows_full',coalesce((v_context->>'policy_allows_full')::boolean,false),
    'card_max_installments',(v_context->>'card_max_installments')::integer,
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