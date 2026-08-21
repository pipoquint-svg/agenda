-- Harden public checkout identity, answer validation and server-side terms evidence.

create or replace function public.public_get_checkout_context(p_checkout_hold_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  v_hold public.checkout_holds%rowtype;
  v_page public.booking_pages%rowtype;
  v_service public.services%rowtype;
begin
  if p_checkout_hold_token is null or btrim(p_checkout_hold_token) = '' then
    raise exception using errcode = 'P0001', message = 'CHECKOUT_HOLD_TOKEN_REQUIRED';
  end if;

  select * into v_hold
  from public.checkout_holds
  where public_token_hash = encode(digest(p_checkout_hold_token, 'sha256'), 'hex')
    and status = 'ACTIVE'
    and expires_at > now();

  if not found then
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

  select * into v_service
  from public.services
  where id = v_hold.service_id and is_active;

  if not found then
    raise exception using errcode = 'P0001', message = 'SERVICE_NOT_AVAILABLE';
  end if;

  return jsonb_build_object(
    'checkout_hold_id', v_hold.id,
    'expires_at', v_hold.expires_at,
    'booking_page_slug', v_page.slug,
    'brand_key', v_page.brand_key,
    'require_tax_id', v_page.require_tax_id,
    'customer_bound', v_hold.primary_customer_id is not null,
    'service', jsonb_build_object(
      'id', v_service.id,
      'name', v_service.name,
      'requires_terms', v_service.requires_terms
    ),
    'schedule', jsonb_build_object(
      'slot_start_at', v_hold.requested_start_at,
      'slot_end_at', v_hold.requested_end_at,
      'core_start_at', v_hold.core_start_at,
      'core_end_at', v_hold.core_end_at,
      'pre_service_minutes', v_hold.pre_service_minutes,
      'post_service_minutes', v_hold.post_service_minutes
    ),
    'summary', jsonb_build_object(
      'people_count', v_hold.people_count,
      'commercial_value', v_hold.commercial_value,
      'duration_minutes', v_hold.duration_minutes,
      'extra_selections', v_hold.extra_selections
    ),
    'fields', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', sf.id,
        'field_key', sf.field_key,
        'label', sf.label,
        'field_type', sf.field_type,
        'help_text', sf.help_text,
        'placeholder', sf.placeholder,
        'is_required', sf.is_required,
        'options', sf.options_json
      ) order by sf.sort_order, sf.id)
      from public.service_fields sf
      where sf.service_id = v_hold.service_id and sf.is_active
    ), '[]'::jsonb),
    'terms', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', tv.id,
        'name', tv.name,
        'version', tv.version,
        'content', tv.content,
        'published_at', tv.published_at
      ) order by tv.name)
      from public.terms_versions tv
      where tv.service_id = v_hold.service_id
        and tv.is_active
        and tv.published_at <= now()
        and tv.published_at = (
          select max(tv2.published_at)
          from public.terms_versions tv2
          where tv2.service_id = tv.service_id
            and tv2.name = tv.name
            and tv2.is_active
            and tv2.published_at <= now()
        )
    ), '[]'::jsonb),
    'package_selected', exists (
      select 1 from public.checkout_hour_package_reservations phr
      where phr.checkout_hold_id = v_hold.id and phr.status = 'HELD'
    )
  );
end;
$$;

create or replace function public.public_bind_checkout_customer(
  p_checkout_hold_token text,
  p_name text,
  p_email text,
  p_phone text,
  p_tax_id text default null,
  p_recovery_enabled boolean default true
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_hold public.checkout_holds%rowtype;
  v_page public.booking_pages%rowtype;
  v_name text := nullif(btrim(p_name), '');
  v_email text := nullif(lower(btrim(p_email)), '');
  v_phone text := regexp_replace(coalesce(p_phone,''), '\D', '', 'g');
  v_tax text := nullif(regexp_replace(coalesce(p_tax_id,''), '\D', '', 'g'), '');
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

  if length(v_phone) not between 10 and 15 then
    raise exception using errcode = 'P0001', message = 'CUSTOMER_PHONE_INVALID';
  end if;

  if v_page.require_tax_id and (v_tax is null or not public.is_valid_tax_id(v_tax)) then
    raise exception using errcode = 'P0001', message = 'CUSTOMER_TAX_ID_INVALID';
  end if;

  if v_tax is not null and not public.is_valid_tax_id(v_tax) then
    raise exception using errcode = 'P0001', message = 'CUSTOMER_TAX_ID_INVALID';
  end if;

  -- A bound hold cannot silently switch identity. This also makes retries safe.
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
    -- Serialize concurrent attempts for the same identity before lookup/create.
    perform pg_advisory_xact_lock(hashtextextended(
      case when v_tax is not null then 'customer-tax:' || v_tax
           else 'customer-contact:' || v_phone || ':' || v_email end,
      0
    ));

    if v_tax is not null then
      select count(*)::integer into v_count
      from public.customers c
      where regexp_replace(coalesce(c.cpf_cnpj,''), '\D', '', 'g') = v_tax;

      if v_count > 1 then
        raise exception using errcode = 'P0001', message = 'CUSTOMER_IDENTITY_AMBIGUOUS';
      elsif v_count = 1 then
        select * into v_customer
        from public.customers c
        where regexp_replace(coalesce(c.cpf_cnpj,''), '\D', '', 'g') = v_tax
        for update;
      end if;
    end if;

    if v_customer.id is null then
      select count(*)::integer into v_count
      from public.customers c
      where regexp_replace(coalesce(c.phone,''), '\D', '', 'g') = v_phone
        and (c.email is null or lower(c.email) = v_email)
        and (v_tax is null or c.cpf_cnpj is null or regexp_replace(c.cpf_cnpj, '\D', '', 'g') = v_tax);

      if v_count > 1 then
        raise exception using errcode = 'P0001', message = 'CUSTOMER_IDENTITY_AMBIGUOUS';
      elsif v_count = 1 then
        select * into v_customer
        from public.customers c
        where regexp_replace(coalesce(c.phone,''), '\D', '', 'g') = v_phone
          and (c.email is null or lower(c.email) = v_email)
          and (v_tax is null or c.cpf_cnpj is null or regexp_replace(c.cpf_cnpj, '\D', '', 'g') = v_tax)
        for update;
      end if;
    end if;

    if v_customer.id is null then
      select count(*)::integer into v_count
      from public.customers c
      where lower(coalesce(c.email,'')) = v_email
        and (c.phone is null or regexp_replace(c.phone, '\D', '', 'g') = v_phone)
        and (v_tax is null or c.cpf_cnpj is null or regexp_replace(c.cpf_cnpj, '\D', '', 'g') = v_tax);

      if v_count > 1 then
        raise exception using errcode = 'P0001', message = 'CUSTOMER_IDENTITY_AMBIGUOUS';
      elsif v_count = 1 then
        select * into v_customer
        from public.customers c
        where lower(coalesce(c.email,'')) = v_email
          and (c.phone is null or regexp_replace(c.phone, '\D', '', 'g') = v_phone)
          and (v_tax is null or c.cpf_cnpj is null or regexp_replace(c.cpf_cnpj, '\D', '', 'g') = v_tax)
        for update;
      end if;
    end if;
  end if;

  if v_customer.id is null then
    insert into public.customers (name, email, phone, cpf_cnpj)
    values (v_name, v_email, v_phone, v_tax)
    returning * into v_customer;
    v_created := true;
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
$$;

create or replace function public.validate_checkout_answers(
  p_service_id uuid,
  p_answers jsonb
)
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_answer record;
  v_field public.service_fields%rowtype;
  v_text text;
  v_date date;
begin
  if jsonb_typeof(coalesce(p_answers, '[]'::jsonb)) <> 'array' then
    raise exception using errcode = 'P0001', message = 'INVALID_SERVICE_ANSWERS';
  end if;

  if exists (
    select 1
    from jsonb_to_recordset(coalesce(p_answers, '[]'::jsonb)) a(service_field_id uuid, value jsonb)
    group by a.service_field_id
    having count(*) > 1
  ) then
    raise exception using errcode = 'P0001', message = 'INVALID_SERVICE_ANSWERS';
  end if;

  if exists (
    select 1
    from jsonb_to_recordset(coalesce(p_answers, '[]'::jsonb)) a(service_field_id uuid, value jsonb)
    left join public.service_fields sf
      on sf.id = a.service_field_id
     and sf.service_id = p_service_id
     and sf.is_active
    where sf.id is null
  ) then
    raise exception using errcode = 'P0001', message = 'INVALID_SERVICE_ANSWERS';
  end if;

  if exists (
    select 1
    from public.service_fields sf
    where sf.service_id = p_service_id
      and sf.is_active
      and sf.is_required
      and not exists (
        select 1
        from jsonb_to_recordset(coalesce(p_answers, '[]'::jsonb)) a(service_field_id uuid, value jsonb)
        where a.service_field_id = sf.id
          and a.value is not null
          and a.value <> 'null'::jsonb
          and not (jsonb_typeof(a.value) = 'string' and btrim(a.value #>> '{}') = '')
      )
  ) then
    raise exception using errcode = 'P0001', message = 'REQUIRED_SERVICE_FIELDS_MISSING';
  end if;

  for v_answer in
    select a.service_field_id, a.value
    from jsonb_to_recordset(coalesce(p_answers, '[]'::jsonb)) a(service_field_id uuid, value jsonb)
  loop
    if v_answer.value is null or v_answer.value = 'null'::jsonb then
      continue;
    end if;

    select * into v_field
    from public.service_fields
    where id = v_answer.service_field_id
      and service_id = p_service_id
      and is_active;

    if v_field.field_type in ('TEXT','TEXTAREA') then
      if jsonb_typeof(v_answer.value) <> 'string' or length(v_answer.value #>> '{}') > 4000 then
        raise exception using errcode = 'P0001', message = 'INVALID_SERVICE_ANSWER_VALUE';
      end if;
    elsif v_field.field_type = 'NUMBER' then
      if jsonb_typeof(v_answer.value) <> 'number' then
        raise exception using errcode = 'P0001', message = 'INVALID_SERVICE_ANSWER_VALUE';
      end if;
    elsif v_field.field_type = 'BOOLEAN' then
      if jsonb_typeof(v_answer.value) <> 'boolean' then
        raise exception using errcode = 'P0001', message = 'INVALID_SERVICE_ANSWER_VALUE';
      end if;
    elsif v_field.field_type = 'DATE' then
      if jsonb_typeof(v_answer.value) <> 'string' or (v_answer.value #>> '{}') !~ '^\d{4}-\d{2}-\d{2}$' then
        raise exception using errcode = 'P0001', message = 'INVALID_SERVICE_ANSWER_VALUE';
      end if;
      begin
        v_text := v_answer.value #>> '{}';
        v_date := v_text::date;
        if to_char(v_date, 'YYYY-MM-DD') <> v_text then
          raise exception using errcode = 'P0001', message = 'INVALID_SERVICE_ANSWER_VALUE';
        end if;
      exception when datetime_field_overflow or invalid_datetime_format then
        raise exception using errcode = 'P0001', message = 'INVALID_SERVICE_ANSWER_VALUE';
      end;
    elsif v_field.field_type = 'SELECT' then
      if jsonb_typeof(v_answer.value) <> 'string' then
        raise exception using errcode = 'P0001', message = 'INVALID_SERVICE_ANSWER_VALUE';
      end if;
      v_text := v_answer.value #>> '{}';
      if v_field.options_json is not null and jsonb_typeof(v_field.options_json) = 'array'
         and not exists (
           select 1
           from jsonb_array_elements(v_field.options_json) option
           where (jsonb_typeof(option) = 'string' and option #>> '{}' = v_text)
              or (jsonb_typeof(option) = 'object' and option->>'value' = v_text)
         ) then
        raise exception using errcode = 'P0001', message = 'INVALID_SERVICE_ANSWER_VALUE';
      end if;
    else
      raise exception using errcode = 'P0001', message = 'INVALID_SERVICE_ANSWER_VALUE';
    end if;
  end loop;
end;
$$;

create or replace function public.service_submit_public_checkout(
  p_checkout_hold_token text,
  p_coupon_code text default null,
  p_term_version_ids uuid[] default '{}'::uuid[],
  p_answers jsonb default '[]'::jsonb,
  p_acceptance_ip inet default null,
  p_user_agent text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_hold public.checkout_holds%rowtype;
begin
  select * into v_hold
  from public.checkout_holds
  where public_token_hash = encode(digest(p_checkout_hold_token, 'sha256'), 'hex')
  for update;

  if not found or v_hold.status <> 'ACTIVE' or v_hold.expires_at <= now() then
    raise exception using errcode = 'P0001', message = 'CHECKOUT_HOLD_NOT_ACTIVE';
  end if;

  if v_hold.primary_customer_id is null then
    raise exception using errcode = 'P0001', message = 'CHECKOUT_CUSTOMER_REQUIRED';
  end if;

  perform public.validate_checkout_answers(v_hold.service_id, coalesce(p_answers, '[]'::jsonb));

  return public.promote_checkout_hold(
    v_hold.id,
    v_hold.primary_customer_id,
    nullif(btrim(p_coupon_code), ''),
    coalesce(p_term_version_ids, '{}'::uuid[]),
    '[]'::jsonb,
    coalesce(p_answers, '[]'::jsonb),
    p_acceptance_ip,
    nullif(left(p_user_agent, 500), '')
  );
end;
$$;

-- The final submit must pass through the Edge Function so IP/User-Agent evidence
-- is captured server-side. Direct anonymous promotion is intentionally disabled.
revoke all on function public.public_promote_checkout_hold(text,text,uuid[],jsonb,text)
  from public, anon, authenticated;
revoke all on function public.service_submit_public_checkout(text,text,uuid[],jsonb,inet,text)
  from public, anon, authenticated;
revoke all on function public.validate_checkout_answers(uuid,jsonb)
  from public, anon, authenticated;

grant execute on function public.public_promote_checkout_hold(text,text,uuid[],jsonb,text) to service_role;
grant execute on function public.service_submit_public_checkout(text,text,uuid[],jsonb,inet,text) to service_role;
grant execute on function public.validate_checkout_answers(uuid,jsonb) to service_role;
