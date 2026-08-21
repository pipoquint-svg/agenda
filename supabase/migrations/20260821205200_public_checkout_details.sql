-- Token-scoped public checkout after a time has been protected.

alter table public.booking_pages
  add column require_tax_id boolean not null default true;

alter table public.checkout_holds
  add column booking_page_id uuid references public.booking_pages(id) on delete restrict;

create index checkout_holds_booking_page_idx
  on public.checkout_holds (booking_page_id)
  where booking_page_id is not null;

create or replace function public.is_valid_cpf(p_value text)
returns boolean
language plpgsql
immutable
strict
as $$
declare
  v text := regexp_replace(p_value, '\D', '', 'g');
  s integer;
  d1 integer;
  d2 integer;
  i integer;
begin
  if length(v) <> 11 or v ~ '^([0-9])\1{10}$' then return false; end if;
  s := 0;
  for i in 1..9 loop s := s + substr(v,i,1)::integer * (11-i); end loop;
  d1 := (s * 10) % 11; if d1 = 10 then d1 := 0; end if;
  if d1 <> substr(v,10,1)::integer then return false; end if;
  s := 0;
  for i in 1..10 loop s := s + substr(v,i,1)::integer * (12-i); end loop;
  d2 := (s * 10) % 11; if d2 = 10 then d2 := 0; end if;
  return d2 = substr(v,11,1)::integer;
end;
$$;

create or replace function public.is_valid_cnpj(p_value text)
returns boolean
language plpgsql
immutable
strict
as $$
declare
  v text := regexp_replace(p_value, '\D', '', 'g');
  w1 integer[] := array[5,4,3,2,9,8,7,6,5,4,3,2];
  w2 integer[] := array[6,5,4,3,2,9,8,7,6,5,4,3,2];
  s integer := 0;
  r integer;
  d1 integer;
  d2 integer;
  i integer;
begin
  if length(v) <> 14 or v ~ '^([0-9])\1{13}$' then return false; end if;
  for i in 1..12 loop s := s + substr(v,i,1)::integer * w1[i]; end loop;
  r := s % 11; d1 := case when r < 2 then 0 else 11-r end;
  if d1 <> substr(v,13,1)::integer then return false; end if;
  s := 0;
  for i in 1..13 loop s := s + substr(v,i,1)::integer * w2[i]; end loop;
  r := s % 11; d2 := case when r < 2 then 0 else 11-r end;
  return d2 = substr(v,14,1)::integer;
end;
$$;

create or replace function public.is_valid_tax_id(p_value text)
returns boolean
language sql
immutable
strict
as $$
  select case length(regexp_replace(p_value, '\D', '', 'g'))
    when 11 then public.is_valid_cpf(p_value)
    when 14 then public.is_valid_cnpj(p_value)
    else false
  end;
$$;

-- Persist which public brand/page created a hold.
create or replace function public.public_create_checkout_hold(
  p_booking_page_slug text,
  p_service_id uuid,
  p_service_employee_id uuid,
  p_extra_selections jsonb,
  p_people_count integer,
  p_requested_start_at timestamptz
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_page_id uuid;
  v_result jsonb;
  v_hold_id uuid;
begin
  perform public.assert_public_booking_selection(
    p_booking_page_slug,
    p_service_id,
    p_service_employee_id,
    p_extra_selections,
    p_people_count
  );

  select id into v_page_id
  from public.booking_pages
  where slug = lower(btrim(p_booking_page_slug))
    and is_active;

  v_result := public.create_checkout_hold(
    p_service_id,
    p_service_employee_id,
    p_extra_selections,
    p_people_count,
    p_requested_start_at
  );

  v_hold_id := (v_result->>'checkout_hold_id')::uuid;

  update public.checkout_holds
  set booking_page_id = v_page_id,
      updated_at = now()
  where id = v_hold_id;

  return v_result || jsonb_build_object('booking_page_slug', lower(btrim(p_booking_page_slug)));
end;
$$;

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

  select * into v_page from public.booking_pages where id = v_hold.booking_page_id and is_active;
  select * into v_service from public.services where id = v_hold.service_id and is_active;

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

  select * into v_page from public.booking_pages where id = v_hold.booking_page_id and is_active;

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
    where regexp_replace(coalesce(c.phone,''), '\D', '', 'g') = v_phone;

    if v_count > 1 then
      raise exception using errcode = 'P0001', message = 'CUSTOMER_IDENTITY_AMBIGUOUS';
    elsif v_count = 1 then
      select * into v_customer
      from public.customers c
      where regexp_replace(coalesce(c.phone,''), '\D', '', 'g') = v_phone
      for update;

      if v_tax is not null
         and v_customer.cpf_cnpj is not null
         and regexp_replace(v_customer.cpf_cnpj, '\D', '', 'g') <> v_tax then
        raise exception using errcode = 'P0001', message = 'CUSTOMER_IDENTITY_CONFLICT';
      end if;
    end if;
  end if;

  if v_customer.id is null then
    select count(*)::integer into v_count
    from public.customers c
    where lower(coalesce(c.email,'')) = v_email;

    if v_count > 1 then
      raise exception using errcode = 'P0001', message = 'CUSTOMER_IDENTITY_AMBIGUOUS';
    elsif v_count = 1 then
      select * into v_customer
      from public.customers c
      where lower(coalesce(c.email,'')) = v_email
      for update;

      if v_tax is not null
         and v_customer.cpf_cnpj is not null
         and regexp_replace(v_customer.cpf_cnpj, '\D', '', 'g') <> v_tax then
        raise exception using errcode = 'P0001', message = 'CUSTOMER_IDENTITY_CONFLICT';
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

create or replace function public.public_list_checkout_hour_packages(p_checkout_hold_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  v_hold public.checkout_holds%rowtype;
  v_timezone text;
  v_quote jsonb;
  v_people_cash numeric(12,2);
  v_extras_cash numeric(12,2);
begin
  select * into v_hold
  from public.checkout_holds
  where public_token_hash = encode(digest(p_checkout_hold_token, 'sha256'), 'hex')
    and status = 'ACTIVE'
    and expires_at > now();

  if not found then
    raise exception using errcode = 'P0001', message = 'CHECKOUT_HOLD_NOT_ACTIVE';
  end if;

  if v_hold.primary_customer_id is null then
    raise exception using errcode = 'P0001', message = 'CHECKOUT_CUSTOMER_REQUIRED';
  end if;

  select timezone into v_timezone from public.operation_settings where id = 1;
  v_quote := public.calculate_booking_quote(
    v_hold.service_id, v_hold.service_employee_id, v_hold.extra_selections,
    v_hold.people_count, coalesce(v_hold.core_start_at, v_hold.requested_start_at), null
  );
  v_people_cash := greatest(coalesce((v_quote->>'people_adjustment')::numeric,0),0);
  v_extras_cash := coalesce((v_quote->>'extras_total')::numeric,0);

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'hour_package_id', hp.id,
      'name', hp.name,
      'valid_until', hp.valid_until,
      'available_seconds', hb.available_seconds,
      'required_seconds', calc.required_seconds,
      'surcharge_seconds', calc.surcharge_seconds,
      'charged_seconds', calc.charged_seconds,
      'is_special_period', calc.is_special_period,
      'usable', hb.available_seconds >= calc.charged_seconds,
      'cash_due', round(v_extras_cash + v_people_cash, 2)
    ) order by hp.valid_until, hp.created_at)
    from public.hour_packages hp
    join public.hour_package_balances hb on hb.hour_package_id = hp.id
    join lateral (
      select
        v_hold.duration_minutes::bigint * 60 as required_seconds,
        case when special.is_special_period
          then round(v_hold.duration_minutes::numeric * 60 * hp.special_surcharge_percent / 100)::bigint
          else 0::bigint end as surcharge_seconds,
        v_hold.duration_minutes::bigint * 60 + case when special.is_special_period
          then round(v_hold.duration_minutes::numeric * 60 * hp.special_surcharge_percent / 100)::bigint
          else 0::bigint end as charged_seconds,
        special.is_special_period
      from lateral (
        select (
          extract(dow from (v_hold.requested_start_at at time zone v_timezone))::integer in (0,6)
          or (v_hold.requested_start_at at time zone v_timezone)::date <> (v_hold.requested_end_at at time zone v_timezone)::date
          or (v_hold.requested_start_at at time zone v_timezone)::time < hp.standard_start_local_time
          or (v_hold.requested_end_at at time zone v_timezone)::time > hp.standard_end_local_time
        ) as is_special_period
      ) special
    ) calc on true
    where hp.customer_id = v_hold.primary_customer_id
      and hp.status = 'ACTIVE'
      and v_hold.requested_start_at >= hp.valid_from
      and v_hold.requested_start_at < hp.valid_until
      and exists (
        select 1 from public.hour_package_services hps
        where hps.hour_package_id = hp.id and hps.service_id = v_hold.service_id
      )
  ), '[]'::jsonb);
end;
$$;

create or replace function public.public_select_checkout_hour_package(
  p_checkout_hold_token text,
  p_hour_package_id uuid
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

  return public.reserve_hour_package_for_checkout(p_hour_package_id, v_hold.id, v_hold.primary_customer_id);
end;
$$;

create or replace function public.public_clear_checkout_hour_package(p_checkout_hold_token text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_hold public.checkout_holds%rowtype;
  v_count integer;
begin
  select * into v_hold
  from public.checkout_holds
  where public_token_hash = encode(digest(p_checkout_hold_token, 'sha256'), 'hex')
  for update;

  if not found or v_hold.status <> 'ACTIVE' or v_hold.expires_at <= now() then
    raise exception using errcode = 'P0001', message = 'CHECKOUT_HOLD_NOT_ACTIVE';
  end if;

  update public.checkout_hour_package_reservations
  set status = 'RELEASED', released_at = now(), release_reason = 'CUSTOMER_DESELECTED_PACKAGE', updated_at = now()
  where checkout_hold_id = v_hold.id and status = 'HELD';
  get diagnostics v_count = row_count;

  return jsonb_build_object('package_selected', false, 'released_count', v_count);
end;
$$;

create or replace function public.public_promote_checkout_hold(
  p_checkout_hold_token text,
  p_coupon_code text default null,
  p_term_version_ids uuid[] default '{}'::uuid[],
  p_answers jsonb default '[]'::jsonb,
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

  return public.promote_checkout_hold(
    v_hold.id,
    v_hold.primary_customer_id,
    nullif(btrim(p_coupon_code), ''),
    coalesce(p_term_version_ids, '{}'::uuid[]),
    '[]'::jsonb,
    coalesce(p_answers, '[]'::jsonb),
    null,
    nullif(left(p_user_agent, 500), '')
  );
end;
$$;

-- Core mutation functions are backend-only. Public clients use token-scoped wrappers.
revoke all on function public.promote_checkout_hold(uuid,uuid,text,uuid[],jsonb,jsonb,inet,text)
  from public, anon, authenticated;
revoke all on function public.calculate_hour_package_quote(uuid,uuid,uuid)
  from public, anon, authenticated;
revoke all on function public.reserve_hour_package_for_checkout(uuid,uuid,uuid)
  from public, anon, authenticated;
revoke all on function public.consume_hour_package_checkout(uuid,uuid)
  from public, anon, authenticated;

grant execute on function public.promote_checkout_hold(uuid,uuid,text,uuid[],jsonb,jsonb,inet,text) to service_role;
grant execute on function public.calculate_hour_package_quote(uuid,uuid,uuid) to service_role;
grant execute on function public.reserve_hour_package_for_checkout(uuid,uuid,uuid) to service_role;
grant execute on function public.consume_hour_package_checkout(uuid,uuid) to service_role;

revoke all on function public.public_get_checkout_context(text) from public;
revoke all on function public.public_bind_checkout_customer(text,text,text,text,text,boolean) from public;
revoke all on function public.public_list_checkout_hour_packages(text) from public;
revoke all on function public.public_select_checkout_hour_package(text,uuid) from public;
revoke all on function public.public_clear_checkout_hour_package(text) from public;
revoke all on function public.public_promote_checkout_hold(text,text,uuid[],jsonb,text) from public;

grant execute on function public.public_get_checkout_context(text) to anon, authenticated;
grant execute on function public.public_bind_checkout_customer(text,text,text,text,text,boolean) to anon, authenticated;
grant execute on function public.public_list_checkout_hour_packages(text) to anon, authenticated;
grant execute on function public.public_select_checkout_hour_package(text,uuid) to anon, authenticated;
grant execute on function public.public_clear_checkout_hour_package(text) to anon, authenticated;
grant execute on function public.public_promote_checkout_hold(text,text,uuid[],jsonb,text) to anon, authenticated;
