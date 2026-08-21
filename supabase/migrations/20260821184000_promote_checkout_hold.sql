alter table public.checkout_holds
  add column quote_snapshot jsonb;

create or replace function public.populate_checkout_hold_quote_snapshot()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.quote_snapshot is null then
    new.quote_snapshot := public.calculate_booking_quote(
      new.service_id,
      new.service_employee_id,
      coalesce(new.extra_selections, '[]'::jsonb),
      new.people_count,
      new.requested_start_at,
      null
    );
  end if;

  return new;
end;
$$;

create trigger checkout_holds_quote_snapshot_trg
before insert on public.checkout_holds
for each row execute function public.populate_checkout_hold_quote_snapshot();

create table public.terms_versions (
  id uuid primary key default gen_random_uuid(),
  service_id uuid references public.services(id) on delete cascade,
  name text not null,
  version text not null,
  content text not null,
  is_active boolean not null default true,
  published_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  unique (service_id, name, version)
);

create index terms_versions_service_active_idx
  on public.terms_versions (service_id, published_at desc)
  where is_active;

create table public.appointment_term_acceptances (
  id uuid primary key default gen_random_uuid(),
  appointment_id uuid not null references public.appointments(id) on delete cascade,
  terms_version_id uuid not null references public.terms_versions(id) on delete restrict,
  content_snapshot text not null,
  accepted_at timestamptz not null default now(),
  ip_address inet,
  user_agent text,
  unique (appointment_id, terms_version_id)
);

create table public.appointment_access_tokens (
  id uuid primary key default gen_random_uuid(),
  appointment_id uuid not null references public.appointments(id) on delete cascade,
  token_hash text not null unique,
  scope text not null check (scope in ('VIEW','MANAGE','PAY')),
  expires_at timestamptz,
  revoked_at timestamptz,
  created_at timestamptz not null default now(),
  last_used_at timestamptz
);

create index appointment_access_tokens_appointment_idx
  on public.appointment_access_tokens (appointment_id)
  where revoked_at is null;

create or replace function public.release_appointment_coupon_usage(
  p_appointment_id uuid
)
returns void
language plpgsql
volatile
set search_path = public
as $$
declare
  v_coupon_id uuid;
begin
  select ad.coupon_id
  into v_coupon_id
  from public.appointment_discounts ad
  where ad.appointment_id = p_appointment_id;

  if v_coupon_id is null then
    return;
  end if;

  update public.coupons
  set used_count = greatest(used_count - 1, 0),
      updated_at = now()
  where id = v_coupon_id
    and used_count > 0;
end;
$$;

create or replace function public.promote_checkout_hold(
  p_checkout_hold_id uuid,
  p_customer_id uuid,
  p_coupon_code text default null,
  p_term_version_ids uuid[] default '{}'::uuid[],
  p_participants jsonb default '[]'::jsonb,
  p_answers jsonb default '[]'::jsonb,
  p_acceptance_ip inet default null,
  p_acceptance_user_agent text default null
)
returns jsonb
language plpgsql
volatile
set search_path = public, extensions
as $$
declare
  v_hold public.checkout_holds%rowtype;
  v_service public.services%rowtype;
  v_customer public.customers%rowtype;
  v_package_res public.checkout_hour_package_reservations%rowtype;
  v_has_package boolean := false;
  v_coupon public.coupons%rowtype;
  v_coupon_discount numeric(12,2) := 0;
  v_cash_due numeric(12,2) := 0;
  v_final_status public.appointment_status;
  v_financial_status public.financial_status;
  v_allocation_status public.allocation_status;
  v_payment_hold_minutes integer;
  v_hold_expires_at timestamptz;
  v_appointment_id uuid := gen_random_uuid();
  v_public_code text;
  v_raw_access_token text;
  v_access_token_hash text;
  v_allocation_count integer;
  v_expected_allocations integer;
  v_missing_required_fields integer;
  v_required_terms uuid[] := '{}'::uuid[];
  v_term_id uuid;
  v_quote jsonb;
  v_base_price numeric(12,2) := 0;
  v_day_time_adjustment numeric(12,2) := 0;
  v_people_adjustment numeric(12,2) := 0;
  v_extras_total numeric(12,2) := 0;
  v_contract_value_before_package numeric(12,2) := 0;
  v_coupon_applied boolean := false;
begin
  select * into v_hold
  from public.checkout_holds
  where id = p_checkout_hold_id
  for update;

  if not found then
    raise exception using errcode = 'P0001', message = 'CHECKOUT_HOLD_NOT_FOUND';
  end if;

  if v_hold.status <> 'ACTIVE' or v_hold.expires_at <= now() then
    raise exception using errcode = 'P0001', message = 'CHECKOUT_HOLD_EXPIRED';
  end if;

  if v_hold.promoted_appointment_id is not null then
    raise exception using errcode = 'P0001', message = 'CHECKOUT_HOLD_ALREADY_PROMOTED';
  end if;

  select * into v_customer
  from public.customers
  where id = p_customer_id;

  if not found then
    raise exception using errcode = 'P0001', message = 'CUSTOMER_NOT_FOUND';
  end if;

  if v_hold.primary_customer_id is not null and v_hold.primary_customer_id <> p_customer_id then
    raise exception using errcode = 'P0001', message = 'CHECKOUT_CUSTOMER_MISMATCH';
  end if;

  update public.checkout_holds
  set primary_customer_id = p_customer_id,
      updated_at = now()
  where id = v_hold.id;

  select * into v_service
  from public.services
  where id = v_hold.service_id;

  if not found or not v_service.is_active then
    raise exception using errcode = 'P0001', message = 'SERVICE_NOT_AVAILABLE';
  end if;

  v_quote := coalesce(
    v_hold.quote_snapshot,
    public.calculate_booking_quote(
      v_hold.service_id,
      v_hold.service_employee_id,
      v_hold.extra_selections,
      v_hold.people_count,
      v_hold.requested_start_at,
      null
    )
  );

  v_base_price := coalesce((v_quote->>'base_price')::numeric, v_service.base_price);
  v_day_time_adjustment := coalesce((v_quote->>'day_time_adjustment')::numeric, 0);
  v_people_adjustment := coalesce((v_quote->>'people_adjustment')::numeric, 0);
  v_extras_total := coalesce((v_quote->>'extras_total')::numeric, 0);
  v_contract_value_before_package := coalesce((v_quote->>'commercial_value')::numeric, v_hold.commercial_value);

  select * into v_package_res
  from public.checkout_hour_package_reservations
  where checkout_hold_id = v_hold.id
    and status = 'HELD'
  for update;

  v_has_package := found;

  if v_has_package and p_coupon_code is not null and btrim(p_coupon_code) <> '' then
    raise exception using errcode = 'P0001', message = 'COUPON_PACKAGE_POLICY_REQUIRES_DECISION';
  end if;

  if v_has_package then
    if not exists (
      select 1
      from public.hour_packages hp
      where hp.id = v_package_res.hour_package_id
        and hp.customer_id = p_customer_id
        and hp.status = 'ACTIVE'
    ) then
      raise exception using errcode = 'P0001', message = 'HOUR_PACKAGE_CUSTOMER_MISMATCH';
    end if;

    v_cash_due := v_package_res.cash_due;
  else
    v_cash_due := v_contract_value_before_package;

    if p_coupon_code is not null and btrim(p_coupon_code) <> '' then
      select c.* into v_coupon
      from public.coupons c
      where lower(c.code) = lower(btrim(p_coupon_code))
      for update;

      if not found
        or not v_coupon.is_active
        or (v_coupon.valid_from is not null and now() < v_coupon.valid_from)
        or (v_coupon.valid_until is not null and now() > v_coupon.valid_until)
      then
        raise exception using errcode = 'P0001', message = 'INVALID_COUPON';
      end if;

      if v_coupon.max_uses is not null and v_coupon.used_count >= v_coupon.max_uses then
        raise exception using errcode = 'P0001', message = 'COUPON_USAGE_LIMIT_REACHED';
      end if;

      if v_coupon.source = 'CANCELLATION_CREDIT'
        and v_coupon.customer_id <> p_customer_id
      then
        raise exception using errcode = 'P0001', message = 'COUPON_CUSTOMER_MISMATCH';
      end if;

      if exists (select 1 from public.coupon_services cs where cs.coupon_id = v_coupon.id)
        and not exists (
          select 1
          from public.coupon_services cs
          where cs.coupon_id = v_coupon.id
            and cs.service_id = v_hold.service_id
        )
      then
        raise exception using errcode = 'P0001', message = 'INVALID_COUPON';
      end if;

      if v_coupon.discount_type = 'FIXED' then
        v_coupon_discount := least(v_coupon.discount_value, v_cash_due);
      else
        v_coupon_discount := round(v_cash_due * v_coupon.discount_value / 100, 2);
      end if;

      v_cash_due := round(greatest(v_cash_due - v_coupon_discount, 0), 2);
      v_coupon_applied := true;
    end if;
  end if;

  if jsonb_typeof(coalesce(p_answers, '[]'::jsonb)) <> 'array' then
    raise exception using errcode = 'P0001', message = 'INVALID_SERVICE_ANSWERS';
  end if;

  select count(*)::integer into v_missing_required_fields
  from public.service_fields sf
  where sf.service_id = v_hold.service_id
    and sf.is_active
    and sf.is_required
    and not exists (
      select 1
      from jsonb_to_recordset(coalesce(p_answers, '[]'::jsonb)) as a(service_field_id uuid, value jsonb)
      where a.service_field_id = sf.id
        and a.value is not null
        and a.value <> 'null'::jsonb
        and not (jsonb_typeof(a.value) = 'string' and btrim(a.value #>> '{}') = '')
    );

  if v_missing_required_fields > 0 then
    raise exception using errcode = 'P0001', message = 'REQUIRED_SERVICE_FIELDS_MISSING';
  end if;

  if v_service.requires_terms then
    select coalesce(array_agg(tv.id), '{}'::uuid[])
    into v_required_terms
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
      );

    if coalesce(array_length(v_required_terms, 1), 0) = 0 then
      raise exception using errcode = 'P0001', message = 'TERMS_CONFIGURATION_MISSING';
    end if;

    if exists (
      select 1
      from unnest(v_required_terms) required_id
      where not (required_id = any(coalesce(p_term_version_ids, '{}'::uuid[])))
    ) then
      raise exception using errcode = 'P0001', message = 'TERMS_NOT_ACCEPTED';
    end if;
  end if;

  if jsonb_typeof(coalesce(p_participants, '[]'::jsonb)) <> 'array' then
    raise exception using errcode = 'P0001', message = 'INVALID_PARTICIPANTS';
  end if;

  if v_cash_due = 0 then
    v_final_status := 'CONFIRMED';
    v_financial_status := 'PAID';
    v_allocation_status := 'CONFIRMED';
    v_hold_expires_at := null;
  else
    v_final_status := 'AWAITING_PAYMENT';
    v_financial_status := 'PENDING';
    v_allocation_status := 'AWAITING_PAYMENT';

    select coalesce(v_service.payment_hold_minutes, os.payment_hold_minutes)
    into v_payment_hold_minutes
    from public.operation_settings os
    where os.id = 1;

    v_hold_expires_at := now() + make_interval(mins => v_payment_hold_minutes);
  end if;

  loop
    v_public_code := upper(substr(encode(gen_random_bytes(8), 'hex'), 1, 12));
    exit when not exists (
      select 1 from public.appointments a where a.public_code = v_public_code
    );
  end loop;

  insert into public.appointments (
    id,
    public_code,
    service_id,
    service_employee_id,
    primary_customer_id,
    status,
    financial_status,
    start_at,
    end_at,
    duration_minutes,
    people_count,
    hold_expires_at,
    service_name_snapshot,
    service_description_snapshot,
    base_duration_snapshot,
    buffer_before_snapshot,
    buffer_after_snapshot,
    base_price_snapshot,
    variable_price_adjustment,
    extras_total,
    coupon_discount,
    commercial_value,
    confirmed_at
  ) values (
    v_appointment_id,
    v_public_code,
    v_hold.service_id,
    v_hold.service_employee_id,
    p_customer_id,
    v_final_status,
    v_financial_status,
    v_hold.requested_start_at,
    v_hold.requested_end_at,
    v_hold.duration_minutes,
    v_hold.people_count,
    v_hold_expires_at,
    v_service.name,
    v_service.full_description,
    v_service.base_duration_minutes,
    v_service.buffer_before_minutes,
    v_service.buffer_after_minutes,
    v_base_price,
    v_day_time_adjustment + v_people_adjustment,
    v_extras_total,
    v_coupon_discount,
    v_cash_due,
    case when v_final_status = 'CONFIRMED' then now() else null end
  );

  insert into public.appointment_participants (
    appointment_id,
    customer_id,
    role,
    name_snapshot,
    email_snapshot,
    phone_snapshot,
    cpf_cnpj_snapshot
  ) values (
    v_appointment_id,
    v_customer.id,
    'BOOKER',
    v_customer.name,
    v_customer.email,
    v_customer.phone,
    v_customer.cpf_cnpj
  );

  insert into public.appointment_participants (
    appointment_id,
    customer_id,
    role,
    name_snapshot,
    email_snapshot,
    phone_snapshot,
    cpf_cnpj_snapshot
  )
  select
    v_appointment_id,
    p.customer_id,
    p.role,
    p.name,
    p.email,
    p.phone,
    p.cpf_cnpj
  from jsonb_to_recordset(coalesce(p_participants, '[]'::jsonb)) as p(
    customer_id uuid,
    role text,
    name text,
    email text,
    phone text,
    cpf_cnpj text
  )
  where p.name is not null
    and p.role in ('END_CUSTOMER','PAYER','OPERATIONAL_CONTACT');

  insert into public.appointment_extras (
    appointment_id,
    extra_id,
    name_snapshot,
    unit_price_snapshot,
    duration_delta_snapshot,
    quantity,
    total_price,
    total_duration_delta
  )
  select
    v_appointment_id,
    e.id,
    e.name,
    e.price,
    e.duration_delta_minutes,
    x.quantity,
    round(e.price * x.quantity, 2),
    e.duration_delta_minutes * x.quantity
  from jsonb_to_recordset(coalesce(v_hold.extra_selections, '[]'::jsonb)) as x(extra_id uuid, quantity integer)
  join public.extras e on e.id = x.extra_id;

  insert into public.appointment_answers (
    appointment_id,
    service_field_id,
    field_key_snapshot,
    label_snapshot,
    value_json
  )
  select
    v_appointment_id,
    sf.id,
    sf.field_key,
    sf.label,
    a.value
  from jsonb_to_recordset(coalesce(p_answers, '[]'::jsonb)) as a(service_field_id uuid, value jsonb)
  join public.service_fields sf
    on sf.id = a.service_field_id
   and sf.service_id = v_hold.service_id
   and sf.is_active;

  if v_coupon_applied then
    insert into public.appointment_discounts (
      appointment_id,
      coupon_id,
      code_snapshot,
      discount_type_snapshot,
      discount_value_snapshot,
      calculated_discount_amount
    ) values (
      v_appointment_id,
      v_coupon.id,
      v_coupon.code,
      v_coupon.discount_type,
      v_coupon.discount_value,
      v_coupon_discount
    );

    update public.coupons
    set used_count = used_count + 1,
        updated_at = now()
    where id = v_coupon.id;
  end if;

  foreach v_term_id in array coalesce(p_term_version_ids, '{}'::uuid[])
  loop
    insert into public.appointment_term_acceptances (
      appointment_id,
      terms_version_id,
      content_snapshot,
      ip_address,
      user_agent
    )
    select
      v_appointment_id,
      tv.id,
      tv.content,
      p_acceptance_ip,
      p_acceptance_user_agent
    from public.terms_versions tv
    where tv.id = v_term_id
      and (tv.service_id is null or tv.service_id = v_hold.service_id)
    on conflict (appointment_id, terms_version_id) do nothing;
  end loop;

  update public.resource_allocations
  set appointment_id = v_appointment_id,
      checkout_hold_id = null,
      allocation_type = 'APPOINTMENT',
      status = v_allocation_status,
      updated_at = now()
  where checkout_hold_id = v_hold.id
    and allocation_type = 'CHECKOUT_HOLD'
    and status = 'HELD';

  get diagnostics v_allocation_count = row_count;
  v_expected_allocations := coalesce(array_length(v_hold.resource_ids, 1), 0);

  if v_allocation_count = 0 or v_allocation_count <> v_expected_allocations then
    raise exception using errcode = 'P0001', message = 'CHECKOUT_HOLD_RESOURCE_INTEGRITY_ERROR';
  end if;

  update public.checkout_holds
  set status = 'PROMOTED',
      promoted_appointment_id = v_appointment_id,
      updated_at = now()
  where id = v_hold.id;

  if v_has_package and v_final_status = 'CONFIRMED' then
    perform public.consume_hour_package_checkout(v_hold.id, v_appointment_id);
  end if;

  v_raw_access_token := encode(gen_random_bytes(32), 'hex');
  v_access_token_hash := encode(digest(v_raw_access_token, 'sha256'), 'hex');

  insert into public.appointment_access_tokens (
    appointment_id,
    token_hash,
    scope
  ) values (
    v_appointment_id,
    v_access_token_hash,
    'MANAGE'
  );

  insert into public.audit_logs (
    entity_type,
    entity_id,
    action,
    before_json,
    after_json,
    origin
  ) values (
    'APPOINTMENT',
    v_appointment_id,
    'CHECKOUT_HOLD_PROMOTED',
    jsonb_build_object('checkout_hold_id', v_hold.id),
    jsonb_build_object(
      'status', v_final_status,
      'financial_status', v_financial_status,
      'cash_due', v_cash_due,
      'package_reserved', v_has_package,
      'coupon_applied', v_coupon_applied
    ),
    'PUBLIC'
  );

  if v_final_status = 'CONFIRMED' then
    insert into public.integration_jobs (
      job_type,
      entity_type,
      entity_id,
      entity_version,
      payload_json,
      idempotency_key
    ) values
      (
        'GOOGLE_APPOINTMENT_SYNC',
        'APPOINTMENT',
        v_appointment_id,
        1,
        jsonb_build_object('reason', 'INITIAL_CONFIRMATION'),
        'google-appointment-sync:' || v_appointment_id::text || ':1'
      ),
      (
        'APPOINTMENT_CONFIRMED_MESSAGE',
        'APPOINTMENT',
        v_appointment_id,
        1,
        jsonb_build_object('reason', 'INITIAL_CONFIRMATION'),
        'appointment-confirmed-message:' || v_appointment_id::text || ':1'
      )
    on conflict (idempotency_key) do nothing;
  end if;

  return jsonb_build_object(
    'appointment_id', v_appointment_id,
    'public_code', v_public_code,
    'status', v_final_status,
    'financial_status', v_financial_status,
    'hold_expires_at', v_hold_expires_at,
    'cash_due', v_cash_due,
    'package_reserved', v_has_package,
    'coupon_applied', v_coupon_applied,
    'access_token', v_raw_access_token
  );
end;
$$;

create or replace function public.expire_due_appointment_holds()
returns integer
language plpgsql
volatile
set search_path = public
as $$
declare
  v_appointment record;
  v_count integer := 0;
begin
  for v_appointment in
    select a.id
    from public.appointments a
    where a.status = 'AWAITING_PAYMENT'
      and a.hold_expires_at is not null
      and a.hold_expires_at <= now()
    for update skip locked
  loop
    perform public.release_appointment_coupon_usage(v_appointment.id);

    update public.appointments
    set status = 'EXPIRED',
        financial_status = case
          when financial_status in ('NOT_STARTED','PENDING','REJECTED') then 'EXPIRED'
          else financial_status
        end,
        updated_at = now()
    where id = v_appointment.id;

    update public.resource_allocations
    set status = 'EXPIRED',
        updated_at = now()
    where appointment_id = v_appointment.id
      and status in ('HELD','AWAITING_PAYMENT');

    update public.checkout_hour_package_reservations phr
    set status = 'RELEASED',
        released_at = now(),
        release_reason = 'APPOINTMENT_PAYMENT_HOLD_EXPIRED',
        updated_at = now()
    from public.checkout_holds ch
    where ch.promoted_appointment_id = v_appointment.id
      and phr.checkout_hold_id = ch.id
      and phr.status = 'HELD';

    insert into public.audit_logs (
      entity_type,
      entity_id,
      action,
      after_json,
      origin
    ) values (
      'APPOINTMENT',
      v_appointment.id,
      'PAYMENT_HOLD_EXPIRED',
      jsonb_build_object('status', 'EXPIRED'),
      'SYSTEM'
    );

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;
