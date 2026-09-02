create or replace function public.normalize_customer_phone_identity(p_phone text)
returns text
language sql
immutable
set search_path to 'public', 'pg_temp'
as $function$
  select case
    when d = '' then null
    when length(d) in (10, 11) then '55' || d
    when length(d) in (12, 13) and left(d, 2) = '55' then d
    when length(d) in (14, 15) and left(d, 4) = '0055' then substr(d, 3)
    else d
  end
  from (select regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g') as d) s;
$function$;

revoke all on function public.normalize_customer_phone_identity(text) from public, anon, authenticated;
grant execute on function public.normalize_customer_phone_identity(text) to service_role;

create or replace function public.public_bind_checkout_customer(
  p_checkout_hold_token text,
  p_name text,
  p_email text,
  p_phone text,
  p_tax_id text default null::text,
  p_recovery_enabled boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions'
as $function$
declare
  v_hold public.checkout_holds%rowtype;
  v_page public.booking_pages%rowtype;
  v_name text := nullif(btrim(p_name), '');
  v_email text := nullif(lower(btrim(p_email)), '');
  v_phone_raw text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  v_phone text := public.normalize_customer_phone_identity(p_phone);
  v_tax text := nullif(regexp_replace(coalesce(p_tax_id, ''), '\D', '', 'g'), '');
  v_customer public.customers%rowtype;
  v_count integer;
  v_created boolean := false;
begin
  select * into v_hold
  from public.checkout_holds
  where public_token_hash = encode(digest(p_checkout_hold_token, 'sha256'), 'hex')
  for update;

  if not found or v_hold.status <> 'ACTIVE' or v_hold.expires_at <= now() then
    raise exception using errcode = 'P0001', message = 'CHECKOUT_HOLD_NOT_ACTIVE';
  end if;
  if v_hold.booking_page_id is null then
    raise exception using errcode = 'P0001', message = 'CHECKOUT_ORIGIN_MISSING';
  end if;

  select * into v_page
  from public.booking_pages
  where id = v_hold.booking_page_id and is_active;
  if not found then
    raise exception using errcode = 'P0001', message = 'CHECKOUT_ORIGIN_NOT_ACTIVE';
  end if;

  if v_name is null or length(v_name) < 2 or length(v_name) > 160 then
    raise exception using errcode = 'P0001', message = 'CUSTOMER_NAME_INVALID';
  end if;
  if v_email is null or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception using errcode = 'P0001', message = 'CUSTOMER_EMAIL_INVALID';
  end if;
  if length(v_phone_raw) not between 10 and 15 or v_phone is null then
    raise exception using errcode = 'P0001', message = 'CUSTOMER_PHONE_INVALID';
  end if;
  if v_page.require_tax_id and (v_tax is null or not public.is_valid_tax_id(v_tax)) then
    raise exception using errcode = 'P0001', message = 'CUSTOMER_TAX_ID_INVALID';
  end if;
  if v_tax is not null and not public.is_valid_tax_id(v_tax) then
    raise exception using errcode = 'P0001', message = 'CUSTOMER_TAX_ID_INVALID';
  end if;

  if v_hold.primary_customer_id is not null then
    select * into v_customer
    from public.customers
    where id = v_hold.primary_customer_id
    for update;
    if not found then
      raise exception using errcode = 'P0001', message = 'CHECKOUT_CUSTOMER_MISSING';
    end if;
    if v_tax is not null
       and v_customer.cpf_cnpj is not null
       and regexp_replace(v_customer.cpf_cnpj, '\D', '', 'g') <> v_tax then
      raise exception using errcode = 'P0001', message = 'CUSTOMER_IDENTITY_CONFLICT';
    end if;
  else
    perform pg_advisory_xact_lock(
      hashtextextended(
        case when v_tax is not null
          then 'customer-tax:' || v_tax
          else 'customer-contact:' || v_phone || ':' || v_email
        end,
        0
      )
    );

    if v_tax is not null then
      select count(*)::integer into v_count
      from public.customers c
      where regexp_replace(coalesce(c.cpf_cnpj, ''), '\D', '', 'g') = v_tax;
      if v_count > 1 then
        raise exception using errcode = 'P0001', message = 'CUSTOMER_IDENTITY_AMBIGUOUS';
      elsif v_count = 1 then
        select * into v_customer
        from public.customers c
        where regexp_replace(coalesce(c.cpf_cnpj, ''), '\D', '', 'g') = v_tax
        for update;
      end if;
    end if;

    if v_customer.id is null then
      select count(*)::integer into v_count
      from public.customers c
      where public.normalize_customer_phone_identity(c.phone) = v_phone
        and (c.email is null or lower(c.email) = v_email)
        and (v_tax is null or c.cpf_cnpj is null or regexp_replace(c.cpf_cnpj, '\D', '', 'g') = v_tax);
      if v_count > 1 then
        raise exception using errcode = 'P0001', message = 'CUSTOMER_IDENTITY_AMBIGUOUS';
      elsif v_count = 1 then
        select * into v_customer
        from public.customers c
        where public.normalize_customer_phone_identity(c.phone) = v_phone
          and (c.email is null or lower(c.email) = v_email)
          and (v_tax is null or c.cpf_cnpj is null or regexp_replace(c.cpf_cnpj, '\D', '', 'g') = v_tax)
        for update;
      end if;
    end if;

    if v_customer.id is null then
      select count(*)::integer into v_count
      from public.customers c
      where lower(coalesce(c.email, '')) = v_email
        and (c.phone is null or public.normalize_customer_phone_identity(c.phone) = v_phone)
        and (v_tax is null or c.cpf_cnpj is null or regexp_replace(c.cpf_cnpj, '\D', '', 'g') = v_tax);
      if v_count > 1 then
        raise exception using errcode = 'P0001', message = 'CUSTOMER_IDENTITY_AMBIGUOUS';
      elsif v_count = 1 then
        select * into v_customer
        from public.customers c
        where lower(coalesce(c.email, '')) = v_email
          and (c.phone is null or public.normalize_customer_phone_identity(c.phone) = v_phone)
          and (v_tax is null or c.cpf_cnpj is null or regexp_replace(c.cpf_cnpj, '\D', '', 'g') = v_tax)
        for update;
      end if;
    end if;

    if v_customer.id is null and exists (
      select 1 from public.customers c where lower(coalesce(c.email, '')) = v_email
    ) then
      raise exception using errcode = 'P0001', message = 'CUSTOMER_IDENTITY_CONFLICT';
    end if;
  end if;

  if v_customer.id is null then
    begin
      insert into public.customers(name, email, phone, cpf_cnpj)
      values (v_name, v_email, v_phone, v_tax)
      returning * into v_customer;
      v_created := true;
    exception when unique_violation then
      raise exception using errcode = 'P0001', message = 'CUSTOMER_IDENTITY_CONFLICT';
    end;
  else
    update public.customers
    set name = v_name,
        email = v_email,
        phone = v_phone,
        cpf_cnpj = coalesce(cpf_cnpj, v_tax),
        updated_at = now()
    where id = v_customer.id
    returning * into v_customer;
  end if;

  update public.checkout_holds
  set primary_customer_id = v_customer.id,
      recovery_phone = case when p_recovery_enabled then v_phone else null end,
      recovery_enabled = p_recovery_enabled,
      updated_at = now()
  where id = v_hold.id;

  return jsonb_build_object(
    'customer_bound', true,
    'customer_created', v_created,
    'recovery_enabled', p_recovery_enabled,
    'has_tax_id', v_customer.cpf_cnpj is not null
  );
end;
$function$;