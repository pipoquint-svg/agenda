create or replace function public.service_admin_create_customer(
  p_customer_type text,
  p_name text,
  p_cpf_cnpj text,
  p_email text,
  p_phone text,
  p_address text,
  p_birth_date date,
  p_admin_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'public','pg_temp'
as $$
declare
  v_type text := upper(btrim(coalesce(p_customer_type,'PERSON')));
  v_name text := nullif(btrim(coalesce(p_name,'')),'');
  v_document text := nullif(regexp_replace(coalesce(p_cpf_cnpj,''),'[^0-9]','','g'),'');
  v_email text := nullif(lower(btrim(coalesce(p_email,''))),'');
  v_phone text := nullif(btrim(coalesce(p_phone,'')),'');
  v_address text := nullif(btrim(coalesce(p_address,'')),'');
  v_id uuid;
begin
  if not public.service_admin_has_permission(p_admin_id,'CUSTOMERS_MANAGE') then raise exception 'ADMIN_PERMISSION_DENIED'; end if;
  if v_type not in ('PERSON','BUSINESS') then raise exception 'CUSTOMER_TYPE_INVALID'; end if;
  if v_name is null or length(v_name)>200 then raise exception 'CUSTOMER_NAME_INVALID'; end if;
  if v_document is not null and length(v_document) not in (11,14) then raise exception 'CUSTOMER_CPF_CNPJ_INVALID'; end if;
  if v_email is not null and (length(v_email)>254 or v_email !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$') then raise exception 'CUSTOMER_EMAIL_INVALID'; end if;
  if v_phone is not null and length(v_phone)>50 then raise exception 'CUSTOMER_PHONE_INVALID'; end if;
  if v_address is not null and length(v_address)>500 then raise exception 'CUSTOMER_ADDRESS_INVALID'; end if;
  if p_birth_date is not null and p_birth_date>current_date then raise exception 'CUSTOMER_BIRTH_DATE_FUTURE'; end if;
  if v_type='BUSINESS' and p_birth_date is not null then raise exception 'CUSTOMER_BIRTH_DATE_NOT_APPLICABLE'; end if;
  if v_email is not null and exists(select 1 from public.customers where lower(email)=v_email) then raise exception 'CUSTOMER_EMAIL_ALREADY_EXISTS'; end if;
  begin
    insert into public.customers(customer_type,name,cpf_cnpj,email,phone,address,birth_date)
    values(v_type,v_name,v_document,v_email,v_phone,v_address,p_birth_date)
    returning id into v_id;
  exception when unique_violation then
    raise exception 'CUSTOMER_EMAIL_ALREADY_EXISTS';
  end;
  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
  values(p_admin_id,'CUSTOMER',v_id,'CUSTOMER_CREATED',null,
    jsonb_build_object('customer_type',v_type,'fields_present',jsonb_build_object(
      'cpf_cnpj',v_document is not null,'email',v_email is not null,'phone',v_phone is not null,'address',v_address is not null,'birth_date',p_birth_date is not null
    )),'ADMIN_UI');
  return public.service_admin_get_customer_commercial_profile(v_id);
end;
$$;

revoke all on function public.service_admin_create_customer(text,text,text,text,text,text,date,uuid) from public, anon, authenticated;
grant execute on function public.service_admin_create_customer(text,text,text,text,text,text,date,uuid) to service_role;

create or replace function public.service_admin_update_customer_identity(
  p_customer_id uuid,
  p_name text,
  p_cpf_cnpj text,
  p_email text,
  p_phone text,
  p_address text,
  p_birth_date date,
  p_admin_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'public','pg_temp'
as $$
declare
  v_current public.customers%rowtype;
  v_name text := nullif(btrim(coalesce(p_name,'')),'');
  v_document text := nullif(regexp_replace(coalesce(p_cpf_cnpj,''),'[^0-9]','','g'),'');
  v_email text := nullif(lower(btrim(coalesce(p_email,''))),'');
  v_phone text := nullif(btrim(coalesce(p_phone,'')),'');
  v_address text := nullif(btrim(coalesce(p_address,'')),'');
  v_changed jsonb;
begin
  if not public.service_admin_has_permission(p_admin_id,'CUSTOMERS_MANAGE') then raise exception 'ADMIN_PERMISSION_DENIED'; end if;
  select * into v_current from public.customers where id=p_customer_id for update;
  if not found then raise exception 'CUSTOMER_NOT_FOUND'; end if;
  if v_current.anonymized_at is not null then raise exception 'CUSTOMER_ANONYMIZED_READ_ONLY'; end if;
  if v_name is null or length(v_name)>200 then raise exception 'CUSTOMER_NAME_INVALID'; end if;
  if v_document is not null and length(v_document) not in (11,14) then raise exception 'CUSTOMER_CPF_CNPJ_INVALID'; end if;
  if v_email is not null and (length(v_email)>254 or v_email !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$') then raise exception 'CUSTOMER_EMAIL_INVALID'; end if;
  if v_phone is not null and length(v_phone)>50 then raise exception 'CUSTOMER_PHONE_INVALID'; end if;
  if v_address is not null and length(v_address)>500 then raise exception 'CUSTOMER_ADDRESS_INVALID'; end if;
  if p_birth_date is not null and p_birth_date>current_date then raise exception 'CUSTOMER_BIRTH_DATE_FUTURE'; end if;
  if upper(v_current.customer_type)='BUSINESS' and p_birth_date is not null then raise exception 'CUSTOMER_BIRTH_DATE_NOT_APPLICABLE'; end if;
  if v_email is not null and exists(select 1 from public.customers where id<>p_customer_id and lower(email)=v_email) then raise exception 'CUSTOMER_EMAIL_ALREADY_EXISTS'; end if;
  v_changed := jsonb_strip_nulls(jsonb_build_object(
    'name',case when v_current.name is distinct from v_name then true end,
    'cpf_cnpj',case when v_current.cpf_cnpj is distinct from v_document then true end,
    'email',case when v_current.email is distinct from v_email then true end,
    'phone',case when v_current.phone is distinct from v_phone then true end,
    'address',case when v_current.address is distinct from v_address then true end,
    'birth_date',case when v_current.birth_date is distinct from p_birth_date then true end
  ));
  begin
    update public.customers set
      name=v_name,cpf_cnpj=v_document,email=v_email,phone=v_phone,address=v_address,birth_date=p_birth_date,updated_at=now()
    where id=p_customer_id;
  exception when unique_violation then
    raise exception 'CUSTOMER_EMAIL_ALREADY_EXISTS';
  end;
  if v_changed <> '{}'::jsonb then
    insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
    values(p_admin_id,'CUSTOMER',p_customer_id,'CUSTOMER_IDENTITY_UPDATED',null,jsonb_build_object('changed_fields',v_changed),'ADMIN_UI');
  end if;
  return public.service_admin_get_customer_commercial_profile(p_customer_id);
end;
$$;

revoke all on function public.service_admin_update_customer_identity(uuid,text,text,text,text,text,date,uuid) from public, anon, authenticated;
grant execute on function public.service_admin_update_customer_identity(uuid,text,text,text,text,text,date,uuid) to service_role;

create or replace function public.service_record_manual_contract_payment(
  p_appointment_id uuid,
  p_admin_id uuid,
  p_amount numeric,
  p_method text,
  p_ip text,
  p_user_agent text,
  p_request_id text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public','pg_temp'
as $$
declare
  v_before numeric(12,2);
  v_after numeric(12,2);
  v_tx uuid;
  v_collection uuid;
  v_request_id uuid;
  v_method text := upper(coalesce(btrim(p_method),''));
  v_customer_id uuid;
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
  insert into public.payment_transactions(
    appointment_id,transaction_type,method,provider,status,contract_amount_settled,payment_discount_amount,cash_amount,paid_at,created_by_admin_id,notes,payment_purpose
  ) values(
    p_appointment_id,'CHARGE',v_method,'MANUAL','APPROVED',round(p_amount,2),0,round(p_amount,2),now(),p_admin_id,'Recebimento manual registrado no painel','CONTRACT'
  ) returning id into v_tx;
  perform public.refresh_appointment_financial_status(p_appointment_id);
  v_after:=round(greatest(coalesce((public.get_appointment_financial_summary(p_appointment_id)->>'contract_balance')::numeric,0),0),2);
  select id into v_collection from public.appointment_balance_collections where appointment_id=p_appointment_id and status='PENDING' order by sequence desc limit 1;
  insert into public.audit_logs(entity_type,entity_id,action,after_json,origin,admin_user_id,request_id)
  values('APPOINTMENT',p_appointment_id,'MANUAL_CONTRACT_PAYMENT_RECORDED',jsonb_build_object(
    'payment_transaction_id',v_tx,'customer_id',v_customer_id,'method',v_method,'amount',round(p_amount,2),'balance_before',v_before,'balance_after',v_after,'ip_address',p_ip,'user_agent',p_user_agent
  ),'ADMIN_UI',p_admin_id,v_request_id);
  return jsonb_build_object('payment_transaction_id',v_tx,'appointment_id',p_appointment_id,'customer_id',v_customer_id,'balance_before',v_before,'amount',round(p_amount,2),'balance_after',v_after,'settled',v_after<=0.005,'active_collection_id',v_collection);
end;
$$;

revoke all on function public.service_record_manual_contract_payment(uuid,uuid,numeric,text,text,text,text) from public, anon, authenticated;
grant execute on function public.service_record_manual_contract_payment(uuid,uuid,numeric,text,text,text,text) to service_role;

create or replace function public.service_admin_edit_manual_contract_payment(
  p_payment_transaction_id uuid,
  p_admin_id uuid,
  p_amount numeric,
  p_method text,
  p_ip text,
  p_user_agent text,
  p_request_id text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public','pg_temp'
as $$
declare
  v_tx public.payment_transactions%rowtype;
  v_before_balance numeric(12,2);
  v_after_balance numeric(12,2);
  v_available numeric(12,2);
  v_request_id uuid;
  v_method text := upper(coalesce(btrim(p_method),''));
begin
  if not public.service_admin_has_permission(p_admin_id,'FINANCE_MANAGE') then raise exception using errcode='42501',message='ADMIN_PERMISSION_DENIED'; end if;
  if p_amount is null or p_amount<=0 then raise exception using errcode='22023',message='MANUAL_PAYMENT_AMOUNT_INVALID'; end if;
  if v_method not in ('CASH','PIX') then raise exception using errcode='22023',message='MANUAL_PAYMENT_METHOD_INVALID'; end if;
  if coalesce(btrim(p_ip),'')='' or coalesce(btrim(p_user_agent),'')='' or coalesce(btrim(p_request_id),'')='' then raise exception using errcode='22023',message='AUTHORSHIP_ADMIN_EVIDENCE_REQUIRED'; end if;
  begin v_request_id:=p_request_id::uuid; exception when invalid_text_representation then raise exception using errcode='22023',message='REQUEST_ID_INVALID'; end;
  select * into v_tx from public.payment_transactions where id=p_payment_transaction_id for update;
  if not found then raise exception using errcode='P0001',message='MANUAL_PAYMENT_NOT_FOUND'; end if;
  if v_tx.provider<>'MANUAL' or v_tx.transaction_type<>'CHARGE' or v_tx.payment_purpose<>'CONTRACT' or v_tx.status<>'APPROVED' then
    raise exception using errcode='P0001',message='MANUAL_PAYMENT_NOT_EDITABLE';
  end if;
  if exists(select 1 from public.payment_transactions where parent_transaction_id=v_tx.id) then
    raise exception using errcode='P0001',message='MANUAL_PAYMENT_ALREADY_REVERSED';
  end if;
  perform 1 from public.appointments where id=v_tx.appointment_id for update;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if;
  v_before_balance:=round(greatest(coalesce((public.get_appointment_financial_summary(v_tx.appointment_id)->>'contract_balance')::numeric,0),0),2);
  v_available:=round(v_before_balance + coalesce(v_tx.contract_amount_settled,0),2);
  if p_amount>v_available+0.005 then raise exception using errcode='22023',message='MANUAL_PAYMENT_EXCEEDS_BALANCE'; end if;
  update public.payment_transactions set
    method=v_method,contract_amount_settled=round(p_amount,2),payment_discount_amount=0,cash_amount=round(p_amount,2),updated_at=now()
  where id=v_tx.id;
  perform public.refresh_appointment_financial_status(v_tx.appointment_id);
  v_after_balance:=round(greatest(coalesce((public.get_appointment_financial_summary(v_tx.appointment_id)->>'contract_balance')::numeric,0),0),2);
  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin,request_id)
  values(p_admin_id,'PAYMENT_TRANSACTION',v_tx.id,'MANUAL_PAYMENT_EDITED',
    jsonb_build_object('amount',v_tx.contract_amount_settled,'method',v_tx.method,'balance',v_before_balance),
    jsonb_build_object('amount',round(p_amount,2),'method',v_method,'balance',v_after_balance,'ip_address',p_ip,'user_agent',p_user_agent),
    'ADMIN_UI',v_request_id);
  return jsonb_build_object('payment_transaction_id',v_tx.id,'appointment_id',v_tx.appointment_id,'amount',round(p_amount,2),'method',v_method,'balance_before',v_before_balance,'balance_after',v_after_balance);
end;
$$;

revoke all on function public.service_admin_edit_manual_contract_payment(uuid,uuid,numeric,text,text,text,text) from public, anon, authenticated;
grant execute on function public.service_admin_edit_manual_contract_payment(uuid,uuid,numeric,text,text,text,text) to service_role;

create or replace function public.service_admin_reverse_manual_contract_payment(
  p_payment_transaction_id uuid,
  p_admin_id uuid,
  p_ip text,
  p_user_agent text,
  p_request_id text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public','pg_temp'
as $$
declare
  v_tx public.payment_transactions%rowtype;
  v_refund_id uuid;
  v_before_balance numeric(12,2);
  v_after_balance numeric(12,2);
  v_request_id uuid;
begin
  if not public.service_admin_has_permission(p_admin_id,'FINANCE_MANAGE') then raise exception using errcode='42501',message='ADMIN_PERMISSION_DENIED'; end if;
  if coalesce(btrim(p_ip),'')='' or coalesce(btrim(p_user_agent),'')='' or coalesce(btrim(p_request_id),'')='' then raise exception using errcode='22023',message='AUTHORSHIP_ADMIN_EVIDENCE_REQUIRED'; end if;
  begin v_request_id:=p_request_id::uuid; exception when invalid_text_representation then raise exception using errcode='22023',message='REQUEST_ID_INVALID'; end;
  select * into v_tx from public.payment_transactions where id=p_payment_transaction_id for update;
  if not found then raise exception using errcode='P0001',message='MANUAL_PAYMENT_NOT_FOUND'; end if;
  if v_tx.provider<>'MANUAL' or v_tx.transaction_type<>'CHARGE' or v_tx.payment_purpose<>'CONTRACT' or v_tx.status<>'APPROVED' then
    raise exception using errcode='P0001',message='MANUAL_PAYMENT_NOT_REVERSIBLE';
  end if;
  if exists(select 1 from public.payment_transactions where parent_transaction_id=v_tx.id) then
    raise exception using errcode='P0001',message='MANUAL_PAYMENT_ALREADY_REVERSED';
  end if;
  perform 1 from public.appointments where id=v_tx.appointment_id for update;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if;
  v_before_balance:=round(greatest(coalesce((public.get_appointment_financial_summary(v_tx.appointment_id)->>'contract_balance')::numeric,0),0),2);
  insert into public.payment_transactions(
    appointment_id,transaction_type,method,provider,status,contract_amount_settled,payment_discount_amount,cash_amount,parent_transaction_id,paid_at,created_by_admin_id,notes,payment_purpose
  ) values(
    v_tx.appointment_id,'REFUND',v_tx.method,'MANUAL','APPROVED',coalesce(v_tx.contract_amount_settled,0),0,coalesce(v_tx.cash_amount,v_tx.contract_amount_settled,0),v_tx.id,now(),p_admin_id,'Estorno de recebimento manual','CONTRACT'
  ) returning id into v_refund_id;
  update public.payment_transactions set status='REFUNDED',updated_at=now() where id=v_tx.id;
  perform public.refresh_appointment_financial_status(v_tx.appointment_id);
  v_after_balance:=round(greatest(coalesce((public.get_appointment_financial_summary(v_tx.appointment_id)->>'contract_balance')::numeric,0),0),2);
  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin,request_id)
  values(p_admin_id,'PAYMENT_TRANSACTION',v_tx.id,'MANUAL_PAYMENT_REVERSED',
    jsonb_build_object('amount',v_tx.contract_amount_settled,'method',v_tx.method,'status',v_tx.status,'balance',v_before_balance),
    jsonb_build_object('amount',v_tx.contract_amount_settled,'method',v_tx.method,'status','REFUNDED','refund_transaction_id',v_refund_id,'balance',v_after_balance,'ip_address',p_ip,'user_agent',p_user_agent),
    'ADMIN_UI',v_request_id);
  return jsonb_build_object('payment_transaction_id',v_tx.id,'refund_transaction_id',v_refund_id,'appointment_id',v_tx.appointment_id,'amount',v_tx.contract_amount_settled,'balance_before',v_before_balance,'balance_after',v_after_balance,'reversed',true);
end;
$$;

revoke all on function public.service_admin_reverse_manual_contract_payment(uuid,uuid,text,text,text) from public, anon, authenticated;
grant execute on function public.service_admin_reverse_manual_contract_payment(uuid,uuid,text,text,text) to service_role;
