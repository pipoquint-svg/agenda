alter table public.customers
  add column if not exists address text,
  add column if not exists anonymized_at timestamptz;

-- Privacy hardening for the append-only identity history. The fraud/access-control
-- model still compares stable equality, but identifiers are no longer stored in
-- plaintext. There is no runtime bypass for the append-only trigger.
create or replace function public.capture_customer_identity_keys(p_customer_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  c public.customers%rowtype;
  v_normalized text;
begin
  select * into c from public.customers where id=p_customer_id;
  if not found then return; end if;

  v_normalized := nullif(regexp_replace(coalesce(c.cpf_cnpj,''),'\D','','g'),'');
  if v_normalized is not null then
    insert into public.customer_identity_keys(customer_id,key_type,normalized_value)
    values(c.id,'TAX_ID','sha256:'||encode(extensions.digest('TAX_ID:'||v_normalized,'sha256'),'hex'))
    on conflict do nothing;
  end if;

  v_normalized := nullif(regexp_replace(coalesce(c.phone,''),'\D','','g'),'');
  if v_normalized is not null then
    insert into public.customer_identity_keys(customer_id,key_type,normalized_value)
    values(c.id,'PHONE','sha256:'||encode(extensions.digest('PHONE:'||v_normalized,'sha256'),'hex'))
    on conflict do nothing;
  end if;

  v_normalized := nullif(lower(btrim(coalesce(c.email,''))),'');
  if v_normalized is not null then
    insert into public.customer_identity_keys(customer_id,key_type,normalized_value)
    values(c.id,'EMAIL','sha256:'||encode(extensions.digest('EMAIL:'||v_normalized,'sha256'),'hex'))
    on conflict do nothing;
  end if;
end;
$$;

-- One-time migration of the existing append-only keys. The guard is removed only
-- inside this migration transaction, all existing values are irreversibly
-- fingerprinted, and the append-only guard is restored immediately. No deployed
-- runtime function can update or delete this history.
drop trigger if exists customer_identity_keys_append_only on public.customer_identity_keys;
update public.customer_identity_keys
set normalized_value = case
  when normalized_value ~ '^sha256:[0-9a-f]{64}$' then normalized_value
  else 'sha256:'||encode(extensions.digest(key_type||':'||normalized_value,'sha256'),'hex')
end;
create trigger customer_identity_keys_append_only
before update or delete on public.customer_identity_keys
for each statement execute function public.guard_customer_access_append_only();

create or replace function public.service_admin_get_customer_commercial_profile(p_customer_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_customer public.customers%rowtype;
  v_terms public.customer_commercial_terms%rowtype;
  v_services jsonb;
  v_pre_reservations jsonb;
begin
  select * into v_customer from public.customers where id=p_customer_id;
  if not found then raise exception 'CUSTOMER_NOT_FOUND'; end if;

  select * into v_terms from public.customer_commercial_terms where customer_id=p_customer_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id',s.id,'name',s.name,'slug',s.slug,'duration_mode',s.duration_mode
  ) order by s.sort_order,s.name),'[]'::jsonb)
  into v_services
  from public.customer_prebook_authorized_services a
  join public.services s on s.id=a.service_id
  where a.customer_id=p_customer_id and s.is_active;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id',p.id,'service_id',p.service_id,'service_name',s.name,
    'start_at',p.start_at,'end_at',p.end_at,'expires_at',p.expires_at,
    'status',p.status,'converted_appointment_id',p.converted_appointment_id
  ) order by p.start_at),'[]'::jsonb)
  into v_pre_reservations
  from public.pre_reservations p
  left join public.services s on s.id=p.service_id
  where p.customer_id=p_customer_id and p.status='ACTIVE';

  return jsonb_build_object(
    'customer',jsonb_build_object(
      'id',v_customer.id,
      'customer_type',v_customer.customer_type,
      'name',v_customer.name,
      'legal_name',v_customer.legal_name,
      'cpf_cnpj',v_customer.cpf_cnpj,
      'email',v_customer.email,
      'phone',v_customer.phone,
      'notes',v_customer.notes,
      'address',v_customer.address,
      'birth_date',v_customer.birth_date,
      'anonymized_at',v_customer.anonymized_at
    ),
    'terms',case when v_terms.customer_id is null then null else jsonb_build_object(
      'can_prebook',v_terms.can_prebook,
      'prebook_hold_minutes',v_terms.prebook_hold_minutes,
      'max_active_prebooks',v_terms.max_active_prebooks,
      'requires_manual_confirmation',v_terms.requires_manual_confirmation,
      'billing_mode',v_terms.billing_mode,
      'invoice_due_days',v_terms.invoice_due_days,
      'is_active',v_terms.is_active
    ) end,
    'authorized_services',v_services,
    'active_pre_reservations',v_pre_reservations
  );
end;
$$;

create or replace function public.service_admin_list_customers_page(
  p_search text default null,
  p_limit integer default 50,
  p_offset integer default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_limit integer := greatest(1,least(coalesce(p_limit,50),200));
  v_offset integer := greatest(0,coalesce(p_offset,0));
  v_search text := nullif(btrim(coalesce(p_search,'')),'');
  v_total integer;
  v_customers jsonb;
begin
  select count(*)::integer into v_total
  from public.customers c
  where v_search is null
     or lower(c.name) like '%'||lower(v_search)||'%'
     or lower(coalesce(c.legal_name,'')) like '%'||lower(v_search)||'%'
     or lower(coalesce(c.email,'')) like '%'||lower(v_search)||'%'
     or coalesce(c.phone,'') like '%'||v_search||'%'
     or coalesce(c.cpf_cnpj,'') like '%'||v_search||'%'
     or lower(coalesce(c.address,'')) like '%'||lower(v_search)||'%';

  select coalesce(jsonb_agg(row_data order by sort_name,sort_id),'[]'::jsonb)
  into v_customers
  from (
    select
      c.name as sort_name,
      c.id as sort_id,
      jsonb_build_object(
        'id',c.id,
        'customer_type',c.customer_type,
        'name',c.name,
        'legal_name',c.legal_name,
        'cpf_cnpj',c.cpf_cnpj,
        'email',c.email,
        'phone',c.phone,
        'address',c.address,
        'birth_date',c.birth_date,
        'anonymized_at',c.anonymized_at,
        'commercial_terms',case when t.customer_id is null then null else jsonb_build_object(
          'can_prebook',t.can_prebook,
          'prebook_hold_minutes',t.prebook_hold_minutes,
          'max_active_prebooks',t.max_active_prebooks,
          'requires_manual_confirmation',t.requires_manual_confirmation,
          'billing_mode',t.billing_mode,
          'invoice_due_days',t.invoice_due_days,
          'is_active',t.is_active
        ) end
      ) as row_data
    from public.customers c
    left join public.customer_commercial_terms t on t.customer_id=c.id
    where v_search is null
       or lower(c.name) like '%'||lower(v_search)||'%'
       or lower(coalesce(c.legal_name,'')) like '%'||lower(v_search)||'%'
       or lower(coalesce(c.email,'')) like '%'||lower(v_search)||'%'
       or coalesce(c.phone,'') like '%'||v_search||'%'
       or coalesce(c.cpf_cnpj,'') like '%'||v_search||'%'
       or lower(coalesce(c.address,'')) like '%'||lower(v_search)||'%'
    order by c.name,c.id
    limit v_limit offset v_offset
  ) page_rows;

  return jsonb_build_object(
    'customers',v_customers,
    'total',v_total,
    'limit',v_limit,
    'offset',v_offset,
    'has_more',(v_offset + v_limit) < v_total
  );
end;
$$;

create or replace function public.service_admin_create_customer(
  p_customer_type text,
  p_name text,
  p_email text,
  p_phone text,
  p_address text,
  p_birth_date date,
  p_admin_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_type text := upper(btrim(coalesce(p_customer_type,'PERSON')));
  v_name text := nullif(btrim(coalesce(p_name,'')),'');
  v_email text := nullif(lower(btrim(coalesce(p_email,''))),'');
  v_phone text := nullif(btrim(coalesce(p_phone,'')),'');
  v_address text := nullif(btrim(coalesce(p_address,'')),'');
  v_id uuid;
begin
  if not public.service_admin_has_permission(p_admin_id,'CUSTOMERS_MANAGE') then raise exception 'ADMIN_PERMISSION_DENIED'; end if;
  if v_type not in ('PERSON','BUSINESS') then raise exception 'CUSTOMER_TYPE_INVALID'; end if;
  if v_name is null or length(v_name)>200 then raise exception 'CUSTOMER_NAME_INVALID'; end if;
  if v_email is not null and (length(v_email)>254 or v_email !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$') then raise exception 'CUSTOMER_EMAIL_INVALID'; end if;
  if v_phone is not null and length(v_phone)>50 then raise exception 'CUSTOMER_PHONE_INVALID'; end if;
  if v_address is not null and length(v_address)>500 then raise exception 'CUSTOMER_ADDRESS_INVALID'; end if;
  if p_birth_date is not null and p_birth_date>current_date then raise exception 'CUSTOMER_BIRTH_DATE_FUTURE'; end if;
  if v_type='BUSINESS' and p_birth_date is not null then raise exception 'CUSTOMER_BIRTH_DATE_NOT_APPLICABLE'; end if;
  if v_email is not null and exists(select 1 from public.customers where lower(email)=v_email) then raise exception 'CUSTOMER_EMAIL_ALREADY_EXISTS'; end if;

  begin
    insert into public.customers(customer_type,name,email,phone,address,birth_date)
    values(v_type,v_name,v_email,v_phone,v_address,p_birth_date)
    returning id into v_id;
  exception when unique_violation then
    raise exception 'CUSTOMER_EMAIL_ALREADY_EXISTS';
  end;

  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
  values(p_admin_id,'CUSTOMER',v_id,'CUSTOMER_CREATED',null,
    jsonb_build_object('customer_type',v_type,'fields_present',jsonb_build_object(
      'email',v_email is not null,'phone',v_phone is not null,'address',v_address is not null,'birth_date',p_birth_date is not null
    )),'ADMIN_UI');

  return public.service_admin_get_customer_commercial_profile(v_id);
end;
$$;

create or replace function public.service_admin_update_customer_identity(
  p_customer_id uuid,
  p_name text,
  p_email text,
  p_phone text,
  p_address text,
  p_birth_date date,
  p_admin_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_current public.customers%rowtype;
  v_name text := nullif(btrim(coalesce(p_name,'')),'');
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
  if v_email is not null and (length(v_email)>254 or v_email !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$') then raise exception 'CUSTOMER_EMAIL_INVALID'; end if;
  if v_phone is not null and length(v_phone)>50 then raise exception 'CUSTOMER_PHONE_INVALID'; end if;
  if v_address is not null and length(v_address)>500 then raise exception 'CUSTOMER_ADDRESS_INVALID'; end if;
  if p_birth_date is not null and p_birth_date>current_date then raise exception 'CUSTOMER_BIRTH_DATE_FUTURE'; end if;
  if upper(v_current.customer_type)='BUSINESS' and p_birth_date is not null then raise exception 'CUSTOMER_BIRTH_DATE_NOT_APPLICABLE'; end if;
  if v_email is not null and exists(select 1 from public.customers where id<>p_customer_id and lower(email)=v_email) then raise exception 'CUSTOMER_EMAIL_ALREADY_EXISTS'; end if;

  v_changed := jsonb_strip_nulls(jsonb_build_object(
    'name',case when v_current.name is distinct from v_name then true end,
    'email',case when v_current.email is distinct from v_email then true end,
    'phone',case when v_current.phone is distinct from v_phone then true end,
    'address',case when v_current.address is distinct from v_address then true end,
    'birth_date',case when v_current.birth_date is distinct from p_birth_date then true end
  ));

  begin
    update public.customers set
      name=v_name,email=v_email,phone=v_phone,address=v_address,birth_date=p_birth_date,updated_at=now()
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

create or replace function public.service_admin_anonymize_customer(
  p_customer_id uuid,
  p_admin_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_customer public.customers%rowtype;
  v_placeholder text;
begin
  if not public.service_admin_has_permission(p_admin_id,'CUSTOMERS_MANAGE') then raise exception 'ADMIN_PERMISSION_DENIED'; end if;
  select * into v_customer from public.customers where id=p_customer_id for update;
  if not found then raise exception 'CUSTOMER_NOT_FOUND'; end if;
  if v_customer.anonymized_at is not null then
    return public.service_admin_get_customer_commercial_profile(p_customer_id);
  end if;

  -- Identity history is intentionally retained as irreversible SHA-256
  -- fingerprints for the existing anti-evasion/access-control policy. The
  -- append-only table is not updated or deleted by this runtime boundary.
  v_placeholder := 'Cliente anonimizado '||left(replace(p_customer_id::text,'-',''),8);

  update public.customers set
    name=v_placeholder,
    legal_name=null,
    cpf_cnpj=null,
    email=null,
    phone=null,
    notes=null,
    address=null,
    birth_date=null,
    anonymized_at=now(),
    updated_at=now()
  where id=p_customer_id;

  delete from public.kommo_customer_links where customer_id=p_customer_id;
  delete from public.customer_prebook_authorized_services where customer_id=p_customer_id;
  update public.customer_commercial_terms set is_active=false,updated_at=now() where customer_id=p_customer_id;

  update public.legacy_customer_sources set
    raw_snapshot=jsonb_build_object('lgpd_anonymized',true),
    match_method='UNMATCHED',
    match_confidence='NONE',
    conflict_code=null,
    updated_at=now()
  where customer_id=p_customer_id;

  update public.notification_delivery_logs set
    recipient_hash=encode(extensions.digest('notification-lgpd:'||p_customer_id::text,'sha256'),'hex'),
    recipient_masked='***',
    payload_snapshot='{}'::jsonb,
    updated_at=now()
  where customer_id=p_customer_id;

  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
  values(p_admin_id,'CUSTOMER',p_customer_id,'CUSTOMER_ANONYMIZED',null,
    jsonb_build_object(
      'pii_removed',true,
      'financial_history_preserved',true,
      'identity_fingerprints_retained',true
    ),'ADMIN_UI');

  return public.service_admin_get_customer_commercial_profile(p_customer_id);
end;
$$;

revoke all on function public.service_admin_list_customers_page(text,integer,integer) from public, anon, authenticated;
revoke all on function public.service_admin_create_customer(text,text,text,text,text,date,uuid) from public, anon, authenticated;
revoke all on function public.service_admin_update_customer_identity(uuid,text,text,text,text,date,uuid) from public, anon, authenticated;
revoke all on function public.service_admin_anonymize_customer(uuid,uuid) from public, anon, authenticated;

grant execute on function public.service_admin_list_customers_page(text,integer,integer) to service_role;
grant execute on function public.service_admin_create_customer(text,text,text,text,text,date,uuid) to service_role;
grant execute on function public.service_admin_update_customer_identity(uuid,text,text,text,text,date,uuid) to service_role;
grant execute on function public.service_admin_anonymize_customer(uuid,uuid) to service_role;
