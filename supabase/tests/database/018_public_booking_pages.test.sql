begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(19);

select has_table('public', 'booking_pages', 'public booking pages exist');

select is(
  (select count(*)::integer from public.booking_pages where slug in ('sabrina','blacksheep')),
  2,
  'Sabrina and BlackSheep public page shells are seeded without guessing services'
);

select ok(
  has_function_privilege('anon', 'public.public_get_booking_page(text)', 'EXECUTE'),
  'anonymous users can load the page-scoped catalog wrapper'
);

select ok(
  not has_function_privilege('anon', 'public.calculate_booking_quote(uuid,uuid,jsonb,integer,timestamptz,text)', 'EXECUTE'),
  'anonymous users cannot execute core quote directly'
);

select ok(
  not has_function_privilege('anon', 'public.list_available_slots(uuid,uuid,jsonb,integer,date,text)', 'EXECUTE'),
  'anonymous users cannot execute core availability directly'
);

select ok(
  not has_function_privilege('anon', 'public.create_checkout_hold(uuid,uuid,jsonb,integer,timestamptz)', 'EXECUTE'),
  'anonymous users cannot create a core hold without page validation'
);

insert into public.categories (id, name, slug)
values ('95000000-0000-0000-0000-000000000001', 'Public Booking Test', 'public-booking-test');

insert into public.resources (id, name, resource_type)
values
  ('95000000-0000-0000-0000-000000000002', 'PUBLIC TEST ESTUDIO', 'PHYSICAL'),
  ('95000000-0000-0000-0000-000000000003', 'PUBLIC TEST PROFISSIONAL', 'PERSON');

insert into public.employees (id, name, resource_id)
values (
  '95000000-0000-0000-0000-000000000004',
  'Profissional Public Test',
  '95000000-0000-0000-0000-000000000003'
);

insert into public.services (
  id, category_id, name, slug, short_description,
  base_duration_minutes, base_price,
  minimum_people, maximum_people,
  maximum_booking_horizon_days, checkout_hold_minutes
) values (
  '95000000-0000-0000-0000-000000000005',
  '95000000-0000-0000-0000-000000000001',
  'Ensaio Public Test',
  'ensaio-public-test',
  'Serviço fixture do fluxo público',
  60, 100.00,
  1, 3,
  5000, 10
);

insert into public.service_employees (id, service_id, employee_id)
values (
  '95000000-0000-0000-0000-000000000006',
  '95000000-0000-0000-0000-000000000005',
  '95000000-0000-0000-0000-000000000004'
);

insert into public.service_resources (service_id, resource_id, is_required)
values
  ('95000000-0000-0000-0000-000000000005', '95000000-0000-0000-0000-000000000002', true),
  ('95000000-0000-0000-0000-000000000005', '95000000-0000-0000-0000-000000000003', true);

insert into public.extras (id, name, description, price, duration_delta_minutes)
values (
  '95000000-0000-0000-0000-000000000007',
  'Preparação Public Test',
  'Extra obrigatório que antecipa a chegada',
  50.00,
  30
);

insert into public.service_extras (
  service_id, extra_id, sort_order, is_required, max_quantity,
  schedule_placement, default_schedule_minutes
) values (
  '95000000-0000-0000-0000-000000000005',
  '95000000-0000-0000-0000-000000000007',
  10, true, 1,
  'PREPEND', 30
);

insert into public.extra_resources (extra_id, resource_id, is_required)
values (
  '95000000-0000-0000-0000-000000000007',
  '95000000-0000-0000-0000-000000000002',
  true
);

-- 2030-01-01 is Tuesday (PostgreSQL DOW = 2).
insert into public.availability_rules (
  service_employee_id, weekday, start_local_time, end_local_time, slot_interval_minutes
) values (
  '95000000-0000-0000-0000-000000000006',
  2, '09:00', '11:00', 30
);

insert into public.resource_availability_rules (
  resource_id, weekday, start_local_time, end_local_time
) values
  ('95000000-0000-0000-0000-000000000002', 2, '08:00', '11:00'),
  ('95000000-0000-0000-0000-000000000003', 2, '09:00', '11:00');

insert into public.booking_page_services (booking_page_id, service_id, sort_order)
select id, '95000000-0000-0000-0000-000000000005', 10
from public.booking_pages
where slug = 'sabrina';

select is(
  jsonb_array_length(public.public_get_booking_page('sabrina')->'services'),
  1,
  'public Sabrina page returns only explicitly assigned services'
);

select is(
  jsonb_array_length(public.public_get_booking_page('sabrina')->'services'->0->'employees'),
  1,
  'public page returns the service employee relation needed by availability'
);

select is(
  jsonb_array_length(public.public_get_booking_page('sabrina')->'services'->0->'extras'),
  1,
  'public page returns the reusable extra configuration'
);

select throws_ok(
  $$
    select public.public_quote_booking(
      'sabrina',
      '95000000-0000-0000-0000-000000000005',
      '95000000-0000-0000-0000-000000000006',
      '[]'::jsonb,
      1
    )
  $$,
  'P0001',
  'REQUIRED_EXTRA_MISSING',
  'required extras cannot be bypassed by a crafted public request'
);

select throws_ok(
  $$
    select public.public_quote_booking(
      'sabrina',
      '95000000-0000-0000-0000-000000000005',
      '95000000-0000-0000-0000-000000000006',
      '[{"extra_id":"95000000-0000-0000-0000-000000000007","quantity":1}]'::jsonb,
      4
    )
  $$,
  'P0001',
  'INVALID_PEOPLE_COUNT',
  'people limits are enforced server-side'
);

select throws_ok(
  $$
    select public.public_quote_booking(
      'blacksheep',
      '95000000-0000-0000-0000-000000000005',
      '95000000-0000-0000-0000-000000000006',
      '[{"extra_id":"95000000-0000-0000-0000-000000000007","quantity":1}]'::jsonb,
      1
    )
  $$,
  'P0001',
  'PUBLIC_SERVICE_NOT_AVAILABLE_ON_PAGE',
  'a service cannot be booked through another brand page'
);

select is(
  (public.public_quote_booking(
    'sabrina',
    '95000000-0000-0000-0000-000000000005',
    '95000000-0000-0000-0000-000000000006',
    '[{"extra_id":"95000000-0000-0000-0000-000000000007","quantity":1}]'::jsonb,
    1
  )->>'commercial_value')::numeric(12,2),
  150.00::numeric(12,2),
  'public quote uses the authoritative pricing engine'
);

select ok(
  exists (
    select 1
    from public.public_list_available_slots(
      'sabrina',
      '95000000-0000-0000-0000-000000000005',
      '95000000-0000-0000-0000-000000000006',
      '[{"extra_id":"95000000-0000-0000-0000-000000000007","quantity":1}]'::jsonb,
      1,
      '2030-01-01'::date
    ) s
    where s.slot_start_at = '2030-01-01 08:30:00-03'::timestamptz
      and s.core_start_at = '2030-01-01 09:00:00-03'::timestamptz
      and s.pre_service_minutes = 30
      and s.commercial_value = 150.00
  ),
  'public availability shows arrival at 08:30 while preserving the 09:00 core anchor'
);

create temporary table public_hold as
select public.public_create_checkout_hold(
  'sabrina',
  '95000000-0000-0000-0000-000000000005',
  '95000000-0000-0000-0000-000000000006',
  '[{"extra_id":"95000000-0000-0000-0000-000000000007","quantity":1}]'::jsonb,
  1,
  '2030-01-01 08:30:00-03'::timestamptz
) as payload;

select ok(
  length((select payload->>'checkout_hold_token' from public_hold)) >= 32,
  'clicking the public slot creates an opaque checkout hold token'
);

select is(
  (select count(*)::integer
   from public.resource_allocations ra
   where ra.checkout_hold_id = ((select payload->>'checkout_hold_id' from public_hold))::uuid
     and ra.status = 'HELD'),
  2,
  'the public hold protects all required physical/person resources using the core exclusion model'
);

select is(
  (select lower(occupied_range)
   from public.resource_allocations ra
   where ra.checkout_hold_id = ((select payload->>'checkout_hold_id' from public_hold))::uuid
     and ra.resource_id = '95000000-0000-0000-0000-000000000002'),
  '2030-01-01 08:30:00-03'::timestamptz,
  'the extra preparation phase protects the studio from the earlier arrival time'
);

select throws_ok(
  $$
    select public.public_create_checkout_hold(
      'sabrina',
      '95000000-0000-0000-0000-000000000005',
      '95000000-0000-0000-0000-000000000006',
      '[{"extra_id":"95000000-0000-0000-0000-000000000007","quantity":1}]'::jsonb,
      1,
      '2030-01-01 08:30:00-03'::timestamptz
    )
  $$,
  'P0001',
  'SLOT_NO_LONGER_AVAILABLE',
  'a second public hold cannot take the same protected slot'
);

select ok(
  not has_table_privilege('anon', 'public.booking_pages', 'SELECT'),
  'anonymous callers cannot bypass the public catalog function with direct table reads'
);

select * from finish();
rollback;
