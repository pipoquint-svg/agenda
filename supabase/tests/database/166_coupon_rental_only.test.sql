begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(42);

insert into public.resources (id, name, resource_type)
values ('96600000-0000-0000-0000-000000000001', 'Coupon Rental Only Studio', 'PHYSICAL');
insert into public.employees (id, name)
values ('96600000-0000-0000-0000-000000000002', 'Coupon Rental Only Employee');
insert into public.categories (id, name, slug, operation_scope)
values ('96600000-0000-0000-0000-000000000003', 'Coupon Rental Only', 'coupon-rental-only', 'BLACKSHEEP');

-- Equivalent catalog and two-block rentals make monetary parity explicit.
insert into public.services (
  id, category_id, name, slug, base_duration_minutes, base_price,
  minimum_people, included_people, maximum_people, price_per_extra_person,
  maximum_booking_horizon_days, requires_terms, duration_mode,
  booking_block_minutes, minimum_booking_blocks, maximum_booking_blocks, price_per_block,
  service_type_id, operation_scope
) values
  ('96600000-0000-0000-0000-000000000010', '96600000-0000-0000-0000-000000000003',
   'Coupon Catalog Rental', 'coupon-catalog-rental', 60, 340,
   1, 1, 10, 25, 5000, false, 'FIXED', 30, 2, 16, 170,
   (select id from public.service_type where key = 'LOCACAO'), 'BLACKSHEEP'),
  ('96600000-0000-0000-0000-000000000011', '96600000-0000-0000-0000-000000000003',
   'Coupon Block Rental', 'coupon-block-rental', 60, 340,
   1, 1, 10, 25, 5000, false, 'BLOCKS', 30, 2, 16, 170,
   (select id from public.service_type where key = 'LOCACAO'), 'BLACKSHEEP');

insert into public.service_change_policies (
  service_id, notice_hours, reschedule_first_early_percent,
  reschedule_first_late_percent, reschedule_repeat_percent, cancellation_late_percent
)
select id, 0, 0, 0, 0, 0
from public.services
where id in ('96600000-0000-0000-0000-000000000010', '96600000-0000-0000-0000-000000000011');

insert into public.service_employees (id, service_id, employee_id)
values
  ('96600000-0000-0000-0000-000000000020', '96600000-0000-0000-0000-000000000010', '96600000-0000-0000-0000-000000000002'),
  ('96600000-0000-0000-0000-000000000021', '96600000-0000-0000-0000-000000000011', '96600000-0000-0000-0000-000000000002');
insert into public.service_resources (service_id, resource_id)
select id, '96600000-0000-0000-0000-000000000001'
from public.services
where id in ('96600000-0000-0000-0000-000000000010', '96600000-0000-0000-0000-000000000011');

insert into public.extras (id, name, price, duration_delta_minutes)
values
  ('96600000-0000-0000-0000-000000000030', 'Coupon Assistance Extra', 75, 0),
  ('96600000-0000-0000-0000-000000000031', 'Coupon Extra Time', 75, 30);
insert into public.service_extras (service_id, extra_id, max_quantity)
select s.id, e.id, 1
from public.services s cross join public.extras e
where s.id in ('96600000-0000-0000-0000-000000000010', '96600000-0000-0000-0000-000000000011')
  and e.id in ('96600000-0000-0000-0000-000000000030', '96600000-0000-0000-0000-000000000031');

insert into public.pricing_rules (service_id, name, rule_scope, action_type, percentage, priority)
select id, 'Rental day/time tariff', 'DAY_TIME', 'ADD_PERCENT', 20, 10
from public.services
where id in ('96600000-0000-0000-0000-000000000010', '96600000-0000-0000-0000-000000000011');

insert into public.customers (id, name, email, phone)
values ('96600000-0000-0000-0000-000000000050', 'Coupon Rental Customer', 'coupon-rental@example.test', '+5548999999660');

insert into public.coupons (id, code, discount_type, discount_value, is_active, source, max_uses)
values
  ('96600000-0000-0000-0000-000000000071', 'C166FIX340', 'FIXED', 340, true, 'PROMOTION', 20),
  ('96600000-0000-0000-0000-000000000072', 'C166FIX999', 'FIXED', 999, true, 'PROMOTION', 20),
  ('96600000-0000-0000-0000-000000000073', 'C166PCT100', 'PERCENT', 100, true, 'PROMOTION', 20),
  ('96600000-0000-0000-0000-000000000074', 'C166PCT10', 'PERCENT', 10, true, 'PROMOTION', 20);

-- Base 340 + tariff 68 = eligible rental 408. Catalog extras stay 75;
-- three people also incur 50 for the two people above the included allowance.
create temporary table coupon_rental_cases (
  case_key text primary key, coupon_code text, people_count integer,
  expected_discount numeric, expected_total numeric
);
insert into coupon_rental_cases values
  ('fixed340', 'C166FIX340', 1, 340, 143),
  ('fixed_oversized', 'C166FIX999', 1, 408, 75),
  ('percent100', 'C166PCT100', 1, 408, 75),
  ('percent100_people', 'C166PCT100', 3, 408, 125),
  ('percent10_people', 'C166PCT10', 3, 40.80, 492.20);

create temporary table coupon_rental_quotes as
select 'CATALOG'::text as quote_path, c.case_key,
  public.calculate_booking_quote(
    '96600000-0000-0000-0000-000000000010', '96600000-0000-0000-0000-000000000020',
    '[{"extra_id":"96600000-0000-0000-0000-000000000030","quantity":1}]'::jsonb,
    c.people_count, '2035-01-15 09:00:00-03', c.coupon_code
  ) as quote
from coupon_rental_cases c
union all
select 'DURATION', c.case_key,
  public.calculate_booking_quote_for_duration(
    '96600000-0000-0000-0000-000000000011', '96600000-0000-0000-0000-000000000021', 2,
    '[{"extra_id":"96600000-0000-0000-0000-000000000030","quantity":1}]'::jsonb,
    c.people_count, '2035-01-15 09:00:00-03', c.coupon_code
  )
from coupon_rental_cases c
union all
select 'BATCH', c.case_key, b.quote
from coupon_rental_cases c
cross join lateral public.calculate_booking_quotes_for_duration_batch(
  '96600000-0000-0000-0000-000000000011', '96600000-0000-0000-0000-000000000021', 2,
  '[{"extra_id":"96600000-0000-0000-0000-000000000030","quantity":1}]'::jsonb,
  c.people_count, array['2035-01-15 09:00:00-03'::timestamptz], c.coupon_code
) b;

select results_eq(
  $$select case_key, (quote->>'coupon_discount')::numeric, (quote->>'commercial_value')::numeric
    from coupon_rental_quotes where quote_path = 'CATALOG' order by case_key$$,
  $$select case_key, expected_discount, expected_total from coupon_rental_cases order by case_key$$,
  'catalog fixed and percent coupons discount rental only and never erase extras'
);
select results_eq(
  $$select case_key, (quote->>'coupon_discount')::numeric, (quote->>'commercial_value')::numeric
    from coupon_rental_quotes where quote_path = 'DURATION' order by case_key$$,
  $$select case_key, expected_discount, expected_total from coupon_rental_cases order by case_key$$,
  'single-duration quotes match the rental-only catalog monetary contract'
);
select results_eq(
  $$select case_key, (quote->>'coupon_discount')::numeric, (quote->>'commercial_value')::numeric
    from coupon_rental_quotes where quote_path = 'BATCH' order by case_key$$,
  $$select case_key, expected_discount, expected_total from coupon_rental_cases order by case_key$$,
  'batch quotes match the rental-only catalog monetary contract'
);
select is(
  (select bool_and(coalesce((quote->>'coupon_eligible_amount')::numeric = 408, false)) from coupon_rental_quotes),
  true, 'every pricing path exposes base plus tariff as the coupon-eligible rental amount'
);
select is(
  (select bool_and(coalesce(quote->>'coupon_scope' = 'RENTAL_ONLY', false)) from coupon_rental_quotes),
  true, 'every pricing path records the rental-only coupon scope'
);
select is(
  (select bool_and(coalesce((quote->>'extras_total')::numeric = 75, false)) from coupon_rental_quotes),
  true, 'extras remain priced at their full catalog amount for every coupon'
);
select is(
  (select bool_and(coalesce((quote->>'extra_people_amount')::numeric = 50
    and (quote->>'people_adjustment')::numeric = 50, false))
   from coupon_rental_quotes q join coupon_rental_cases c using (case_key) where c.people_count = 3),
  true, 'additional people keep their full surcharge independently from the coupon'
);
select is(
  (public.calculate_booking_quote(
    '96600000-0000-0000-0000-000000000010', '96600000-0000-0000-0000-000000000020',
    '[{"extra_id":"96600000-0000-0000-0000-000000000030","quantity":1}]'::jsonb,
    3, '2035-01-15 09:00:00-03', null
  )->>'commercial_value')::numeric,
  533::numeric, 'a quote without a coupon keeps rental, tariff, people and extras'
);
select is(
  (public.calculate_booking_quote(
    '96600000-0000-0000-0000-000000000010', '96600000-0000-0000-0000-000000000020',
    '[{"extra_id":"96600000-0000-0000-0000-000000000030","quantity":1}]'::jsonb,
    1, null, 'C166FIX340'
  )->>'commercial_value')::numeric,
  75::numeric, 'a 340 coupon on a 340 rental without a tariff leaves the entire 75 extra payable'
);
select results_eq(
  $$select b.requested_start_at, (b.quote->>'coupon_eligible_amount')::numeric,
      (b.quote->>'commercial_value')::numeric
    from public.calculate_booking_quotes_for_duration_batch(
      '96600000-0000-0000-0000-000000000011', '96600000-0000-0000-0000-000000000021', 2,
      '[{"extra_id":"96600000-0000-0000-0000-000000000030","quantity":1}]'::jsonb,
      1, array['2035-01-15 09:00:00-03'::timestamptz, null, '2035-01-16 09:00:00-03'::timestamptz],
      'C166FIX340'
    ) b order by b.requested_start_at nulls first$$,
  $$values
      (null::timestamptz, 340::numeric, 75::numeric),
      ('2035-01-15 09:00:00-03'::timestamptz, 408::numeric, 143::numeric),
      ('2035-01-16 09:00:00-03'::timestamptz, 408::numeric, 143::numeric)$$,
  'each batch candidate independently caps the coupon at its own rental and applicable tariff'
);
select results_eq(
  $$select quote_path, (quote->>'coupon_eligible_amount')::numeric, (quote->>'extras_total')::numeric,
      (quote->>'commercial_value')::numeric
    from (
      select 'CATALOG'::text as quote_path, public.calculate_booking_quote(
        '96600000-0000-0000-0000-000000000010', '96600000-0000-0000-0000-000000000020',
        '[{"extra_id":"96600000-0000-0000-0000-000000000031","quantity":1}]'::jsonb,
        1, '2035-01-15 09:00:00-03', 'C166PCT100'
      ) as quote
      union all
      select 'DURATION', public.calculate_booking_quote_for_duration(
        '96600000-0000-0000-0000-000000000011', '96600000-0000-0000-0000-000000000021', 2,
        '[{"extra_id":"96600000-0000-0000-0000-000000000031","quantity":1}]'::jsonb,
        1, '2035-01-15 09:00:00-03', 'C166PCT100'
      )
    ) q order by quote_path$$,
  $$values ('CATALOG'::text, 408::numeric, 75::numeric, 75::numeric),
      ('DURATION'::text, 408::numeric, 75::numeric, 75::numeric)$$,
  'duration metadata on a catalog extra does not make its charge eligible for a rental coupon'
);

create temporary table coupon_rental_hold_cases (
  id uuid primary key, case_key text, day_offset integer, people_count integer,
  commercial_value numeric, coupon_discount numeric, pre_discount_value numeric,
  applied_coupon_id uuid, coupon_code text
);
insert into coupon_rental_hold_cases values
  ('96600000-0000-0000-0000-000000000080', 'persisted', 0, 3, 533, 0, null, null, null),
  ('96600000-0000-0000-0000-000000000081', 'direct-legacy', 1, 3, 533, 0, null, null, null),
  ('96600000-0000-0000-0000-000000000082', 'old-percent', 2, 1, 434.70, 48.30, 483,
   '96600000-0000-0000-0000-000000000074', 'C166PCT10'),
  ('96600000-0000-0000-0000-000000000083', 'old-fixed', 3, 1, 0, 483, 483,
   '96600000-0000-0000-0000-000000000072', 'C166FIX999'),
  ('96600000-0000-0000-0000-000000000084', 'valid-legacy', 4, 1, 143, 340, 483,
   '96600000-0000-0000-0000-000000000071', 'C166FIX340');

-- All holds start with historical, untagged snapshots. The public apply RPC
-- upgrades the first one before promotion; the other cases exercise compatibility.
insert into public.checkout_holds (
  id, public_token_hash, service_id, service_employee_id, selection_hash,
  people_count, requested_start_at, requested_end_at, expires_at,
  extra_selections, commercial_value, pricing_version, duration_minutes, resource_ids,
  quote_snapshot, applied_coupon_id, coupon_code_snapshot, coupon_discount, pre_discount_value
)
select c.id, encode(digest('rental-only-' || c.case_key, 'sha256'), 'hex'),
  '96600000-0000-0000-0000-000000000010', '96600000-0000-0000-0000-000000000020',
  'rental-only-selection-' || c.case_key, c.people_count,
  '2035-01-16 09:00:00-03'::timestamptz + make_interval(days => c.day_offset),
  '2035-01-16 10:00:00-03'::timestamptz + make_interval(days => c.day_offset),
  now() + interval '10 minutes',
  '[{"extra_id":"96600000-0000-0000-0000-000000000030","quantity":1}]'::jsonb,
  c.commercial_value, 'coupon-rental-only-legacy-test', 60,
  array['96600000-0000-0000-0000-000000000001'::uuid],
  jsonb_build_object(
    'base_price', 340, 'day_time_adjustment', 68,
    'people_adjustment', (c.people_count - 1) * 25,
    'extra_people_amount', (c.people_count - 1) * 25,
    'extras_total', 75, 'commercial_value', c.commercial_value,
    'coupon_discount', c.coupon_discount
  ), c.applied_coupon_id, c.coupon_code, c.coupon_discount, c.pre_discount_value
from coupon_rental_hold_cases c;

insert into public.resource_allocations (
  resource_id, checkout_hold_id, allocation_type, status, occupied_range
)
select resource_id, h.id, 'CHECKOUT_HOLD', 'HELD',
  tstzrange(h.requested_start_at, h.requested_end_at, '[)')
from public.checkout_holds h
join coupon_rental_hold_cases c on c.id = h.id
cross join lateral unnest(h.resource_ids) resource_id;

select set_config('agenda.c166_applied', public.apply_checkout_coupon(
  'rental-only-persisted', 'C166PCT10'
)::text, true);
select is(
  (current_setting('agenda.c166_applied')::jsonb->>'coupon_discount')::numeric,
  40.80::numeric, 'coupon application discounts only the 408 rental despite 125 in additional charges'
);
select is(
  (current_setting('agenda.c166_applied')::jsonb->>'commercial_value')::numeric,
  492.20::numeric, 'coupon application returns the authoritative rental-only checkout total'
);
select is(
  (select jsonb_build_array(quote_snapshot->>'coupon_scope',
    (quote_snapshot->>'coupon_eligible_amount')::numeric, pre_discount_value, coupon_discount, commercial_value)
   from public.checkout_holds where id = '96600000-0000-0000-0000-000000000080'),
  '["RENTAL_ONLY",408,533,40.80,492.20]'::jsonb,
  'the persisted snapshot keeps the scope, eligible base, full subtotal and effective discount'
);
select is(
  (public.apply_checkout_coupon('rental-only-persisted', 'C166PCT10')->>'commercial_value')::numeric,
  492.20::numeric, 'reapplying the same coupon does not compound its discount'
);
select is(
  (select used_count from public.coupons where id = '96600000-0000-0000-0000-000000000074'),
  0, 'quoting and applying coupons do not consume usage before promotion'
);
select is(
  (public.promote_checkout_hold(
    '96600000-0000-0000-0000-000000000080', '96600000-0000-0000-0000-000000000050', 'C166PCT10'
  )->>'cash_due')::numeric,
  492.20::numeric, 'promotion applies the persisted percent coupon exactly once'
);
select is(
  (select public.appointment_original_coupon_scope(h.promoted_appointment_id)
   from public.checkout_holds h where h.id = '96600000-0000-0000-0000-000000000080'),
  'RENTAL_ONLY', 'an actually promoted appointment resolves its original rental-only coupon scope'
);
select is(
  (select jsonb_build_array(al.after_json->>'coupon_scope',
    (al.after_json->>'coupon_eligible_amount')::numeric)
   from public.audit_logs al
   join public.checkout_holds h on h.promoted_appointment_id = al.entity_id
   where h.id = '96600000-0000-0000-0000-000000000080'
     and al.entity_type = 'APPOINTMENT' and al.action = 'CHECKOUT_HOLD_PROMOTED'),
  '["RENTAL_ONLY",408]'::jsonb,
  'promotion persists scope and eligible rental directly in the durable original audit'
);
select is(
  (select jsonb_build_array(a.commercial_value, a.coupon_discount, a.extras_total)
   from public.appointments a join public.checkout_holds h on h.promoted_appointment_id = a.id
   where h.id = '96600000-0000-0000-0000-000000000080'),
  '[492.20,40.80,75]'::jsonb, 'appointment preserves the checkout money and undiscounted extras'
);
select is(
  (select ae.total_price from public.appointment_extras ae
   join public.checkout_holds h on h.promoted_appointment_id = ae.appointment_id
   where h.id = '96600000-0000-0000-0000-000000000080'),
  75::numeric, 'the booked extra retains its full catalog price'
);
select is(
  (select ad.calculated_discount_amount from public.appointment_discounts ad
   join public.checkout_holds h on h.promoted_appointment_id = ad.appointment_id
   where h.id = '96600000-0000-0000-0000-000000000080'),
  40.80::numeric, 'the discount audit records the rental-only amount once'
);
select is(
  (select used_count from public.coupons where id = '96600000-0000-0000-0000-000000000074'),
  1, 'successful promotion consumes one coupon use'
);
select throws_ok(
  $$select public.promote_checkout_hold(
    '96600000-0000-0000-0000-000000000080', '96600000-0000-0000-0000-000000000050', 'C166PCT10'
  )$$,
  'P0001', 'CHECKOUT_HOLD_EXPIRED', 'a promotion retry cannot create a second discounted appointment'
);
select is(
  (select used_count from public.coupons where id = '96600000-0000-0000-0000-000000000074'),
  1, 'a rejected promotion retry does not consume another coupon use'
);

select is(
  (public.promote_checkout_hold(
    '96600000-0000-0000-0000-000000000081', '96600000-0000-0000-0000-000000000050', 'C166PCT10'
  )->>'cash_due')::numeric,
  492.20::numeric, 'the legacy direct-coupon promotion path excludes extras and additional people'
);
select is(
  (select ad.calculated_discount_amount from public.appointment_discounts ad
   join public.checkout_holds h on h.promoted_appointment_id = ad.appointment_id
   where h.id = '96600000-0000-0000-0000-000000000081'),
  40.80::numeric, 'direct-coupon promotion audits the same rental-only amount as checkout application'
);

select throws_ok(
  $$select public.promote_checkout_hold(
    '96600000-0000-0000-0000-000000000082', '96600000-0000-0000-0000-000000000050', 'C166PCT10'
  )$$,
  'P0001', 'CHECKOUT_COUPON_REAPPLY_REQUIRED',
  'a legacy percent snapshot discounted on extras requires explicit reapplication'
);
select is(
  (select jsonb_build_array(status, commercial_value, coupon_discount, promoted_appointment_id)
   from public.checkout_holds where id = '96600000-0000-0000-0000-000000000082'),
  '["ACTIVE",434.70,48.30,null]'::jsonb,
  'rejecting an invalid legacy percent snapshot does not silently change its amount or create an appointment'
);
select throws_ok(
  $$select public.promote_checkout_hold(
    '96600000-0000-0000-0000-000000000083', '96600000-0000-0000-0000-000000000050', 'C166FIX999'
  )$$,
  'P0001', 'CHECKOUT_COUPON_REAPPLY_REQUIRED',
  'a legacy fixed snapshot that zeroed extras is rejected at promotion'
);
select is(
  (select jsonb_build_array(status, commercial_value, coupon_discount, promoted_appointment_id)
   from public.checkout_holds where id = '96600000-0000-0000-0000-000000000083'),
  '["ACTIVE",0,483,null]'::jsonb,
  'rejecting an oversized legacy discount preserves the unsubmitted hold for correction'
);
select results_eq(
  $$select code, used_count from public.coupons
    where id in ('96600000-0000-0000-0000-000000000072', '96600000-0000-0000-0000-000000000074')
    order by code$$,
  $$values ('C166FIX999'::text, 0), ('C166PCT10'::text, 2)$$,
  'invalid legacy promotion attempts consume no coupon uses'
);
select is(
  (public.promote_checkout_hold(
    '96600000-0000-0000-0000-000000000084', '96600000-0000-0000-0000-000000000050', 'C166FIX340'
  )->>'cash_due')::numeric,
  143::numeric, 'a valid untagged legacy fixed coupon preserves the 68 tariff remainder plus 75 extras'
);
select is(
  (select jsonb_build_array(a.commercial_value, a.coupon_discount, a.extras_total)
   from public.appointments a join public.checkout_holds h on h.promoted_appointment_id = a.id
   where h.id = '96600000-0000-0000-0000-000000000084'),
  '[143,340,75]'::jsonb, 'valid legacy promotion neither reapplies nor enlarges the fixed discount'
);

select is(
  (public.apply_checkout_coupon('rental-only-old-percent', 'C166PCT10')->>'commercial_value')::numeric,
  442.20::numeric, 'explicit reapplication replaces a legacy percent amount with the rental-only quote'
);
select is(
  (public.promote_checkout_hold(
    '96600000-0000-0000-0000-000000000082', '96600000-0000-0000-0000-000000000050', 'C166PCT10'
  )->>'cash_due')::numeric,
  442.20::numeric, 'the corrected legacy hold can be promoted at its newly displayed amount'
);
select is(
  (public.clear_checkout_coupon('rental-only-old-fixed')->>'commercial_value')::numeric,
  483::numeric, 'clearing a legacy coupon restores the full rental and extras subtotal'
);
select is(
  (public.apply_checkout_coupon('rental-only-old-fixed', 'C166FIX999')->>'commercial_value')::numeric,
  75::numeric, 'reapplying an oversized fixed coupon caps it at rental and preserves all extras'
);
select is(
  (public.promote_checkout_hold(
    '96600000-0000-0000-0000-000000000083', '96600000-0000-0000-0000-000000000050', 'C166FIX999'
  )->>'cash_due')::numeric,
  75::numeric, 'an oversized fixed coupon still leaves an actual payable extra after promotion'
);

-- Historical finalized contracts retain their accepted values, including an old
-- erroneous full discount. Checkout corrections cannot retroactively create debt.
insert into public.appointments (
  id, public_code, service_id, service_employee_id, primary_customer_id,
  status, financial_status, start_at, end_at, duration_minutes, people_count,
  base_price_snapshot, variable_price_adjustment, extras_total, coupon_discount, commercial_value
) values (
  '96600000-0000-0000-0000-000000000090', 'COUPON-OLD-PAID',
  '96600000-0000-0000-0000-000000000010', '96600000-0000-0000-0000-000000000020',
  '96600000-0000-0000-0000-000000000050', 'CONFIRMED', 'PAID',
  '2035-01-25 09:00:00-03', '2035-01-25 10:00:00-03', 60, 1, 340, 68, 75, 483, 0
);
insert into public.checkout_holds (
  id, public_token_hash, service_id, service_employee_id, selection_hash,
  people_count, requested_start_at, requested_end_at, expires_at, status,
  commercial_value, pricing_version, duration_minutes, quote_snapshot,
  applied_coupon_id, coupon_code_snapshot, coupon_discount, pre_discount_value, promoted_appointment_id
) values (
  '96600000-0000-0000-0000-000000000086', encode(digest('rental-only-finalized', 'sha256'), 'hex'),
  '96600000-0000-0000-0000-000000000010', '96600000-0000-0000-0000-000000000020',
  'rental-only-finalized-selection', 1,
  '2035-01-25 09:00:00-03', '2035-01-25 10:00:00-03', now() + interval '10 minutes', 'PROMOTED',
  0, 'coupon-rental-only-finalized-legacy', 60,
  '{"base_price":340,"day_time_adjustment":68,"extras_total":75,"coupon_discount":483,"commercial_value":0}'::jsonb,
  '96600000-0000-0000-0000-000000000072', 'C166FIX999', 483, 483,
  '96600000-0000-0000-0000-000000000090'
);
select throws_ok(
  $$select public.apply_checkout_coupon('rental-only-finalized', 'C166FIX999')$$,
  'P0001', 'HOLD_EXPIRED', 'coupon application cannot rewrite a finalized historical contract'
);
select throws_ok(
  $$select public.promote_checkout_hold(
    '96600000-0000-0000-0000-000000000086', '96600000-0000-0000-0000-000000000050', 'C166FIX999'
  )$$,
  'P0001', 'CHECKOUT_HOLD_EXPIRED', 'a finalized legacy hold cannot be promoted again under new pricing'
);
select is(
  (select jsonb_build_array(commercial_value, coupon_discount, extras_total)
   from public.appointments where id = '96600000-0000-0000-0000-000000000090'),
  '[0,483,75]'::jsonb, 'accepted historical amounts are preserved without retroactive extra charges'
);

select * from finish();
rollback;
