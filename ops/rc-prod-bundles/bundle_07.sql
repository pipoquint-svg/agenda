
-- BEGIN RC MIGRATION 20260823221500_duration_guidance_ranges.sql
-- Editorial guidance for variable-duration services.
-- This table carries no pricing logic: it only helps the UI explain what can
-- typically be produced within a selected duration range.

create table if not exists public.service_duration_guidance_ranges (
  id uuid primary key default gen_random_uuid(),
  service_id uuid not null references public.services(id) on delete cascade,
  min_blocks integer not null check (min_blocks > 0),
  max_blocks integer check (max_blocks is null or max_blocks >= min_blocks),
  title text not null check (btrim(title) <> ''),
  description text not null check (btrim(description) <> ''),
  is_active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists service_duration_guidance_ranges_service_idx
  on public.service_duration_guidance_ranges(service_id, is_active, min_blocks, max_blocks, sort_order);

alter table public.service_duration_guidance_ranges enable row level security;
revoke all on public.service_duration_guidance_ranges from public, anon, authenticated;

create or replace function public.public_get_booking_page(p_slug text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
select jsonb_build_object(
  'id', bp.id,
  'slug', bp.slug,
  'display_name', bp.display_name,
  'title', bp.title,
  'subtitle', bp.subtitle,
  'brand_key', bp.brand_key,
  'logo_url', bp.logo_url,
  'accent_color', bp.accent_color,
  'require_tax_id', bp.require_tax_id,
  'services', coalesce((
    select jsonb_agg(
      jsonb_build_object(
        'id', s.id,
        'name', s.name,
        'slug', s.slug,
        'short_description', s.short_description,
        'cover_image_url', s.cover_image_url,
        'base_duration_minutes', s.base_duration_minutes,
        'base_price', s.base_price,
        'duration_mode', s.duration_mode,
        'booking_block_minutes', s.booking_block_minutes,
        'minimum_booking_blocks', s.minimum_booking_blocks,
        'maximum_booking_blocks', s.maximum_booking_blocks,
        'price_per_block', s.price_per_block,
        'buffer_before_minutes', s.buffer_before_minutes,
        'buffer_after_minutes', s.buffer_after_minutes,
        'minimum_people', s.minimum_people,
        'maximum_people', s.maximum_people,
        'requires_terms', s.requires_terms,
        'duration_presets', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', p.id,
            'block_count', p.block_count,
            'title', p.title,
            'description', p.description,
            'badge', p.badge,
            'is_featured', p.is_featured
          ) order by p.sort_order, p.block_count, p.id)
          from public.service_duration_presets p
          where p.service_id = s.id and p.is_active
        ), '[]'::jsonb),
        'duration_guidance', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', g.id,
            'min_blocks', g.min_blocks,
            'max_blocks', g.max_blocks,
            'title', g.title,
            'description', g.description
          ) order by g.sort_order, g.min_blocks, g.id)
          from public.service_duration_guidance_ranges g
          where g.service_id = s.id and g.is_active
        ), '[]'::jsonb),
        'employees', coalesce((
          select jsonb_agg(jsonb_build_object(
            'service_employee_id', se.id,
            'employee_id', e.id,
            'name', e.name
          ) order by e.name, se.id)
          from public.service_employees se
          join public.employees e on e.id = se.employee_id and e.is_active
          where se.service_id = s.id and se.is_active
        ), '[]'::jsonb),
        'extras', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', e.id,
            'name', e.name,
            'description', e.description,
            'price', e.price,
            'duration_delta_minutes', e.duration_delta_minutes,
            'is_required', sx.is_required,
            'max_quantity', sx.max_quantity,
            'schedule_placement', sx.schedule_placement,
            'default_schedule_minutes', sx.default_schedule_minutes
          ) order by sx.sort_order, e.name, e.id)
          from public.service_extras sx
          join public.extras e on e.id = sx.extra_id and e.is_active
          where sx.service_id = s.id
        ), '[]'::jsonb),
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
          where sf.service_id = s.id and sf.is_active
        ), '[]'::jsonb)
      ) order by bps.sort_order, s.sort_order, s.name
    )
    from public.booking_page_services bps
    join public.services s on s.id = bps.service_id and s.is_active
    where bps.booking_page_id = bp.id and bps.is_active
  ), '[]'::jsonb)
)
from public.booking_pages bp
where bp.slug = lower(btrim(p_slug)) and bp.is_active;
$$;

revoke all on function public.public_get_booking_page(text) from public;
grant execute on function public.public_get_booking_page(text) to anon, authenticated;
-- END RC MIGRATION 20260823221500_duration_guidance_ranges.sql

-- BEGIN RC MIGRATION 20260823235500_fix_duration_checkout_origin.sql
-- Preserve the public booking-page origin on duration-based checkout holds.
-- The FIXED wrapper already does this; BLOCKS must follow the same contract so
-- public_get_checkout_context can enforce CHECKOUT_ORIGIN_MISSING fail-closed.

create or replace function public.public_create_checkout_hold_duration(
  p_booking_page_slug text,
  p_service_id uuid,
  p_service_employee_id uuid,
  p_duration_blocks integer,
  p_extra_selections jsonb,
  p_people_count integer,
  p_requested_start_at timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_page_id uuid;
  v_result jsonb;
  v_hold_id uuid;
begin
  perform public.assert_public_booking_duration(
    p_booking_page_slug,
    p_service_id,
    p_service_employee_id,
    p_duration_blocks,
    p_extra_selections,
    p_people_count
  );

  select id into v_page_id
  from public.booking_pages
  where slug = lower(btrim(p_booking_page_slug))
    and is_active;

  if v_page_id is null then
    raise exception using errcode = 'P0001', message = 'BOOKING_PAGE_NOT_AVAILABLE';
  end if;

  v_result := public.create_checkout_hold_for_duration(
    p_service_id,
    p_service_employee_id,
    p_duration_blocks,
    p_extra_selections,
    p_people_count,
    p_requested_start_at
  );

  v_hold_id := (v_result->>'checkout_hold_id')::uuid;

  update public.checkout_holds
  set booking_page_id = v_page_id,
      updated_at = now()
  where id = v_hold_id;

  if not found then
    raise exception using errcode = 'P0001', message = 'CHECKOUT_HOLD_NOT_FOUND';
  end if;

  return v_result || jsonb_build_object(
    'booking_page_slug', lower(btrim(p_booking_page_slug))
  );
end;
$$;

-- Keep the production hardening contract: state-changing public RPCs are callable
-- only through the Edge gateway, never directly from anon/authenticated clients.
revoke all on function public.public_create_checkout_hold_duration(
  text, uuid, uuid, integer, jsonb, integer, timestamptz
) from public, anon, authenticated;
grant execute on function public.public_create_checkout_hold_duration(
  text, uuid, uuid, integer, jsonb, integer, timestamptz
) to service_role;
-- END RC MIGRATION 20260823235500_fix_duration_checkout_origin.sql

-- BEGIN RC MIGRATION 20260823235600_restore_duration_pricing_tiers_catalog.sql
-- Restore duration_pricing_tiers in the public catalog after the duration-guidance
-- migration replaced public_get_booking_page. Preserve the new editorial guidance too.

create or replace function public.public_get_booking_page(p_slug text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
select jsonb_build_object(
  'id', bp.id,
  'slug', bp.slug,
  'display_name', bp.display_name,
  'title', bp.title,
  'subtitle', bp.subtitle,
  'brand_key', bp.brand_key,
  'logo_url', bp.logo_url,
  'accent_color', bp.accent_color,
  'require_tax_id', bp.require_tax_id,
  'services', coalesce((
    select jsonb_agg(
      jsonb_build_object(
        'id', s.id,
        'name', s.name,
        'slug', s.slug,
        'short_description', s.short_description,
        'cover_image_url', s.cover_image_url,
        'base_duration_minutes', s.base_duration_minutes,
        'base_price', s.base_price,
        'duration_mode', s.duration_mode,
        'booking_block_minutes', s.booking_block_minutes,
        'minimum_booking_blocks', s.minimum_booking_blocks,
        'maximum_booking_blocks', s.maximum_booking_blocks,
        'price_per_block', s.price_per_block,
        'buffer_before_minutes', s.buffer_before_minutes,
        'buffer_after_minutes', s.buffer_after_minutes,
        'minimum_people', s.minimum_people,
        'maximum_people', s.maximum_people,
        'requires_terms', s.requires_terms,
        'duration_pricing_tiers', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', t.id,
            'min_blocks', t.min_blocks,
            'max_blocks', t.max_blocks,
            'price_per_block', t.price_per_block
          ) order by t.sort_order, t.min_blocks, t.id)
          from public.service_duration_pricing_tiers t
          where t.service_id = s.id and t.is_active
        ), '[]'::jsonb),
        'duration_presets', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', p.id,
            'block_count', p.block_count,
            'title', p.title,
            'description', p.description,
            'badge', p.badge,
            'is_featured', p.is_featured
          ) order by p.sort_order, p.block_count, p.id)
          from public.service_duration_presets p
          where p.service_id = s.id and p.is_active
        ), '[]'::jsonb),
        'duration_guidance', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', g.id,
            'min_blocks', g.min_blocks,
            'max_blocks', g.max_blocks,
            'title', g.title,
            'description', g.description
          ) order by g.sort_order, g.min_blocks, g.id)
          from public.service_duration_guidance_ranges g
          where g.service_id = s.id and g.is_active
        ), '[]'::jsonb),
        'employees', coalesce((
          select jsonb_agg(jsonb_build_object(
            'service_employee_id', se.id,
            'employee_id', e.id,
            'name', e.name
          ) order by e.name, se.id)
          from public.service_employees se
          join public.employees e on e.id = se.employee_id and e.is_active
          where se.service_id = s.id and se.is_active
        ), '[]'::jsonb),
        'extras', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', e.id,
            'name', e.name,
            'description', e.description,
            'price', e.price,
            'duration_delta_minutes', e.duration_delta_minutes,
            'is_required', sx.is_required,
            'max_quantity', sx.max_quantity,
            'schedule_placement', sx.schedule_placement,
            'default_schedule_minutes', sx.default_schedule_minutes
          ) order by sx.sort_order, e.name, e.id)
          from public.service_extras sx
          join public.extras e on e.id = sx.extra_id and e.is_active
          where sx.service_id = s.id
        ), '[]'::jsonb),
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
          where sf.service_id = s.id and sf.is_active
        ), '[]'::jsonb)
      ) order by bps.sort_order, s.sort_order, s.name
    )
    from public.booking_page_services bps
    join public.services s on s.id = bps.service_id and s.is_active
    where bps.booking_page_id = bp.id and bps.is_active
  ), '[]'::jsonb)
)
from public.booking_pages bp
where bp.slug = lower(btrim(p_slug)) and bp.is_active;
$$;

revoke all on function public.public_get_booking_page(text) from public;
grant execute on function public.public_get_booking_page(text) to anon, authenticated;
-- END RC MIGRATION 20260823235600_restore_duration_pricing_tiers_catalog.sql

-- BEGIN RC MIGRATION 20260824002000_payment_method_preview.sql
-- Preview autoritativo dos valores por método de pagamento.
-- A UI nunca calcula desconto: recebe o valor líquido já calculado pelo banco.

create or replace function public.service_calculate_payment_cash_amount(
  p_contract_amount numeric,
  p_method text,
  p_pix_discount_percent numeric
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_contract numeric(12,2);
  v_discount_percent numeric(5,2);
  v_discount numeric(12,2);
  v_cash numeric(12,2);
begin
  if p_method not in ('PIX','CARD') then
    raise exception using errcode = 'P0001', message = 'PUBLIC_PAYMENT_METHOD_NOT_ALLOWED';
  end if;

  v_contract := round(coalesce(p_contract_amount, 0), 2);
  v_discount_percent := round(coalesce(p_pix_discount_percent, 0), 2);

  if v_contract < 0 then
    raise exception using errcode = '22023', message = 'PAYMENT_AMOUNT_INVALID';
  end if;
  if v_discount_percent < 0 or v_discount_percent > 100 then
    raise exception using errcode = '22023', message = 'PIX_DISCOUNT_PERCENT_INVALID';
  end if;

  v_discount := case
    when p_method = 'PIX' then round(v_contract * v_discount_percent / 100, 2)
    else 0
  end;
  v_cash := round(v_contract - v_discount, 2);

  return jsonb_build_object(
    'contract_amount', v_contract,
    'payment_discount_amount', v_discount,
    'cash_amount', v_cash,
    'method', p_method
  );
end;
$$;

revoke all on function public.service_calculate_payment_cash_amount(numeric,text,numeric) from public, anon, authenticated;
grant execute on function public.service_calculate_payment_cash_amount(numeric,text,numeric) to service_role;

create or replace function public.service_get_public_payment_method_preview(
  p_access_token text
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_context jsonb;
  v_minimum_contract numeric(12,2);
  v_full_contract numeric(12,2);
  v_discount_percent numeric(5,2);
  v_minimum_pix jsonb;
  v_full_pix jsonb;
begin
  -- Reusa toda a validação autoritativa de token/status/hold já existente.
  v_context := public.service_get_public_payment_context(p_access_token);

  v_minimum_contract := round(coalesce((v_context->>'minimum_due_contract_amount')::numeric, 0), 2);
  v_full_contract := round(coalesce((v_context->>'contract_balance')::numeric, 0), 2);

  select round(coalesce(os.pix_discount_percent, 0), 2)
  into v_discount_percent
  from public.operation_settings os
  where os.id = 1;

  if v_discount_percent is null then
    raise exception using errcode = 'P0001', message = 'PAYMENT_SETTINGS_LOAD_FAILED';
  end if;

  v_minimum_pix := public.service_calculate_payment_cash_amount(v_minimum_contract, 'PIX', v_discount_percent);
  v_full_pix := public.service_calculate_payment_cash_amount(v_full_contract, 'PIX', v_discount_percent);

  return jsonb_build_object(
    'pix_discount_percent', v_discount_percent,
    'confirmation_percentage', (v_context->>'confirmation_percentage')::numeric,
    'minimum_available', coalesce((v_context->>'minimum_available')::boolean, false),
    'full_available', coalesce((v_context->>'full_available')::boolean, false),
    'minimum_due_contract_amount', v_minimum_contract,
    'minimum_due_card_cash_amount', v_minimum_contract,
    'minimum_due_pix_cash_amount', (v_minimum_pix->>'cash_amount')::numeric,
    'full_due_contract_amount', v_full_contract,
    'full_due_card_cash_amount', v_full_contract,
    'full_due_pix_cash_amount', (v_full_pix->>'cash_amount')::numeric
  );
end;
$$;

revoke all on function public.service_get_public_payment_method_preview(text) from public, anon, authenticated;
grant execute on function public.service_get_public_payment_method_preview(text) to service_role;

-- Mantém create_payment_intent como fonte da cobrança e faz o cálculo usar o
-- mesmo helper do preview, eliminando divergência de arredondamento/regra.
create or replace function public.create_payment_intent(
  p_appointment_id uuid,
  p_payment_percentage numeric,
  p_method text,
  p_idempotency_key text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_appointment public.appointments%rowtype;
  v_service public.services%rowtype;
  v_existing public.payment_transactions%rowtype;
  v_summary jsonb;
  v_balance numeric(12,2);
  v_settled_before numeric(12,2);
  v_confirmation_percentage numeric(5,2);
  v_confirmation_target numeric(12,2);
  v_contract_amount numeric(12,2);
  v_discount_percent numeric(5,2);
  v_discount numeric(12,2);
  v_cash_amount numeric(12,2);
  v_amounts jsonb;
  v_transaction_id uuid;
  v_payment_kind text;
begin
  if p_method not in ('PIX','CARD') then
    raise exception using errcode = 'P0001', message = 'PUBLIC_PAYMENT_METHOD_NOT_ALLOWED';
  end if;

  if p_idempotency_key is null or btrim(p_idempotency_key) = '' then
    raise exception using errcode = 'P0001', message = 'IDEMPOTENCY_KEY_REQUIRED';
  end if;

  select * into v_existing
  from public.payment_transactions
  where idempotency_key = p_idempotency_key;

  if found then
    if v_existing.appointment_id <> p_appointment_id
       or v_existing.method <> p_method
       or v_existing.requested_percentage is distinct from p_payment_percentage then
      raise exception using errcode = 'P0001', message = 'IDEMPOTENCY_KEY_CONFLICT';
    end if;

    return jsonb_build_object(
      'transaction_id', v_existing.id,
      'appointment_id', v_existing.appointment_id,
      'status', v_existing.status,
      'payment_percentage', v_existing.requested_percentage,
      'contract_amount_settled', v_existing.contract_amount_settled,
      'payment_discount_amount', v_existing.payment_discount_amount,
      'cash_amount', v_existing.cash_amount,
      'method', v_existing.method,
      'idempotent_replay', true
    );
  end if;

  perform public.expire_due_appointment_holds();

  select * into v_appointment
  from public.appointments
  where id = p_appointment_id
  for update;

  if not found then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_NOT_FOUND';
  end if;

  if v_appointment.status not in ('AWAITING_PAYMENT','CONFIRMED') then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_NOT_PAYABLE';
  end if;

  if v_appointment.status = 'AWAITING_PAYMENT'
     and (v_appointment.hold_expires_at is null or v_appointment.hold_expires_at <= now()) then
    raise exception using errcode = 'P0001', message = 'PAYMENT_HOLD_EXPIRED';
  end if;

  select * into v_service
  from public.services
  where id = v_appointment.service_id;

  if not found then
    raise exception using errcode = 'P0001', message = 'SERVICE_NOT_FOUND';
  end if;

  select
    coalesce(v_service.confirmation_percentage, os.default_confirmation_percentage),
    os.pix_discount_percent
  into v_confirmation_percentage, v_discount_percent
  from public.operation_settings os
  where os.id = 1;

  if p_payment_percentage <> 100
     and p_payment_percentage <> v_confirmation_percentage then
    raise exception using errcode = 'P0001', message = 'INVALID_PAYMENT_PERCENTAGE';
  end if;

  v_summary := public.get_appointment_financial_summary(p_appointment_id);
  v_balance := (v_summary->>'contract_balance')::numeric;
  v_settled_before := (v_summary->>'contract_settled')::numeric;

  if v_balance <= 0 then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_ALREADY_PAID';
  end if;

  v_confirmation_target := round(
    coalesce(v_appointment.commercial_value, 0) * v_confirmation_percentage / 100,
    2
  );

  if p_payment_percentage = 100 then
    v_payment_kind := 'FULL_BALANCE';
    v_contract_amount := v_balance;
  else
    v_payment_kind := 'CONFIRMATION_MINIMUM';
    v_contract_amount := round(greatest(v_confirmation_target - v_settled_before, 0), 2);

    if v_contract_amount <= 0 then
      raise exception using errcode = 'P0001', message = 'CONFIRMATION_PAYMENT_ALREADY_SATISFIED';
    end if;

    v_contract_amount := least(v_contract_amount, v_balance);
  end if;

  v_amounts := public.service_calculate_payment_cash_amount(v_contract_amount, p_method, v_discount_percent);
  v_discount := (v_amounts->>'payment_discount_amount')::numeric;
  v_cash_amount := (v_amounts->>'cash_amount')::numeric;

  insert into public.payment_transactions (
    appointment_id,
    transaction_type,
    method,
    provider,
    status,
    contract_amount_settled,
    payment_discount_amount,
    cash_amount,
    idempotency_key,
    requested_percentage
  ) values (
    p_appointment_id,
    'CHARGE',
    p_method,
    'MERCADO_PAGO',
    'PENDING',
    v_contract_amount,
    v_discount,
    v_cash_amount,
    p_idempotency_key,
    p_payment_percentage
  ) returning id into v_transaction_id;

  if v_appointment.financial_status not in ('PARTIALLY_PAID','PAID','UNPAID_AUTHORIZED') then
    update public.appointments
    set financial_status = 'PENDING',
        updated_at = now()
    where id = p_appointment_id;
  end if;

  return jsonb_build_object(
    'transaction_id', v_transaction_id,
    'appointment_id', p_appointment_id,
    'status', 'PENDING',
    'payment_kind', v_payment_kind,
    'payment_percentage', p_payment_percentage,
    'confirmation_percentage', v_confirmation_percentage,
    'confirmation_target_amount', v_confirmation_target,
    'contract_settled_before', v_settled_before,
    'contract_balance_before', v_balance,
    'contract_amount_settled', v_contract_amount,
    'payment_discount_amount', v_discount,
    'cash_amount', v_cash_amount,
    'method', p_method,
    'provider', 'MERCADO_PAGO',
    'idempotent_replay', false
  );
end;
$$;
-- END RC MIGRATION 20260824002000_payment_method_preview.sql

-- BEGIN RC MIGRATION 20260824110000_blacksheep_update_active_hold_selection.sql
create or replace function public.public_update_checkout_hold_selection(
  p_checkout_hold_token text,
  p_extra_selections jsonb,
  p_people_count integer
)
returns jsonb
language plpgsql
security definer
set search_path to 'public','extensions'
as $function$
declare
  v_hold public.checkout_holds%rowtype;
  v_page_slug text;
  v_service public.services%rowtype;
  v_quote jsonb;
  v_canonical_extras jsonb;
  v_resource_ids uuid[] := '{}'::uuid[];
  v_new_pre integer;
  v_new_post integer;
  v_new_contracted integer;
  v_selection_hash text;
begin
  if p_checkout_hold_token is null or btrim(p_checkout_hold_token) = '' then
    raise exception using errcode='P0001', message='CHECKOUT_HOLD_TOKEN_REQUIRED';
  end if;

  select * into v_hold
  from public.checkout_holds
  where public_token_hash = encode(digest(p_checkout_hold_token,'sha256'),'hex')
  for update;

  if not found or v_hold.status <> 'ACTIVE' or v_hold.expires_at <= now() then
    raise exception using errcode='P0001', message='CHECKOUT_HOLD_NOT_ACTIVE';
  end if;

  select * into v_service from public.services where id=v_hold.service_id and is_active;
  if not found then
    raise exception using errcode='P0001', message='SERVICE_NOT_AVAILABLE';
  end if;
  if coalesce(v_service.operation_scope,'') <> 'BLACKSHEEP' then
    raise exception using errcode='P0001', message='HOLD_SELECTION_UPDATE_NOT_ALLOWED';
  end if;

  select bp.slug into v_page_slug
  from public.booking_pages bp
  where bp.id=v_hold.booking_page_id and bp.is_active;
  if v_page_slug is null then
    raise exception using errcode='P0001', message='CHECKOUT_ORIGIN_NOT_ACTIVE';
  end if;

  if exists (
    select 1 from public.checkout_hour_package_reservations phr
    where phr.checkout_hold_id=v_hold.id and phr.status='HELD'
  ) then
    raise exception using errcode='P0001', message='HOLD_SELECTION_LOCKED';
  end if;

  select coalesce(jsonb_agg(
    jsonb_build_object('extra_id',x.extra_id,'quantity',x.quantity) order by x.extra_id
  ),'[]'::jsonb)
  into v_canonical_extras
  from jsonb_to_recordset(coalesce(p_extra_selections,'[]'::jsonb)) x(extra_id uuid,quantity integer);

  perform public.assert_public_booking_duration(
    v_page_slug,
    v_hold.service_id,
    v_hold.service_employee_id,
    v_hold.duration_blocks,
    v_canonical_extras,
    p_people_count
  );

  v_new_contracted := public.resolve_service_contracted_minutes(v_hold.service_id,v_hold.duration_blocks);
  v_quote := public.calculate_booking_quote_for_duration(
    v_hold.service_id,
    v_hold.service_employee_id,
    v_hold.duration_blocks,
    v_canonical_extras,
    p_people_count,
    v_hold.core_start_at,
    null
  );

  v_new_pre := coalesce((v_quote->>'pre_service_minutes')::integer,0);
  v_new_post := coalesce((v_quote->>'post_service_minutes')::integer,0);

  if v_new_contracted <> v_hold.contracted_minutes
     or v_new_pre <> coalesce(v_hold.pre_service_minutes,0)
     or v_new_post <> coalesce(v_hold.post_service_minutes,0) then
    raise exception using errcode='P0001', message='HOLD_SELECTION_REQUIRES_NEW_SLOT';
  end if;

  select coalesce(array_agg(r.resource_id order by r.resource_id),'{}'::uuid[])
  into v_resource_ids
  from public.calculate_booking_resource_ranges_for_duration(
    v_hold.service_id,
    v_canonical_extras,
    v_hold.core_start_at,
    v_hold.duration_blocks
  ) r;

  if coalesce(array_length(v_resource_ids,1),0)=0 then
    raise exception using errcode='P0001', message='SERVICE_HAS_NO_REQUIRED_RESOURCES';
  end if;

  delete from public.resource_allocations
  where checkout_hold_id=v_hold.id
    and allocation_type='CHECKOUT_HOLD'
    and status='HELD';

  begin
    insert into public.resource_allocations(resource_id,checkout_hold_id,allocation_type,status,occupied_range)
    select r.resource_id,v_hold.id,'CHECKOUT_HOLD','HELD',r.occupied_range
    from public.calculate_booking_resource_ranges_for_duration(
      v_hold.service_id,
      v_canonical_extras,
      v_hold.core_start_at,
      v_hold.duration_blocks
    ) r;
  exception when exclusion_violation then
    raise exception using errcode='P0001', message='RESOURCE_NOT_AVAILABLE';
  end;

  v_selection_hash := md5(concat_ws('|',
    v_hold.service_id::text,
    v_hold.service_employee_id::text,
    coalesce(v_hold.duration_blocks::text,'FIXED'),
    v_canonical_extras::text,
    p_people_count::text,
    v_hold.requested_start_at::text,
    v_hold.core_start_at::text,
    v_quote->>'pricing_version'
  ));

  update public.checkout_holds
  set people_count=p_people_count,
      extra_selections=v_canonical_extras,
      commercial_value=(v_quote->>'commercial_value')::numeric(12,2),
      pricing_version=v_quote->>'pricing_version',
      quote_snapshot=v_quote,
      resource_ids=v_resource_ids,
      selection_hash=v_selection_hash,
      schedule_profile=v_quote->'schedule_profile',
      updated_at=now()
  where id=v_hold.id;

  return public.public_get_checkout_context(p_checkout_hold_token);
end;
$function$;

revoke all on function public.public_update_checkout_hold_selection(text,jsonb,integer) from public, anon, authenticated;
grant execute on function public.public_update_checkout_hold_selection(text,jsonb,integer) to service_role;

-- BlackSheep rentals require 24h advance notice. Visits remain separately configurable.
update public.services
set minimum_booking_notice_minutes = 1440,
    updated_at = now()
where operation_scope = 'BLACKSHEEP'
  and duration_mode = 'BLOCKS'
  and minimum_booking_notice_minutes <> 1440;
-- END RC MIGRATION 20260824110000_blacksheep_update_active_hold_selection.sql

-- BEGIN RC MIGRATION 20260824120000_autonomous_appointment_hold_expiry.sql
-- Finding 15: abandoned AWAITING_PAYMENT appointments must not keep resources occupied.
-- The custom GUC is test-only clock injection; production falls back to transaction time.

create or replace function public.expire_due_appointment_holds()
returns integer
language plpgsql
volatile
set search_path = public
as $$
declare
  v_appointment record;
  v_count integer := 0;
  v_now timestamptz := coalesce(
    nullif(current_setting('agenda.test_now', true), '')::timestamptz,
    now()
  );
begin
  for v_appointment in
    select a.id
    from public.appointments a
    where a.status = 'AWAITING_PAYMENT'
      and a.hold_expires_at is not null
      and a.hold_expires_at <= v_now
    for update skip locked
  loop
    perform public.release_appointment_coupon_usage(v_appointment.id);

    update public.appointments
    set status = 'EXPIRED',
        financial_status = case
          when financial_status in ('NOT_STARTED','PENDING','REJECTED') then 'EXPIRED'
          else financial_status
        end,
        updated_at = v_now
    where id = v_appointment.id;

    update public.resource_allocations
    set status = 'EXPIRED',
        updated_at = v_now
    where appointment_id = v_appointment.id
      and status in ('HELD','AWAITING_PAYMENT');

    update public.checkout_hour_package_reservations phr
    set status = 'RELEASED',
        released_at = v_now,
        release_reason = 'APPOINTMENT_PAYMENT_HOLD_EXPIRED',
        updated_at = v_now
    from public.checkout_holds ch
    where ch.promoted_appointment_id = v_appointment.id
      and phr.checkout_hold_id = ch.id
      and phr.status = 'HELD';

    insert into public.audit_logs (
      entity_type, entity_id, action, after_json, origin
    ) values (
      'APPOINTMENT', v_appointment.id, 'PAYMENT_HOLD_EXPIRED',
      jsonb_build_object('status', 'EXPIRED'), 'SYSTEM'
    );

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

create or replace function public.list_available_slots_for_duration(
  p_service_id uuid,
  p_service_employee_id uuid,
  p_duration_blocks integer default null,
  p_extra_selections jsonb default '[]'::jsonb,
  p_people_count integer default 1,
  p_local_date date default current_date,
  p_coupon_code text default null
)
returns table (
  slot_start_at timestamptz,
  slot_end_at timestamptz,
  core_start_at timestamptz,
  core_end_at timestamptz,
  pre_service_minutes integer,
  post_service_minutes integer,
  duration_minutes integer,
  commercial_value numeric(12,2)
)
language plpgsql
stable
set search_path = public, extensions
as $$
declare
  v_service public.services%rowtype;
  v_timezone text;
  v_slot_interval integer := 30;
  v_dow smallint;
  v_candidate_local timestamp without time zone;
  v_anchor_start timestamptz;
  v_core_end timestamptz;
  v_appointment_start timestamptz;
  v_appointment_end timestamptz;
  v_contracted_minutes integer;
  v_quote jsonb;
  v_pre integer;
  v_post integer;
  v_resource record;
  v_resource_local_date date;
  v_resource_dow smallint;
  v_resource_ok boolean;
  v_service_window_ok boolean;
  v_now timestamptz := coalesce(
    nullif(current_setting('agenda.test_now', true), '')::timestamptz,
    now()
  );
begin
  select * into v_service from public.services where id = p_service_id and is_active;
  if not found then
    raise exception using errcode = 'P0001', message = 'SERVICE_NOT_AVAILABLE';
  end if;

  if not exists (
    select 1 from public.service_employees se
    where se.id = p_service_employee_id and se.service_id = p_service_id and se.is_active
  ) then
    raise exception using errcode = 'P0001', message = 'EMPLOYEE_NOT_AVAILABLE_FOR_SERVICE';
  end if;

  v_contracted_minutes := public.resolve_service_contracted_minutes(p_service_id, p_duration_blocks);
  select timezone into v_timezone from public.operation_settings where id = 1;
  v_dow := extract(dow from p_local_date)::smallint;

  select coalesce(min(ar.slot_interval_minutes), public.get_default_slot_interval_minutes())
  into v_slot_interval
  from public.availability_rules ar
  where ar.service_employee_id = p_service_employee_id
    and ar.weekday = v_dow
    and ar.is_active;

  for v_candidate_local in
    select gs from generate_series(
      p_local_date::timestamp,
      (p_local_date + 1)::timestamp - interval '1 minute',
      make_interval(mins => v_slot_interval)
    ) gs
  loop
    v_anchor_start := v_candidate_local at time zone v_timezone;
    v_core_end := v_anchor_start + make_interval(mins => v_contracted_minutes);

    v_quote := public.calculate_booking_quote_for_duration(
      p_service_id, p_service_employee_id, p_duration_blocks,
      p_extra_selections, p_people_count, v_anchor_start, p_coupon_code
    );
    v_pre := coalesce((v_quote->>'pre_service_minutes')::integer, 0);
    v_post := coalesce((v_quote->>'post_service_minutes')::integer, 0);
    v_appointment_start := v_anchor_start - make_interval(mins => v_pre);
    v_appointment_end := v_core_end + make_interval(mins => v_post);

    if v_appointment_start < v_now + make_interval(mins => v_service.minimum_booking_notice_minutes) then continue; end if;
    if v_anchor_start > v_now + make_interval(days => v_service.maximum_booking_horizon_days) then continue; end if;

    select (
      exists (
        select 1 from public.availability_rules ar
        where ar.service_employee_id = p_service_employee_id
          and ar.weekday = v_dow and ar.is_active
          and tstzrange(
            (p_local_date + ar.start_local_time) at time zone v_timezone,
            (p_local_date + ar.end_local_time) at time zone v_timezone,
            '[)'
          ) @> tstzrange(v_anchor_start, v_core_end, '[)')
      )
      or exists (
        select 1 from public.availability_exceptions ae
        where ae.service_employee_id = p_service_employee_id
          and ae.exception_type = 'OPEN'
          and tstzrange(ae.start_at, ae.end_at, '[)') @> tstzrange(v_anchor_start, v_core_end, '[)')
      )
    ) into v_service_window_ok;
    if not v_service_window_ok then continue; end if;

    if exists (
      select 1 from public.availability_exceptions ae
      where ae.service_employee_id = p_service_employee_id
        and ae.exception_type = 'BLOCK'
        and tstzrange(ae.start_at, ae.end_at, '[)') && tstzrange(v_anchor_start, v_core_end, '[)')
    ) then continue; end if;

    v_resource_ok := true;
    for v_resource in
      select * from public.calculate_booking_resource_ranges_for_duration(
        p_service_id, p_extra_selections, v_anchor_start, p_duration_blocks
      )
    loop
      v_resource_local_date := (lower(v_resource.occupied_range) at time zone v_timezone)::date;
      v_resource_dow := extract(dow from v_resource_local_date)::smallint;

      if exists (
        select 1 from public.resource_availability_rules rar
        where rar.resource_id = v_resource.resource_id
          and rar.weekday = v_resource_dow and rar.is_active
      ) then
        if not (
          exists (
            select 1 from public.resource_availability_rules rar
            where rar.resource_id = v_resource.resource_id
              and rar.weekday = v_resource_dow and rar.is_active
              and tstzrange(
                (v_resource_local_date + rar.start_local_time) at time zone v_timezone,
                (v_resource_local_date + rar.end_local_time) at time zone v_timezone,
                '[)'
              ) @> v_resource.occupied_range
          )
          or exists (
            select 1 from public.availability_exceptions ae
            where ae.resource_id = v_resource.resource_id
              and ae.exception_type = 'OPEN'
              and tstzrange(ae.start_at, ae.end_at, '[)') @> v_resource.occupied_range
          )
        ) then
          v_resource_ok := false; exit;
        end if;
      end if;

      if exists (
        select 1 from public.availability_exceptions ae
        where ae.resource_id = v_resource.resource_id
          and ae.exception_type = 'BLOCK'
          and tstzrange(ae.start_at, ae.end_at, '[)') && v_resource.occupied_range
      ) then v_resource_ok := false; exit; end if;

      if exists (
        select 1 from public.resource_allocations ra
        where ra.resource_id = v_resource.resource_id
          and ra.status in ('HELD','AWAITING_PAYMENT','CONFIRMED','BLOCKED','EXTERNAL_ACTIVE')
          and ra.occupied_range && v_resource.occupied_range
          and not (
            ra.status = 'AWAITING_PAYMENT'
            and ra.appointment_id is not null
            and exists (
              select 1
              from public.appointments a
              where a.id = ra.appointment_id
                and a.status = 'AWAITING_PAYMENT'
                and a.hold_expires_at is not null
                and a.hold_expires_at <= v_now
            )
          )
      ) then v_resource_ok := false; exit; end if;
    end loop;

    if not v_resource_ok then continue; end if;

    slot_start_at := v_appointment_start;
    slot_end_at := v_appointment_end;
    core_start_at := v_anchor_start;
    core_end_at := v_core_end;
    pre_service_minutes := v_pre;
    post_service_minutes := v_post;
    duration_minutes := v_contracted_minutes + v_pre + v_post;
    commercial_value := (v_quote->>'commercial_value')::numeric(12,2);
    return next;
  end loop;
end;
$$;

comment on function public.list_available_slots_for_duration(uuid,uuid,integer,jsonb,integer,date,text) is
  'Lists duration slots. Expired AWAITING_PAYMENT appointment allocations are ignored at read time; periodic maintenance performs authoritative expiry cleanup.';
-- END RC MIGRATION 20260824120000_autonomous_appointment_hold_expiry.sql

-- BEGIN RC MIGRATION 20260824143000_booking_policy_publication_guard.sql
-- Phase 3 / finding 4: a service cannot be publicly bookable without an
-- authoritative change/cancellation policy. Existing invalid links are disabled;
-- no historical appointment policy is fabricated by this migration.

create or replace function public.assert_booking_page_service_has_change_policy()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_page_active boolean;
begin
  if not new.is_active then
    return new;
  end if;

  select bp.is_active into v_page_active
  from public.booking_pages bp
  where bp.id = new.booking_page_id;

  if coalesce(v_page_active, false)
     and not exists (
       select 1
       from public.service_change_policies cp
       where cp.service_id = new.service_id
     ) then
    raise exception using
      errcode = 'P0001',
      message = 'SERVICE_CHANGE_POLICY_REQUIRED_FOR_PUBLIC_BOOKING';
  end if;

  return new;
end;
$$;

create or replace function public.assert_booking_page_activation_has_policies()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.is_active and (tg_op = 'INSERT' or old.is_active is distinct from true) then
    if exists (
      select 1
      from public.booking_page_services bps
      left join public.service_change_policies cp on cp.service_id = bps.service_id
      where bps.booking_page_id = new.id
        and bps.is_active
        and cp.service_id is null
    ) then
      raise exception using
        errcode = 'P0001',
        message = 'BOOKING_PAGE_HAS_SERVICE_WITHOUT_CHANGE_POLICY';
    end if;
  end if;

  return new;
end;
$$;

create or replace function public.prevent_public_service_policy_delete()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if exists (
    select 1
    from public.booking_page_services bps
    join public.booking_pages bp on bp.id = bps.booking_page_id
    where bps.service_id = old.service_id
      and bps.is_active
      and bp.is_active
  ) then
    raise exception using
      errcode = 'P0001',
      message = 'PUBLIC_SERVICE_CHANGE_POLICY_CANNOT_BE_REMOVED';
  end if;

  return old;
end;
$$;

-- Repair current staging/seed state conservatively: invalid public links are
-- disabled rather than inventing commercial policy values.
update public.booking_page_services bps
set is_active = false
where bps.is_active
  and exists (
    select 1
    from public.booking_pages bp
    where bp.id = bps.booking_page_id
      and bp.is_active
  )
  and not exists (
    select 1
    from public.service_change_policies cp
    where cp.service_id = bps.service_id
  );

drop trigger if exists booking_page_services_require_change_policy on public.booking_page_services;
create trigger booking_page_services_require_change_policy
before insert or update of booking_page_id, service_id, is_active
on public.booking_page_services
for each row execute function public.assert_booking_page_service_has_change_policy();

drop trigger if exists booking_pages_require_service_policies on public.booking_pages;
create trigger booking_pages_require_service_policies
before insert or update of is_active
on public.booking_pages
for each row execute function public.assert_booking_page_activation_has_policies();

drop trigger if exists service_change_policies_protect_public_service on public.service_change_policies;
create trigger service_change_policies_protect_public_service
before delete on public.service_change_policies
for each row execute function public.prevent_public_service_policy_delete();

revoke all on function public.assert_booking_page_service_has_change_policy() from public, anon, authenticated;
revoke all on function public.assert_booking_page_activation_has_policies() from public, anon, authenticated;
revoke all on function public.prevent_public_service_policy_delete() from public, anon, authenticated;

comment on function public.assert_booking_page_service_has_change_policy() is
  'Fail-closed publication guard: active services on active booking pages require service_change_policies.';
comment on function public.prevent_public_service_policy_delete() is
  'Prevents removal of the authoritative change policy while a service remains publicly bookable.';
-- END RC MIGRATION 20260824143000_booking_policy_publication_guard.sql

-- BEGIN RC MIGRATION 20260824150000_commercial_configuration_authority.sql
-- Phase 3 findings 5 + 8: configuration must govern the engine.
-- New reservations snapshot commercial configuration once. Historical rows are
-- not assigned an unverifiable confirmation percentage by this migration.

alter table public.services
  drop constraint if exists services_confirmation_percentage_check,
  add constraint services_confirmation_percentage_check
    check (confirmation_percentage is null or confirmation_percentage > 0 and confirmation_percentage <= 100);

alter table public.operation_settings
  drop constraint if exists operation_settings_default_confirmation_percentage_check,
  add constraint operation_settings_default_confirmation_percentage_check
    check (default_confirmation_percentage > 0 and default_confirmation_percentage <= 100);

alter table public.appointment_change_settlements
  drop constraint if exists appointment_change_settlements_commitment_check,
  add constraint appointment_change_settlements_commitment_check
    check (payment_commitment_percent >= 0 and payment_commitment_percent <= 100);

alter table public.appointment_change_policy_snapshots
  drop constraint if exists appointment_change_policy_snapsh_max_customer_reschedules_check,
  add constraint appointment_change_policy_snapshots_max_customer_reschedules_check
    check (max_customer_reschedules >= 0);

alter table public.appointments
  add column confirmation_percentage_snapshot numeric(5,2),
  add constraint appointments_confirmation_percentage_snapshot_check
    check (
      confirmation_percentage_snapshot is null
      or confirmation_percentage_snapshot > 0 and confirmation_percentage_snapshot <= 100
    );

comment on column public.appointments.confirmation_percentage_snapshot is
  'Immutable checkout confirmation target captured when the reservation is created. NULL is allowed only for legacy reservations whose historical value cannot be proven.';

-- Preserve any historical value that was explicitly recorded by a payment request.
-- Do not guess for appointments with no such evidence.
with evidenced as (
  select distinct on (pt.appointment_id)
    pt.appointment_id,
    pt.requested_percentage
  from public.payment_transactions pt
  where pt.payment_purpose = 'CONTRACT'
    and pt.transaction_type = 'CHARGE'
    and pt.requested_percentage is not null
    and pt.requested_percentage < 100
  order by pt.appointment_id, pt.created_at, pt.id
)
update public.appointments a
set confirmation_percentage_snapshot = e.requested_percentage
from evidenced e
where a.id = e.appointment_id
  and a.confirmation_percentage_snapshot is null;

create or replace function public.capture_appointment_commercial_configuration()
returns trigger
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_confirmation numeric(5,2);
begin
  if new.confirmation_percentage_snapshot is null then
    select coalesce(s.confirmation_percentage, os.default_confirmation_percentage)
    into v_confirmation
    from public.services s
    cross join public.operation_settings os
    where s.id = new.service_id
      and os.id = 1;

    if v_confirmation is null then
      raise exception using errcode='P0001', message='APPOINTMENT_CONFIRMATION_CONFIGURATION_MISSING';
    end if;

    new.confirmation_percentage_snapshot := v_confirmation;
  end if;

  return new;
end;
$$;

drop trigger if exists appointments_capture_commercial_configuration on public.appointments;
create trigger appointments_capture_commercial_configuration
before insert on public.appointments
for each row execute function public.capture_appointment_commercial_configuration();

create or replace function public.prevent_appointment_confirmation_snapshot_change()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if old.confirmation_percentage_snapshot is not null
     and new.confirmation_percentage_snapshot is distinct from old.confirmation_percentage_snapshot then
    raise exception using errcode='42501', message='APPOINTMENT_CONFIRMATION_SNAPSHOT_IMMUTABLE';
  end if;
  return new;
end;
$$;

drop trigger if exists appointments_protect_confirmation_snapshot on public.appointments;
create trigger appointments_protect_confirmation_snapshot
before update of confirmation_percentage_snapshot on public.appointments
for each row execute function public.prevent_appointment_confirmation_snapshot_change();

create or replace function public.normalize_change_policy_snapshot(p_policy jsonb)
returns jsonb
language sql
immutable
set search_path = public
as $$
  select case
    when p_policy is null then null
    else p_policy || jsonb_build_object(
      'max_customer_reschedules', coalesce((p_policy->>'max_customer_reschedules')::integer, 3),
      'policy_timezone', 'America/Sao_Paulo',
      'notice_boundary_semantics', 'EXACT_LIMIT_IS_OUTSIDE_WINDOW',
      'snapshot_schema_version', case
        when nullif(p_policy->>'reschedule_first_early_percent','') is not null
         and nullif(p_policy->>'reschedule_first_late_percent','') is not null
         and nullif(p_policy->>'reschedule_repeat_percent','') is not null
         and nullif(p_policy->>'cancellation_late_percent','') is not null
        then 'CONSOLIDATED_POLICY_V2'
        else 'CHANGE_POLICY_SNAPSHOT_V1'
      end
    )
  end;
$$;

create or replace function public.capture_current_appointment_change_policy_snapshot()
returns trigger
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_policy public.service_change_policies%rowtype;
  v_effective_at timestamptz;
  v_max_reschedules integer;
  v_policy_json jsonb;
begin
  if new.status not in ('AWAITING_PAYMENT','CONFIRMED') then return new; end if;
  if exists (select 1 from public.appointment_change_policy_snapshots s where s.appointment_id=new.id) then return new; end if;

  select cp.*
  into v_policy
  from public.service_change_policies cp
  where cp.service_id=new.service_id;

  if not found then return new; end if;

  select coalesce(s.max_reschedules, 3)
  into v_max_reschedules
  from public.services s
  where s.id=new.service_id;

  if not found then return new; end if;

  v_effective_at := case when new.status='AWAITING_PAYMENT' then new.created_at else coalesce(new.confirmed_at,new.created_at) end;
  v_policy_json := public.normalize_change_policy_snapshot(
    to_jsonb(v_policy) || jsonb_build_object('max_customer_reschedules',v_max_reschedules)
  );

  insert into public.appointment_change_policy_snapshots(
    appointment_id,service_id,policy_json,effective_at,source,
    max_customer_reschedules,policy_timezone,notice_boundary_semantics
  ) values (
    new.id,new.service_id,v_policy_json,v_effective_at,'BOOKING_CAPTURE',
    v_max_reschedules,'America/Sao_Paulo','EXACT_LIMIT_IS_OUTSIDE_WINDOW'
  );

  perform public.capture_appointment_policy_terms_snapshot(new.id,new.service_id,v_effective_at);
  return new;
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
  if v_confirmation_percentage is null then
    raise exception using errcode='P0001',message='APPOINTMENT_CONFIRMATION_SNAPSHOT_MISSING';
  end if;

  v_summary := public.get_appointment_financial_summary(v_appointment.id);
  v_settled := (v_summary->>'contract_settled')::numeric;
  v_confirmation_target := round(coalesce(v_appointment.commercial_value,0)*v_confirmation_percentage/100,2);
  v_minimum_due := round(greatest(v_confirmation_target-v_settled,0),2);

  return jsonb_build_object(
    'appointment_id',v_appointment.id,'public_code',v_appointment.public_code,
    'appointment_status',v_appointment.status,'financial_status',v_appointment.financial_status,
    'service_name',v_appointment.service_name_snapshot,'hold_expires_at',v_appointment.hold_expires_at,
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

create or replace function public.service_create_payment_intent_by_token(
  p_access_token text,p_payment_kind text,p_method text,p_request_key text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_appointment_id uuid;
  v_appointment public.appointments%rowtype;
  v_percentage numeric(5,2);
  v_idempotency_key text;
begin
  if p_payment_kind not in ('MINIMUM','FULL') then raise exception using errcode='P0001',message='INVALID_PAYMENT_KIND'; end if;
  if p_method not in ('PIX','CARD') then raise exception using errcode='P0001',message='PUBLIC_PAYMENT_METHOD_NOT_ALLOWED'; end if;
  if p_request_key is null or p_request_key !~ '^[A-Za-z0-9_-]{12,100}$' then raise exception using errcode='P0001',message='PAYMENT_REQUEST_KEY_INVALID'; end if;

  v_appointment_id := public.resolve_appointment_access_token(p_access_token,'PAY');
  select * into v_appointment from public.appointments where id=v_appointment_id;

  if p_payment_kind='FULL' then v_percentage:=100;
  else
    v_percentage:=v_appointment.confirmation_percentage_snapshot;
    if v_percentage is null then raise exception using errcode='P0001',message='APPOINTMENT_CONFIRMATION_SNAPSHOT_MISSING'; end if;
  end if;

  v_idempotency_key := 'public:'||v_appointment_id::text||':'||p_request_key;
  return public.create_payment_intent(v_appointment_id,v_percentage,p_method,v_idempotency_key);
end;
$$;

create or replace function public.create_payment_intent(
  p_appointment_id uuid,p_payment_percentage numeric,p_method text,p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_appointment public.appointments%rowtype;
  v_existing public.payment_transactions%rowtype;
  v_summary jsonb;
  v_balance numeric(12,2); v_settled_before numeric(12,2);
  v_confirmation_percentage numeric(5,2); v_confirmation_target numeric(12,2);
  v_contract_amount numeric(12,2); v_discount_percent numeric(5,2);
  v_discount numeric(12,2); v_cash_amount numeric(12,2); v_amounts jsonb;
  v_transaction_id uuid; v_payment_kind text;
begin
  if p_method not in ('PIX','CARD') then raise exception using errcode='P0001',message='PUBLIC_PAYMENT_METHOD_NOT_ALLOWED'; end if;
  if p_idempotency_key is null or btrim(p_idempotency_key)='' then raise exception using errcode='P0001',message='IDEMPOTENCY_KEY_REQUIRED'; end if;

  select * into v_existing from public.payment_transactions where idempotency_key=p_idempotency_key;
  if found then
    if v_existing.appointment_id<>p_appointment_id or v_existing.method<>p_method or v_existing.requested_percentage is distinct from p_payment_percentage then
      raise exception using errcode='P0001',message='IDEMPOTENCY_KEY_CONFLICT';
    end if;
    return jsonb_build_object('transaction_id',v_existing.id,'appointment_id',v_existing.appointment_id,'status',v_existing.status,
      'payment_percentage',v_existing.requested_percentage,'contract_amount_settled',v_existing.contract_amount_settled,
      'payment_discount_amount',v_existing.payment_discount_amount,'cash_amount',v_existing.cash_amount,'method',v_existing.method,'idempotent_replay',true);
  end if;

  perform public.expire_due_appointment_holds();
  select * into v_appointment from public.appointments where id=p_appointment_id for update;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if;
  if v_appointment.status not in ('AWAITING_PAYMENT','CONFIRMED') then raise exception using errcode='P0001',message='APPOINTMENT_NOT_PAYABLE'; end if;
  if v_appointment.status='AWAITING_PAYMENT' and (v_appointment.hold_expires_at is null or v_appointment.hold_expires_at<=now()) then
    raise exception using errcode='P0001',message='PAYMENT_HOLD_EXPIRED';
  end if;

  v_confirmation_percentage:=v_appointment.confirmation_percentage_snapshot;
  if v_confirmation_percentage is null then raise exception using errcode='P0001',message='APPOINTMENT_CONFIRMATION_SNAPSHOT_MISSING'; end if;
  if p_payment_percentage<>100 and p_payment_percentage<>v_confirmation_percentage then
    raise exception using errcode='P0001',message='INVALID_PAYMENT_PERCENTAGE';
  end if;

  select os.pix_discount_percent into v_discount_percent from public.operation_settings os where os.id=1;
  v_summary:=public.get_appointment_financial_summary(p_appointment_id);
  v_balance:=(v_summary->>'contract_balance')::numeric;
  v_settled_before:=(v_summary->>'contract_settled')::numeric;
  if v_balance<=0 then raise exception using errcode='P0001',message='APPOINTMENT_ALREADY_PAID'; end if;

  v_confirmation_target:=round(coalesce(v_appointment.commercial_value,0)*v_confirmation_percentage/100,2);
  if p_payment_percentage=100 then
    v_payment_kind:='FULL_BALANCE'; v_contract_amount:=v_balance;
  else
    v_payment_kind:='CONFIRMATION_MINIMUM';
    v_contract_amount:=round(greatest(v_confirmation_target-v_settled_before,0),2);
    if v_contract_amount<=0 then raise exception using errcode='P0001',message='CONFIRMATION_PAYMENT_ALREADY_SATISFIED'; end if;
    v_contract_amount:=least(v_contract_amount,v_balance);
  end if;

  v_amounts:=public.service_calculate_payment_cash_amount(v_contract_amount,p_method,v_discount_percent);
  v_discount:=(v_amounts->>'payment_discount_amount')::numeric;
  v_cash_amount:=(v_amounts->>'cash_amount')::numeric;

  insert into public.payment_transactions(
    appointment_id,transaction_type,method,provider,status,contract_amount_settled,
    payment_discount_amount,cash_amount,idempotency_key,requested_percentage
  ) values (
    p_appointment_id,'CHARGE',p_method,'MERCADO_PAGO','PENDING',v_contract_amount,
    v_discount,v_cash_amount,p_idempotency_key,p_payment_percentage
  ) returning id into v_transaction_id;

  if v_appointment.financial_status not in ('PARTIALLY_PAID','PAID','UNPAID_AUTHORIZED') then
    update public.appointments set financial_status='PENDING',updated_at=now() where id=p_appointment_id;
  end if;

  return jsonb_build_object('transaction_id',v_transaction_id,'appointment_id',p_appointment_id,'status','PENDING',
    'payment_kind',v_payment_kind,'payment_percentage',p_payment_percentage,'confirmation_percentage',v_confirmation_percentage,
    'confirmation_target_amount',v_confirmation_target,'contract_settled_before',v_settled_before,'contract_balance_before',v_balance,
    'contract_amount_settled',v_contract_amount,'payment_discount_amount',v_discount,'cash_amount',v_cash_amount,
    'method',p_method,'provider','MERCADO_PAGO','idempotent_replay',false);
end;
$$;

create or replace function public.calculate_reservation_change(
  p_appointment_id uuid,p_action_type text,p_requested_at timestamptz,p_change_origin text,p_new_contract_value numeric
)
returns jsonb
language plpgsql
stable
set search_path=public
as $$
declare
  v_appointment public.appointments%rowtype;
  v_snapshot public.appointment_change_policy_snapshots%rowtype;
  v_policy jsonb; v_schema text; v_notice integer; v_seconds numeric; v_hours numeric(12,2); v_inside boolean;
  v_count integer; v_contract numeric(12,2); v_funds numeric(12,2); v_applied numeric(12,2); v_excess_before numeric(12,2);
  v_contract_coverage numeric(12,2); v_contract_coverage_after numeric(12,2); v_commitment numeric(5,2); v_target numeric(12,2);
  v_percent numeric(5,2):=0; v_theoretical numeric(12,2):=0; v_retained numeric(12,2):=0;
  v_after numeric(12,2):=0; v_applicable numeric(12,2):=0; v_excess_after numeric(12,2):=0;
  v_difference numeric(12,2):=0; v_refund numeric(12,2):=0;
  v_legacy_type public.change_penalty_type; v_legacy_value numeric(12,2):=0;
begin
  if p_action_type not in ('RESCHEDULE','CANCEL') then raise exception using errcode='P0001',message='INVALID_CHANGE_ACTION'; end if;
  if p_requested_at is null then raise exception using errcode='P0001',message='CHANGE_REQUESTED_AT_REQUIRED'; end if;
  if p_change_origin not in ('CLIENT','OPERATION') then raise exception using errcode='P0001',message='CHANGE_ORIGIN_REQUIRED'; end if;
  if p_action_type='RESCHEDULE' and p_new_contract_value is null then raise exception using errcode='P0001',message='NEW_CONTRACT_VALUE_REQUIRED'; end if;
  if p_new_contract_value is not null and p_new_contract_value<0 then raise exception using errcode='P0001',message='NEW_CONTRACT_VALUE_INVALID'; end if;

  select * into v_appointment from public.appointments where id=p_appointment_id and deleted_at is null;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if;
  select * into v_snapshot from public.appointment_change_policy_snapshots where appointment_id=p_appointment_id;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_CHANGE_POLICY_SNAPSHOT_MISSING'; end if;

  v_policy:=v_snapshot.policy_json; v_schema:=coalesce(v_policy->>'snapshot_schema_version','CHANGE_POLICY_SNAPSHOT_V1');
  v_notice:=(v_policy->>'notice_hours')::integer;
  if v_notice is null then raise exception using errcode='P0001',message='APPOINTMENT_CHANGE_POLICY_SNAPSHOT_INVALID'; end if;

  v_seconds:=extract(epoch from (v_appointment.start_at-p_requested_at)); v_hours:=round(v_seconds/3600.0,2);
  v_inside:=v_seconds<(v_notice::numeric*3600); v_count:=public.appointment_client_reschedule_count(p_appointment_id);
  v_contract:=round(coalesce(v_appointment.commercial_value,0),2);
  v_funds:=round(public.appointment_customer_funds_amount(p_appointment_id),2);
  v_applied:=round(least(v_funds,v_contract),2); v_excess_before:=round(greatest(v_funds-v_contract,0),2);
  v_contract_coverage:=round(public.appointment_contract_coverage_amount(p_appointment_id),2);

  if v_appointment.billing_mode_snapshot='INVOICE' or v_appointment.financial_status='UNPAID_AUTHORIZED' then v_commitment:=0;
  elsif v_contract<=0 or v_contract_coverage>=v_contract then v_commitment:=100;
  else
    v_commitment:=v_appointment.confirmation_percentage_snapshot;
    if v_commitment is null then raise exception using errcode='P0001',message='APPOINTMENT_CONFIRMATION_SNAPSHOT_MISSING'; end if;
  end if;

  if p_change_origin='OPERATION' then v_percent:=0;
  elsif v_schema='CONSOLIDATED_POLICY_V2' then
    if p_action_type='RESCHEDULE' then
      if v_count>0 then v_percent:=(v_policy->>'reschedule_repeat_percent')::numeric;
      elsif v_inside then v_percent:=(v_policy->>'reschedule_first_late_percent')::numeric;
      else v_percent:=(v_policy->>'reschedule_first_early_percent')::numeric; end if;
    else v_percent:=case when v_inside then (v_policy->>'cancellation_late_percent')::numeric else 0 end; end if;
  else
    if p_action_type='RESCHEDULE' then
      if v_count>0 then v_legacy_type:=(v_policy->>'reschedule_repeat_penalty_type')::public.change_penalty_type; v_legacy_value:=(v_policy->>'reschedule_repeat_penalty_value')::numeric;
      elsif v_inside then v_legacy_type:=(v_policy->>'reschedule_late_penalty_type')::public.change_penalty_type; v_legacy_value:=(v_policy->>'reschedule_late_penalty_value')::numeric;
      else v_legacy_type:=(v_policy->>'reschedule_first_penalty_type')::public.change_penalty_type; v_legacy_value:=(v_policy->>'reschedule_first_penalty_value')::numeric; end if;
    else
      if v_inside then v_legacy_type:=(v_policy->>'cancellation_late_penalty_type')::public.change_penalty_type; v_legacy_value:=(v_policy->>'cancellation_late_penalty_value')::numeric;
      else v_legacy_type:=(v_policy->>'cancellation_early_penalty_type')::public.change_penalty_type; v_legacy_value:=(v_policy->>'cancellation_early_penalty_value')::numeric; end if;
    end if;
    if v_legacy_type='PERCENT' then v_percent:=v_legacy_value; elsif v_legacy_type='NONE' then v_percent:=0; else v_percent:=0; v_theoretical:=round(v_legacy_value,2); end if;
  end if;

  if v_theoretical=0 then v_theoretical:=round(v_contract*v_percent/100,2); end if;
  v_retained:=case when p_change_origin='OPERATION' then 0 else round(least(v_theoretical,v_applied),2) end;
  v_after:=round(greatest(v_funds-v_retained,0),2); v_contract_coverage_after:=round(greatest(v_contract_coverage-v_retained,0),2);
  if p_action_type='RESCHEDULE' then
    v_target:=round(p_new_contract_value*v_commitment/100,2); v_applicable:=round(least(v_after,p_new_contract_value),2);
    v_excess_after:=round(greatest(v_after-p_new_contract_value,0),2); v_difference:=round(greatest(v_target-v_contract_coverage_after,0),2);
  else
    v_target:=0; v_applicable:=round(greatest(v_applied-v_retained,0),2); v_excess_after:=v_excess_before; v_refund:=round(v_applicable+v_excess_before,2);
  end if;

  return jsonb_build_object(
    'appointment_id',p_appointment_id,'service_id',v_appointment.service_id,'action_type',p_action_type,'change_origin',p_change_origin,
    'requested_at',p_requested_at,'original_start_at',v_appointment.start_at,'hours_before_start',v_hours,'notice_hours',v_notice,
    'inside_notice_window',v_inside,'prior_customer_reschedules',v_count,'max_customer_reschedules',v_snapshot.max_customer_reschedules,
    'contract_value',v_contract,'new_contract_value',p_new_contract_value,'customer_funds_before',v_funds,
    'contract_applied_before',v_applied,'excess_before',v_excess_before,'contract_coverage_before',v_contract_coverage,
    'payment_commitment_percent',v_commitment,'confirmation_target_amount',v_target,
    'penalty_percent',v_percent,'theoretical_penalty',v_theoretical,'penalty_retained',v_retained,'penalty_amount',v_retained,
    'customer_funds_after_penalty',v_after,'contract_coverage_after_penalty',v_contract_coverage_after,
    'applicable_amount',v_applicable,'excess_amount',v_excess_after,'difference_due',v_difference,
    'refund_due',v_refund,'refundable_amount',v_refund,
    'customer_reschedule_limit_reached',(p_action_type='RESCHEDULE' and p_change_origin='CLIENT' and v_count>=v_snapshot.max_customer_reschedules),
    'snapshot_schema_version',v_schema
  );
end;
$$;

revoke all on function public.capture_appointment_commercial_configuration() from public,anon,authenticated,service_role;
revoke all on function public.prevent_appointment_confirmation_snapshot_change() from public,anon,authenticated;
-- END RC MIGRATION 20260824150000_commercial_configuration_authority.sql

-- BEGIN RC MIGRATION 20260824150100_fix_policy_snapshot_capture.sql
-- Keep the policy row and service-level reschedule configuration as separate
-- lookups so the typed row target remains valid in PL/pgSQL.
create or replace function public.capture_current_appointment_change_policy_snapshot()
returns trigger
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_policy public.service_change_policies%rowtype;
  v_effective_at timestamptz;
  v_max_reschedules integer;
  v_policy_json jsonb;
begin
  if new.status not in ('AWAITING_PAYMENT','CONFIRMED') then return new; end if;
  if exists (
    select 1 from public.appointment_change_policy_snapshots s
    where s.appointment_id=new.id
  ) then return new; end if;

  select * into v_policy
  from public.service_change_policies
  where service_id=new.service_id;
  if not found then return new; end if;

  select coalesce(s.max_reschedules,3)
  into v_max_reschedules
  from public.services s
  where s.id=new.service_id;

  if v_max_reschedules is null then
    raise exception using errcode='P0001',message='SERVICE_RESCHEDULE_CONFIGURATION_MISSING';
  end if;

  v_effective_at := case
    when new.status='AWAITING_PAYMENT' then new.created_at
    else coalesce(new.confirmed_at,new.created_at)
  end;

  v_policy_json := public.normalize_change_policy_snapshot(
    to_jsonb(v_policy) || jsonb_build_object('max_customer_reschedules',v_max_reschedules)
  );

  insert into public.appointment_change_policy_snapshots(
    appointment_id,service_id,policy_json,effective_at,source,
    max_customer_reschedules,policy_timezone,notice_boundary_semantics
  ) values (
    new.id,new.service_id,v_policy_json,v_effective_at,'BOOKING_CAPTURE',
    v_max_reschedules,'America/Sao_Paulo','EXACT_LIMIT_IS_OUTSIDE_WINDOW'
  );

  perform public.capture_appointment_policy_terms_snapshot(new.id,new.service_id,v_effective_at);
  return new;
end;
$$;
-- END RC MIGRATION 20260824150100_fix_policy_snapshot_capture.sql

-- BEGIN RC MIGRATION 20260824162000_contracted_minutes_transport.sql
-- Commercial duration boundary: blocks are selection/pricing internals only.
-- Legacy duration_blocks transport is accepted temporarily by booking-hold until 2026-09-07.

create table if not exists public.booking_contract_legacy_usage (
  id bigint generated always as identity primary key,
  occurred_at timestamptz not null default now(),
  surface text not null,
  booking_page_slug text,
  service_id uuid,
  duration_blocks integer,
  user_agent text,
  constraint booking_contract_legacy_usage_surface_check check (surface in ('BOOKING_HOLD'))
);

revoke all on table public.booking_contract_legacy_usage from public, anon, authenticated;
grant insert, select on table public.booking_contract_legacy_usage to service_role;
grant usage, select on sequence public.booking_contract_legacy_usage_id_seq to service_role;

create or replace function public.resolve_service_duration_blocks_from_minutes(
  p_service_id uuid,
  p_contracted_minutes integer
)
returns integer
language plpgsql
stable
set search_path = public
as $$
declare
  v_service public.services%rowtype;
  v_blocks integer;
begin
  if p_contracted_minutes is null or p_contracted_minutes <= 0 then
    raise exception using errcode='P0001', message='INVALID_CONTRACTED_MINUTES';
  end if;

  select * into v_service from public.services where id=p_service_id and is_active;
  if not found then raise exception using errcode='P0001', message='SERVICE_NOT_AVAILABLE'; end if;

  if v_service.duration_mode='FIXED' then
    if p_contracted_minutes <> v_service.base_duration_minutes then
      raise exception using errcode='P0001', message='INVALID_CONTRACTED_MINUTES';
    end if;
    return null;
  end if;

  if v_service.booking_block_minutes is null or v_service.booking_block_minutes <= 0 then
    raise exception using errcode='P0001', message='SERVICE_DURATION_CONFIGURATION_INVALID';
  end if;
  if p_contracted_minutes % v_service.booking_block_minutes <> 0 then
    raise exception using errcode='P0001', message='INVALID_CONTRACTED_MINUTES';
  end if;

  v_blocks := p_contracted_minutes / v_service.booking_block_minutes;
  if v_blocks < coalesce(v_service.minimum_booking_blocks,1)
     or (v_service.maximum_booking_blocks is not null and v_blocks > v_service.maximum_booking_blocks) then
    raise exception using errcode='P0001', message='INVALID_CONTRACTED_MINUTES';
  end if;
  return v_blocks;
end;
$$;

create or replace function public.public_quote_booking_minutes(
  p_booking_page_slug text,
  p_service_id uuid,
  p_service_employee_id uuid,
  p_contracted_minutes integer,
  p_extra_selections jsonb default '[]'::jsonb,
  p_people_count integer default 1
)
returns jsonb
language plpgsql
stable
security definer
set search_path=public
as $$
declare v_blocks integer;
begin
  v_blocks := public.resolve_service_duration_blocks_from_minutes(p_service_id,p_contracted_minutes);
  perform public.assert_public_booking_duration(
    p_booking_page_slug,p_service_id,p_service_employee_id,v_blocks,p_extra_selections,p_people_count
  );
  return (public.calculate_booking_quote_for_duration(
    p_service_id,p_service_employee_id,v_blocks,p_extra_selections,p_people_count,null,null
  ) - 'duration_blocks') || jsonb_build_object('contracted_minutes',p_contracted_minutes);
end;
$$;

create or replace function public.public_list_available_slots_minutes(
  p_booking_page_slug text,
  p_service_id uuid,
  p_service_employee_id uuid,
  p_contracted_minutes integer,
  p_extra_selections jsonb default '[]'::jsonb,
  p_people_count integer default 1,
  p_local_date date default current_date
)
returns table(
  slot_start_at timestamptz, slot_end_at timestamptz, core_start_at timestamptz, core_end_at timestamptz,
  pre_service_minutes integer, post_service_minutes integer, duration_minutes integer, commercial_value numeric
)
language plpgsql
stable
security definer
set search_path=public
as $$
declare v_blocks integer;
begin
  v_blocks := public.resolve_service_duration_blocks_from_minutes(p_service_id,p_contracted_minutes);
  perform public.assert_public_booking_duration(
    p_booking_page_slug,p_service_id,p_service_employee_id,v_blocks,p_extra_selections,p_people_count
  );
  return query select * from public.list_available_slots_for_duration(
    p_service_id,p_service_employee_id,v_blocks,p_extra_selections,p_people_count,p_local_date,null
  );
end;
$$;

create or replace function public.public_create_checkout_hold_tracked_minutes(
  p_booking_page_slug text,
  p_service_id uuid,
  p_service_employee_id uuid,
  p_contracted_minutes integer,
  p_extra_selections jsonb,
  p_people_count integer,
  p_requested_start_at timestamptz,
  p_attribution_json jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_blocks integer;
  v_result jsonb;
  v_hold_id uuid;
begin
  if p_attribution_json is not null and jsonb_typeof(p_attribution_json)<>'object' then
    raise exception using errcode='P0001',message='ATTRIBUTION_INVALID';
  end if;
  v_blocks := public.resolve_service_duration_blocks_from_minutes(p_service_id,p_contracted_minutes);
  v_result := public.public_create_checkout_hold_duration(
    p_booking_page_slug,p_service_id,p_service_employee_id,v_blocks,p_extra_selections,p_people_count,p_requested_start_at
  );
  v_hold_id := (v_result->>'checkout_hold_id')::uuid;
  update public.checkout_holds
  set attribution_json=public.sanitize_public_attribution(coalesce(p_attribution_json,'{}'::jsonb)), updated_at=now()
  where id=v_hold_id;
  return (v_result - 'duration_blocks') || jsonb_build_object('contracted_minutes',p_contracted_minutes);
end;
$$;

revoke all on function public.resolve_service_duration_blocks_from_minutes(uuid,integer) from public,anon,authenticated;
revoke all on function public.public_quote_booking_minutes(text,uuid,uuid,integer,jsonb,integer) from public;
revoke all on function public.public_list_available_slots_minutes(text,uuid,uuid,integer,jsonb,integer,date) from public;
revoke all on function public.public_create_checkout_hold_tracked_minutes(text,uuid,uuid,integer,jsonb,integer,timestamptz,jsonb) from public,anon,authenticated;
grant execute on function public.public_quote_booking_minutes(text,uuid,uuid,integer,jsonb,integer) to anon,authenticated;
grant execute on function public.public_list_available_slots_minutes(text,uuid,uuid,integer,jsonb,integer,date) to anon,authenticated;
grant execute on function public.public_create_checkout_hold_tracked_minutes(text,uuid,uuid,integer,jsonb,integer,timestamptz,jsonb) to service_role;
-- END RC MIGRATION 20260824162000_contracted_minutes_transport.sql

-- BEGIN RC MIGRATION 20260824163000_commercial_description.sql
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
-- END RC MIGRATION 20260824163000_commercial_description.sql

-- BEGIN RC MIGRATION 20260824170000_rental_balance_collection.sql
create table if not exists public.appointment_balance_collections (
  id uuid primary key default gen_random_uuid(),
  appointment_id uuid not null references public.appointments(id) on delete cascade,
  sequence integer not null,
  source text not null check (source in ('AUTO_START','ADMIN_REISSUE')),
  status text not null default 'ACTIVE' check (status in ('ACTIVE','PAID','EXPIRED','REVOKED')),
  amount_snapshot numeric(12,2) not null check (amount_snapshot > 0),
  issued_at timestamptz not null default now(),
  expires_at timestamptz not null,
  created_by_admin_id uuid references public.admin_users(id),
  email_delivered_at timestamptz,
  kommo_delivered_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (appointment_id, sequence),
  check (expires_at > issued_at),
  check ((source='ADMIN_REISSUE') = (created_by_admin_id is not null))
);

create index if not exists appointment_balance_collections_active_idx
  on public.appointment_balance_collections(appointment_id,status,expires_at);

alter table public.appointment_access_tokens
  add column if not exists balance_collection_id uuid references public.appointment_balance_collections(id) on delete set null;

create index if not exists appointment_access_tokens_balance_collection_idx
  on public.appointment_access_tokens(balance_collection_id)
  where balance_collection_id is not null;

alter table public.appointment_balance_collections enable row level security;
revoke all on public.appointment_balance_collections from public,anon,authenticated;
grant select,insert,update on public.appointment_balance_collections to service_role;

create or replace function public.balance_collection_clock()
returns timestamptz
language sql
stable
set search_path=public
as $$
  select coalesce(nullif(current_setting('agenda.test_now',true),'')::timestamptz,now())
$$;

create or replace function public.expire_due_balance_collections()
returns integer
language plpgsql
volatile
security definer
set search_path=public
as $$
declare v_now timestamptz:=public.balance_collection_clock(); v_count integer:=0;
begin
  update public.appointment_balance_collections
  set status='EXPIRED',updated_at=v_now
  where status='ACTIVE' and expires_at<=v_now;
  get diagnostics v_count=row_count;

  update public.appointment_access_tokens t
  set revoked_at=coalesce(t.revoked_at,v_now)
  from public.appointment_balance_collections c
  where t.balance_collection_id=c.id and c.status='EXPIRED' and t.revoked_at is null;
  return v_count;
end;
$$;

create or replace function public.create_balance_collection(
  p_appointment_id uuid,
  p_source text,
  p_admin_id uuid default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path=public
as $$
declare
  v_now timestamptz:=public.balance_collection_clock();
  v_appointment public.appointments%rowtype;
  v_scope text;
  v_balance numeric(12,2);
  v_sequence integer;
  v_collection public.appointment_balance_collections%rowtype;
begin
  if p_source not in ('AUTO_START','ADMIN_REISSUE') then
    raise exception using errcode='22023',message='BALANCE_COLLECTION_SOURCE_INVALID';
  end if;

  select * into v_appointment from public.appointments where id=p_appointment_id for update;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if;
  select operation_scope into v_scope from public.services where id=v_appointment.service_id;
  if v_scope<>'BLACKSHEEP' then raise exception using errcode='P0001',message='BALANCE_COLLECTION_SCOPE_DENIED'; end if;
  if v_appointment.status not in ('CONFIRMED','COMPLETED') then
    raise exception using errcode='P0001',message='BALANCE_COLLECTION_APPOINTMENT_NOT_ELIGIBLE';
  end if;
  if p_source='AUTO_START' and v_appointment.start_at>v_now then
    raise exception using errcode='P0001',message='BALANCE_COLLECTION_NOT_DUE';
  end if;

  if p_source='ADMIN_REISSUE' then
    if p_admin_id is null or not public.service_admin_has_permission(p_admin_id,'FINANCE_MANAGE') then
      raise exception using errcode='42501',message='ADMIN_PERMISSION_DENIED';
    end if;
  elsif p_admin_id is not null then
    raise exception using errcode='22023',message='BALANCE_COLLECTION_ADMIN_INVALID';
  end if;

  v_balance:=round(greatest(coalesce((public.get_appointment_financial_summary(p_appointment_id)->>'contract_balance')::numeric,0),0),2);
  if v_balance<=0 then raise exception using errcode='P0001',message='BALANCE_COLLECTION_NOT_DUE'; end if;

  if p_source='AUTO_START' and exists(select 1 from public.appointment_balance_collections where appointment_id=p_appointment_id) then
    raise exception using errcode='P0001',message='BALANCE_COLLECTION_ALREADY_CREATED';
  end if;

  if p_source='ADMIN_REISSUE' then
    update public.appointment_balance_collections set status='REVOKED',updated_at=v_now
    where appointment_id=p_appointment_id and status='ACTIVE';
    update public.appointment_access_tokens set revoked_at=coalesce(revoked_at,v_now)
    where appointment_id=p_appointment_id and balance_collection_id is not null and revoked_at is null;
  end if;

  select coalesce(max(sequence),0)+1 into v_sequence
  from public.appointment_balance_collections where appointment_id=p_appointment_id;

  insert into public.appointment_balance_collections(
    appointment_id,sequence,source,status,amount_snapshot,issued_at,expires_at,created_by_admin_id
  ) values(
    p_appointment_id,v_sequence,p_source,'ACTIVE',v_balance,v_now,v_now+interval '48 hours',p_admin_id
  ) returning * into v_collection;

  insert into public.integration_jobs(job_type,entity_type,entity_id,entity_version,payload_json,idempotency_key)
  values(
    'RENTAL_BALANCE_DUE_MESSAGE','BALANCE_COLLECTION',v_collection.id,v_sequence,
    jsonb_build_object('appointment_id',p_appointment_id,'source',p_source),
    'rental-balance-due-message:'||v_collection.id::text
  ) on conflict(idempotency_key) do nothing;

  insert into public.audit_logs(entity_type,entity_id,action,before_json,after_json,origin,admin_user_id)
  values(
    'APPOINTMENT',p_appointment_id,
    case when p_source='AUTO_START' then 'BALANCE_COLLECTION_AUTO_CREATED' else 'BALANCE_COLLECTION_REISSUED' end,
    null,
    jsonb_build_object('collection_id',v_collection.id,'sequence',v_sequence,'amount',v_balance,'expires_at',v_collection.expires_at),
    case when p_source='AUTO_START' then 'SYSTEM' else 'OPERATION' end,
    p_admin_id
  );

  return jsonb_build_object(
    'collection_id',v_collection.id,'appointment_id',p_appointment_id,'sequence',v_sequence,
    'status','ACTIVE','amount',v_balance,'issued_at',v_collection.issued_at,'expires_at',v_collection.expires_at
  );
end;
$$;

create or replace function public.enqueue_due_rental_balance_collections()
returns integer
language plpgsql
volatile
security definer
set search_path=public
as $$
declare v_now timestamptz:=public.balance_collection_clock(); v_row record; v_count integer:=0;
begin
  perform public.expire_due_balance_collections();
  for v_row in
    select a.id
    from public.appointments a
    join public.services s on s.id=a.service_id
    cross join lateral (select public.get_appointment_financial_summary(a.id) as summary) fin
    where s.operation_scope='BLACKSHEEP'
      and a.status='CONFIRMED'
      and a.start_at<=v_now
      and a.start_at>v_now-interval '24 hours'
      and coalesce((fin.summary->>'contract_balance')::numeric,0)>0.005
      and not exists(select 1 from public.appointment_balance_collections c where c.appointment_id=a.id)
    order by a.start_at,a.id
    for update of a skip locked
  loop
    begin
      perform public.create_balance_collection(v_row.id,'AUTO_START',null);
      v_count:=v_count+1;
    exception when others then
      if sqlerrm not in ('BALANCE_COLLECTION_ALREADY_CREATED','BALANCE_COLLECTION_NOT_DUE') then raise; end if;
    end;
  end loop;
  return v_count;
end;
$$;

create or replace function public.service_admin_reissue_balance_collection(p_appointment_id uuid,p_admin_id uuid)
returns jsonb
language sql
volatile
security definer
set search_path=public
as $$ select public.create_balance_collection(p_appointment_id,'ADMIN_REISSUE',p_admin_id) $$;

create or replace function public.service_verify_balance_collection_email(p_collection_id uuid,p_email text)
returns jsonb
language plpgsql
volatile
security definer
set search_path=public,extensions
as $$
declare
  v_now timestamptz:=public.balance_collection_clock();
  v_collection public.appointment_balance_collections%rowtype;
  v_customer_email text;
  v_raw_token text;
  v_hash text;
  v_token_id uuid;
  v_balance numeric(12,2);
begin
  perform public.expire_due_balance_collections();
  select * into v_collection from public.appointment_balance_collections where id=p_collection_id for update;
  if not found or v_collection.status<>'ACTIVE' or v_collection.expires_at<=v_now then
    raise exception using errcode='P0001',message='BALANCE_COLLECTION_INVALID_OR_EXPIRED';
  end if;

  select lower(trim(c.email)) into v_customer_email
  from public.appointments a join public.customers c on c.id=a.primary_customer_id
  where a.id=v_collection.appointment_id;
  if v_customer_email is null or lower(trim(coalesce(p_email,'')))<>v_customer_email then
    raise exception using errcode='P0001',message='BALANCE_COLLECTION_VERIFICATION_FAILED';
  end if;

  v_balance:=round(greatest(coalesce((public.get_appointment_financial_summary(v_collection.appointment_id)->>'contract_balance')::numeric,0),0),2);
  if v_balance<=0.005 then
    update public.appointment_balance_collections set status='PAID',updated_at=v_now where id=v_collection.id;
    raise exception using errcode='P0001',message='BALANCE_COLLECTION_ALREADY_PAID';
  end if;

  v_raw_token:=encode(gen_random_bytes(32),'hex');
  v_hash:=encode(digest(v_raw_token,'sha256'),'hex');
  insert into public.appointment_access_tokens(
    appointment_id,token_hash,scope,expires_at,delivery_channel,destination_masked,balance_collection_id
  ) values(
    v_collection.appointment_id,v_hash,'PAY',v_collection.expires_at,'INTERNAL','verified-email',v_collection.id
  ) returning id into v_token_id;

  return jsonb_build_object(
    'access_token',v_raw_token,'token_id',v_token_id,'appointment_id',v_collection.appointment_id,
    'collection_id',v_collection.id,'expires_at',v_collection.expires_at,'amount',v_balance
  );
end;
$$;

create or replace view public.appointment_open_balances as
select
  a.id appointment_id,a.public_code,a.primary_customer_id customer_id,c.name customer_name,
  a.service_id,a.service_name_snapshot service_name,s.operation_scope,
  a.status appointment_status,a.financial_status,a.start_at,a.commercial_value total_value,
  coalesce((fin.summary->>'contract_settled')::numeric,0)::numeric(12,2) paid_value,
  coalesce((fin.summary->>'contract_balance')::numeric,0)::numeric(12,2) balance_value,
  bc.id active_collection_id,bc.sequence collection_sequence,bc.expires_at collection_expires_at
from public.appointments a
join public.services s on s.id=a.service_id
left join public.customers c on c.id=a.primary_customer_id
cross join lateral (select public.get_appointment_financial_summary(a.id) as summary) fin
left join lateral(
  select x.id,x.sequence,x.expires_at from public.appointment_balance_collections x
  where x.appointment_id=a.id and x.status='ACTIVE' and x.expires_at>public.balance_collection_clock()
  order by x.sequence desc limit 1
) bc on true
where a.status in ('CONFIRMED','COMPLETED')
  and coalesce((fin.summary->>'contract_balance')::numeric,0)>0.005;

revoke all on public.appointment_open_balances from public,anon,authenticated;
grant select on public.appointment_open_balances to service_role;

revoke all on function public.balance_collection_clock() from public,anon,authenticated;
revoke all on function public.expire_due_balance_collections() from public,anon,authenticated;
revoke all on function public.create_balance_collection(uuid,text,uuid) from public,anon,authenticated;
revoke all on function public.enqueue_due_rental_balance_collections() from public,anon,authenticated;
revoke all on function public.service_admin_reissue_balance_collection(uuid,uuid) from public,anon,authenticated;
revoke all on function public.service_verify_balance_collection_email(uuid,text) from public,anon,authenticated;

grant execute on function public.expire_due_balance_collections() to service_role;
grant execute on function public.enqueue_due_rental_balance_collections() to service_role;
grant execute on function public.service_admin_reissue_balance_collection(uuid,uuid) to service_role;
grant execute on function public.service_verify_balance_collection_email(uuid,text) to service_role;
-- END RC MIGRATION 20260824170000_rental_balance_collection.sql

-- BEGIN RC MIGRATION 20260824170100_balance_collection_delivery_channels.sql
create or replace function public.create_balance_collection(
  p_appointment_id uuid,
  p_source text,
  p_admin_id uuid default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path=public
as $$
declare
  v_now timestamptz:=public.balance_collection_clock();
  v_appointment public.appointments%rowtype;
  v_scope text;
  v_balance numeric(12,2);
  v_sequence integer;
  v_collection public.appointment_balance_collections%rowtype;
begin
  if p_source not in ('AUTO_START','ADMIN_REISSUE') then raise exception using errcode='22023',message='BALANCE_COLLECTION_SOURCE_INVALID'; end if;
  select * into v_appointment from public.appointments where id=p_appointment_id for update;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if;
  select operation_scope into v_scope from public.services where id=v_appointment.service_id;
  if v_scope<>'BLACKSHEEP' then raise exception using errcode='P0001',message='BALANCE_COLLECTION_SCOPE_DENIED'; end if;
  if v_appointment.status not in ('CONFIRMED','COMPLETED') then raise exception using errcode='P0001',message='BALANCE_COLLECTION_APPOINTMENT_NOT_ELIGIBLE'; end if;
  if p_source='AUTO_START' and v_appointment.start_at>v_now then raise exception using errcode='P0001',message='BALANCE_COLLECTION_NOT_DUE'; end if;

  if p_source='ADMIN_REISSUE' then
    if p_admin_id is null or not public.service_admin_has_permission(p_admin_id,'FINANCE_MANAGE') then raise exception using errcode='42501',message='ADMIN_PERMISSION_DENIED'; end if;
  elsif p_admin_id is not null then
    raise exception using errcode='22023',message='BALANCE_COLLECTION_ADMIN_INVALID';
  end if;

  v_balance:=round(greatest(coalesce((public.get_appointment_financial_summary(p_appointment_id)->>'contract_balance')::numeric,0),0),2);
  if v_balance<=0 then raise exception using errcode='P0001',message='BALANCE_COLLECTION_NOT_DUE'; end if;
  if p_source='AUTO_START' and exists(select 1 from public.appointment_balance_collections where appointment_id=p_appointment_id) then
    raise exception using errcode='P0001',message='BALANCE_COLLECTION_ALREADY_CREATED';
  end if;

  if p_source='ADMIN_REISSUE' then
    update public.appointment_balance_collections set status='REVOKED',updated_at=v_now where appointment_id=p_appointment_id and status='ACTIVE';
    update public.appointment_access_tokens set revoked_at=coalesce(revoked_at,v_now)
    where appointment_id=p_appointment_id and balance_collection_id is not null and revoked_at is null;
  end if;

  select coalesce(max(sequence),0)+1 into v_sequence from public.appointment_balance_collections where appointment_id=p_appointment_id;
  insert into public.appointment_balance_collections(appointment_id,sequence,source,status,amount_snapshot,issued_at,expires_at,created_by_admin_id)
  values(p_appointment_id,v_sequence,p_source,'ACTIVE',v_balance,v_now,v_now+interval '48 hours',p_admin_id)
  returning * into v_collection;

  insert into public.integration_jobs(job_type,entity_type,entity_id,entity_version,payload_json,idempotency_key)
  values
    ('RENTAL_BALANCE_DUE_EMAIL','BALANCE_COLLECTION',v_collection.id,v_sequence,jsonb_build_object('appointment_id',p_appointment_id,'source',p_source),'rental-balance-email:'||v_collection.id::text),
    ('RENTAL_BALANCE_DUE_KOMMO','BALANCE_COLLECTION',v_collection.id,v_sequence,jsonb_build_object('appointment_id',p_appointment_id,'source',p_source),'rental-balance-kommo:'||v_collection.id::text)
  on conflict(idempotency_key) do nothing;

  insert into public.audit_logs(entity_type,entity_id,action,before_json,after_json,origin,admin_user_id)
  values('APPOINTMENT',p_appointment_id,
    case when p_source='AUTO_START' then 'BALANCE_COLLECTION_AUTO_CREATED' else 'BALANCE_COLLECTION_REISSUED' end,
    null,jsonb_build_object('collection_id',v_collection.id,'sequence',v_sequence,'amount',v_balance,'expires_at',v_collection.expires_at),
    case when p_source='AUTO_START' then 'SYSTEM' else 'OPERATION' end,p_admin_id);

  return jsonb_build_object('collection_id',v_collection.id,'appointment_id',p_appointment_id,'sequence',v_sequence,'status','ACTIVE','amount',v_balance,'issued_at',v_collection.issued_at,'expires_at',v_collection.expires_at);
end;
$$;
-- END RC MIGRATION 20260824170100_balance_collection_delivery_channels.sql

-- BEGIN RC MIGRATION 20260824170150_prepare_balance_collection_views.sql
-- CREATE OR REPLACE VIEW cannot insert columns in the middle of an existing view.
-- The hardening migration intentionally expands the projection, so drop the V1 view
-- before recreating it with the authoritative finance columns.
drop view if exists public.appointment_open_balances;
-- END RC MIGRATION 20260824170150_prepare_balance_collection_views.sql
