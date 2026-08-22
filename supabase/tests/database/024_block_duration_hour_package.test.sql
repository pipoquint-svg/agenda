begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(6);

insert into public.categories(id, name, slug)
values ('97200000-0000-0000-0000-000000000001', 'Block Package Test', 'block-package-test');

insert into public.employees(id, name)
values ('97200000-0000-0000-0000-000000000002', 'Block Package Employee');

insert into public.services(
  id, category_id, name, slug,
  base_duration_minutes, base_price,
  buffer_before_minutes, buffer_after_minutes,
  minimum_people, maximum_people, maximum_booking_horizon_days,
  duration_mode, booking_block_minutes,
  minimum_booking_blocks, maximum_booking_blocks, price_per_block
) values (
  '97200000-0000-0000-0000-000000000003',
  '97200000-0000-0000-0000-000000000001',
  'Locação Package Blocks', 'locacao-package-blocks',
  30, 90.00,
  0, 30,
  1, 10, 5000,
  'BLOCKS', 30, 2, 12, 90.00
);

insert into public.service_employees(id, service_id, employee_id)
values (
  '97200000-0000-0000-0000-000000000004',
  '97200000-0000-0000-0000-000000000003',
  '97200000-0000-0000-0000-000000000002'
);

insert into public.extras(id, name, price, duration_delta_minutes)
values ('97200000-0000-0000-0000-000000000005', 'Preparação Package Block', 50.00, 30);

insert into public.service_extras(
  service_id, extra_id, max_quantity, schedule_placement, default_schedule_minutes
) values (
  '97200000-0000-0000-0000-000000000003',
  '97200000-0000-0000-0000-000000000005',
  1, 'PREPEND', 30
);

insert into public.customers(id, name, email, phone)
values (
  '97200000-0000-0000-0000-000000000006',
  'Block Package Customer', 'block-package@test.invalid', '+5548999999777'
);

insert into public.hour_packages(
  id, customer_id, name, total_minutes, purchased_value,
  valid_from, valid_until, standard_start_local_time, standard_end_local_time
) values (
  '97200000-0000-0000-0000-000000000007',
  '97200000-0000-0000-0000-000000000006',
  'Block Package 40h', 2400, 4000.00,
  '2034-01-01 00:00:00-03', '2036-01-01 00:00:00-03',
  '09:00', '18:00'
);

insert into public.hour_package_services(hour_package_id, service_id)
values (
  '97200000-0000-0000-0000-000000000007',
  '97200000-0000-0000-0000-000000000003'
);

-- Customer arrives at 09:30 for a 30m PREPEND extra. Contracted rental is 10:00-12:00.
-- Studio service buffer after 12:00 is operational and also must not consume package time.
insert into public.checkout_holds(
  id, public_token_hash, service_id, service_employee_id, selection_hash,
  people_count, requested_start_at, requested_end_at,
  core_start_at, core_end_at,
  pre_service_minutes, post_service_minutes,
  expires_at, extra_selections, commercial_value, pricing_version,
  duration_minutes, duration_blocks, contracted_minutes, resource_ids,
  primary_customer_id
) values (
  '97200000-0000-0000-0000-000000000008',
  'block-package-hold',
  '97200000-0000-0000-0000-000000000003',
  '97200000-0000-0000-0000-000000000004',
  'block-package-selection',
  1,
  '2035-01-15 09:30:00-03', '2035-01-15 12:00:00-03',
  '2035-01-15 10:00:00-03', '2035-01-15 12:00:00-03',
  30, 0,
  now() + interval '10 minutes',
  '[{"extra_id":"97200000-0000-0000-0000-000000000005","quantity":1}]'::jsonb,
  410.00, 'block-package-test',
  150, 4, 120, '{}'::uuid[],
  '97200000-0000-0000-0000-000000000006'
);

select is(
  (public.calculate_hour_package_quote(
    '97200000-0000-0000-0000-000000000007',
    '97200000-0000-0000-0000-000000000008',
    '97200000-0000-0000-0000-000000000006'
  )->>'required_minutes')::integer,
  120,
  'package requires only the 120 contracted minutes'
);

select is(
  (public.calculate_hour_package_quote(
    '97200000-0000-0000-0000-000000000007',
    '97200000-0000-0000-0000-000000000008',
    '97200000-0000-0000-0000-000000000006'
  )->>'required_seconds')::bigint,
  7200::bigint,
  'package excludes PREPEND extra and post buffer from time consumption'
);

select is(
  (public.calculate_hour_package_quote(
    '97200000-0000-0000-0000-000000000007',
    '97200000-0000-0000-0000-000000000008',
    '97200000-0000-0000-0000-000000000006'
  )->>'extras_cash_amount')::numeric(12,2),
  50.00::numeric(12,2),
  'extra remains a cash item even though it adds schedule time'
);

select is(
  (public.calculate_hour_package_quote(
    '97200000-0000-0000-0000-000000000007',
    '97200000-0000-0000-0000-000000000008',
    '97200000-0000-0000-0000-000000000006'
  )->>'cash_due')::numeric(12,2),
  50.00::numeric(12,2),
  'cash due contains the extra while rental time is covered by package'
);

select is(
  (public.calculate_hour_package_quote(
    '97200000-0000-0000-0000-000000000007',
    '97200000-0000-0000-0000-000000000008',
    '97200000-0000-0000-0000-000000000006'
  )->>'surcharge_seconds')::bigint,
  0::bigint,
  '09:30 PREPEND does not falsely make a 10:00-12:00 rental special-period time'
);

select is(
  (public.reserve_hour_package_for_checkout(
    '97200000-0000-0000-0000-000000000007',
    '97200000-0000-0000-0000-000000000008',
    '97200000-0000-0000-0000-000000000006'
  )->>'charged_seconds')::bigint,
  7200::bigint,
  'actual package hold reserves exactly contracted rental time'
);

select * from finish();
rollback;
