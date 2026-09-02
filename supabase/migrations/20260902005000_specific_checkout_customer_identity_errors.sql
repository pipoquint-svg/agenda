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
  v_phone_raw text := regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g');
  v_phone text := public.normalize_customer_phone_identity(p_phone);
  v_tax text := nullif(regexp_replace(coalesce(p_tax_id, ''), '[^0-9]', '', 'g'), '');
  v_customer public.customers%rowtype;
  v_by_email public.customers%rowtype;
  v_by_phone public.customers%rowtype;
  v_by_tax public.customers%rowtype;
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

    if v_customer.email is not null and lower(v_customer.email) <> v_email then
      raise exception using errcode = 'P0001', message = 'CUSTOMER_EMAIL_MISMATCH';
    end if;
    if v_customer.phone is not null and public.normalize_customer_phone_identity(v_customer.phone) <> v_phone then
      raise exception using errcode = 'P0001', message = 'CUSTOMER_PHONE_MISMATCH';
    end if;
    if v_tax is not null and v_customer.cpf_cnpj is not null
       and regexp_replace(v_customer.cpf_cnpj, '[^0-9]', '', 'g') <> v_tax then
      raise exception using errcode = 'P0001', message = 'CUSTOMER_TAX_ID_MISMATCH';
    end if;
  else
    perform pg_advisory_xact_lock(hashtextextended(
      'customer-bind:' || coalesce(v_email, '') || ':' || coalesce(v_phone, '') || ':' || coalesce(v_tax, ''),
      0
    ));

    select count(*)::integer into v_count
    from public.customers c
    where lower(coalesce(c.email, '')) = v_email;
    if v_count > 1 then
      raise exception using errcode = 'P0001', message = 'CUSTOMER_IDENTITY_AMBIGUOUS';
    elsif v_count = 1 then
      select * into v_by_email
      from public.customers c
      where lower(coalesce(c.email, '')) = v_email
      for update;
    end if;

    select count(*)::integer into v_count
    from public.customers c
    where public.normalize_customer_phone_identity(c.phone) = v_phone;
    if v_count > 1 then
      raise exception using errcode = 'P0001', message = 'CUSTOMER_IDENTITY_AMBIGUOUS';
    elsif v_count = 1 then
      select * into v_by_phone
      from public.customers c
      where public.normalize_customer_phone_identity(c.phone) = v_phone
      for update;
    end if;

    if v_tax is not null then
      select count(*)::integer into v_count
      from public.customers c
      where regexp_replace(coalesce(c.cpf_cnpj, ''), '[^0-9]', '', 'g') = v_tax;
      if v_count > 1 then
        raise exception using errcode = 'P0001', message = 'CUSTOMER_IDENTITY_AMBIGUOUS';
      elsif v_count = 1 then
        select * into v_by_tax
        from public.customers c
        where regexp_replace(coalesce(c.cpf_cnpj, ''), '[^0-9]', '', 'g') = v_tax
        for update;
      end if;
    end if;

    if v_by_tax.id is not null then
      v_customer := v_by_tax;
      if v_by_email.id is not null and v_by_email.id <> v_customer.id then
        raise exception using errcode = 'P0001', message = 'CUSTOMER_EMAIL_MISMATCH';
      end if;
      if v_customer.email is not null and lower(v_customer.email) <> v_email then
        raise exception using errcode = 'P0001', message = 'CUSTOMER_EMAIL_MISMATCH';
      end if;
      if v_by_phone.id is not null and v_by_phone.id <> v_customer.id then
        raise exception using errcode = 'P0001', message = 'CUSTOMER_PHONE_MISMATCH';
      end if;
      if v_customer.phone is not null and public.normalize_customer_phone_identity(v_customer.phone) <> v_phone then
        raise exception using errcode = 'P0001', message = 'CUSTOMER_PHONE_MISMATCH';
      end if;
    elsif v_by_email.id is not null then
      v_customer := v_by_email;
      if v_by_phone.id is not null and v_by_phone.id <> v_customer.id then
        raise exception using errcode = 'P0001', message = 'CUSTOMER_PHONE_MISMATCH';
      end if;
      if v_customer.phone is not null and public.normalize_customer_phone_identity(v_customer.phone) <> v_phone then
        raise exception using errcode = 'P0001', message = 'CUSTOMER_PHONE_MISMATCH';
      end if;
      if v_tax is not null and v_customer.cpf_cnpj is not null
         and regexp_replace(v_customer.cpf_cnpj, '[^0-9]', '', 'g') <> v_tax then
        raise exception using errcode = 'P0001', message = 'CUSTOMER_TAX_ID_MISMATCH';
      end if;
    elsif v_by_phone.id is not null then
      v_customer := v_by_phone;
      if v_customer.email is not null and lower(v_customer.email) <> v_email then
        raise exception using errcode = 'P0001', message = 'CUSTOMER_EMAIL_MISMATCH';
      end if;
      if v_tax is not null and v_customer.cpf_cnpj is not null
         and regexp_replace(v_customer.cpf_cnpj, '[^0-9]', '', 'g') <> v_tax then
        raise exception using errcode = 'P0001', message = 'CUSTOMER_TAX_ID_MISMATCH';
      end if;
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
        email = coalesce(email, v_email),
        phone = coalesce(phone, v_phone),
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
