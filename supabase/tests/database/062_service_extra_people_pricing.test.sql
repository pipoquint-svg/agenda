begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(10);

insert into public.employees (id, name)
values ('62000000-0000-0000-0000-000000000001', 'TEST PEOPLE EMPLOYEE');

insert into public.categories (id, name, slug, operation_scope)
values ('62000000-0000-0000-0000-000000000002', 'Test people', 'test-people-pricing', 'SABRINA');

insert into public.services (
  id, category_id, name, slug, base_duration_minutes, base_price,
  minimum_people, maximum_people, price_per_extra_person, operation_scope
) values (
  '62000000-0000-0000-0000-000000000003',
  '62000000-0000-0000-0000-000000000002',
  'Test people pricing',
  'test-people-pricing-service',
  60,
  890.00,
  1,
  6,
  75.00,
  'SABRINA'
);

insert into public.service_employees (id, service_id, employee_id)
values (
  '62000000-0000-0000-0000-000000000004',
  '62000000-0000-0000-0000-000000000003',
  '62000000-0000-0000-0000-000000000001'
);

insert into public.booking_pages (id, slug, display_name, title, brand_key, require_tax_id)
values (
  '62000000-0000-0000-0000-000000000005',
  'test-people-pricing-page',
  'Test people pricing',
  'Test people pricing',
  'SABRINA',
  false
);

insert into public.booking_page_services (booking_page_id, service_id)
values (
  '62000000-0000-0000-0000-000000000005',
  '62000000-0000-0000-0000-000000000003'
);

select is(
  (public.calculate_booking_quote(
    '62000000-0000-0000-0000-000000000003',
    '62000000-0000-0000-0000-000000000004',
    '[]'::jsonb,
    6,
    null,
    null
  )->>'commercial_value')::numeric,
  890.00::numeric,
  'maximum_people is included in the base price'
);

select is(
  (public.calculate_booking_quote(
    '62000000-0000-0000-0000-000000000003',
    '62000000-0000-0000-0000-000000000004',
    '[]'::jsonb,
    6,
    null,
    null
  )->>'extra_people_count')::integer,
  0,
  'no extra person exists at the included maximum'
);

select is(
  (public.calculate_booking_quote(
    '62000000-0000-0000-0000-000000000003',
    '62000000-0000-0000-0000-000000000004',
    '[]'::jsonb,
    7,
    null,
    null
  )->>'commercial_value')::numeric,
  965.00::numeric,
  'the seventh person adds one configured surcharge'
);

select is(
  (public.calculate_booking_quote(
    '62000000-0000-0000-0000-000000000003',
    '62000000-0000-0000-0000-000000000004',
    '[]'::jsonb,
    7,
    null,
    null
  )->>'extra_people_amount')::numeric,
  75.00::numeric,
  'quote exposes the authoritative extra people amount'
);

select is(
  (public.calculate_booking_quote(
    '62000000-0000-0000-0000-000000000003',
    '62000000-0000-0000-0000-000000000004',
    '[]'::jsonb,
    8,
    null,
    null
  )->>'commercial_value')::numeric,
  1040.00::numeric,
  'each person above the included maximum adds one surcharge'
);

select is(
  (public.calculate_booking_quote(
    '62000000-0000-0000-0000-000000000003',
    '62000000-0000-0000-0000-000000000004',
    '[]'::jsonb,
    8,
    null,
    null
  )->>'extra_people_count')::integer,
  2,
  'quote exposes two extra people for eight attendees'
);

select lives_ok(
  $$select public.assert_public_booking_selection(
    'test-people-pricing-page',
    '62000000-0000-0000-0000-000000000003',
    '62000000-0000-0000-0000-000000000004',
    '[]'::jsonb,
    7
  )$$,
  'public selection accepts people above included maximum when surcharge is configured'
);

select is(
  (public.public_get_booking_page('test-people-pricing-page')->'services'->0->>'price_per_extra_person')::numeric,
  75.00::numeric,
  'public catalog exposes the configured per-person surcharge'
);

select is(
  (public.public_get_booking_page('test-people-pricing-page')->'services'->0->>'allows_extra_people')::boolean,
  true,
  'public catalog tells the UI that extra people are enabled'
);

update public.services
set price_per_extra_person = 0
where id = '62000000-0000-0000-0000-000000000003';

select throws_ok(
  $$select public.calculate_booking_quote(
    '62000000-0000-0000-0000-000000000003',
    '62000000-0000-0000-0000-000000000004',
    '[]'::jsonb,
    7,
    null,
    null
  )$$,
  'P0001',
  'PEOPLE_ABOVE_MAXIMUM',
  'service without extra-person price preserves the effective hard cap'
);

select * from finish();
rollback;
