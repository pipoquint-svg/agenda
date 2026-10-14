begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(65);

-- ---------------------------------------------------------------------------
-- Fixture
-- ---------------------------------------------------------------------------

insert into public.resources (id, name, resource_type) values
  ('96900000-0000-0000-0000-000000000001', 'S05 FIXED STUDIO', 'PHYSICAL'),
  ('96900000-0000-0000-0000-000000000002', 'S05 BLOCKS STUDIO', 'PHYSICAL');

insert into public.employees (id, name)
values ('96900000-0000-0000-0000-000000000003', 'S05 Employee');

insert into public.categories (id, name, slug)
values ('96900000-0000-0000-0000-000000000004', 'S05 Coupons', 's05-coupon-lifecycle');

insert into public.services (
  id, category_id, name, slug, base_duration_minutes, base_price,
  buffer_before_minutes, buffer_after_minutes, minimum_people, maximum_people,
  minimum_booking_notice_minutes, maximum_booking_horizon_days, requires_terms,
  duration_mode, booking_block_minutes, minimum_booking_blocks, maximum_booking_blocks, price_per_block,
  service_type_id
) values
  ('96900000-0000-0000-0000-000000000010', '96900000-0000-0000-0000-000000000004',
   'S05 Fixed rental', 's05-fixed-rental', 60, 100, 0, 0, 1, 10, 0, 5000, false,
   'FIXED', null, null, null, null,
   (select id from public.service_type where key = 'LOCACAO')),
  ('96900000-0000-0000-0000-000000000011', '96900000-0000-0000-0000-000000000004',
   'S05 Blocks rental', 's05-blocks-rental', 30, 80, 0, 0, 1, 10, 0, 5000, false,
   'BLOCKS', 30, 8, 16, 80,
   (select id from public.service_type where key = 'LOCACAO'));

insert into public.service_change_policies (
  service_id, notice_hours, reschedule_first_early_percent,
  reschedule_first_late_percent, reschedule_repeat_percent, cancellation_late_percent
) values
  ('96900000-0000-0000-0000-000000000010', 0, 0, 0, 0, 0),
  ('96900000-0000-0000-0000-000000000011', 0, 0, 0, 0, 0);

insert into public.service_employees (id, service_id, employee_id) values
  ('96900000-0000-0000-0000-000000000020', '96900000-0000-0000-0000-000000000010', '96900000-0000-0000-0000-000000000003'),
  ('96900000-0000-0000-0000-000000000021', '96900000-0000-0000-0000-000000000011', '96900000-0000-0000-0000-000000000003');

insert into public.service_resources (service_id, resource_id, is_required) values
  ('96900000-0000-0000-0000-000000000010', '96900000-0000-0000-0000-000000000001', true),
  ('96900000-0000-0000-0000-000000000011', '96900000-0000-0000-0000-000000000002', true);

insert into public.service_duration_pricing_tiers (service_id, min_blocks, max_blocks, price_per_block, sort_order)
values ('96900000-0000-0000-0000-000000000011', 8, 16, 80, 10);

-- 2035-01-15 is a Monday: +20% from 19:00, block by block (BLOCKS) as in production.
insert into public.pricing_rules (
  service_id, name, rule_scope, days_of_week, start_local_time, end_local_time,
  action_type, percentage, priority, is_active
) values (
  '96900000-0000-0000-0000-000000000011', 'S05 night +20', 'DAY_TIME', array[1]::smallint[],
  time '19:00', time '23:59:59', 'ADD_PERCENT', 20, 10, true
);

insert into public.extras (id, name, price, duration_delta_minutes)
values ('96900000-0000-0000-0000-000000000030', 'S05 Fundo infinito', 50, 0);

insert into public.service_extras (service_id, extra_id, max_quantity) values
  ('96900000-0000-0000-0000-000000000010', '96900000-0000-0000-0000-000000000030', 1),
  ('96900000-0000-0000-0000-000000000011', '96900000-0000-0000-0000-000000000030', 1);

insert into public.customers (id, name, email, phone) values
  ('96900000-0000-0000-0000-000000000050', 'S05 Customer One', 's05-one@example.com', '+5548999996901'),
  ('96900000-0000-0000-0000-000000000051', 'S05 Customer Two', 's05-two@example.com', '+5548999996902');

insert into public.coupons (
  id, code, discount_type, discount_value, valid_from, valid_until, is_active,
  source, customer_id, max_uses, max_uses_per_customer, discount_scope
) values
  -- E: same 20% with and without extras in the base.
  ('96900000-0000-0000-0000-000000000060', 'S05ORDER20', 'PERCENT', 20, now() - interval '1 day', timestamptz '2036-01-01 00:00:00-03', true, 'PROMOTION', null, null, null, 'ORDER_SUBTOTAL'),
  ('96900000-0000-0000-0000-000000000061', 'S05RENT20', 'PERCENT', 20, now() - interval '1 day', timestamptz '2036-01-01 00:00:00-03', true, 'PROMOTION', null, null, null, 'SERVICE_ONLY'),
  ('96900000-0000-0000-0000-000000000062', 'S05RENTFIX', 'FIXED', 1000, now() - interval '1 day', timestamptz '2036-01-01 00:00:00-03', true, 'PROMOTION', null, null, null, 'SERVICE_ONLY'),
  -- A/B/D: single global use.
  ('96900000-0000-0000-0000-000000000063', 'S05ONCE', 'PERCENT', 10, now() - interval '1 day', timestamptz '2036-01-01 00:00:00-03', true, 'PROMOTION', null, 1, null, 'ORDER_SUBTOTAL'),
  -- C: several global uses, one per customer.
  ('96900000-0000-0000-0000-000000000064', 'S05PERCUST', 'PERCENT', 10, now() - interval '1 day', timestamptz '2036-01-01 00:00:00-03', true, 'PROMOTION', null, 5, 1, 'ORDER_SUBTOTAL'),
  -- Repeated release.
  ('96900000-0000-0000-0000-000000000065', 'S05MULTI', 'PERCENT', 10, now() - interval '1 day', timestamptz '2036-01-01 00:00:00-03', true, 'PROMOTION', null, 5, null, 'ORDER_SUBTOTAL');

-- Birthday-shaped coupon exactly as run_birthday_automation issues it (no discount_scope given).
insert into public.coupons (
  id, code, discount_type, discount_value, valid_from, valid_until, is_active,
  source, customer_id, max_uses, max_uses_per_customer, used_count
) values (
  '96900000-0000-0000-0000-000000000066', 'S05NIVER50-2035-P-96900000', 'PERCENT', 50,
  now() - interval '1 day', timestamptz '2036-01-01 00:00:00-03', true,
  'BIRTHDAY', '96900000-0000-0000-0000-000000000050', 1, 1, 0
);
insert into public.coupon_services (coupon_id, service_id)
values ('96900000-0000-0000-0000-000000000066', '96900000-0000-0000-0000-000000000010');

-- Books one FIXED slot through the real checkout path: hold -> apply_checkout_coupon -> promote.
create function pg_temp.s05_hold(p_n integer, p_extras jsonb default '[]'::jsonb)
returns uuid
language plpgsql
as $$
declare
  v_hold uuid := ('96900000-0000-0000-0001-' || lpad(p_n::text, 12, '0'))::uuid;
  v_start timestamptz := timestamptz '2035-01-15 08:00:00-03' + make_interval(hours => p_n);
begin
  insert into public.checkout_holds (
    id, public_token_hash, service_id, service_employee_id, selection_hash,
    people_count, requested_start_at, requested_end_at, core_start_at, core_end_at, expires_at,
    extra_selections, commercial_value, pricing_version, duration_minutes, resource_ids
  ) values (
    v_hold, encode(extensions.digest('s05-checkout-token-' || p_n, 'sha256'), 'hex'),
    '96900000-0000-0000-0000-000000000010', '96900000-0000-0000-0000-000000000020', 's05-' || p_n,
    1, v_start, v_start + interval '1 hour', v_start, v_start + interval '1 hour', now() + interval '10 minutes',
    p_extras, 0, 's05', 60, array['96900000-0000-0000-0000-000000000001'::uuid]
  );
  insert into public.resource_allocations (resource_id, checkout_hold_id, allocation_type, status, occupied_range)
  values ('96900000-0000-0000-0000-000000000001', v_hold, 'CHECKOUT_HOLD', 'HELD',
          tstzrange(v_start, v_start + interval '1 hour', '[)'));
  return v_hold;
end;
$$;

create function pg_temp.s05_book(p_n integer, p_customer uuid, p_code text, p_extras jsonb default '[]'::jsonb)
returns uuid
language plpgsql
as $$
declare
  v_hold uuid := pg_temp.s05_hold(p_n, p_extras);
begin
  if p_code is not null then
    perform public.apply_checkout_coupon('s05-checkout-token-' || p_n, p_code);
  end if;
  perform public.promote_checkout_hold(v_hold, p_customer);
  return (select promoted_appointment_id from public.checkout_holds where id = v_hold);
end;
$$;

create function pg_temp.s05_state(p_appointment uuid)
returns text
language sql
as $$
  select public.coupon_redemption_status(ad.released_at, ad.redeemed_at, a.status)
  from public.appointment_discounts ad join public.appointments a on a.id = ad.appointment_id
  where ad.appointment_id = p_appointment;
$$;

create function pg_temp.s05_used(p_coupon uuid)
returns integer
language sql
as $$ select used_count from public.coupons where id = p_coupon; $$;

create temporary table s05 (name text primary key, id uuid);

-- ---------------------------------------------------------------------------
-- E. Discount scope (both pricing paths)
-- ---------------------------------------------------------------------------

select is(
  (public.calculate_booking_quote('96900000-0000-0000-0000-000000000010', '96900000-0000-0000-0000-000000000020',
     '[{"extra_id":"96900000-0000-0000-0000-000000000030","quantity":1}]'::jsonb, 1, timestamptz '2035-01-15 09:00:00-03', 'S05ORDER20')->>'coupon_discount')::numeric,
  30.00::numeric,
  'FIXED path: ORDER_SUBTOTAL coupon keeps legacy base (100 rental + 50 extra)');

select is(
  (public.calculate_booking_quote('96900000-0000-0000-0000-000000000010', '96900000-0000-0000-0000-000000000020',
     '[{"extra_id":"96900000-0000-0000-0000-000000000030","quantity":1}]'::jsonb, 1, timestamptz '2035-01-15 09:00:00-03', 'S05RENT20')->>'coupon_discount')::numeric,
  20.00::numeric,
  'FIXED path: SERVICE_ONLY coupon does not discount extras');

select is(
  (public.calculate_booking_quote('96900000-0000-0000-0000-000000000010', '96900000-0000-0000-0000-000000000020',
     '[{"extra_id":"96900000-0000-0000-0000-000000000030","quantity":1}]'::jsonb, 1, timestamptz '2035-01-15 09:00:00-03', 'S05RENT20')->>'commercial_value')::numeric,
  130.00::numeric,
  'FIXED path: extras are charged in full under a SERVICE_ONLY coupon');

select is(
  (public.calculate_booking_quote_for_duration('96900000-0000-0000-0000-000000000011', '96900000-0000-0000-0000-000000000021', 8,
     '[{"extra_id":"96900000-0000-0000-0000-000000000030","quantity":1}]'::jsonb, 1, timestamptz '2035-01-15 10:00:00-03', 'S05ORDER20')->>'coupon_discount')::numeric,
  138.00::numeric,
  'BLOCKS path: ORDER_SUBTOTAL coupon keeps legacy base (640 rental + 50 extra)');

select is(
  (public.calculate_booking_quote_for_duration('96900000-0000-0000-0000-000000000011', '96900000-0000-0000-0000-000000000021', 8,
     '[{"extra_id":"96900000-0000-0000-0000-000000000030","quantity":1}]'::jsonb, 1, timestamptz '2035-01-15 10:00:00-03', 'S05RENT20')->>'coupon_discount')::numeric,
  128.00::numeric,
  'BLOCKS path: SERVICE_ONLY coupon does not discount extras');

select is(
  (public.calculate_booking_quote_for_duration('96900000-0000-0000-0000-000000000011', '96900000-0000-0000-0000-000000000021', 8,
     '[{"extra_id":"96900000-0000-0000-0000-000000000030","quantity":1}]'::jsonb, 1, timestamptz '2035-01-15 18:00:00-03', 'S05RENT20')->>'coupon_discount')::numeric,
  147.20::numeric,
  'BLOCKS path: SERVICE_ONLY base keeps the night surcharge (640 + 96) and excludes extras');

select is(
  (public.calculate_booking_quote_for_duration('96900000-0000-0000-0000-000000000011', '96900000-0000-0000-0000-000000000021', 8,
     '[{"extra_id":"96900000-0000-0000-0000-000000000030","quantity":1}]'::jsonb, 1, timestamptz '2035-01-15 18:00:00-03', 'S05RENT20')->>'surcharge_amount')::numeric,
  96.00::numeric,
  'BLOCKS path: surcharge itself is unchanged by the coupon scope');

select is(
  (public.calculate_booking_quote('96900000-0000-0000-0000-000000000010', '96900000-0000-0000-0000-000000000020',
     '[{"extra_id":"96900000-0000-0000-0000-000000000030","quantity":1}]'::jsonb, 1, timestamptz '2035-01-15 09:00:00-03', 'S05RENTFIX')->>'commercial_value')::numeric,
  50.00::numeric,
  'FIXED amount larger than the rental is capped at the rental; extras still charged, total never negative');

select is(
  (public.calculate_booking_quote('96900000-0000-0000-0000-000000000010', '96900000-0000-0000-0000-000000000020',
     '[]'::jsonb, 1, timestamptz '2035-01-15 09:00:00-03', 'S05ORDER20')->>'commercial_value')::numeric,
  (public.calculate_booking_quote('96900000-0000-0000-0000-000000000010', '96900000-0000-0000-0000-000000000020',
     '[]'::jsonb, 1, timestamptz '2035-01-15 09:00:00-03', 'S05RENT20')->>'commercial_value')::numeric,
  'Without extras both scopes produce the same total');

select is(public.coupon_discount_amount('PERCENT', 33.33, 'ORDER_SUBTOTAL', 199.99, 0), round(199.99 * (33.33 / 100), 2),
  'ORDER_SUBTOTAL helper is arithmetically identical to the pre-S0.5 formula');

select is((select discount_scope from public.coupons where id = '96900000-0000-0000-0000-000000000066'), 'ORDER_SUBTOTAL',
  'Birthday coupons keep the legacy discount base by default (no commercial change)');

select ok(
  (select is_active = false and coupon_discount_type = 'PERCENT' and coupon_discount_value = 50 and coupon_validity_days = 30
          and coupon_max_uses = 1 and coupon_max_uses_per_customer = 1
   from public.birthday_automation_settings where operation_scope = 'BLACKSHEEP'),
  'BlackSheep birthday automation settings are untouched by S0.5');

-- Reschedule of a SERVICE_ONLY redemption keeps extras out of the base.
insert into s05 values ('rescheduled', pg_temp.s05_book(1, '96900000-0000-0000-0000-000000000050', 'S05RENT20',
  '[{"extra_id":"96900000-0000-0000-0000-000000000030","quantity":1}]'::jsonb));

select is((select discount_scope_snapshot from public.appointment_discounts where appointment_id = (select id from s05 where name = 'rescheduled')),
  'SERVICE_ONLY', 'redemption snapshots the coupon discount scope');

select is((select calculated_discount_amount from public.appointment_discounts where appointment_id = (select id from s05 where name = 'rescheduled')),
  20.00::numeric, 'checkout redemption of SERVICE_ONLY coupon discounts only the rental');

select is(
  (public.calculate_reschedule_quote_for_appointment((select id from s05 where name = 'rescheduled'), timestamptz '2035-01-16 10:00:00-03')->>'coupon_discount')::numeric,
  20.00::numeric,
  'reschedule quote reapplies the SERVICE_ONLY snapshot without discounting extras');

-- ---------------------------------------------------------------------------
-- Hour packages: coupon + package policy is unchanged
-- ---------------------------------------------------------------------------

insert into public.hour_packages (
  id, customer_id, name, total_minutes, purchased_value,
  valid_from, valid_until, standard_start_local_time, standard_end_local_time
) values (
  '96900000-0000-0000-0000-000000000070', '96900000-0000-0000-0000-000000000050', 'S05 package', 600, 500,
  '2034-01-01 00:00:00-03', '2036-01-01 00:00:00-03', '08:00', '23:00'
);
insert into public.hour_package_services (hour_package_id, service_id)
values ('96900000-0000-0000-0000-000000000070', '96900000-0000-0000-0000-000000000010');

select pg_temp.s05_hold(2);
select public.reserve_hour_package_for_checkout('96900000-0000-0000-0000-000000000070', '96900000-0000-0000-0001-000000000002', '96900000-0000-0000-0000-000000000050');

select throws_ok(
  $$ select public.apply_checkout_coupon('s05-checkout-token-2', 'S05ORDER20') $$,
  'P0001', 'COUPON_PACKAGE_POLICY_REQUIRES_DECISION',
  'hour package checkout still rejects coupons pending a commercial decision');

-- ---------------------------------------------------------------------------
-- A/B. Lifecycle: Pix pending, confirmed (50%), expired, abandoned checkout
-- ---------------------------------------------------------------------------

-- Abandoned checkout: coupon applied on a hold that is never promoted.
select pg_temp.s05_hold(3);
select public.apply_checkout_coupon('s05-checkout-token-3', 'S05ONCE');
update public.checkout_holds set status = 'EXPIRED', created_at = now() - interval '20 minutes', expires_at = now() - interval '1 second'
where id = '96900000-0000-0000-0001-000000000003';

select is(pg_temp.s05_used('96900000-0000-0000-0000-000000000063'), 0, 'abandoned checkout never consumes the coupon');
select is((select count(*)::integer from public.appointment_discounts where coupon_id = '96900000-0000-0000-0000-000000000063'), 0,
  'abandoned checkout leaves no redemption');

-- Pix pending.
insert into s05 values ('pix', pg_temp.s05_book(4, '96900000-0000-0000-0000-000000000050', 'S05ONCE'));

select is((select status::text from public.appointments where id = (select id from s05 where name = 'pix')), 'AWAITING_PAYMENT',
  'promotion with cash due waits for payment');
select is(pg_temp.s05_state((select id from s05 where name = 'pix')), 'RESERVED', 'Pix pending keeps the coupon RESERVED, not consumed');
select ok((select reserved_at is not null and redeemed_at is null and released_at is null
           from public.appointment_discounts where appointment_id = (select id from s05 where name = 'pix')),
  'reserved redemption carries only reserved_at');
select is(pg_temp.s05_used('96900000-0000-0000-0000-000000000063'), 1, 'reservation holds the single available use');

insert into s05
select 'pix_tx', (public.create_payment_intent_v2((select id from s05 where name = 'pix'), 'MINIMUM', 'PIX', 's05-pix-1')->>'transaction_id')::uuid;
select is(pg_temp.s05_state((select id from s05 where name = 'pix')), 'RESERVED', 'Pix intent pending does not redeem');

-- D. Second booking while the first is still pending.
select pg_temp.s05_hold(5);
select throws_ok(
  $$ select public.apply_checkout_coupon('s05-checkout-token-5', 'S05ONCE') $$,
  'P0001', 'COUPON_USAGE_LIMIT_REACHED',
  'single-use coupon reserved by a pending Pix cannot be applied elsewhere');

-- Pix confirmed for the 50% minimum: reservation is confirmed, coupon is consumed.
select public.apply_provider_payment_status((select id from s05 where name = 'pix_tx'), 's05-mp-1', 'APPROVED', 's05-event-1', '{}'::jsonb, now());

select is((select status::text from public.appointments where id = (select id from s05 where name = 'pix')), 'CONFIRMED',
  'approved minimum Pix confirms the reservation');
select is((select financial_status::text from public.appointments where id = (select id from s05 where name = 'pix')), 'PARTIALLY_PAID',
  'partial (50%) payment is not mistaken for full payment');
select is(pg_temp.s05_state((select id from s05 where name = 'pix')), 'REDEEMED', 'partially paid confirmed reservation consumes the coupon');
select is(pg_temp.s05_used('96900000-0000-0000-0000-000000000063'), 1, 'confirmation does not change the usage counter');

-- Duplicate webhook is idempotent for the coupon too.
select public.apply_provider_payment_status((select id from s05 where name = 'pix_tx'), 's05-mp-1', 'APPROVED', 's05-event-1', '{}'::jsonb, now());
select is(pg_temp.s05_used('96900000-0000-0000-0000-000000000063'), 1, 'duplicate approved webhook does not touch the coupon');

-- Reuse attempt after definitive consumption.
select pg_temp.s05_hold(6);
select throws_ok(
  $$ select public.apply_checkout_coupon('s05-checkout-token-6', 'S05ONCE') $$,
  'P0001', 'COUPON_USAGE_LIMIT_REACHED',
  'redeemed single-use coupon cannot be reused');

-- Pix expired: provider expiry, then the payment hold expires.
insert into s05 values ('expired', pg_temp.s05_book(7, '96900000-0000-0000-0000-000000000051', 'S05MULTI'));
insert into s05
select 'expired_tx', (public.create_payment_intent_v2((select id from s05 where name = 'expired'), 'MINIMUM', 'PIX', 's05-pix-exp')->>'transaction_id')::uuid;
select public.apply_provider_payment_status((select id from s05 where name = 'expired_tx'), 's05-mp-exp', 'EXPIRED', 's05-event-exp', '{}'::jsonb, now());

select is(pg_temp.s05_state((select id from s05 where name = 'expired')), 'RESERVED', 'expired Pix charge alone keeps the reservation until the hold expires');

update public.appointments set hold_expires_at = now() - interval '1 minute' where id = (select id from s05 where name = 'expired');
select public.expire_due_appointment_holds();

select is((select status::text from public.appointments where id = (select id from s05 where name = 'expired')), 'EXPIRED', 'payment hold expiry expires the reservation');
select is(pg_temp.s05_state((select id from s05 where name = 'expired')), 'RELEASED', 'expired Pix releases the coupon');
select is(pg_temp.s05_used('96900000-0000-0000-0000-000000000065'), 0, 'expired Pix returns the use exactly once');
select is((select count(*)::integer from public.appointment_discounts where appointment_id = (select id from s05 where name = 'expired')), 1,
  'released redemption is kept for audit');

-- Rejected Pix keeps the reservation until expiry (existing policy).
insert into s05 values ('rejected', pg_temp.s05_book(8, '96900000-0000-0000-0000-000000000051', 'S05MULTI'));
insert into s05
select 'rejected_tx', (public.create_payment_intent_v2((select id from s05 where name = 'rejected'), 'MINIMUM', 'PIX', 's05-pix-rej')->>'transaction_id')::uuid;
select public.apply_provider_payment_status((select id from s05 where name = 'rejected_tx'), 's05-mp-rej', 'REJECTED', 's05-event-rej', '{}'::jsonb, now());
select is(pg_temp.s05_state((select id from s05 where name = 'rejected')), 'RESERVED', 'rejected Pix does not consume the coupon');

-- ---------------------------------------------------------------------------
-- Future billing (invoice) and cancellation
-- ---------------------------------------------------------------------------

insert into s05 values ('invoice', pg_temp.s05_book(9, '96900000-0000-0000-0000-000000000050', 'S05MULTI'));
select public.confirm_without_payment((select id from s05 where name = 'invoice'), 'S05 faturamento', null);
select is((select financial_status::text from public.appointments where id = (select id from s05 where name = 'invoice')), 'UNPAID_AUTHORIZED',
  'invoice confirmation keeps the future financial obligation');
select is(pg_temp.s05_state((select id from s05 where name = 'invoice')), 'REDEEMED', 'confirmed invoice reservation consumes the coupon');

select is(pg_temp.s05_used('96900000-0000-0000-0000-000000000065'), 2, 'counter = rejected-pending reservation + invoice redemption');

select public.release_appointment_coupon_usage('00000000-0000-0000-0000-000000000000'::uuid);
select is(pg_temp.s05_used('96900000-0000-0000-0000-000000000065'), 2, 'releasing an appointment without coupon is a no-op');

create temporary table s05_jobs_before as select count(*)::integer as n from public.integration_jobs;

update public.appointments set status = 'CANCELLED' where id = (select id from s05 where name = 'invoice');
select is(pg_temp.s05_state((select id from s05 where name = 'invoice')), 'RELEASED', 'cancellation releases the coupon (existing policy preserved)');
select is((select release_reason from public.appointment_discounts where appointment_id = (select id from s05 where name = 'invoice')),
  'APPOINTMENT_CANCELLED', 'release reason records the transition');

-- ---------------------------------------------------------------------------
-- B. Repeated release is idempotent and never frees another reservation's use
-- ---------------------------------------------------------------------------

select is(pg_temp.s05_used('96900000-0000-0000-0000-000000000065'), 1, 'cancellation returned one use');
select public.release_appointment_coupon_usage((select id from s05 where name = 'invoice'));
select public.release_appointment_coupon_usage((select id from s05 where name = 'invoice'));
select ok(not public.service_release_appointment_coupon((select id from s05 where name = 'invoice'), 'S05_REPEAT', true),
  'repeated release reports nothing to release');
select is(pg_temp.s05_used('96900000-0000-0000-0000-000000000065'), 1,
  'repeated releases do not decrease the counter held by the other active reservation');
select is((select count(*)::integer from public.integration_jobs), (select n from s05_jobs_before),
  'coupon release enqueues no integration job (no Kommo movement from S0.5 code)');

update public.appointments set status = 'EXPIRED' where id = (select id from s05 where name = 'rejected');
update public.appointments set status = 'CANCELLED' where id = (select id from s05 where name = 'rejected');
select is(pg_temp.s05_used('96900000-0000-0000-0000-000000000065'), 0, 'expired then cancelled releases once');

-- ---------------------------------------------------------------------------
-- C. Per-customer limit ignores released redemptions
-- ---------------------------------------------------------------------------

insert into s05 values ('pc1', pg_temp.s05_book(10, '96900000-0000-0000-0000-000000000050', 'S05PERCUST'));
select pg_temp.s05_hold(11);
select public.apply_checkout_coupon('s05-checkout-token-11', 'S05PERCUST');
select throws_ok(
  $$ select public.promote_checkout_hold('96900000-0000-0000-0001-000000000011', '96900000-0000-0000-0000-000000000050') $$,
  'P0001', 'COUPON_CUSTOMER_USAGE_LIMIT_REACHED',
  'per-customer limit blocks a second reservation while the first is pending');

update public.appointments set hold_expires_at = now() - interval '1 minute' where id = (select id from s05 where name = 'pc1');
select public.expire_due_appointment_holds();

insert into s05 values ('pc2', pg_temp.s05_book(12, '96900000-0000-0000-0000-000000000050', 'S05PERCUST'));
select is(pg_temp.s05_state((select id from s05 where name = 'pc2')), 'RESERVED',
  'customer can legitimately reuse the coupon after the abandoned Pix expired');
select is((select count(*)::integer from public.appointment_discounts where coupon_id = '96900000-0000-0000-0000-000000000064'), 2,
  'both redemptions are kept in history');

-- Legacy row (created before S0.5) for an appointment that expired before S0.5.
-- Emulate the pre-S0.5 state: legacy release already returned the counter and no lifecycle trigger existed.
insert into s05 values ('legacy', pg_temp.s05_book(13, '96900000-0000-0000-0000-000000000051', 'S05PERCUST'));
set local session_replication_role = replica;
update public.appointment_discounts set reserved_at = null where appointment_id = (select id from s05 where name = 'legacy');
update public.coupons set used_count = used_count - 1 where id = '96900000-0000-0000-0000-000000000064';
update public.appointments set status = 'EXPIRED' where id = (select id from s05 where name = 'legacy');
set local session_replication_role = origin;

select is(pg_temp.s05_state((select id from s05 where name = 'legacy')), 'RELEASED', 'legacy expired row is classified RELEASED without backfill');
create temporary table s05_legacy_used as select pg_temp.s05_used('96900000-0000-0000-0000-000000000064') as n;
select public.release_appointment_coupon_usage((select id from s05 where name = 'legacy'));
select is(pg_temp.s05_used('96900000-0000-0000-0000-000000000064'), (select n from s05_legacy_used),
  'direct release of a legacy terminal row does not return the use a second time');

insert into s05 values ('legacy_reuse', pg_temp.s05_book(14, '96900000-0000-0000-0000-000000000051', 'S05PERCUST'));
select is(pg_temp.s05_state((select id from s05 where name = 'legacy_reuse')), 'RESERVED',
  'legacy expired redemption no longer blocks the customer limit');

-- ---------------------------------------------------------------------------
-- Birthday coupon: customer-bound, single use, abandoned Pix then legitimate use
-- ---------------------------------------------------------------------------

select pg_temp.s05_hold(15);
select public.apply_checkout_coupon('s05-checkout-token-15', 'S05NIVER50-2035-P-96900000');
select throws_ok(
  $$ select public.promote_checkout_hold('96900000-0000-0000-0001-000000000015', '96900000-0000-0000-0000-000000000051') $$,
  'P0001', 'COUPON_CUSTOMER_MISMATCH',
  'birthday coupon cannot be used by another customer');

insert into s05 values ('bday1', pg_temp.s05_book(16, '96900000-0000-0000-0000-000000000050', 'S05NIVER50-2035-P-96900000'));
select is((select calculated_discount_amount from public.appointment_discounts where appointment_id = (select id from s05 where name = 'bday1')),
  50.00::numeric, 'birthday coupon keeps its 50% commercial condition');
update public.appointments set hold_expires_at = now() - interval '1 minute' where id = (select id from s05 where name = 'bday1');
select public.expire_due_appointment_holds();
select is(pg_temp.s05_used('96900000-0000-0000-0000-000000000066'), 0, 'abandoned birthday Pix returns the single use');

insert into s05 values ('bday2', pg_temp.s05_book(17, '96900000-0000-0000-0000-000000000050', 'S05NIVER50-2035-P-96900000'));
select is(pg_temp.s05_state((select id from s05 where name = 'bday2')), 'RESERVED',
  'birthday customer is no longer locked out after an abandoned Pix');
select public.confirm_appointment_internal((select id from s05 where name = 'bday2'), 'S05_TEST_CONFIRMATION');
select is(pg_temp.s05_state((select id from s05 where name = 'bday2')), 'REDEEMED', 'confirmed birthday reservation consumes the coupon');

select pg_temp.s05_hold(18);
select throws_ok(
  $$ select public.apply_checkout_coupon('s05-checkout-token-18', 'S05NIVER50-2035-P-96900000') $$,
  'P0001', 'COUPON_USAGE_LIMIT_REACHED',
  'redeemed birthday coupon cannot be reused');

-- ---------------------------------------------------------------------------
-- Admin read models
-- ---------------------------------------------------------------------------

select is(
  (select (item->>'actual_used_count')::integer
   from jsonb_array_elements(public.admin_list_coupons()) item
   where item->>'id' = '96900000-0000-0000-0000-000000000066'),
  1, 'admin list counts only non-released redemptions');

select is(
  (select (item->>'reserved_count')::integer
   from jsonb_array_elements(public.admin_list_coupons_page(0, 100)->'coupons') item
   where item->>'id' = '96900000-0000-0000-0000-000000000064'),
  2, 'admin page exposes pending reservations separately');

select is(
  (select count(*)::integer from jsonb_array_elements(public.admin_coupon_usage('96900000-0000-0000-0000-000000000066')) u
   where u->>'redemption_status' = 'RELEASED'),
  1, 'usage history keeps the released birthday redemption with its status');

select is(
  (select (r->>'uses')::integer from jsonb_array_elements(public.admin_coupon_metrics()->'ranking') r
   where r->>'id' = '96900000-0000-0000-0000-000000000066'),
  1, 'metrics do not count released redemptions as uses');

-- ---------------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------------

select ok(not has_function_privilege('anon', 'public.service_release_appointment_coupon(uuid,text,boolean)', 'EXECUTE')
          and not has_function_privilege('authenticated', 'public.service_release_appointment_coupon(uuid,text,boolean)', 'EXECUTE'),
  'browser roles cannot release coupons');
select ok(not has_function_privilege('anon', 'public.coupon_discount_amount(text,numeric,text,numeric,numeric)', 'EXECUTE')
          and not has_function_privilege('anon', 'public.coupon_redemption_status(timestamptz,timestamptz,text)', 'EXECUTE'),
  'new helpers are not exposed to anon');

select * from finish();
rollback;
