begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(15);

insert into public.employees (id, name)
values ('62000000-0000-0000-0000-000000000001', 'TEST PEOPLE EMPLOYEE');

insert into public.categories (id, name, slug, operation_scope)
values ('62000000-0000-0000-0000-000000000002', 'Test people', 'test-people-pricing', 'SABRINA');

insert into public.services (
  id, category_id, name, slug, base_duration_minutes, base_price,
  minimum_people, included_people, maximum_people, price_per_extra_person, operation_scope
) values (
  '62000000-0000-0000-0000-000000000003',
  '62000000-0000-0000-0000-000000000002',
  'Test people pricing',
  'test-people-pricing-service',
  60,
  890.00,
  1,
  6,
  15,
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

insert into public.service_change_policies(
  service_id, notice_hours,
  reschedule_first_early_percent, reschedule_first_late_percent,
  reschedule_repeat_percent, cancellation_late_percent
) values (
  '62000000-0000-0000-0000-000000000003', 48, 0, 20, 20, 20
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
    '[]'::jsonb,1,null,null
  )->>'commercial_value')::numeric,
  890.00::numeric,
  'minimum allowed person count keeps the base price'
);

select is(
  (public.calculate_booking_quote(
    '62000000-0000-0000-0000-000000000003',
    '62000000-0000-0000-0000-000000000004',
    '[]'::jsonb,6,null,null
  )->>'commercial_value')::numeric,
  890.00::numeric,
  'all six included people keep the base price'
);

select is(
  (public.calculate_booking_quote(
    '62000000-0000-0000-0000-000000000003',
    '62000000-0000-0000-0000-000000000004',
    '[]'::jsonb,7,null,null
  )->>'commercial_value')::numeric,
  965.00::numeric,
  'seventh person adds exactly one surcharge'
);

select is(
  (public.calculate_booking_quote(
    '62000000-0000-0000-0000-000000000003',
    '62000000-0000-0000-0000-000000000004',
    '[]'::jsonb,7,null,null
  )->>'extra_people_amount')::numeric,
  75.00::numeric,
  'quote exposes authoritative extra amount for seventh person'
);

select is(
  (public.calculate_booking_quote(
    '62000000-0000-0000-0000-000000000003',
    '62000000-0000-0000-0000-000000000004',
    '[]'::jsonb,8,null,null
  )->>'commercial_value')::numeric,
  1040.00::numeric,
  'eighth person means two paid extra people'
);

select is(
  (public.calculate_booking_quote(
    '62000000-0000-0000-0000-000000000003',
    '62000000-0000-0000-0000-000000000004',
    '[]'::jsonb,15,null,null
  )->>'commercial_value')::numeric,
  1565.00::numeric,
  'maximum allowed people count charges nine extra people'
);

select throws_ok(
  $$select public.calculate_booking_quote(
    '62000000-0000-0000-0000-000000000003',
    '62000000-0000-0000-0000-000000000004',
    '[]'::jsonb,16,null,null
  )$$,
  'P0001','PEOPLE_ABOVE_MAXIMUM',
  'quote rejects people above the hard maximum'
);

select lives_ok(
  $$select public.assert_public_booking_selection(
    'test-people-pricing-page',
    '62000000-0000-0000-0000-000000000003',
    '62000000-0000-0000-0000-000000000004',
    '[]'::jsonb,15
  )$$,
  'public selection accepts the configured hard maximum'
);

select throws_ok(
  $$select public.assert_public_booking_selection(
    'test-people-pricing-page',
    '62000000-0000-0000-0000-000000000003',
    '62000000-0000-0000-0000-000000000004',
    '[]'::jsonb,16
  )$$,
  'P0001','INVALID_PEOPLE_COUNT',
  'public selection rejects people above maximum'
);

select is(
  (public.public_get_booking_page('test-people-pricing-page')->'services'->0->>'included_people')::integer,
  6,
  'public catalog exposes included people'
);

select is(
  (public.public_get_booking_page('test-people-pricing-page')->'services'->0->>'maximum_people')::integer,
  15,
  'public catalog keeps maximum as hard cap'
);

select is(
  jsonb_array_length(public.public_get_booking_page('test-people-pricing-page')->'services'->0->'people_options'),
  15,
  'public catalog emits one authoritative option per allowed people count'
);

select is(
  (public.public_get_booking_page('test-people-pricing-page')->'services'->0->'people_options'->6->>'extra_people_amount')::numeric,
  75.00::numeric,
  'option seven exposes one extra-person amount'
);

select is(
  (public.public_get_booking_page('test-people-pricing-page')->'services'->0->'people_options'->14->>'extra_people_amount')::numeric,
  675.00::numeric,
  'option fifteen exposes nine extra-person amount'
);

select is(
  ((select item from jsonb_array_elements(public.service_admin_list_service_settings()) item where item->>'id'='62000000-0000-0000-0000-000000000003')->>'included_people')::integer,
  6,
  'admin service settings exposes included people'
);

select * from finish();
rollback;
