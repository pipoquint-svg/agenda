begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(8);

insert into public.resources (id, name, resource_type)
values
  ('10000000-0000-0000-0000-000000000001', 'TEST STUDIO', 'PHYSICAL'),
  ('10000000-0000-0000-0000-000000000002', 'TEST MAKEUP', 'PHYSICAL');

insert into public.employees (id, name, resource_id)
values (
  '10000000-0000-0000-0000-000000000010',
  'Test Employee',
  null
);

insert into public.categories (id, name, slug)
values ('10000000-0000-0000-0000-000000000020', 'Test', 'test-pricing');

insert into public.services (
  id, category_id, name, slug, base_duration_minutes, base_price,
  minimum_people, maximum_people
) values (
  '10000000-0000-0000-0000-000000000030',
  '10000000-0000-0000-0000-000000000020',
  'Pricing Service',
  'pricing-service',
  60,
  100.00,
  1,
  10
);

insert into public.service_employees (id, service_id, employee_id)
values (
  '10000000-0000-0000-0000-000000000040',
  '10000000-0000-0000-0000-000000000030',
  '10000000-0000-0000-0000-000000000010'
);

insert into public.service_resources (service_id, resource_id)
values (
  '10000000-0000-0000-0000-000000000030',
  '10000000-0000-0000-0000-000000000001'
);

insert into public.extras (id, name, price, duration_delta_minutes)
values (
  '10000000-0000-0000-0000-000000000050',
  'Makeup',
  20.00,
  30
);

insert into public.service_extras (service_id, extra_id, max_quantity)
values (
  '10000000-0000-0000-0000-000000000030',
  '10000000-0000-0000-0000-000000000050',
  1
);

insert into public.extra_resources (extra_id, resource_id)
values (
  '10000000-0000-0000-0000-000000000050',
  '10000000-0000-0000-0000-000000000002'
);

insert into public.pricing_rules (
  id, service_id, name, rule_scope, days_of_week,
  action_type, amount, priority
) values (
  '10000000-0000-0000-0000-000000000060',
  '10000000-0000-0000-0000-000000000030',
  'Saturday surcharge',
  'DAY_TIME',
  array[6]::smallint[],
  'ADD_AMOUNT',
  20.00,
  10
);

insert into public.pricing_rules (
  id, service_id, name, rule_scope, days_of_week,
  start_local_time, end_local_time,
  action_type, amount, priority
) values (
  '10000000-0000-0000-0000-000000000061',
  '10000000-0000-0000-0000-000000000030',
  'Evening surcharge',
  'DAY_TIME',
  array[6]::smallint[],
  '18:00',
  '23:59:59',
  'ADD_AMOUNT',
  40.00,
  20
);

insert into public.pricing_rules (
  id, service_id, name, rule_scope, min_people, max_people,
  action_type, amount, priority
) values (
  '10000000-0000-0000-0000-000000000062',
  '10000000-0000-0000-0000-000000000030',
  'Six to ten people',
  'PEOPLE',
  6,
  10,
  'ADD_AMOUNT',
  100.00,
  10
);

insert into public.coupons (id, code, discount_type, discount_value)
values (
  '10000000-0000-0000-0000-000000000070',
  'TEST10',
  'PERCENT',
  10.00
);

insert into public.coupon_services (coupon_id, service_id)
values (
  '10000000-0000-0000-0000-000000000070',
  '10000000-0000-0000-0000-000000000030'
);

select is(
  (public.calculate_booking_quote(
    '10000000-0000-0000-0000-000000000030',
    '10000000-0000-0000-0000-000000000040',
    '[]'::jsonb,
    4,
    '2026-08-22 14:00:00-03'::timestamptz,
    null
  )->>'commercial_value')::numeric,
  120.00::numeric,
  'Saturday rule is applied before slot display'
);

select is(
  (public.calculate_booking_quote(
    '10000000-0000-0000-0000-000000000030',
    '10000000-0000-0000-0000-000000000040',
    '[]'::jsonb,
    6,
    '2026-08-22 14:00:00-03'::timestamptz,
    null
  )->>'commercial_value')::numeric,
  220.00::numeric,
  'people rule is applied before slot display'
);

select is(
  (public.calculate_booking_quote(
    '10000000-0000-0000-0000-000000000030',
    '10000000-0000-0000-0000-000000000040',
    '[]'::jsonb,
    6,
    '2026-08-22 18:30:00-03'::timestamptz,
    null
  )->>'commercial_value')::numeric,
  260.00::numeric,
  'time-band pricing stacks deterministically'
);

select is(
  (public.calculate_booking_quote(
    '10000000-0000-0000-0000-000000000030',
    '10000000-0000-0000-0000-000000000040',
    '[{"extra_id":"10000000-0000-0000-0000-000000000050","quantity":1}]'::jsonb,
    6,
    '2026-08-22 18:30:00-03'::timestamptz,
    null
  )->>'commercial_value')::numeric,
  280.00::numeric,
  'extras are added after variable pricing'
);

select is(
  (public.calculate_booking_quote(
    '10000000-0000-0000-0000-000000000030',
    '10000000-0000-0000-0000-000000000040',
    '[{"extra_id":"10000000-0000-0000-0000-000000000050","quantity":1}]'::jsonb,
    6,
    '2026-08-22 18:30:00-03'::timestamptz,
    'TEST10'
  )->>'commercial_value')::numeric,
  252.00::numeric,
  'coupon is applied after extras'
);

select is(
  (public.calculate_booking_quote(
    '10000000-0000-0000-0000-000000000030',
    '10000000-0000-0000-0000-000000000040',
    '[{"extra_id":"10000000-0000-0000-0000-000000000050","quantity":1}]'::jsonb,
    6,
    '2026-08-22 18:30:00-03'::timestamptz,
    'TEST10'
  )->>'duration_minutes')::integer,
  90,
  'extra duration is included before availability'
);

select is(
  jsonb_array_length(public.calculate_booking_quote(
    '10000000-0000-0000-0000-000000000030',
    '10000000-0000-0000-0000-000000000040',
    '[{"extra_id":"10000000-0000-0000-0000-000000000050","quantity":1}]'::jsonb,
    6,
    '2026-08-22 18:30:00-03'::timestamptz,
    'TEST10'
  )->'resource_ids'),
  2,
  'service and extra resources are both required'
);

select ok(
  length(public.calculate_booking_quote(
    '10000000-0000-0000-0000-000000000030',
    '10000000-0000-0000-0000-000000000040',
    '[]'::jsonb,
    4,
    '2026-08-22 14:00:00-03'::timestamptz,
    null
  )->>'pricing_version') = 32,
  'pricing quote returns a deterministic version hash'
);

select * from finish();
rollback;
