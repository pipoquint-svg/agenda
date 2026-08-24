begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(3);

insert into public.resources (id, name, resource_type)
values ('29000000-0000-0000-0000-000000000001', 'DURATION ORIGIN TEST STUDIO', 'PHYSICAL');

insert into public.employees (id, name)
values ('29000000-0000-0000-0000-000000000010', 'Duration Origin Employee');

insert into public.categories (id, name, slug)
values ('29000000-0000-0000-0000-000000000020', 'Duration Origin', 'duration-origin-category');

insert into public.services (
  id, category_id, name, slug, base_duration_minutes, base_price,
  minimum_people, maximum_people, maximum_booking_horizon_days,
  duration_mode, booking_block_minutes, minimum_booking_blocks,
  maximum_booking_blocks, price_per_block
) values (
  '29000000-0000-0000-0000-000000000030',
  '29000000-0000-0000-0000-000000000020',
  'Duration Origin Service',
  'duration-origin-service',
  60,
  100.00,
  1,
  10,
  5000,
  'BLOCKS',
  30,
  2,
  4,
  50.00
);

insert into public.service_employees (id, service_id, employee_id)
values (
  '29000000-0000-0000-0000-000000000040',
  '29000000-0000-0000-0000-000000000030',
  '29000000-0000-0000-0000-000000000010'
);

insert into public.service_resources (service_id, resource_id)
values (
  '29000000-0000-0000-0000-000000000030',
  '29000000-0000-0000-0000-000000000001'
);

insert into public.availability_rules (
  service_employee_id, weekday, start_local_time, end_local_time, slot_interval_minutes
) values (
  '29000000-0000-0000-0000-000000000040',
  1,
  '09:00',
  '12:00',
  30
);

insert into public.booking_pages (
  id, slug, display_name, title, brand_key, require_tax_id
) values (
  '29000000-0000-0000-0000-000000000050',
  'duration-origin-test',
  'Duration Origin Test',
  'Duration Origin Test',
  'BLACKSHEEP',
  false
);

insert into public.booking_page_services (booking_page_id, service_id)
values (
  '29000000-0000-0000-0000-000000000050',
  '29000000-0000-0000-0000-000000000030'
);

create temporary table duration_origin_hold as
select public.public_create_checkout_hold_duration(
  'duration-origin-test',
  '29000000-0000-0000-0000-000000000030',
  '29000000-0000-0000-0000-000000000040',
  2,
  '[]'::jsonb,
  1,
  '2035-01-15 09:00:00-03'::timestamptz
) as payload;

select is(
  (select payload->>'booking_page_slug' from duration_origin_hold),
  'duration-origin-test',
  'duration hold returns the originating booking page slug'
);

select is(
  (
    select ch.booking_page_id::text
    from public.checkout_holds ch
    where ch.id = ((select payload->>'checkout_hold_id' from duration_origin_hold))::uuid
  ),
  '29000000-0000-0000-0000-000000000050',
  'duration hold persists booking_page_id'
);

select is(
  (
    select public.public_get_checkout_context(
      (select payload->>'checkout_hold_token' from duration_origin_hold)
    )->>'booking_page_slug'
  ),
  'duration-origin-test',
  'checkout context accepts duration hold and preserves origin'
);

select * from finish();
rollback;
