
-- BEGIN RC MIGRATION 20260821205600_mercado_pago_adapter_support.sql
create or replace function public.service_fail_payment_intent(
  p_transaction_id uuid,
  p_reason text,
  p_payload_json jsonb default '{}'::jsonb
)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_tx public.payment_transactions%rowtype;
begin
  select * into v_tx
  from public.payment_transactions
  where id = p_transaction_id
  for update;

  if not found or v_tx.provider <> 'MERCADO_PAGO' or v_tx.transaction_type <> 'CHARGE' then
    raise exception using errcode = 'P0001', message = 'PAYMENT_TRANSACTION_NOT_FOUND';
  end if;

  if v_tx.status = 'APPROVED' then
    raise exception using errcode = 'P0001', message = 'APPROVED_PAYMENT_CANNOT_FAIL';
  end if;

  update public.payment_transactions
  set status = 'REJECTED',
      provider_payload_json = coalesce(p_payload_json, '{}'::jsonb),
      notes = concat_ws(E'\n', nullif(notes, ''), nullif(left(p_reason, 500), '')),
      updated_at = now()
  where id = p_transaction_id;

  if not exists (
    select 1 from public.payment_transactions pt
    where pt.appointment_id = v_tx.appointment_id
      and pt.transaction_type = 'CHARGE'
      and pt.status = 'APPROVED'
  ) then
    update public.appointments
    set financial_status = 'REJECTED',
        updated_at = now()
    where id = v_tx.appointment_id
      and status = 'AWAITING_PAYMENT';
  else
    perform public.refresh_appointment_financial_status(v_tx.appointment_id);
  end if;

  insert into public.audit_logs (
    entity_type, entity_id, action, after_json, origin
  ) values (
    'APPOINTMENT',
    v_tx.appointment_id,
    'PAYMENT_INTENT_PROVIDER_REJECTED',
    jsonb_build_object('payment_transaction_id', p_transaction_id, 'reason', left(p_reason,500)),
    'MERCADO_PAGO'
  );
end;
$$;

revoke all on function public.service_fail_payment_intent(uuid,text,jsonb) from public, anon, authenticated;
grant execute on function public.service_fail_payment_intent(uuid,text,jsonb) to service_role;
-- END RC MIGRATION 20260821205600_mercado_pago_adapter_support.sql

-- BEGIN RC MIGRATION 20260821205800_conversion_attribution.sql
-- Conversion attribution is first-party context attached to the booking transaction.
-- It intentionally excludes customer PII. Third-party tags remain consent-gated in the web app.

alter table public.checkout_holds
  add column attribution_json jsonb not null default '{}'::jsonb;

alter table public.appointments
  add column attribution_json jsonb not null default '{}'::jsonb;

alter table public.checkout_holds
  add constraint checkout_holds_attribution_object_check
  check (jsonb_typeof(attribution_json) = 'object');

alter table public.appointments
  add constraint appointments_attribution_object_check
  check (jsonb_typeof(attribution_json) = 'object');

create index appointments_attribution_campaign_idx
  on public.appointments ((attribution_json->>'utm_campaign'))
  where attribution_json ? 'utm_campaign';

create index appointments_attribution_source_idx
  on public.appointments ((attribution_json->>'utm_source'))
  where attribution_json ? 'utm_source';

create or replace function public.sanitize_public_attribution(p_value jsonb)
returns jsonb
language sql
immutable
set search_path = public
as $$
select jsonb_strip_nulls(jsonb_build_object(
  'visitor_id', case when coalesce(p_value->>'visitor_id','') ~ '^[0-9a-fA-F-]{36}$' then left(p_value->>'visitor_id', 36) end,
  'session_id', case when coalesce(p_value->>'session_id','') ~ '^[0-9a-fA-F-]{36}$' then left(p_value->>'session_id', 36) end,
  'landing_path', nullif(left(btrim(coalesce(p_value->>'landing_path','')), 500), ''),
  'referrer', nullif(left(btrim(coalesce(p_value->>'referrer','')), 500), ''),
  'utm_source', nullif(left(btrim(coalesce(p_value->>'utm_source','')), 180), ''),
  'utm_medium', nullif(left(btrim(coalesce(p_value->>'utm_medium','')), 180), ''),
  'utm_campaign', nullif(left(btrim(coalesce(p_value->>'utm_campaign','')), 180), ''),
  'utm_content', nullif(left(btrim(coalesce(p_value->>'utm_content','')), 180), ''),
  'utm_term', nullif(left(btrim(coalesce(p_value->>'utm_term','')), 180), ''),
  'fbclid', nullif(left(btrim(coalesce(p_value->>'fbclid','')), 300), ''),
  'gclid', nullif(left(btrim(coalesce(p_value->>'gclid','')), 300), '')
));
$$;

revoke all on function public.sanitize_public_attribution(jsonb) from public, anon, authenticated;
grant execute on function public.sanitize_public_attribution(jsonb) to service_role;

create or replace function public.public_create_checkout_hold_tracked(
  p_booking_page_slug text,
  p_service_id uuid,
  p_service_employee_id uuid,
  p_extra_selections jsonb,
  p_people_count integer,
  p_requested_start_at timestamptz,
  p_attribution_json jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_result jsonb;
  v_hold_id uuid;
begin
  if p_attribution_json is not null and jsonb_typeof(p_attribution_json) <> 'object' then
    raise exception using errcode = 'P0001', message = 'ATTRIBUTION_INVALID';
  end if;

  v_result := public.public_create_checkout_hold(
    p_booking_page_slug,
    p_service_id,
    p_service_employee_id,
    p_extra_selections,
    p_people_count,
    p_requested_start_at
  );

  v_hold_id := (v_result->>'checkout_hold_id')::uuid;

  update public.checkout_holds
  set attribution_json = public.sanitize_public_attribution(coalesce(p_attribution_json, '{}'::jsonb)),
      updated_at = now()
  where id = v_hold_id;

  return v_result;
end;
$$;

revoke all on function public.public_create_checkout_hold_tracked(text,uuid,uuid,jsonb,integer,timestamptz,jsonb)
  from public;
grant execute on function public.public_create_checkout_hold_tracked(text,uuid,uuid,jsonb,integer,timestamptz,jsonb)
  to anon, authenticated;

create or replace function public.copy_checkout_attribution_to_appointment()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status = 'PROMOTED'
     and new.promoted_appointment_id is not null
     and (old.status is distinct from new.status or old.promoted_appointment_id is distinct from new.promoted_appointment_id) then
    update public.appointments
    set attribution_json = coalesce(new.attribution_json, '{}'::jsonb),
        updated_at = now()
    where id = new.promoted_appointment_id;
  end if;
  return new;
end;
$$;

create trigger checkout_hold_copy_attribution_trg
after update of status, promoted_appointment_id on public.checkout_holds
for each row execute function public.copy_checkout_attribution_to_appointment();

comment on column public.checkout_holds.attribution_json is
  'Consent-gated first-party acquisition context. PII is not accepted by the public sanitizer.';
comment on column public.appointments.attribution_json is
  'Immutable-at-promotion acquisition snapshot inherited from the checkout hold for conversion reporting.';
comment on function public.public_create_checkout_hold_tracked(text,uuid,uuid,jsonb,integer,timestamptz,jsonb) is
  'Public hold creator that preserves a strict allowlist of consented acquisition parameters alongside the authoritative hold.';
-- END RC MIGRATION 20260821205800_conversion_attribution.sql

-- BEGIN RC MIGRATION 20260821206000_service_slot_interval_policy.sql
-- Scheduling policy clarified from operational rules.
-- 1) Offered start-time cadence defaults to 30 minutes.
-- 2) Buffers belong to the service, never to an individual rental block.
-- 3) Fixed-duration services (e.g. Sabrina) keep per-service before/after buffers.
-- 4) Block-duration services (e.g. studio rental) use 30-minute contracted blocks
--    and receive the service buffer exactly once around the whole contracted period.

alter table public.operation_settings
  add column if not exists default_slot_interval_minutes integer not null default 30
  check (default_slot_interval_minutes > 0 and default_slot_interval_minutes <= 1440);

alter table public.availability_rules
  alter column slot_interval_minutes set default 30;

update public.operation_settings
set default_slot_interval_minutes = 30,
    updated_at = now()
where id = 1;

alter table public.services
  add column duration_mode text not null default 'FIXED'
    check (duration_mode in ('FIXED','BLOCKS')),
  add column booking_block_minutes integer,
  add column minimum_booking_blocks integer,
  add column maximum_booking_blocks integer,
  add column price_per_block numeric(12,2);

alter table public.services
  add constraint services_duration_policy_check
  check (
    (
      duration_mode = 'FIXED'
      and booking_block_minutes is null
      and minimum_booking_blocks is null
      and maximum_booking_blocks is null
      and price_per_block is null
    )
    or
    (
      duration_mode = 'BLOCKS'
      and booking_block_minutes = 30
      and minimum_booking_blocks is not null
      and maximum_booking_blocks is not null
      and minimum_booking_blocks >= 1
      and maximum_booking_blocks >= minimum_booking_blocks
      and price_per_block is not null
      and price_per_block >= 0
    )
  );

alter table public.checkout_holds
  add column duration_blocks integer,
  add column contracted_minutes integer;

alter table public.appointments
  add column duration_blocks integer,
  add column contracted_minutes integer;

update public.checkout_holds
set contracted_minutes = greatest(
  1,
  round(extract(epoch from (core_end_at - core_start_at)) / 60)::integer
)
where contracted_minutes is null
  and core_start_at is not null
  and core_end_at is not null;

update public.appointments
set contracted_minutes = greatest(
  1,
  round(extract(epoch from (core_end_at - core_start_at)) / 60)::integer
)
where contracted_minutes is null
  and core_start_at is not null
  and core_end_at is not null;

alter table public.checkout_holds
  add constraint checkout_holds_duration_blocks_check
    check (duration_blocks is null or duration_blocks >= 1),
  add constraint checkout_holds_contracted_minutes_check
    check (contracted_minutes is null or contracted_minutes > 0);

alter table public.appointments
  add constraint appointments_duration_blocks_check
    check (duration_blocks is null or duration_blocks >= 1),
  add constraint appointments_contracted_minutes_check
    check (contracted_minutes is null or contracted_minutes > 0);

comment on column public.operation_settings.default_slot_interval_minutes is
  'Default cadence between offered start times. V1 default is 30 minutes.';
comment on column public.services.duration_mode is
  'FIXED uses base_duration_minutes. BLOCKS lets the customer contract multiple 30-minute blocks.';
comment on column public.services.booking_block_minutes is
  'Contracted unit size for BLOCKS services. V1 rental block is exactly 30 minutes.';
comment on column public.services.buffer_before_minutes is
  'Service-level buffer applied once before the complete contracted service period.';
comment on column public.services.buffer_after_minutes is
  'Service-level buffer applied once after the complete contracted service period; never multiplied by block count.';
comment on column public.checkout_holds.contracted_minutes is
  'Customer-contracted core duration, excluding PREPEND/APPEND extras and service buffers.';
comment on column public.appointments.contracted_minutes is
  'Snapshot of customer-contracted core duration, excluding service buffers.';

create or replace function public.get_default_slot_interval_minutes()
returns integer
language sql
stable
set search_path = public
as $$
select coalesce(
  (select os.default_slot_interval_minutes from public.operation_settings os where os.id = 1),
  30
);
$$;

create or replace function public.resolve_service_contracted_minutes(
  p_service_id uuid,
  p_duration_blocks integer default null
)
returns integer
language plpgsql
stable
set search_path = public
as $$
declare
  v_service public.services%rowtype;
begin
  select * into v_service
  from public.services
  where id = p_service_id;

  if not found then
    raise exception using errcode = 'P0001', message = 'SERVICE_NOT_FOUND';
  end if;

  if v_service.duration_mode = 'FIXED' then
    if p_duration_blocks is not null then
      raise exception using errcode = 'P0001', message = 'DURATION_BLOCKS_NOT_ALLOWED';
    end if;
    return v_service.base_duration_minutes;
  end if;

  if p_duration_blocks is null
     or p_duration_blocks < v_service.minimum_booking_blocks
     or p_duration_blocks > v_service.maximum_booking_blocks then
    raise exception using errcode = 'P0001', message = 'INVALID_DURATION_BLOCKS';
  end if;

  return v_service.booking_block_minutes * p_duration_blocks;
end;
$$;

create or replace function public.service_resource_envelope(
  p_service_id uuid,
  p_core_start_at timestamptz,
  p_duration_blocks integer default null
)
returns tstzrange
language plpgsql
stable
set search_path = public
as $$
declare
  v_service public.services%rowtype;
  v_contracted_minutes integer;
begin
  select * into v_service
  from public.services
  where id = p_service_id;

  if not found then
    raise exception using errcode = 'P0001', message = 'SERVICE_NOT_FOUND';
  end if;

  v_contracted_minutes := public.resolve_service_contracted_minutes(
    p_service_id,
    p_duration_blocks
  );

  -- Critical invariant: buffers are applied once to the WHOLE service envelope.
  -- They are deliberately outside the block multiplication.
  return tstzrange(
    p_core_start_at - make_interval(mins => v_service.buffer_before_minutes),
    p_core_start_at
      + make_interval(mins => v_contracted_minutes)
      + make_interval(mins => v_service.buffer_after_minutes),
    '[)'
  );
end;
$$;

create or replace function public.set_service_duration_policy(
  p_service_id uuid,
  p_duration_mode text,
  p_buffer_before_minutes integer,
  p_buffer_after_minutes integer,
  p_booking_block_minutes integer default null,
  p_minimum_booking_blocks integer default null,
  p_maximum_booking_blocks integer default null,
  p_price_per_block numeric default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_mode text := upper(btrim(coalesce(p_duration_mode, '')));
  v_service public.services%rowtype;
begin
  if v_mode not in ('FIXED','BLOCKS') then
    raise exception using errcode = 'P0001', message = 'INVALID_DURATION_MODE';
  end if;

  if p_buffer_before_minutes is null or p_buffer_before_minutes < 0
     or p_buffer_after_minutes is null or p_buffer_after_minutes < 0 then
    raise exception using errcode = 'P0001', message = 'INVALID_SERVICE_BUFFER';
  end if;

  if v_mode = 'BLOCKS' then
    if p_booking_block_minutes is distinct from 30 then
      raise exception using errcode = 'P0001', message = 'RENTAL_BLOCK_MUST_BE_30_MINUTES';
    end if;
    if p_minimum_booking_blocks is null
       or p_maximum_booking_blocks is null
       or p_minimum_booking_blocks < 1
       or p_maximum_booking_blocks < p_minimum_booking_blocks
       or p_price_per_block is null
       or p_price_per_block < 0 then
      raise exception using errcode = 'P0001', message = 'INVALID_BLOCK_DURATION_POLICY';
    end if;
  end if;

  update public.services
  set duration_mode = v_mode,
      buffer_before_minutes = p_buffer_before_minutes,
      buffer_after_minutes = p_buffer_after_minutes,
      booking_block_minutes = case when v_mode = 'BLOCKS' then 30 else null end,
      minimum_booking_blocks = case when v_mode = 'BLOCKS' then p_minimum_booking_blocks else null end,
      maximum_booking_blocks = case when v_mode = 'BLOCKS' then p_maximum_booking_blocks else null end,
      price_per_block = case when v_mode = 'BLOCKS' then p_price_per_block::numeric(12,2) else null end,
      updated_at = now()
  where id = p_service_id
  returning * into v_service;

  if not found then
    raise exception using errcode = 'P0001', message = 'SERVICE_NOT_FOUND';
  end if;

  insert into public.audit_logs(entity_type, entity_id, action, after_json, origin)
  values (
    'SERVICE',
    p_service_id,
    'DURATION_POLICY_CHANGED',
    jsonb_build_object(
      'duration_mode', v_mode,
      'buffer_before_minutes', p_buffer_before_minutes,
      'buffer_after_minutes', p_buffer_after_minutes,
      'booking_block_minutes', case when v_mode = 'BLOCKS' then 30 else null end,
      'minimum_booking_blocks', case when v_mode = 'BLOCKS' then p_minimum_booking_blocks else null end,
      'maximum_booking_blocks', case when v_mode = 'BLOCKS' then p_maximum_booking_blocks else null end,
      'price_per_block', case when v_mode = 'BLOCKS' then p_price_per_block else null end
    ),
    'ADMIN'
  );

  return jsonb_build_object(
    'service_id', v_service.id,
    'duration_mode', v_service.duration_mode,
    'buffer_before_minutes', v_service.buffer_before_minutes,
    'buffer_after_minutes', v_service.buffer_after_minutes,
    'booking_block_minutes', v_service.booking_block_minutes,
    'minimum_booking_blocks', v_service.minimum_booking_blocks,
    'maximum_booking_blocks', v_service.maximum_booking_blocks,
    'price_per_block', v_service.price_per_block
  );
end;
$$;

revoke all on function public.get_default_slot_interval_minutes() from public, anon, authenticated;
grant execute on function public.get_default_slot_interval_minutes() to service_role;
revoke all on function public.resolve_service_contracted_minutes(uuid,integer) from public, anon, authenticated;
grant execute on function public.resolve_service_contracted_minutes(uuid,integer) to service_role;
revoke all on function public.service_resource_envelope(uuid,timestamptz,integer) from public, anon, authenticated;
grant execute on function public.service_resource_envelope(uuid,timestamptz,integer) to service_role;
revoke all on function public.set_service_duration_policy(uuid,text,integer,integer,integer,integer,integer,numeric)
  from public, anon, authenticated;
grant execute on function public.set_service_duration_policy(uuid,text,integer,integer,integer,integer,integer,numeric)
  to service_role;
-- END RC MIGRATION 20260821206000_service_slot_interval_policy.sql

-- BEGIN RC MIGRATION 20260821206100_block_duration_booking.sql
-- Block-duration booking path.
-- Contracted duration and service buffers are distinct by design:
-- contracted_minutes = block_minutes * block_count
-- occupied service-resource range = contracted period + buffer_before/buffer_after ONCE.

create or replace function public.calculate_booking_quote_for_duration(
  p_service_id uuid,
  p_service_employee_id uuid,
  p_duration_blocks integer default null,
  p_extra_selections jsonb default '[]'::jsonb,
  p_people_count integer default 1,
  p_requested_start_at timestamptz default null,
  p_coupon_code text default null
)
returns jsonb
language plpgsql
stable
set search_path = public, extensions
as $$
declare
  v_service public.services%rowtype;
  v_timezone text;
  v_price numeric := 0;
  v_dynamic_base numeric := 0;
  v_after_day_time numeric := 0;
  v_after_people numeric := 0;
  v_day_time_adjustment numeric := 0;
  v_people_adjustment numeric := 0;
  v_extras_total numeric := 0;
  v_subtotal numeric := 0;
  v_coupon_discount numeric := 0;
  v_commercial_value numeric := 0;
  v_coupon public.coupons%rowtype;
  v_local_ts timestamp without time zone;
  v_local_date date;
  v_local_time time without time zone;
  v_dow smallint;
  v_processed_extras integer := 0;
  v_requested_extras integer := 0;
  v_resource_ids uuid[] := '{}'::uuid[];
  v_contracted_minutes integer;
  v_profile jsonb;
  v_pre integer := 0;
  v_post integer := 0;
  v_pricing_version text;
  r record;
begin
  select * into v_service
  from public.services
  where id = p_service_id and is_active;

  if not found then
    raise exception using errcode = 'P0001', message = 'SERVICE_NOT_AVAILABLE';
  end if;

  if not exists (
    select 1 from public.service_employees se
    where se.id = p_service_employee_id
      and se.service_id = p_service_id
      and se.is_active
  ) then
    raise exception using errcode = 'P0001', message = 'EMPLOYEE_NOT_AVAILABLE_FOR_SERVICE';
  end if;

  v_contracted_minutes := public.resolve_service_contracted_minutes(p_service_id, p_duration_blocks);

  -- Fixed services keep the existing mature pricing engine unchanged.
  if v_service.duration_mode = 'FIXED' then
    return public.calculate_booking_quote(
      p_service_id,
      p_service_employee_id,
      p_extra_selections,
      p_people_count,
      p_requested_start_at,
      p_coupon_code
    ) || jsonb_build_object(
      'duration_mode', 'FIXED',
      'duration_blocks', null,
      'contracted_minutes', v_contracted_minutes,
      'buffer_before_minutes', v_service.buffer_before_minutes,
      'buffer_after_minutes', v_service.buffer_after_minutes
    );
  end if;

  if p_people_count < v_service.minimum_people or p_people_count > v_service.maximum_people then
    raise exception using errcode = 'P0001', message = 'INVALID_PEOPLE_COUNT';
  end if;

  if jsonb_typeof(coalesce(p_extra_selections, '[]'::jsonb)) <> 'array' then
    raise exception using errcode = 'P0001', message = 'INVALID_EXTRA';
  end if;

  select count(*) into v_requested_extras
  from jsonb_array_elements(coalesce(p_extra_selections, '[]'::jsonb));

  if exists (
    select 1
    from jsonb_to_recordset(coalesce(p_extra_selections, '[]'::jsonb)) x(extra_id uuid, quantity integer)
    group by x.extra_id having count(*) > 1
  ) then
    raise exception using errcode = 'P0001', message = 'INVALID_EXTRA';
  end if;

  v_dynamic_base := round(v_service.price_per_block * p_duration_blocks, 2);
  v_price := v_dynamic_base;

  for r in
    select e.id, e.price, x.quantity, se.max_quantity
    from jsonb_to_recordset(coalesce(p_extra_selections, '[]'::jsonb)) x(extra_id uuid, quantity integer)
    join public.service_extras se on se.service_id = p_service_id and se.extra_id = x.extra_id
    join public.extras e on e.id = x.extra_id and e.is_active
  loop
    if r.quantity is null or r.quantity < 1 or r.quantity > r.max_quantity then
      raise exception using errcode = 'P0001', message = 'INVALID_EXTRA_QUANTITY';
    end if;
    v_processed_extras := v_processed_extras + 1;
    v_extras_total := v_extras_total + (r.price * r.quantity);
  end loop;

  if v_processed_extras <> v_requested_extras then
    raise exception using errcode = 'P0001', message = 'INVALID_EXTRA';
  end if;

  select timezone into v_timezone from public.operation_settings where id = 1;

  if p_requested_start_at is not null then
    v_local_ts := p_requested_start_at at time zone v_timezone;
    v_local_date := v_local_ts::date;
    v_local_time := v_local_ts::time;
    v_dow := extract(dow from v_local_ts)::smallint;

    for r in
      select pr.*
      from public.pricing_rules pr
      where pr.service_id = p_service_id
        and pr.is_active
        and pr.rule_scope = 'DAY_TIME'
        and (pr.valid_from_date is null or v_local_date >= pr.valid_from_date)
        and (pr.valid_until_date is null or v_local_date <= pr.valid_until_date)
        and (pr.days_of_week is null or v_dow = any(pr.days_of_week))
        and (pr.start_local_time is null or v_local_time >= pr.start_local_time)
        and (pr.end_local_time is null or v_local_time < pr.end_local_time)
      order by pr.priority, pr.id
    loop
      if r.action_type = 'REPLACE_PRICE' then
        v_price := r.amount;
      elsif r.action_type = 'ADD_AMOUNT' then
        v_price := v_price + r.amount;
      elsif r.action_type = 'ADD_PERCENT' then
        v_price := v_price * (1 + (r.percentage / 100));
      end if;
    end loop;
  end if;

  v_after_day_time := round(greatest(v_price, 0), 2);
  v_day_time_adjustment := v_after_day_time - v_dynamic_base;
  v_price := v_after_day_time;

  for r in
    select pr.*
    from public.pricing_rules pr
    where pr.service_id = p_service_id
      and pr.is_active
      and pr.rule_scope = 'PEOPLE'
      and p_people_count between pr.min_people and pr.max_people
      and (pr.valid_from_date is null or coalesce(v_local_date, current_date) >= pr.valid_from_date)
      and (pr.valid_until_date is null or coalesce(v_local_date, current_date) <= pr.valid_until_date)
    order by pr.priority, pr.id
  loop
    if r.action_type = 'REPLACE_PRICE' then
      v_price := r.amount;
    elsif r.action_type = 'ADD_AMOUNT' then
      v_price := v_price + r.amount;
    elsif r.action_type = 'ADD_PERCENT' then
      v_price := v_price * (1 + (r.percentage / 100));
    end if;
  end loop;

  v_after_people := round(greatest(v_price, 0), 2);
  v_people_adjustment := v_after_people - v_after_day_time;
  v_extras_total := round(v_extras_total, 2);
  v_subtotal := round(greatest(v_after_people + v_extras_total, 0), 2);

  if p_coupon_code is not null and btrim(p_coupon_code) <> '' then
    select c.* into v_coupon
    from public.coupons c
    where lower(c.code) = lower(btrim(p_coupon_code))
      and c.is_active
      and (c.valid_from is null or coalesce(p_requested_start_at, now()) >= c.valid_from)
      and (c.valid_until is null or coalesce(p_requested_start_at, now()) <= c.valid_until)
      and (
        not exists (select 1 from public.coupon_services cs where cs.coupon_id = c.id)
        or exists (select 1 from public.coupon_services cs where cs.coupon_id = c.id and cs.service_id = p_service_id)
      )
    limit 1;

    if not found then
      raise exception using errcode = 'P0001', message = 'INVALID_COUPON';
    end if;

    if v_coupon.discount_type = 'FIXED' then
      v_coupon_discount := least(v_coupon.discount_value, v_subtotal);
    else
      v_coupon_discount := round(v_subtotal * (v_coupon.discount_value / 100), 2);
    end if;
  end if;

  v_coupon_discount := round(v_coupon_discount, 2);
  v_commercial_value := round(greatest(v_subtotal - v_coupon_discount, 0), 2);

  select coalesce(array_agg(distinct resource_id order by resource_id), '{}'::uuid[])
  into v_resource_ids
  from (
    select sr.resource_id
    from public.service_resources sr
    where sr.service_id = p_service_id and sr.is_required
    union
    select er.resource_id
    from jsonb_to_recordset(coalesce(p_extra_selections, '[]'::jsonb)) x(extra_id uuid, quantity integer)
    join public.extra_resources er on er.extra_id = x.extra_id and er.is_required
  ) q;

  v_profile := public.resolve_extra_schedule_profile(p_service_id, p_extra_selections, p_requested_start_at);
  v_pre := coalesce((v_profile->>'pre_service_minutes')::integer, 0);
  v_post := coalesce((v_profile->>'post_service_minutes')::integer, 0);

  select md5(concat_ws('|',
    v_service.updated_at::text,
    p_duration_blocks::text,
    v_dynamic_base::text,
    coalesce((select max(updated_at)::text from public.pricing_rules where service_id = p_service_id), ''),
    coalesce((select max(e.updated_at)::text
      from jsonb_to_recordset(coalesce(p_extra_selections, '[]'::jsonb)) x(extra_id uuid, quantity integer)
      join public.extras e on e.id = x.extra_id), ''),
    coalesce(v_coupon.updated_at::text, ''),
    coalesce(v_profile->>'schedule_version', '')
  )) into v_pricing_version;

  return jsonb_build_object(
    'service_id', p_service_id,
    'service_employee_id', p_service_employee_id,
    'duration_mode', 'BLOCKS',
    'duration_blocks', p_duration_blocks,
    'booking_block_minutes', v_service.booking_block_minutes,
    'contracted_minutes', v_contracted_minutes,
    'core_duration_minutes', v_contracted_minutes,
    'pre_service_minutes', v_pre,
    'post_service_minutes', v_post,
    'duration_minutes', v_contracted_minutes + v_pre + v_post,
    'buffer_before_minutes', v_service.buffer_before_minutes,
    'buffer_after_minutes', v_service.buffer_after_minutes,
    'resource_ids', to_jsonb(v_resource_ids),
    'base_price', v_dynamic_base,
    'day_time_adjustment', round(v_day_time_adjustment, 2),
    'people_adjustment', round(v_people_adjustment, 2),
    'extras_total', v_extras_total,
    'coupon_discount', v_coupon_discount,
    'commercial_value', v_commercial_value,
    'schedule_profile', v_profile,
    'pricing_version', v_pricing_version
  );
end;
$$;

create or replace function public.calculate_booking_resource_ranges_for_duration(
  p_service_id uuid,
  p_extra_selections jsonb,
  p_anchor_start_at timestamptz,
  p_duration_blocks integer default null
)
returns table(resource_id uuid, occupied_range tstzrange)
language sql
stable
set search_path = public
as $$
with service_data as (
  select
    public.resolve_service_contracted_minutes(p_service_id, p_duration_blocks) as contracted_minutes,
    s.buffer_before_minutes,
    s.buffer_after_minutes,
    public.resolve_extra_schedule_profile(p_service_id, p_extra_selections, p_anchor_start_at) as profile
  from public.services s
  where s.id = p_service_id
), bounds as (
  select
    p_anchor_start_at as core_start_at,
    p_anchor_start_at + make_interval(mins => contracted_minutes) as core_end_at,
    p_anchor_start_at - make_interval(mins => coalesce((profile->>'pre_service_minutes')::integer, 0)) as appointment_start_at,
    p_anchor_start_at + make_interval(mins => contracted_minutes + coalesce((profile->>'post_service_minutes')::integer, 0)) as appointment_end_at,
    buffer_before_minutes,
    buffer_after_minutes,
    profile
  from service_data
), ranges as (
  select
    sr.resource_id,
    tstzrange(
      b.core_start_at - make_interval(mins => b.buffer_before_minutes),
      b.core_end_at + make_interval(mins => b.buffer_after_minutes),
      '[)'
    ) as r
  from public.service_resources sr
  cross join bounds b
  where sr.service_id = p_service_id and sr.is_required

  union all

  select er.resource_id,
    case d.placement
      when 'PREPEND' then tstzrange(b.appointment_start_at, b.core_start_at, '[)')
      when 'APPEND' then tstzrange(b.core_end_at, b.appointment_end_at, '[)')
    end
  from bounds b
  cross join lateral jsonb_to_recordset(b.profile->'details') d(
    extra_id uuid, quantity integer, placement text,
    minutes_per_unit integer, total_schedule_minutes integer
  )
  join public.extra_resources er on er.extra_id = d.extra_id and er.is_required
  where d.total_schedule_minutes > 0
), nonempty as (
  select resource_id, r from ranges where r is not null and not isempty(r)
)
select resource_id, tstzrange(min(lower(r)), max(upper(r)), '[)')
from nonempty
group by resource_id;
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

    if v_appointment_start < now() + make_interval(mins => v_service.minimum_booking_notice_minutes) then continue; end if;
    if v_anchor_start > now() + make_interval(days => v_service.maximum_booking_horizon_days) then continue; end if;

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

create or replace function public.create_checkout_hold_for_duration(
  p_service_id uuid,
  p_service_employee_id uuid,
  p_duration_blocks integer,
  p_extra_selections jsonb,
  p_people_count integer,
  p_requested_start_at timestamptz
)
returns jsonb
language plpgsql
volatile
set search_path = public, extensions
as $$
declare
  v_timezone text;
  v_requested_local_date date;
  v_slot record;
  v_quote jsonb;
  v_resource_ids uuid[] := '{}'::uuid[];
  v_hold_id uuid;
  v_raw_token text;
  v_token_hash text;
  v_selection_hash text;
  v_canonical_extras jsonb;
  v_expires_at timestamptz;
  v_hold_minutes integer;
  v_contracted_minutes integer;
begin
  perform public.expire_due_checkout_holds();
  v_contracted_minutes := public.resolve_service_contracted_minutes(p_service_id, p_duration_blocks);
  select timezone into v_timezone from public.operation_settings where id = 1;

  select coalesce(jsonb_agg(
    jsonb_build_object('extra_id', x.extra_id, 'quantity', x.quantity) order by x.extra_id
  ), '[]'::jsonb)
  into v_canonical_extras
  from jsonb_to_recordset(coalesce(p_extra_selections, '[]'::jsonb)) x(extra_id uuid, quantity integer);

  v_requested_local_date := (p_requested_start_at at time zone v_timezone)::date;

  select s.* into v_slot
  from (
    select * from public.list_available_slots_for_duration(
      p_service_id, p_service_employee_id, p_duration_blocks,
      v_canonical_extras, p_people_count, v_requested_local_date, null
    )
    union all
    select * from public.list_available_slots_for_duration(
      p_service_id, p_service_employee_id, p_duration_blocks,
      v_canonical_extras, p_people_count, v_requested_local_date + 1, null
    )
  ) s
  where s.slot_start_at = p_requested_start_at
  order by s.core_start_at limit 1;

  if not found then
    raise exception using errcode = 'P0001', message = 'SLOT_NO_LONGER_AVAILABLE';
  end if;

  v_quote := public.calculate_booking_quote_for_duration(
    p_service_id, p_service_employee_id, p_duration_blocks,
    v_canonical_extras, p_people_count, v_slot.core_start_at, null
  );

  select coalesce(array_agg(r.resource_id order by r.resource_id), '{}'::uuid[])
  into v_resource_ids
  from public.calculate_booking_resource_ranges_for_duration(
    p_service_id, v_canonical_extras, v_slot.core_start_at, p_duration_blocks
  ) r;

  if coalesce(array_length(v_resource_ids, 1), 0) = 0 then
    raise exception using errcode = 'P0001', message = 'SERVICE_HAS_NO_REQUIRED_RESOURCES';
  end if;

  select coalesce(s.checkout_hold_minutes, os.checkout_hold_minutes)
  into v_hold_minutes
  from public.services s cross join public.operation_settings os
  where s.id = p_service_id and os.id = 1;

  v_expires_at := now() + make_interval(mins => v_hold_minutes);
  v_raw_token := encode(gen_random_bytes(32), 'hex');
  v_token_hash := encode(digest(v_raw_token, 'sha256'), 'hex');
  v_selection_hash := md5(concat_ws('|',
    p_service_id::text,
    p_service_employee_id::text,
    coalesce(p_duration_blocks::text, 'FIXED'),
    v_canonical_extras::text,
    p_people_count::text,
    v_slot.slot_start_at::text,
    v_slot.core_start_at::text,
    v_quote->>'pricing_version'
  ));

  insert into public.checkout_holds (
    public_token_hash, service_id, service_employee_id, selection_hash, people_count,
    requested_start_at, requested_end_at, core_start_at, core_end_at,
    pre_service_minutes, post_service_minutes, schedule_profile,
    status, expires_at, extra_selections, commercial_value, pricing_version,
    duration_minutes, resource_ids, duration_blocks, contracted_minutes
  ) values (
    v_token_hash, p_service_id, p_service_employee_id, v_selection_hash, p_people_count,
    v_slot.slot_start_at, v_slot.slot_end_at, v_slot.core_start_at, v_slot.core_end_at,
    v_slot.pre_service_minutes, v_slot.post_service_minutes, v_quote->'schedule_profile',
    'ACTIVE', v_expires_at, v_canonical_extras,
    (v_quote->>'commercial_value')::numeric(12,2), v_quote->>'pricing_version',
    v_slot.duration_minutes, v_resource_ids, p_duration_blocks, v_contracted_minutes
  ) returning id into v_hold_id;

  begin
    insert into public.resource_allocations(
      resource_id, checkout_hold_id, allocation_type, status, occupied_range
    )
    select r.resource_id, v_hold_id, 'CHECKOUT_HOLD', 'HELD', r.occupied_range
    from public.calculate_booking_resource_ranges_for_duration(
      p_service_id, v_canonical_extras, v_slot.core_start_at, p_duration_blocks
    ) r;
  exception when exclusion_violation then
    raise exception using errcode = 'P0001', message = 'SLOT_NO_LONGER_AVAILABLE';
  end;

  return jsonb_build_object(
    'checkout_hold_token', v_raw_token,
    'checkout_hold_id', v_hold_id,
    'status', 'ACTIVE',
    'expires_at', v_expires_at,
    'slot_start_at', v_slot.slot_start_at,
    'slot_end_at', v_slot.slot_end_at,
    'core_start_at', v_slot.core_start_at,
    'core_end_at', v_slot.core_end_at,
    'pre_service_minutes', v_slot.pre_service_minutes,
    'post_service_minutes', v_slot.post_service_minutes,
    'commercial_value', (v_quote->>'commercial_value')::numeric(12,2),
    'duration_minutes', v_slot.duration_minutes,
    'duration_blocks', p_duration_blocks,
    'contracted_minutes', v_contracted_minutes,
    'pricing_version', v_quote->>'pricing_version'
  );
end;
$$;

create or replace function public.sync_promoted_appointment_schedule()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.promoted_appointment_id is not null
     and (old.promoted_appointment_id is distinct from new.promoted_appointment_id) then
    update public.appointments
    set core_start_at = new.core_start_at,
        core_end_at = new.core_end_at,
        pre_service_minutes = new.pre_service_minutes,
        post_service_minutes = new.post_service_minutes,
        schedule_profile_snapshot = new.schedule_profile,
        duration_blocks = new.duration_blocks,
        contracted_minutes = new.contracted_minutes,
        updated_at = now()
    where id = new.promoted_appointment_id;
  end if;
  return new;
end;
$$;

revoke all on function public.calculate_booking_quote_for_duration(uuid,uuid,integer,jsonb,integer,timestamptz,text)
  from public, anon, authenticated;
revoke all on function public.calculate_booking_resource_ranges_for_duration(uuid,jsonb,timestamptz,integer)
  from public, anon, authenticated;
revoke all on function public.list_available_slots_for_duration(uuid,uuid,integer,jsonb,integer,date,text)
  from public, anon, authenticated;
revoke all on function public.create_checkout_hold_for_duration(uuid,uuid,integer,jsonb,integer,timestamptz)
  from public, anon, authenticated;

grant execute on function public.calculate_booking_quote_for_duration(uuid,uuid,integer,jsonb,integer,timestamptz,text) to service_role;
grant execute on function public.calculate_booking_resource_ranges_for_duration(uuid,jsonb,timestamptz,integer) to service_role;
grant execute on function public.list_available_slots_for_duration(uuid,uuid,integer,jsonb,integer,date,text) to service_role;
grant execute on function public.create_checkout_hold_for_duration(uuid,uuid,integer,jsonb,integer,timestamptz) to service_role;
-- END RC MIGRATION 20260821206100_block_duration_booking.sql

-- BEGIN RC MIGRATION 20260821206101_public_block_duration_booking.sql
-- Public wrappers for configurable block-duration services.
-- Existing fixed-duration entrypoints stay available for compatibility.

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
        'employees', coalesce((
          select jsonb_agg(
            jsonb_build_object(
              'service_employee_id', se.id,
              'employee_id', e.id,
              'name', e.name
            ) order by e.name, se.id
          )
          from public.service_employees se
          join public.employees e on e.id = se.employee_id and e.is_active
          where se.service_id = s.id and se.is_active
        ), '[]'::jsonb),
        'extras', coalesce((
          select jsonb_agg(
            jsonb_build_object(
              'id', e.id,
              'name', e.name,
              'description', e.description,
              'price', e.price,
              'duration_delta_minutes', e.duration_delta_minutes,
              'is_required', sx.is_required,
              'max_quantity', sx.max_quantity,
              'schedule_placement', sx.schedule_placement,
              'default_schedule_minutes', sx.default_schedule_minutes
            ) order by sx.sort_order, e.name, e.id
          )
          from public.service_extras sx
          join public.extras e on e.id = sx.extra_id and e.is_active
          where sx.service_id = s.id
        ), '[]'::jsonb),
        'fields', coalesce((
          select jsonb_agg(
            jsonb_build_object(
              'id', sf.id,
              'field_key', sf.field_key,
              'label', sf.label,
              'field_type', sf.field_type,
              'help_text', sf.help_text,
              'placeholder', sf.placeholder,
              'is_required', sf.is_required,
              'options', sf.options_json
            ) order by sf.sort_order, sf.id
          )
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

create or replace function public.assert_public_booking_duration(
  p_booking_page_slug text,
  p_service_id uuid,
  p_service_employee_id uuid,
  p_duration_blocks integer,
  p_extra_selections jsonb default '[]'::jsonb,
  p_people_count integer default 1
)
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.assert_public_booking_selection(
    p_booking_page_slug,
    p_service_id,
    p_service_employee_id,
    p_extra_selections,
    p_people_count
  );
  perform public.resolve_service_contracted_minutes(p_service_id, p_duration_blocks);
end;
$$;

create or replace function public.public_quote_booking_duration(
  p_booking_page_slug text,
  p_service_id uuid,
  p_service_employee_id uuid,
  p_duration_blocks integer,
  p_extra_selections jsonb default '[]'::jsonb,
  p_people_count integer default 1
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.assert_public_booking_duration(
    p_booking_page_slug, p_service_id, p_service_employee_id,
    p_duration_blocks, p_extra_selections, p_people_count
  );
  return public.calculate_booking_quote_for_duration(
    p_service_id, p_service_employee_id, p_duration_blocks,
    p_extra_selections, p_people_count, null, null
  );
end;
$$;

create or replace function public.public_list_available_slots_duration(
  p_booking_page_slug text,
  p_service_id uuid,
  p_service_employee_id uuid,
  p_duration_blocks integer,
  p_extra_selections jsonb default '[]'::jsonb,
  p_people_count integer default 1,
  p_local_date date default current_date
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
security definer
set search_path = public
as $$
begin
  perform public.assert_public_booking_duration(
    p_booking_page_slug, p_service_id, p_service_employee_id,
    p_duration_blocks, p_extra_selections, p_people_count
  );
  return query
  select * from public.list_available_slots_for_duration(
    p_service_id, p_service_employee_id, p_duration_blocks,
    p_extra_selections, p_people_count, p_local_date, null
  );
end;
$$;

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
volatile
security definer
set search_path = public
as $$
begin
  perform public.assert_public_booking_duration(
    p_booking_page_slug, p_service_id, p_service_employee_id,
    p_duration_blocks, p_extra_selections, p_people_count
  );
  return public.create_checkout_hold_for_duration(
    p_service_id, p_service_employee_id, p_duration_blocks,
    p_extra_selections, p_people_count, p_requested_start_at
  );
end;
$$;

create or replace function public.public_create_checkout_hold_tracked_duration(
  p_booking_page_slug text,
  p_service_id uuid,
  p_service_employee_id uuid,
  p_duration_blocks integer,
  p_extra_selections jsonb,
  p_people_count integer,
  p_requested_start_at timestamptz,
  p_attribution_json jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_result jsonb;
  v_hold_id uuid;
begin
  if p_attribution_json is not null and jsonb_typeof(p_attribution_json) <> 'object' then
    raise exception using errcode = 'P0001', message = 'ATTRIBUTION_INVALID';
  end if;

  v_result := public.public_create_checkout_hold_duration(
    p_booking_page_slug, p_service_id, p_service_employee_id,
    p_duration_blocks, p_extra_selections, p_people_count, p_requested_start_at
  );

  v_hold_id := (v_result->>'checkout_hold_id')::uuid;
  update public.checkout_holds
  set attribution_json = public.sanitize_public_attribution(coalesce(p_attribution_json, '{}'::jsonb)),
      updated_at = now()
  where id = v_hold_id;

  return v_result;
end;
$$;

revoke all on function public.assert_public_booking_duration(text,uuid,uuid,integer,jsonb,integer)
  from public, anon, authenticated;
revoke all on function public.public_quote_booking_duration(text,uuid,uuid,integer,jsonb,integer) from public;
revoke all on function public.public_list_available_slots_duration(text,uuid,uuid,integer,jsonb,integer,date) from public;
revoke all on function public.public_create_checkout_hold_duration(text,uuid,uuid,integer,jsonb,integer,timestamptz) from public;
revoke all on function public.public_create_checkout_hold_tracked_duration(text,uuid,uuid,integer,jsonb,integer,timestamptz,jsonb) from public;

grant execute on function public.public_quote_booking_duration(text,uuid,uuid,integer,jsonb,integer) to anon, authenticated;
grant execute on function public.public_list_available_slots_duration(text,uuid,uuid,integer,jsonb,integer,date) to anon, authenticated;
grant execute on function public.public_create_checkout_hold_duration(text,uuid,uuid,integer,jsonb,integer,timestamptz) to anon, authenticated;
grant execute on function public.public_create_checkout_hold_tracked_duration(text,uuid,uuid,integer,jsonb,integer,timestamptz,jsonb) to anon, authenticated;
-- END RC MIGRATION 20260821206101_public_block_duration_booking.sql

-- BEGIN RC MIGRATION 20260821206102_block_duration_hour_packages.sql
-- Hour packages cover contracted service time only.
-- Service buffers and PREPEND/APPEND extra time are operational occupancy, not package consumption.

create or replace function public.calculate_hour_package_quote(
  p_hour_package_id uuid,
  p_checkout_hold_id uuid,
  p_customer_id uuid
)
returns jsonb
language plpgsql
stable
set search_path = public
as $$
declare
  v_package public.hour_packages%rowtype;
  v_hold public.checkout_holds%rowtype;
  v_quote jsonb;
  v_available_seconds bigint;
  v_required_minutes integer;
  v_required_seconds bigint;
  v_surcharge_seconds bigint;
  v_charged_seconds bigint;
  v_extras numeric(12,2);
  v_people_adjustment numeric(12,2);
  v_cash_due numeric(12,2);
  v_covered_reference numeric(12,2);
  v_timezone text;
  v_local_start timestamp without time zone;
  v_local_end timestamp without time zone;
  v_is_weekend boolean;
  v_is_outside_standard boolean;
  v_is_special boolean;
begin
  select * into v_package
  from public.hour_packages
  where id = p_hour_package_id;

  if not found then
    raise exception using errcode = 'P0001', message = 'HOUR_PACKAGE_NOT_FOUND';
  end if;

  select * into v_hold
  from public.checkout_holds
  where id = p_checkout_hold_id
    and status = 'ACTIVE'
    and expires_at > now();

  if not found then
    raise exception using errcode = 'P0001', message = 'CHECKOUT_HOLD_NOT_ACTIVE';
  end if;

  if v_package.customer_id <> p_customer_id then
    raise exception using errcode = 'P0001', message = 'HOUR_PACKAGE_CUSTOMER_MISMATCH';
  end if;

  if v_package.status <> 'ACTIVE' then
    raise exception using errcode = 'P0001', message = 'HOUR_PACKAGE_NOT_ACTIVE';
  end if;

  if coalesce(v_hold.core_start_at, v_hold.requested_start_at) < v_package.valid_from
     or coalesce(v_hold.core_start_at, v_hold.requested_start_at) >= v_package.valid_until then
    raise exception using errcode = 'P0001', message = 'HOUR_PACKAGE_OUTSIDE_VALIDITY';
  end if;

  if not exists (
    select 1
    from public.hour_package_services hps
    where hps.hour_package_id = v_package.id
      and hps.service_id = v_hold.service_id
  ) then
    raise exception using errcode = 'P0001', message = 'HOUR_PACKAGE_SERVICE_NOT_ELIGIBLE';
  end if;

  v_required_minutes := coalesce(v_hold.contracted_minutes, v_hold.duration_minutes);
  if v_required_minutes is null or v_required_minutes <= 0 then
    raise exception using errcode = 'P0001', message = 'CHECKOUT_HOLD_DURATION_MISSING';
  end if;

  v_required_seconds := v_required_minutes::bigint * 60;

  select timezone into v_timezone
  from public.operation_settings
  where id = 1;

  -- Special-period classification follows the contracted core period, not hidden
  -- buffer or extra preparation time.
  v_local_start := coalesce(v_hold.core_start_at, v_hold.requested_start_at) at time zone v_timezone;
  v_local_end := coalesce(v_hold.core_end_at, v_hold.requested_end_at) at time zone v_timezone;
  v_is_weekend := extract(dow from v_local_start)::integer in (0, 6);
  v_is_outside_standard :=
    v_local_start::date <> v_local_end::date
    or v_local_start::time < v_package.standard_start_local_time
    or v_local_end::time > v_package.standard_end_local_time;
  v_is_special := v_is_weekend or v_is_outside_standard;

  v_surcharge_seconds := case
    when v_is_special then round(v_required_seconds::numeric * v_package.special_surcharge_percent / 100)::bigint
    else 0
  end;
  v_charged_seconds := v_required_seconds + v_surcharge_seconds;

  select available_seconds into v_available_seconds
  from public.hour_package_balances
  where hour_package_id = v_package.id;

  if coalesce(v_available_seconds, 0) < v_charged_seconds then
    raise exception using errcode = 'P0001', message = 'HOUR_PACKAGE_INSUFFICIENT_BALANCE';
  end if;

  v_quote := public.calculate_booking_quote_for_duration(
    v_hold.service_id,
    v_hold.service_employee_id,
    v_hold.duration_blocks,
    v_hold.extra_selections,
    v_hold.people_count,
    coalesce(v_hold.core_start_at, v_hold.requested_start_at),
    null
  );

  v_extras := coalesce((v_quote->>'extras_total')::numeric, 0);
  v_people_adjustment := greatest(coalesce((v_quote->>'people_adjustment')::numeric, 0), 0);
  v_cash_due := round(v_extras + v_people_adjustment, 2);
  v_covered_reference := round(v_package.reference_minute_value * v_required_minutes, 2);

  return jsonb_build_object(
    'hour_package_id', v_package.id,
    'required_minutes', v_required_minutes,
    'required_seconds', v_required_seconds,
    'available_minutes', floor(v_available_seconds / 60.0)::bigint,
    'available_seconds', v_available_seconds,
    'covered_minutes', v_required_minutes,
    'uncovered_minutes', 0,
    'package_reference_minute_value', v_package.reference_minute_value,
    'covered_reference_value', v_covered_reference,
    'is_special_period', v_is_special,
    'special_surcharge_percent', case when v_is_special then v_package.special_surcharge_percent else 0 end,
    'surcharge_seconds', v_surcharge_seconds,
    'charged_seconds', v_charged_seconds,
    'special_surcharge_amount', 0,
    'uncovered_time_amount', 0,
    'extras_cash_amount', v_extras,
    'people_cash_amount', v_people_adjustment,
    'cash_due', v_cash_due
  );
end;
$$;

comment on function public.calculate_hour_package_quote(uuid,uuid,uuid) is
  'Packages consume only contracted core service time. Buffers and extra schedule phases never consume package balance; extras/people adjustments remain cash.';
-- END RC MIGRATION 20260821206102_block_duration_hour_packages.sql

-- BEGIN RC MIGRATION 20260821209000_admin_agenda_read_model.sql
-- Authenticated admin read models. Service-role only; the Edge Function validates
-- the Supabase user against admin_users before calling these functions.

create or replace function public.service_admin_list_agenda(
  p_start_at timestamptz,
  p_end_at timestamptz
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if p_start_at is null or p_end_at is null or p_end_at <= p_start_at then
    raise exception using errcode = 'P0001', message = 'ADMIN_AGENDA_INVALID_RANGE';
  end if;

  if p_end_at - p_start_at > interval '31 days' then
    raise exception using errcode = 'P0001', message = 'ADMIN_AGENDA_RANGE_TOO_LARGE';
  end if;

  return jsonb_build_object(
    'range', jsonb_build_object('start_at', p_start_at, 'end_at', p_end_at),
    'appointments', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', a.id,
        'public_code', a.public_code,
        'status', a.status,
        'financial_status', a.financial_status,
        'start_at', a.start_at,
        'end_at', a.end_at,
        'duration_minutes', a.duration_minutes,
        'duration_blocks', a.duration_blocks,
        'contracted_minutes', a.contracted_minutes,
        'people_count', a.people_count,
        'origin', a.origin,
        'service_name', coalesce(a.service_name_snapshot, s.name),
        'duration_mode', s.duration_mode,
        'buffer_before_minutes', s.buffer_before_minutes,
        'buffer_after_minutes', s.buffer_after_minutes,
        'employee_name', e.name,
        'customer', jsonb_build_object(
          'id', c.id,
          'name', c.name,
          'phone', c.phone,
          'email', c.email
        ),
        'commercial_value', a.commercial_value,
        'financial', public.get_appointment_financial_summary(a.id),
        'resources', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', r.id,
            'name', r.name,
            'type', r.resource_type,
            'occupied_start_at', lower(ra.occupied_range),
            'occupied_end_at', upper(ra.occupied_range)
          ) order by r.name)
          from public.resource_allocations ra
          join public.resources r on r.id = ra.resource_id
          where ra.appointment_id = a.id
            and ra.allocation_type = 'APPOINTMENT'
            and ra.status not in ('RELEASED','CANCELLED','EXPIRED')
        ), '[]'::jsonb)
      ) order by a.start_at, a.public_code)
      from public.appointments a
      left join public.services s on s.id = a.service_id
      left join public.service_employees se on se.id = a.service_employee_id
      left join public.employees e on e.id = se.employee_id
      left join public.customers c on c.id = a.primary_customer_id
      where a.deleted_at is null
        and a.status <> 'DRAFT'
        and a.start_at < p_end_at
        and a.end_at > p_start_at
    ), '[]'::jsonb),
    'external_blocks', coalesce((
      select jsonb_agg(jsonb_build_object(
        'allocation_id', ra.id,
        'resource_id', r.id,
        'resource_name', r.name,
        'start_at', lower(ra.occupied_range),
        'end_at', upper(ra.occupied_range),
        'status', ra.status,
        'reason', ra.reason,
        'source', coalesce(ra.external_source, 'GOOGLE'),
        'calendar_name', gc.name,
        'event_summary', gce.summary,
        'event_qualification', gce.qualification
      ) order by lower(ra.occupied_range), r.name)
      from public.resource_allocations ra
      join public.resources r on r.id = ra.resource_id
      left join public.google_calendar_events gce on gce.id = ra.google_calendar_event_id
      left join public.google_calendars gc on gc.id = gce.google_calendar_id
      where ra.allocation_type = 'EXTERNAL_BLOCK'
        and ra.status = 'EXTERNAL_ACTIVE'
        and lower(ra.occupied_range) < p_end_at
        and upper(ra.occupied_range) > p_start_at
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function public.service_admin_get_appointment(p_appointment_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_a public.appointments%rowtype;
  v_customer public.customers%rowtype;
  v_service public.services%rowtype;
  v_employee_name text;
begin
  select * into v_a
  from public.appointments
  where id = p_appointment_id
    and deleted_at is null;

  if not found then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_NOT_FOUND';
  end if;

  select * into v_customer from public.customers where id = v_a.primary_customer_id;
  select * into v_service from public.services where id = v_a.service_id;
  select e.name into v_employee_name
  from public.service_employees se
  join public.employees e on e.id = se.employee_id
  where se.id = v_a.service_employee_id;

  return jsonb_build_object(
    'appointment', jsonb_build_object(
      'id', v_a.id,
      'public_code', v_a.public_code,
      'status', v_a.status,
      'financial_status', v_a.financial_status,
      'start_at', v_a.start_at,
      'end_at', v_a.end_at,
      'duration_minutes', v_a.duration_minutes,
      'duration_blocks', v_a.duration_blocks,
      'contracted_minutes', v_a.contracted_minutes,
      'people_count', v_a.people_count,
      'origin', v_a.origin,
      'version', v_a.version,
      'service_name', coalesce(v_a.service_name_snapshot, v_service.name),
      'service_description', coalesce(v_a.service_description_snapshot, v_service.full_description),
      'duration_mode', v_service.duration_mode,
      'buffer_before_minutes', v_service.buffer_before_minutes,
      'buffer_after_minutes', v_service.buffer_after_minutes,
      'employee_name', v_employee_name,
      'commercial_value', v_a.commercial_value,
      'base_price', v_a.base_price_snapshot,
      'variable_price_adjustment', v_a.variable_price_adjustment,
      'extras_total', v_a.extras_total,
      'coupon_discount', v_a.coupon_discount,
      'hold_expires_at', v_a.hold_expires_at,
      'confirmed_at', v_a.confirmed_at,
      'completed_at', v_a.completed_at,
      'cancelled_at', v_a.cancelled_at,
      'cancel_reason', v_a.cancel_reason,
      'attendance_status', v_a.attendance_status
    ),
    'customer', case when v_customer.id is null then null else jsonb_build_object(
      'id', v_customer.id,
      'name', v_customer.name,
      'email', v_customer.email,
      'phone', v_customer.phone,
      'cpf_cnpj', v_customer.cpf_cnpj,
      'customer_type', v_customer.customer_type
    ) end,
    'financial', public.get_appointment_financial_summary(v_a.id),
    'extras', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', ae.id,
        'extra_id', ae.extra_id,
        'name', ae.name_snapshot,
        'quantity', ae.quantity,
        'unit_price', ae.unit_price_snapshot,
        'total_price', ae.total_price,
        'duration_delta_minutes', ae.total_duration_delta
      ) order by ae.created_at, ae.id)
      from public.appointment_extras ae
      where ae.appointment_id = v_a.id
    ), '[]'::jsonb),
    'answers', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', aa.id,
        'field_key', aa.field_key_snapshot,
        'label', aa.label_snapshot,
        'value', aa.value_json
      ) order by aa.created_at, aa.id)
      from public.appointment_answers aa
      where aa.appointment_id = v_a.id
    ), '[]'::jsonb),
    'terms', coalesce((
      select jsonb_agg(jsonb_build_object(
        'terms_version_id', ata.terms_version_id,
        'name', tv.name,
        'version', tv.version,
        'accepted_at', ata.accepted_at,
        'content_snapshot', ata.content_snapshot
      ) order by ata.accepted_at, ata.id)
      from public.appointment_term_acceptances ata
      left join public.terms_versions tv on tv.id = ata.terms_version_id
      where ata.appointment_id = v_a.id
    ), '[]'::jsonb),
    'payments', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', pt.id,
        'transaction_type', pt.transaction_type,
        'method', pt.method,
        'provider', pt.provider,
        'provider_payment_id', pt.provider_payment_id,
        'status', pt.status,
        'contract_amount_settled', pt.contract_amount_settled,
        'payment_discount_amount', pt.payment_discount_amount,
        'cash_amount', pt.cash_amount,
        'paid_at', pt.paid_at,
        'notes', pt.notes,
        'created_at', pt.created_at
      ) order by pt.created_at, pt.id)
      from public.payment_transactions pt
      where pt.appointment_id = v_a.id
    ), '[]'::jsonb),
    'package_usage', (
      select jsonb_build_object(
        'hour_package_id', apu.hour_package_id,
        'package_name', hp.name,
        'required_seconds', apu.required_seconds,
        'surcharge_seconds', apu.surcharge_seconds,
        'charged_seconds', apu.charged_seconds,
        'is_special_period', apu.is_special_period,
        'cash_due', apu.cash_due,
        'reversed_at', apu.reversed_at
      )
      from public.appointment_package_usage apu
      join public.hour_packages hp on hp.id = apu.hour_package_id
      where apu.appointment_id = v_a.id
    ),
    'resources', coalesce((
      select jsonb_agg(jsonb_build_object(
        'allocation_id', ra.id,
        'resource_id', r.id,
        'resource_name', r.name,
        'resource_type', r.resource_type,
        'status', ra.status,
        'start_at', lower(ra.occupied_range),
        'end_at', upper(ra.occupied_range)
      ) order by r.name)
      from public.resource_allocations ra
      join public.resources r on r.id = ra.resource_id
      where ra.appointment_id = v_a.id
        and ra.allocation_type = 'APPOINTMENT'
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function public.service_admin_list_amelia_history(
  p_start_at timestamptz,
  p_end_at timestamptz,
  p_search text default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_search text := nullif(lower(btrim(p_search)), '');
begin
  if p_start_at is null or p_end_at is null or p_end_at <= p_start_at then
    raise exception using errcode = 'P0001', message = 'ADMIN_AMELIA_INVALID_RANGE';
  end if;

  if p_end_at - p_start_at > interval '366 days' then
    raise exception using errcode = 'P0001', message = 'ADMIN_AMELIA_RANGE_TOO_LARGE';
  end if;

  return jsonb_build_object(
    'records', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', lab.id,
        'amelia_booking_id', lab.amelia_booking_id,
        'woocommerce_order_id', lab.woocommerce_order_id,
        'customer_name', lab.customer_name,
        'customer_email', lab.customer_email,
        'customer_phone', lab.customer_phone,
        'cpf_cnpj', lab.cpf_cnpj,
        'service_name', lab.service_name,
        'employee_name', lab.employee_name,
        'start_at', lab.start_at,
        'end_at', lab.end_at,
        'declared_duration_minutes', lab.declared_duration_minutes,
        'status_raw', lab.status_raw,
        'amelia_price_amount', lab.amelia_price_amount,
        'payment_status_raw', lab.payment_status_raw,
        'payment_method_raw', lab.payment_method_raw,
        'extras', lab.extras_json,
        'custom_fields', lab.custom_fields_json,
        'notes', lab.notes,
        'record_mode', lab.record_mode,
        'operational_authority', lab.operational_authority,
        'last_imported_at', lab.last_imported_at
      ) order by lab.start_at desc nulls last, lab.amelia_booking_id)
      from (
        select *
        from public.legacy_amelia_bookings x
        where x.start_at is not null
          and x.start_at >= p_start_at
          and x.start_at < p_end_at
          and (
            v_search is null
            or lower(coalesce(x.customer_name,'')) like '%' || v_search || '%'
            or lower(coalesce(x.customer_email,'')) like '%' || v_search || '%'
            or regexp_replace(coalesce(x.customer_phone,''), '\D', '', 'g') like '%' || regexp_replace(v_search, '\D', '', 'g') || '%'
            or lower(coalesce(x.service_name,'')) like '%' || v_search || '%'
            or lower(x.amelia_booking_id) like '%' || v_search || '%'
          )
        order by x.start_at desc
        limit 500
      ) lab
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.service_admin_list_agenda(timestamptz,timestamptz) from public, anon, authenticated;
revoke all on function public.service_admin_get_appointment(uuid) from public, anon, authenticated;
revoke all on function public.service_admin_list_amelia_history(timestamptz,timestamptz,text) from public, anon, authenticated;

grant execute on function public.service_admin_list_agenda(timestamptz,timestamptz) to service_role;
grant execute on function public.service_admin_get_appointment(uuid) to service_role;
grant execute on function public.service_admin_list_amelia_history(timestamptz,timestamptz,text) to service_role;

comment on function public.service_admin_list_agenda(timestamptz,timestamptz) is
  'Operational admin agenda: native appointments and active external blocks only. Amelia history is intentionally excluded.';
comment on function public.service_admin_list_amelia_history(timestamptz,timestamptz,text) is
  'Read-only Amelia legacy history. These rows are never operational appointments.';
-- END RC MIGRATION 20260821209000_admin_agenda_read_model.sql

-- BEGIN RC MIGRATION 20260821210000_progressive_duration_pricing.sql
-- Progressive duration pricing for block-based services.
-- Pricing tiers are deliberately separate from editorial duration presets:
-- tiers control money; presets guide the customer toward useful durations.

create table public.service_duration_pricing_tiers (
  id uuid primary key default gen_random_uuid(),
  service_id uuid not null references public.services(id) on delete cascade,
  min_blocks integer not null check (min_blocks > 0),
  max_blocks integer check (max_blocks is null or max_blocks >= min_blocks),
  price_per_block numeric(12,2) not null check (price_per_block >= 0),
  is_active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index service_duration_pricing_tiers_service_idx
  on public.service_duration_pricing_tiers(service_id, is_active, min_blocks, max_blocks);

create table public.service_duration_presets (
  id uuid primary key default gen_random_uuid(),
  service_id uuid not null references public.services(id) on delete cascade,
  block_count integer not null check (block_count > 0),
  title text not null check (btrim(title) <> ''),
  description text,
  badge text,
  is_featured boolean not null default false,
  is_active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(service_id, block_count)
);

create index service_duration_presets_service_idx
  on public.service_duration_presets(service_id, is_active, sort_order, block_count);

alter table public.service_duration_pricing_tiers enable row level security;
alter table public.service_duration_presets enable row level security;
revoke all on public.service_duration_pricing_tiers from public, anon, authenticated;
revoke all on public.service_duration_presets from public, anon, authenticated;

create or replace function public.prevent_duration_pricing_overlap()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.is_active and exists (
    select 1
    from public.service_duration_pricing_tiers t
    where t.service_id = new.service_id
      and t.is_active
      and t.id <> new.id
      and int4range(t.min_blocks, coalesce(t.max_blocks, 2147483646) + 1, '[)')
          && int4range(new.min_blocks, coalesce(new.max_blocks, 2147483646) + 1, '[)')
  ) then
    raise exception using errcode = 'P0001', message = 'DURATION_PRICING_TIER_OVERLAP';
  end if;
  new.updated_at := now();
  return new;
end;
$$;

create trigger service_duration_pricing_tiers_no_overlap
before insert or update on public.service_duration_pricing_tiers
for each row execute function public.prevent_duration_pricing_overlap();

create or replace function public.touch_duration_preset_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger service_duration_presets_touch
before update on public.service_duration_presets
for each row execute function public.touch_duration_preset_updated_at();

create or replace function public.resolve_service_duration_pricing(
  p_service_id uuid,
  p_duration_blocks integer
)
returns jsonb
language plpgsql
stable
set search_path = public
as $$
declare
  v_service public.services%rowtype;
  v_tier public.service_duration_pricing_tiers%rowtype;
  v_matches integer;
begin
  select * into v_service
  from public.services
  where id = p_service_id and is_active;

  if not found then
    raise exception using errcode = 'P0001', message = 'SERVICE_NOT_AVAILABLE';
  end if;

  if v_service.duration_mode <> 'BLOCKS' then
    raise exception using errcode = 'P0001', message = 'DURATION_PRICING_NOT_ALLOWED';
  end if;

  perform public.resolve_service_contracted_minutes(p_service_id, p_duration_blocks);

  select count(*) into v_matches
  from public.service_duration_pricing_tiers t
  where t.service_id = p_service_id
    and t.is_active
    and p_duration_blocks >= t.min_blocks
    and (t.max_blocks is null or p_duration_blocks <= t.max_blocks);

  if v_matches > 1 then
    raise exception using errcode = 'P0001', message = 'DURATION_PRICING_TIER_OVERLAP';
  end if;

  select * into v_tier
  from public.service_duration_pricing_tiers t
  where t.service_id = p_service_id
    and t.is_active
    and p_duration_blocks >= t.min_blocks
    and (t.max_blocks is null or p_duration_blocks <= t.max_blocks)
  order by t.min_blocks desc, t.sort_order, t.id
  limit 1;

  if found then
    return jsonb_build_object(
      'source', 'TIER',
      'tier_id', v_tier.id,
      'min_blocks', v_tier.min_blocks,
      'max_blocks', v_tier.max_blocks,
      'unit_price', v_tier.price_per_block,
      'base_price', round(v_tier.price_per_block * p_duration_blocks, 2)
    );
  end if;

  if v_service.price_per_block is null then
    raise exception using errcode = 'P0001', message = 'DURATION_PRICING_NOT_CONFIGURED';
  end if;

  return jsonb_build_object(
    'source', 'SERVICE_FALLBACK',
    'tier_id', null,
    'min_blocks', null,
    'max_blocks', null,
    'unit_price', v_service.price_per_block,
    'base_price', round(v_service.price_per_block * p_duration_blocks, 2)
  );
end;
$$;

create or replace function public.calculate_booking_quote_for_duration(
  p_service_id uuid,
  p_service_employee_id uuid,
  p_duration_blocks integer default null,
  p_extra_selections jsonb default '[]'::jsonb,
  p_people_count integer default 1,
  p_requested_start_at timestamptz default null,
  p_coupon_code text default null
)
returns jsonb
language plpgsql
stable
set search_path = public, extensions
as $$
declare
  v_service public.services%rowtype;
  v_timezone text;
  v_price numeric := 0;
  v_dynamic_base numeric := 0;
  v_after_day_time numeric := 0;
  v_after_people numeric := 0;
  v_day_time_adjustment numeric := 0;
  v_people_adjustment numeric := 0;
  v_extras_total numeric := 0;
  v_subtotal numeric := 0;
  v_coupon_discount numeric := 0;
  v_commercial_value numeric := 0;
  v_coupon public.coupons%rowtype;
  v_local_ts timestamp without time zone;
  v_local_date date;
  v_local_time time without time zone;
  v_dow smallint;
  v_processed_extras integer := 0;
  v_requested_extras integer := 0;
  v_resource_ids uuid[] := '{}'::uuid[];
  v_contracted_minutes integer;
  v_profile jsonb;
  v_pre integer := 0;
  v_post integer := 0;
  v_pricing_version text;
  v_duration_pricing jsonb;
  v_unit_price numeric := 0;
  r record;
begin
  select * into v_service
  from public.services
  where id = p_service_id and is_active;

  if not found then
    raise exception using errcode = 'P0001', message = 'SERVICE_NOT_AVAILABLE';
  end if;

  if not exists (
    select 1 from public.service_employees se
    where se.id = p_service_employee_id
      and se.service_id = p_service_id
      and se.is_active
  ) then
    raise exception using errcode = 'P0001', message = 'EMPLOYEE_NOT_AVAILABLE_FOR_SERVICE';
  end if;

  v_contracted_minutes := public.resolve_service_contracted_minutes(p_service_id, p_duration_blocks);

  if v_service.duration_mode = 'FIXED' then
    return public.calculate_booking_quote(
      p_service_id,
      p_service_employee_id,
      p_extra_selections,
      p_people_count,
      p_requested_start_at,
      p_coupon_code
    ) || jsonb_build_object(
      'duration_mode', 'FIXED',
      'duration_blocks', null,
      'contracted_minutes', v_contracted_minutes,
      'buffer_before_minutes', v_service.buffer_before_minutes,
      'buffer_after_minutes', v_service.buffer_after_minutes
    );
  end if;

  if p_people_count < v_service.minimum_people or p_people_count > v_service.maximum_people then
    raise exception using errcode = 'P0001', message = 'INVALID_PEOPLE_COUNT';
  end if;

  if jsonb_typeof(coalesce(p_extra_selections, '[]'::jsonb)) <> 'array' then
    raise exception using errcode = 'P0001', message = 'INVALID_EXTRA';
  end if;

  select count(*) into v_requested_extras
  from jsonb_array_elements(coalesce(p_extra_selections, '[]'::jsonb));

  if exists (
    select 1
    from jsonb_to_recordset(coalesce(p_extra_selections, '[]'::jsonb)) x(extra_id uuid, quantity integer)
    group by x.extra_id having count(*) > 1
  ) then
    raise exception using errcode = 'P0001', message = 'INVALID_EXTRA';
  end if;

  v_duration_pricing := public.resolve_service_duration_pricing(p_service_id, p_duration_blocks);
  v_unit_price := (v_duration_pricing->>'unit_price')::numeric;
  v_dynamic_base := (v_duration_pricing->>'base_price')::numeric;
  v_price := v_dynamic_base;

  for r in
    select e.id, e.price, x.quantity, se.max_quantity
    from jsonb_to_recordset(coalesce(p_extra_selections, '[]'::jsonb)) x(extra_id uuid, quantity integer)
    join public.service_extras se on se.service_id = p_service_id and se.extra_id = x.extra_id
    join public.extras e on e.id = x.extra_id and e.is_active
  loop
    if r.quantity is null or r.quantity < 1 or r.quantity > r.max_quantity then
      raise exception using errcode = 'P0001', message = 'INVALID_EXTRA_QUANTITY';
    end if;
    v_processed_extras := v_processed_extras + 1;
    v_extras_total := v_extras_total + (r.price * r.quantity);
  end loop;

  if v_processed_extras <> v_requested_extras then
    raise exception using errcode = 'P0001', message = 'INVALID_EXTRA';
  end if;

  select timezone into v_timezone from public.operation_settings where id = 1;

  if p_requested_start_at is not null then
    v_local_ts := p_requested_start_at at time zone v_timezone;
    v_local_date := v_local_ts::date;
    v_local_time := v_local_ts::time;
    v_dow := extract(dow from v_local_ts)::smallint;

    for r in
      select pr.*
      from public.pricing_rules pr
      where pr.service_id = p_service_id
        and pr.is_active
        and pr.rule_scope = 'DAY_TIME'
        and (pr.valid_from_date is null or v_local_date >= pr.valid_from_date)
        and (pr.valid_until_date is null or v_local_date <= pr.valid_until_date)
        and (pr.days_of_week is null or v_dow = any(pr.days_of_week))
        and (pr.start_local_time is null or v_local_time >= pr.start_local_time)
        and (pr.end_local_time is null or v_local_time < pr.end_local_time)
      order by pr.priority, pr.id
    loop
      if r.action_type = 'REPLACE_PRICE' then
        v_price := r.amount;
      elsif r.action_type = 'ADD_AMOUNT' then
        v_price := v_price + r.amount;
      elsif r.action_type = 'ADD_PERCENT' then
        v_price := v_price * (1 + (r.percentage / 100));
      end if;
    end loop;
  end if;

  v_after_day_time := round(greatest(v_price, 0), 2);
  v_day_time_adjustment := v_after_day_time - v_dynamic_base;
  v_price := v_after_day_time;

  for r in
    select pr.*
    from public.pricing_rules pr
    where pr.service_id = p_service_id
      and pr.is_active
      and pr.rule_scope = 'PEOPLE'
      and p_people_count between pr.min_people and pr.max_people
      and (pr.valid_from_date is null or coalesce(v_local_date, current_date) >= pr.valid_from_date)
      and (pr.valid_until_date is null or coalesce(v_local_date, current_date) <= pr.valid_until_date)
    order by pr.priority, pr.id
  loop
    if r.action_type = 'REPLACE_PRICE' then
      v_price := r.amount;
    elsif r.action_type = 'ADD_AMOUNT' then
      v_price := v_price + r.amount;
    elsif r.action_type = 'ADD_PERCENT' then
      v_price := v_price * (1 + (r.percentage / 100));
    end if;
  end loop;

  v_after_people := round(greatest(v_price, 0), 2);
  v_people_adjustment := v_after_people - v_after_day_time;
  v_extras_total := round(v_extras_total, 2);
  v_subtotal := round(greatest(v_after_people + v_extras_total, 0), 2);

  if p_coupon_code is not null and btrim(p_coupon_code) <> '' then
    select c.* into v_coupon
    from public.coupons c
    where lower(c.code) = lower(btrim(p_coupon_code))
      and c.is_active
      and (c.valid_from is null or coalesce(p_requested_start_at, now()) >= c.valid_from)
      and (c.valid_until is null or coalesce(p_requested_start_at, now()) <= c.valid_until)
      and (
        not exists (select 1 from public.coupon_services cs where cs.coupon_id = c.id)
        or exists (select 1 from public.coupon_services cs where cs.coupon_id = c.id and cs.service_id = p_service_id)
      )
    limit 1;

    if not found then
      raise exception using errcode = 'P0001', message = 'INVALID_COUPON';
    end if;

    if v_coupon.discount_type = 'FIXED' then
      v_coupon_discount := least(v_coupon.discount_value, v_subtotal);
    else
      v_coupon_discount := round(v_subtotal * (v_coupon.discount_value / 100), 2);
    end if;
  end if;

  v_coupon_discount := round(v_coupon_discount, 2);
  v_commercial_value := round(greatest(v_subtotal - v_coupon_discount, 0), 2);

  select coalesce(array_agg(distinct resource_id order by resource_id), '{}'::uuid[])
  into v_resource_ids
  from (
    select sr.resource_id
    from public.service_resources sr
    where sr.service_id = p_service_id and sr.is_required
    union
    select er.resource_id
    from jsonb_to_recordset(coalesce(p_extra_selections, '[]'::jsonb)) x(extra_id uuid, quantity integer)
    join public.extra_resources er on er.extra_id = x.extra_id and er.is_required
  ) q;

  v_profile := public.resolve_extra_schedule_profile(p_service_id, p_extra_selections, p_requested_start_at);
  v_pre := coalesce((v_profile->>'pre_service_minutes')::integer, 0);
  v_post := coalesce((v_profile->>'post_service_minutes')::integer, 0);

  select md5(concat_ws('|',
    v_service.updated_at::text,
    p_duration_blocks::text,
    v_dynamic_base::text,
    coalesce((select max(updated_at)::text from public.service_duration_pricing_tiers where service_id = p_service_id), ''),
    coalesce((select max(updated_at)::text from public.pricing_rules where service_id = p_service_id), ''),
    coalesce((select max(e.updated_at)::text
      from jsonb_to_recordset(coalesce(p_extra_selections, '[]'::jsonb)) x(extra_id uuid, quantity integer)
      join public.extras e on e.id = x.extra_id), ''),
    coalesce(v_coupon.updated_at::text, ''),
    coalesce(v_profile->>'schedule_version', '')
  )) into v_pricing_version;

  return jsonb_build_object(
    'service_id', p_service_id,
    'service_employee_id', p_service_employee_id,
    'duration_mode', 'BLOCKS',
    'duration_blocks', p_duration_blocks,
    'booking_block_minutes', v_service.booking_block_minutes,
    'contracted_minutes', v_contracted_minutes,
    'core_duration_minutes', v_contracted_minutes,
    'pre_service_minutes', v_pre,
    'post_service_minutes', v_post,
    'duration_minutes', v_contracted_minutes + v_pre + v_post,
    'buffer_before_minutes', v_service.buffer_before_minutes,
    'buffer_after_minutes', v_service.buffer_after_minutes,
    'resource_ids', to_jsonb(v_resource_ids),
    'base_price', v_dynamic_base,
    'duration_unit_price', v_unit_price,
    'duration_pricing_source', v_duration_pricing->>'source',
    'duration_pricing_tier_id', v_duration_pricing->'tier_id',
    'day_time_adjustment', round(v_day_time_adjustment, 2),
    'people_adjustment', round(v_people_adjustment, 2),
    'extras_total', v_extras_total,
    'coupon_discount', v_coupon_discount,
    'commercial_value', v_commercial_value,
    'schedule_profile', v_profile,
    'pricing_version', v_pricing_version
  );
end;
$$;

-- Public catalog exposes active pricing tiers and recommendation presets as read-only
-- data. The authoritative quote still comes from calculate_booking_quote_for_duration.
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

revoke all on function public.resolve_service_duration_pricing(uuid,integer) from public, anon, authenticated;
grant execute on function public.resolve_service_duration_pricing(uuid,integer) to service_role;

comment on table public.service_duration_pricing_tiers is
  'Authoritative block-duration pricing ranges. No overlap is allowed per active service.';
comment on table public.service_duration_presets is
  'Editorial duration shortcuts such as 1h/2h/4h/8h. They do not determine price.';
-- END RC MIGRATION 20260821210000_progressive_duration_pricing.sql

-- BEGIN RC MIGRATION 20260821211000_admin_service_settings.sql
-- Administrative service settings. These RPCs are service-role only and are
-- intended to be called after the Edge Function authenticates an admin user.

create or replace function public.service_admin_list_service_settings()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
select coalesce(jsonb_agg(jsonb_build_object(
  'id', s.id,
  'name', s.name,
  'slug', s.slug,
  'category', c.name,
  'is_active', s.is_active,
  'duration_mode', s.duration_mode,
  'base_duration_minutes', s.base_duration_minutes,
  'booking_block_minutes', s.booking_block_minutes,
  'minimum_booking_blocks', s.minimum_booking_blocks,
  'maximum_booking_blocks', s.maximum_booking_blocks,
  'price_per_block', s.price_per_block,
  'base_price', s.base_price,
  'buffer_before_minutes', s.buffer_before_minutes,
  'buffer_after_minutes', s.buffer_after_minutes,
  'pricing_tiers', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', t.id,
      'min_blocks', t.min_blocks,
      'max_blocks', t.max_blocks,
      'price_per_block', t.price_per_block,
      'is_active', t.is_active,
      'sort_order', t.sort_order
    ) order by t.sort_order, t.min_blocks, t.id)
    from public.service_duration_pricing_tiers t
    where t.service_id = s.id
  ), '[]'::jsonb),
  'duration_presets', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', p.id,
      'block_count', p.block_count,
      'title', p.title,
      'description', p.description,
      'badge', p.badge,
      'is_featured', p.is_featured,
      'is_active', p.is_active,
      'sort_order', p.sort_order
    ) order by p.sort_order, p.block_count, p.id)
    from public.service_duration_presets p
    where p.service_id = s.id
  ), '[]'::jsonb),
  'change_policy', (
    select to_jsonb(cp) - 'service_id' - 'created_at' - 'updated_at'
    from public.service_change_policies cp
    where cp.service_id = s.id
  )
) order by c.sort_order, s.sort_order, s.name), '[]'::jsonb)
from public.services s
left join public.categories c on c.id = s.category_id;
$$;

create or replace function public.service_admin_update_timing(
  p_service_id uuid,
  p_duration_mode text,
  p_base_duration_minutes integer,
  p_booking_block_minutes integer,
  p_minimum_booking_blocks integer,
  p_maximum_booking_blocks integer,
  p_base_price numeric,
  p_price_per_block numeric,
  p_buffer_before_minutes integer,
  p_buffer_after_minutes integer
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_service public.services%rowtype;
begin
  select * into v_service from public.services where id = p_service_id for update;
  if not found then
    raise exception using errcode = 'P0001', message = 'SERVICE_NOT_FOUND';
  end if;

  if p_duration_mode not in ('FIXED','BLOCKS') then
    raise exception using errcode = 'P0001', message = 'INVALID_DURATION_MODE';
  end if;
  if coalesce(p_base_duration_minutes, 0) <= 0 then
    raise exception using errcode = 'P0001', message = 'INVALID_BASE_DURATION';
  end if;
  if coalesce(p_buffer_before_minutes, -1) < 0 or coalesce(p_buffer_after_minutes, -1) < 0 then
    raise exception using errcode = 'P0001', message = 'INVALID_BUFFER';
  end if;
  if coalesce(p_base_price, -1) < 0 then
    raise exception using errcode = 'P0001', message = 'INVALID_BASE_PRICE';
  end if;

  if p_duration_mode = 'BLOCKS' then
    if coalesce(p_booking_block_minutes, 0) <= 0
      or coalesce(p_minimum_booking_blocks, 0) <= 0
      or coalesce(p_maximum_booking_blocks, 0) < p_minimum_booking_blocks
      or coalesce(p_price_per_block, -1) < 0 then
      raise exception using errcode = 'P0001', message = 'INVALID_BLOCK_DURATION_CONFIG';
    end if;
  end if;

  update public.services
  set duration_mode = p_duration_mode,
      base_duration_minutes = p_base_duration_minutes,
      booking_block_minutes = case when p_duration_mode = 'BLOCKS' then p_booking_block_minutes else null end,
      minimum_booking_blocks = case when p_duration_mode = 'BLOCKS' then p_minimum_booking_blocks else null end,
      maximum_booking_blocks = case when p_duration_mode = 'BLOCKS' then p_maximum_booking_blocks else null end,
      price_per_block = case when p_duration_mode = 'BLOCKS' then p_price_per_block else null end,
      base_price = p_base_price,
      buffer_before_minutes = p_buffer_before_minutes,
      buffer_after_minutes = p_buffer_after_minutes,
      updated_at = now()
  where id = p_service_id;

  return jsonb_build_object(
    'service_id', p_service_id,
    'duration_mode', p_duration_mode,
    'base_duration_minutes', p_base_duration_minutes,
    'booking_block_minutes', case when p_duration_mode = 'BLOCKS' then p_booking_block_minutes else null end,
    'minimum_booking_blocks', case when p_duration_mode = 'BLOCKS' then p_minimum_booking_blocks else null end,
    'maximum_booking_blocks', case when p_duration_mode = 'BLOCKS' then p_maximum_booking_blocks else null end,
    'price_per_block', case when p_duration_mode = 'BLOCKS' then p_price_per_block else null end,
    'base_price', p_base_price,
    'buffer_before_minutes', p_buffer_before_minutes,
    'buffer_after_minutes', p_buffer_after_minutes
  );
end;
$$;

create or replace function public.service_admin_replace_duration_configuration(
  p_service_id uuid,
  p_pricing_tiers jsonb default '[]'::jsonb,
  p_duration_presets jsonb default '[]'::jsonb
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_service public.services%rowtype;
  v_tier jsonb;
  v_preset jsonb;
  v_count integer := 0;
begin
  select * into v_service from public.services where id = p_service_id for update;
  if not found then
    raise exception using errcode = 'P0001', message = 'SERVICE_NOT_FOUND';
  end if;
  if v_service.duration_mode <> 'BLOCKS' then
    raise exception using errcode = 'P0001', message = 'DURATION_CONFIGURATION_REQUIRES_BLOCKS';
  end if;
  if jsonb_typeof(coalesce(p_pricing_tiers, '[]'::jsonb)) <> 'array'
     or jsonb_typeof(coalesce(p_duration_presets, '[]'::jsonb)) <> 'array' then
    raise exception using errcode = 'P0001', message = 'INVALID_DURATION_CONFIGURATION';
  end if;

  delete from public.service_duration_pricing_tiers where service_id = p_service_id;

  for v_tier in select value from jsonb_array_elements(coalesce(p_pricing_tiers, '[]'::jsonb)) loop
    if coalesce((v_tier->>'min_blocks')::integer, 0) <= 0
      or (v_tier ? 'max_blocks' and v_tier->>'max_blocks' is not null
          and (v_tier->>'max_blocks')::integer < (v_tier->>'min_blocks')::integer)
      or coalesce((v_tier->>'price_per_block')::numeric, -1) < 0 then
      raise exception using errcode = 'P0001', message = 'INVALID_DURATION_PRICING_TIER';
    end if;

    insert into public.service_duration_pricing_tiers(
      service_id, min_blocks, max_blocks, price_per_block, is_active, sort_order
    ) values (
      p_service_id,
      (v_tier->>'min_blocks')::integer,
      case when v_tier->>'max_blocks' is null then null else (v_tier->>'max_blocks')::integer end,
      (v_tier->>'price_per_block')::numeric,
      coalesce((v_tier->>'is_active')::boolean, true),
      coalesce((v_tier->>'sort_order')::integer, v_count * 10)
    );
    v_count := v_count + 1;
  end loop;

  delete from public.service_duration_presets where service_id = p_service_id;
  v_count := 0;

  for v_preset in select value from jsonb_array_elements(coalesce(p_duration_presets, '[]'::jsonb)) loop
    if coalesce((v_preset->>'block_count')::integer, 0) <= 0
      or nullif(btrim(v_preset->>'title'), '') is null then
      raise exception using errcode = 'P0001', message = 'INVALID_DURATION_PRESET';
    end if;
    if (v_preset->>'block_count')::integer < v_service.minimum_booking_blocks
      or (v_preset->>'block_count')::integer > v_service.maximum_booking_blocks then
      raise exception using errcode = 'P0001', message = 'DURATION_PRESET_OUT_OF_RANGE';
    end if;

    insert into public.service_duration_presets(
      service_id, block_count, title, description, badge, is_featured, is_active, sort_order
    ) values (
      p_service_id,
      (v_preset->>'block_count')::integer,
      btrim(v_preset->>'title'),
      nullif(btrim(v_preset->>'description'), ''),
      nullif(btrim(v_preset->>'badge'), ''),
      coalesce((v_preset->>'is_featured')::boolean, false),
      coalesce((v_preset->>'is_active')::boolean, true),
      coalesce((v_preset->>'sort_order')::integer, v_count * 10)
    );
    v_count := v_count + 1;
  end loop;

  return jsonb_build_object(
    'service_id', p_service_id,
    'pricing_tiers', coalesce((
      select jsonb_agg(to_jsonb(t) - 'service_id' - 'created_at' - 'updated_at' order by t.sort_order, t.min_blocks, t.id)
      from public.service_duration_pricing_tiers t where t.service_id = p_service_id
    ), '[]'::jsonb),
    'duration_presets', coalesce((
      select jsonb_agg(to_jsonb(p) - 'service_id' - 'created_at' - 'updated_at' order by p.sort_order, p.block_count, p.id)
      from public.service_duration_presets p where p.service_id = p_service_id
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.service_admin_list_service_settings() from public, anon, authenticated;
revoke all on function public.service_admin_update_timing(uuid,text,integer,integer,integer,integer,numeric,numeric,integer,integer) from public, anon, authenticated;
revoke all on function public.service_admin_replace_duration_configuration(uuid,jsonb,jsonb) from public, anon, authenticated;

grant execute on function public.service_admin_list_service_settings() to service_role;
grant execute on function public.service_admin_update_timing(uuid,text,integer,integer,integer,integer,numeric,numeric,integer,integer) to service_role;
grant execute on function public.service_admin_replace_duration_configuration(uuid,jsonb,jsonb) to service_role;
-- END RC MIGRATION 20260821211000_admin_service_settings.sql

-- BEGIN RC MIGRATION 20260821212000_admin_change_policies.sql
-- Administrative mutation for per-service reschedule/cancellation policy.
-- The Edge Function authenticates admin users before calling this service-role RPC.

create or replace function public.service_admin_upsert_change_policy(
  p_service_id uuid,
  p_policy jsonb
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_current public.service_change_policies%rowtype;
  v_result public.service_change_policies%rowtype;
  v_notice_hours integer;
  v_reschedule_first_type public.change_penalty_type;
  v_reschedule_first_value numeric(12,2);
  v_reschedule_repeat_type public.change_penalty_type;
  v_reschedule_repeat_value numeric(12,2);
  v_reschedule_late_type public.change_penalty_type;
  v_reschedule_late_value numeric(12,2);
  v_cancel_early_type public.change_penalty_type;
  v_cancel_early_value numeric(12,2);
  v_cancel_late_type public.change_penalty_type;
  v_cancel_late_value numeric(12,2);
  v_early_refund boolean;
  v_early_credit boolean;
  v_late_refund boolean;
  v_late_credit boolean;
  v_credit_days integer;
begin
  if not exists (select 1 from public.services where id = p_service_id) then
    raise exception using errcode = 'P0001', message = 'SERVICE_NOT_FOUND';
  end if;

  if p_policy is null or jsonb_typeof(p_policy) <> 'object' then
    raise exception using errcode = 'P0001', message = 'INVALID_CHANGE_POLICY';
  end if;

  select * into v_current
  from public.service_change_policies
  where service_id = p_service_id;

  v_notice_hours := coalesce((p_policy->>'notice_hours')::integer, v_current.notice_hours, 48);

  v_reschedule_first_type := coalesce(
    nullif(p_policy->>'reschedule_first_penalty_type', '')::public.change_penalty_type,
    v_current.reschedule_first_penalty_type,
    'NONE'::public.change_penalty_type
  );
  v_reschedule_first_value := coalesce((p_policy->>'reschedule_first_penalty_value')::numeric, v_current.reschedule_first_penalty_value, 0);

  v_reschedule_repeat_type := coalesce(
    nullif(p_policy->>'reschedule_repeat_penalty_type', '')::public.change_penalty_type,
    v_current.reschedule_repeat_penalty_type,
    'PERCENT'::public.change_penalty_type
  );
  v_reschedule_repeat_value := coalesce((p_policy->>'reschedule_repeat_penalty_value')::numeric, v_current.reschedule_repeat_penalty_value, 20);

  v_reschedule_late_type := coalesce(
    nullif(p_policy->>'reschedule_late_penalty_type', '')::public.change_penalty_type,
    v_current.reschedule_late_penalty_type,
    'PERCENT'::public.change_penalty_type
  );
  v_reschedule_late_value := coalesce((p_policy->>'reschedule_late_penalty_value')::numeric, v_current.reschedule_late_penalty_value, 20);

  v_cancel_early_type := coalesce(
    nullif(p_policy->>'cancellation_early_penalty_type', '')::public.change_penalty_type,
    v_current.cancellation_early_penalty_type,
    'NONE'::public.change_penalty_type
  );
  v_cancel_early_value := coalesce((p_policy->>'cancellation_early_penalty_value')::numeric, v_current.cancellation_early_penalty_value, 0);

  v_cancel_late_type := coalesce(
    nullif(p_policy->>'cancellation_late_penalty_type', '')::public.change_penalty_type,
    v_current.cancellation_late_penalty_type,
    'PERCENT'::public.change_penalty_type
  );
  v_cancel_late_value := coalesce((p_policy->>'cancellation_late_penalty_value')::numeric, v_current.cancellation_late_penalty_value, 20);

  v_early_refund := coalesce((p_policy->>'cancellation_early_refund_allowed')::boolean, v_current.cancellation_early_refund_allowed, true);
  v_early_credit := coalesce((p_policy->>'cancellation_early_credit_allowed')::boolean, v_current.cancellation_early_credit_allowed, true);
  v_late_refund := coalesce((p_policy->>'cancellation_late_refund_allowed')::boolean, v_current.cancellation_late_refund_allowed, true);
  v_late_credit := coalesce((p_policy->>'cancellation_late_credit_allowed')::boolean, v_current.cancellation_late_credit_allowed, true);
  v_credit_days := coalesce((p_policy->>'cancellation_credit_validity_days')::integer, v_current.cancellation_credit_validity_days, 90);

  if v_notice_hours < 0 or v_credit_days <= 0 then
    raise exception using errcode = 'P0001', message = 'INVALID_CHANGE_POLICY';
  end if;

  insert into public.service_change_policies(
    service_id,
    notice_hours,
    reschedule_first_penalty_type,
    reschedule_first_penalty_value,
    reschedule_repeat_penalty_type,
    reschedule_repeat_penalty_value,
    reschedule_late_penalty_type,
    reschedule_late_penalty_value,
    cancellation_early_penalty_type,
    cancellation_early_penalty_value,
    cancellation_late_penalty_type,
    cancellation_late_penalty_value,
    cancellation_early_refund_allowed,
    cancellation_early_credit_allowed,
    cancellation_late_refund_allowed,
    cancellation_late_credit_allowed,
    cancellation_credit_validity_days
  ) values (
    p_service_id,
    v_notice_hours,
    v_reschedule_first_type,
    v_reschedule_first_value,
    v_reschedule_repeat_type,
    v_reschedule_repeat_value,
    v_reschedule_late_type,
    v_reschedule_late_value,
    v_cancel_early_type,
    v_cancel_early_value,
    v_cancel_late_type,
    v_cancel_late_value,
    v_early_refund,
    v_early_credit,
    v_late_refund,
    v_late_credit,
    v_credit_days
  )
  on conflict (service_id) do update
  set notice_hours = excluded.notice_hours,
      reschedule_first_penalty_type = excluded.reschedule_first_penalty_type,
      reschedule_first_penalty_value = excluded.reschedule_first_penalty_value,
      reschedule_repeat_penalty_type = excluded.reschedule_repeat_penalty_type,
      reschedule_repeat_penalty_value = excluded.reschedule_repeat_penalty_value,
      reschedule_late_penalty_type = excluded.reschedule_late_penalty_type,
      reschedule_late_penalty_value = excluded.reschedule_late_penalty_value,
      cancellation_early_penalty_type = excluded.cancellation_early_penalty_type,
      cancellation_early_penalty_value = excluded.cancellation_early_penalty_value,
      cancellation_late_penalty_type = excluded.cancellation_late_penalty_type,
      cancellation_late_penalty_value = excluded.cancellation_late_penalty_value,
      cancellation_early_refund_allowed = excluded.cancellation_early_refund_allowed,
      cancellation_early_credit_allowed = excluded.cancellation_early_credit_allowed,
      cancellation_late_refund_allowed = excluded.cancellation_late_refund_allowed,
      cancellation_late_credit_allowed = excluded.cancellation_late_credit_allowed,
      cancellation_credit_validity_days = excluded.cancellation_credit_validity_days,
      updated_at = now()
  returning * into v_result;

  return to_jsonb(v_result) - 'service_id' - 'created_at' - 'updated_at';
exception
  when invalid_text_representation or numeric_value_out_of_range then
    raise exception using errcode = 'P0001', message = 'INVALID_CHANGE_POLICY';
end;
$$;

revoke all on function public.service_admin_upsert_change_policy(uuid,jsonb) from public, anon, authenticated;
grant execute on function public.service_admin_upsert_change_policy(uuid,jsonb) to service_role;

comment on function public.service_admin_upsert_change_policy(uuid,jsonb) is
  'Admin-only per-service reschedule/cancellation policy mutation. Table constraints remain authoritative for penalty shapes.';
-- END RC MIGRATION 20260821212000_admin_change_policies.sql
