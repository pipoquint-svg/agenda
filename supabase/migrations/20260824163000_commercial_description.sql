-- One commercial description for checkout, payment provider, receipts and future transactional messages.

create or replace function public.format_contracted_duration(p_minutes integer)
returns text
language plpgsql
immutable
set search_path=public
as $$
declare v_hours integer; v_rest integer;
begin
  if p_minutes is null or p_minutes <= 0 then
    raise exception using errcode='P0001',message='INVALID_CONTRACTED_MINUTES';
  end if;
  v_hours := p_minutes / 60;
  v_rest := p_minutes % 60;
  if v_hours = 0 then return v_rest::text || ' min'; end if;
  if v_rest = 0 then return v_hours::text || 'h'; end if;
  return v_hours::text || 'h' || lpad(v_rest::text,2,'0');
end;
$$;

create or replace function public.build_commercial_description(
  p_service_name text,
  p_duration_mode text,
  p_contracted_minutes integer
)
returns text
language plpgsql
immutable
set search_path=public
as $$
declare v_product text;
begin
  if p_service_name is null or btrim(p_service_name)='' then
    raise exception using errcode='P0001',message='COMMERCIAL_PRODUCT_NAME_MISSING';
  end if;
  if p_duration_mode='BLOCKS' then
    v_product := 'Locação de estúdio fotográfico';
  else
    v_product := btrim(p_service_name);
  end if;
  return v_product || ', ' || public.format_contracted_duration(p_contracted_minutes);
end;
$$;

create or replace function public.build_provider_commercial_description(
  p_service_name text,
  p_duration_mode text,
  p_contracted_minutes integer
)
returns text
language plpgsql
immutable
set search_path=public
as $$
declare v_full text; v_fallback text;
begin
  v_full := public.build_commercial_description(p_service_name,p_duration_mode,p_contracted_minutes);
  if char_length(v_full) <= 150 then return v_full; end if;
  v_fallback := 'Atendimento fotográfico, ' || public.format_contracted_duration(p_contracted_minutes);
  if char_length(v_fallback) > 150 then
    raise exception using errcode='P0001',message='PROVIDER_COMMERCIAL_DESCRIPTION_TOO_LONG';
  end if;
  return v_fallback;
end;
$$;

create or replace function public.appointment_commercial_description(p_appointment_id uuid)
returns text
language plpgsql
stable
security definer
set search_path=public
as $$
declare v_appointment public.appointments%rowtype; v_mode text;
begin
  select * into v_appointment from public.appointments where id=p_appointment_id and deleted_at is null;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if;
  select duration_mode into v_mode from public.services where id=v_appointment.service_id;
  return public.build_commercial_description(
    v_appointment.service_name_snapshot,
    coalesce(v_mode,'FIXED'),
    coalesce(v_appointment.contracted_minutes,v_appointment.base_duration_snapshot,v_appointment.duration_minutes)
  );
end;
$$;

create or replace function public.appointment_provider_commercial_description(p_appointment_id uuid)
returns text
language plpgsql
stable
security definer
set search_path=public
as $$
declare v_appointment public.appointments%rowtype; v_mode text;
begin
  select * into v_appointment from public.appointments where id=p_appointment_id and deleted_at is null;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if;
  select duration_mode into v_mode from public.services where id=v_appointment.service_id;
  return public.build_provider_commercial_description(
    v_appointment.service_name_snapshot,
    coalesce(v_mode,'FIXED'),
    coalesce(v_appointment.contracted_minutes,v_appointment.base_duration_snapshot,v_appointment.duration_minutes)
  );
end;
$$;

create or replace function public.service_get_public_payment_context(p_access_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_appointment_id uuid;
  v_appointment public.appointments%rowtype;
  v_customer public.customers%rowtype;
  v_summary jsonb;
  v_confirmation_percentage numeric(5,2);
  v_confirmation_target numeric(12,2);
  v_settled numeric(12,2);
  v_minimum_due numeric(12,2);
  v_description text;
  v_provider_description text;
begin
  v_appointment_id := public.resolve_appointment_access_token(p_access_token,'PAY');
  select * into v_appointment from public.appointments where id=v_appointment_id;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if;
  if v_appointment.status not in ('AWAITING_PAYMENT','CONFIRMED') then raise exception using errcode='P0001',message='APPOINTMENT_NOT_PAYABLE'; end if;
  if v_appointment.status='AWAITING_PAYMENT' and (v_appointment.hold_expires_at is null or v_appointment.hold_expires_at<=now()) then
    raise exception using errcode='P0001',message='PAYMENT_HOLD_EXPIRED';
  end if;

  select * into v_customer from public.customers where id=v_appointment.primary_customer_id;
  if v_customer.id is null then raise exception using errcode='P0001',message='CUSTOMER_NOT_FOUND'; end if;

  v_confirmation_percentage := v_appointment.confirmation_percentage_snapshot;
  if v_confirmation_percentage is null then raise exception using errcode='P0001',message='APPOINTMENT_CONFIRMATION_SNAPSHOT_MISSING'; end if;

  v_summary := public.get_appointment_financial_summary(v_appointment.id);
  v_settled := (v_summary->>'contract_settled')::numeric;
  v_confirmation_target := round(coalesce(v_appointment.commercial_value,0)*v_confirmation_percentage/100,2);
  v_minimum_due := round(greatest(v_confirmation_target-v_settled,0),2);
  v_description := public.appointment_commercial_description(v_appointment.id);
  v_provider_description := public.appointment_provider_commercial_description(v_appointment.id);

  return jsonb_build_object(
    'appointment_id',v_appointment.id,'public_code',v_appointment.public_code,
    'appointment_status',v_appointment.status,'financial_status',v_appointment.financial_status,
    'service_name',v_appointment.service_name_snapshot,'commercial_description',v_description,
    'provider_commercial_description',v_provider_description,
    'contracted_minutes',coalesce(v_appointment.contracted_minutes,v_appointment.base_duration_snapshot,v_appointment.duration_minutes),
    'hold_expires_at',v_appointment.hold_expires_at,
    'commercial_value',coalesce(v_appointment.commercial_value,0),'contract_settled',v_settled,
    'contract_balance',(v_summary->>'contract_balance')::numeric,
    'confirmation_percentage',v_confirmation_percentage,'confirmation_target_amount',v_confirmation_target,
    'minimum_due_contract_amount',v_minimum_due,'minimum_available',v_minimum_due>0,
    'full_available',(v_summary->>'contract_balance')::numeric>0,
    'payer',jsonb_build_object('name',v_customer.name,'email',v_customer.email,
      'tax_id',regexp_replace(coalesce(v_customer.cpf_cnpj,''),'\D','','g'))
  );
end;
$$;

revoke all on function public.format_contracted_duration(integer) from public,anon,authenticated;
revoke all on function public.build_commercial_description(text,text,integer) from public,anon,authenticated;
revoke all on function public.build_provider_commercial_description(text,text,integer) from public,anon,authenticated;
revoke all on function public.appointment_commercial_description(uuid) from public,anon,authenticated;
revoke all on function public.appointment_provider_commercial_description(uuid) from public,anon,authenticated;
grant execute on function public.appointment_commercial_description(uuid) to service_role;
grant execute on function public.appointment_provider_commercial_description(uuid) to service_role;
