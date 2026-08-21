begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(18);

insert into public.resources (id, name, resource_type)
values ('30000000-0000-0000-0000-000000000001', 'PACKAGE TEST STUDIO', 'PHYSICAL');

insert into public.employees (id, name)
values ('30000000-0000-0000-0000-000000000010', 'Package Employee');

insert into public.categories (id, name, slug)
values ('30000000-0000-0000-0000-000000000020', 'Package', 'package-test');

insert into public.services (
  id, category_id, name, slug, base_duration_minutes, base_price,
  minimum_people, maximum_people, maximum_booking_horizon_days
) values
  (
    '30000000-0000-0000-0000-000000000030',
    '30000000-0000-0000-0000-000000000020',
    'Package Service',
    'package-service',
    120,
    240.00,
    1,
    20,
    5000
  ),
  (
    '30000000-0000-0000-0000-000000000031',
    '30000000-0000-0000-0000-000000000020',
    'Ineligible Service',
    'package-ineligible-service',
    120,
    240.00,
    1,
    20,
    5000
  ),
  (
    '30000000-0000-0000-0000-000000000032',
    '30000000-0000-0000-0000-000000000020',
    'Fifty Minute Package Service',
    'package-fifty-minute-service',
    50,
    100.00,
    1,
    20,
    5000
  );

insert into public.service_employees (id, service_id, employee_id)
values
  ('30000000-0000-0000-0000-000000000040', '30000000-0000-0000-0000-000000000030', '30000000-0000-0000-0000-000000000010'),
  ('30000000-0000-0000-0000-000000000041', '30000000-0000-0000-0000-000000000031', '30000000-0000-0000-0000-000000000010'),
  ('30000000-0000-0000-0000-000000000042', '30000000-0000-0000-0000-000000000032', '30000000-0000-0000-0000-000000000010');

insert into public.service_resources (service_id, resource_id)
values
  ('30000000-0000-0000-0000-000000000030', '30000000-0000-0000-0000-000000000001'),
  ('30000000-0000-0000-0000-000000000031', '30000000-0000-0000-0000-000000000001'),
  ('30000000-0000-0000-0000-000000000032', '30000000-0000-0000-0000-000000000001');

insert into public.extras (id, name, price, duration_delta_minutes)
values ('30000000-0000-0000-0000-000000000050', 'Package Cash Extra', 50.00, 0);

insert into public.service_extras (service_id, extra_id, max_quantity)
values ('30000000-0000-0000-0000-000000000030', '30000000-0000-0000-0000-000000000050', 1);

insert into public.customers (id, name, email, phone)
values
  ('30000000-0000-0000-0000-000000000060', 'Package Customer', 'package@example.com', '+5548999999001'),
  ('30000000-0000-0000-0000-000000000061', 'Wrong Customer', 'wrong@example.com', '+5548999999002');

insert into public.hour_packages (
  id, customer_id, name, total_minutes, purchased_value,
  valid_from, valid_until, standard_start_local_time, standard_end_local_time
) values
  (
    '30000000-0000-0000-0000-000000000070',
    '30000000-0000-0000-0000-000000000060',
    '40h Package',
    2400,
    4000.00,
    '2034-01-01 00:00:00-03',
    '2036-01-01 00:00:00-03',
    '09:00',
    '18:00'
  ),
  (
    '30000000-0000-0000-0000-000000000071',
    '30000000-0000-0000-0000-000000000060',
    'Insufficient Package',
    120,
    200.00,
    '2034-01-01 00:00:00-03',
    '2036-01-01 00:00:00-03',
    '09:00',
    '18:00'
  );

insert into public.hour_package_services (hour_package_id, service_id)
values
  ('30000000-0000-0000-0000-000000000070', '30000000-0000-0000-0000-000000000030'),
  ('30000000-0000-0000-0000-000000000070', '30000000-0000-0000-0000-000000000032'),
  ('30000000-0000-0000-0000-000000000071', '30000000-0000-0000-0000-000000000030');

insert into public.hour_package_movements (
  hour_package_id, movement_type, minutes_delta, seconds_delta, reason
) values (
  '30000000-0000-0000-0000-000000000071',
  'ADMIN_ADJUSTMENT',
  -60,
  -3600,
  'Fixture leaves only 60 minutes available'
);

insert into public.checkout_holds (
  id, public_token_hash, service_id, service_employee_id, selection_hash,
  people_count, requested_start_at, requested_end_at, expires_at,
  extra_selections, commercial_value, pricing_version, duration_minutes, resource_ids
) values
  ('30000000-0000-0000-0000-000000000080', 'pkg-hold-regular', '30000000-0000-0000-0000-000000000030', '30000000-0000-0000-0000-000000000040', 'pkg-regular', 1, '2035-01-15 10:00:00-03', '2035-01-15 12:00:00-03', now() + interval '10 minutes', '[]', 240.00, 'pkg-test', 120, array['30000000-0000-0000-0000-000000000001'::uuid]),
  ('30000000-0000-0000-0000-000000000081', 'pkg-hold-saturday', '30000000-0000-0000-0000-000000000030', '30000000-0000-0000-0000-000000000040', 'pkg-saturday', 1, '2035-01-13 10:00:00-03', '2035-01-13 12:00:00-03', now() + interval '10 minutes', '[]', 240.00, 'pkg-test', 120, array['30000000-0000-0000-0000-000000000001'::uuid]),
  ('30000000-0000-0000-0000-000000000082', 'pkg-hold-outside', '30000000-0000-0000-0000-000000000030', '30000000-0000-0000-0000-000000000040', 'pkg-outside', 1, '2035-01-15 19:00:00-03', '2035-01-15 21:00:00-03', now() + interval '10 minutes', '[]', 240.00, 'pkg-test', 120, array['30000000-0000-0000-0000-000000000001'::uuid]),
  ('30000000-0000-0000-0000-000000000083', 'pkg-hold-both', '30000000-0000-0000-0000-000000000030', '30000000-0000-0000-0000-000000000040', 'pkg-both', 1, '2035-01-13 19:00:00-03', '2035-01-13 21:00:00-03', now() + interval '10 minutes', '[]', 240.00, 'pkg-test', 120, array['30000000-0000-0000-0000-000000000001'::uuid]),
  ('30000000-0000-0000-0000-000000000084', 'pkg-hold-extra', '30000000-0000-0000-0000-000000000030', '30000000-0000-0000-0000-000000000040', 'pkg-extra', 1, '2035-01-15 10:00:00-03', '2035-01-15 12:00:00-03', now() + interval '10 minutes', '[{"extra_id":"30000000-0000-0000-0000-000000000050","quantity":1}]', 290.00, 'pkg-test', 120, array['30000000-0000-0000-0000-000000000001'::uuid]),
  ('30000000-0000-0000-0000-000000000085', 'pkg-hold-ineligible', '30000000-0000-0000-0000-000000000031', '30000000-0000-0000-0000-000000000041', 'pkg-ineligible', 1, '2035-01-15 10:00:00-03', '2035-01-15 12:00:00-03', now() + interval '10 minutes', '[]', 240.00, 'pkg-test', 120, array['30000000-0000-0000-0000-000000000001'::uuid]),
  ('30000000-0000-0000-0000-000000000086', 'pkg-hold-fifty', '30000000-0000-0000-0000-000000000032', '30000000-0000-0000-0000-000000000042', 'pkg-fifty', 1, '2035-01-13 10:00:00-03', '2035-01-13 10:50:00-03', now() + interval '10 minutes', '[]', 100.00, 'pkg-test', 50, array['30000000-0000-0000-0000-000000000001'::uuid]);

select is(
  (select ledger_seconds from public.hour_package_balances where hour_package_id = '30000000-0000-0000-0000-000000000070'),
  144000::bigint,
  '40-hour package starts with exact 144000-second credit'
);

select is(
  (public.calculate_hour_package_quote('30000000-0000-0000-0000-000000000070', '30000000-0000-0000-0000-000000000080', '30000000-0000-0000-0000-000000000060')->>'charged_seconds')::bigint,
  7200::bigint,
  'regular two-hour reservation consumes exactly two hours'
);

select is(
  (public.calculate_hour_package_quote('30000000-0000-0000-0000-000000000070', '30000000-0000-0000-0000-000000000080', '30000000-0000-0000-0000-000000000060')->>'surcharge_seconds')::bigint,
  0::bigint,
  'regular weekday inside standard hours has no time surcharge'
);

select is(
  (public.calculate_hour_package_quote('30000000-0000-0000-0000-000000000070', '30000000-0000-0000-0000-000000000081', '30000000-0000-0000-0000-000000000060')->>'surcharge_seconds')::bigint,
  1080::bigint,
  'Saturday adds 15 percent as package time'
);

select is(
  (public.calculate_hour_package_quote('30000000-0000-0000-0000-000000000070', '30000000-0000-0000-0000-000000000081', '30000000-0000-0000-0000-000000000060')->>'charged_seconds')::bigint,
  8280::bigint,
  'two-hour Saturday reservation consumes 2h18 from balance'
);

select is(
  (public.calculate_hour_package_quote('30000000-0000-0000-0000-000000000070', '30000000-0000-0000-0000-000000000082', '30000000-0000-0000-0000-000000000060')->>'charged_seconds')::bigint,
  8280::bigint,
  'outside standard hours also consumes 115 percent of time'
);

select is(
  (public.calculate_hour_package_quote('30000000-0000-0000-0000-000000000070', '30000000-0000-0000-0000-000000000083', '30000000-0000-0000-0000-000000000060')->>'charged_seconds')::bigint,
  8280::bigint,
  'weekend plus outside hours applies one 15 percent surcharge, never 30 percent'
);

select is(
  (public.calculate_hour_package_quote('30000000-0000-0000-0000-000000000070', '30000000-0000-0000-0000-000000000086', '30000000-0000-0000-0000-000000000060')->>'charged_seconds')::bigint,
  3450::bigint,
  '50-minute special-period reservation consumes exactly 57m30s'
);

select throws_ok(
  $$ select public.calculate_hour_package_quote('30000000-0000-0000-0000-000000000071', '30000000-0000-0000-0000-000000000084', '30000000-0000-0000-0000-000000000060') $$,
  'P0001', 'HOUR_PACKAGE_INSUFFICIENT_BALANCE',
  'package with only 60 minutes cannot partially cover a 120-minute reservation'
);

select is(
  (public.calculate_hour_package_quote('30000000-0000-0000-0000-000000000070', '30000000-0000-0000-0000-000000000084', '30000000-0000-0000-0000-000000000060')->>'cash_due')::numeric,
  50.00::numeric,
  'package covers eligible rental time while non-covered extra remains cash'
);

select throws_ok(
  $$ select public.calculate_hour_package_quote('30000000-0000-0000-0000-000000000070', '30000000-0000-0000-0000-000000000080', '30000000-0000-0000-0000-000000000061') $$,
  'P0001', 'HOUR_PACKAGE_CUSTOMER_MISMATCH',
  'package cannot be used by another customer'
);

select throws_ok(
  $$ select public.calculate_hour_package_quote('30000000-0000-0000-0000-000000000070', '30000000-0000-0000-0000-000000000085', '30000000-0000-0000-0000-000000000060') $$,
  'P0001', 'HOUR_PACKAGE_SERVICE_NOT_ELIGIBLE',
  'package cannot be used for a service not explicitly eligible'
);

select is(
  (public.reserve_hour_package_for_checkout('30000000-0000-0000-0000-000000000070', '30000000-0000-0000-0000-000000000080', '30000000-0000-0000-0000-000000000060')->>'charged_seconds')::bigint,
  7200::bigint,
  'checkout reserves exact package seconds atomically'
);

select is(
  (select available_seconds from public.hour_package_balances where hour_package_id = '30000000-0000-0000-0000-000000000070'),
  136800::bigint,
  'held package time is removed from exact available balance'
);

insert into public.appointments (
  id, public_code, service_id, service_employee_id, primary_customer_id,
  status, financial_status, start_at, end_at, duration_minutes, people_count
) values (
  '30000000-0000-0000-0000-000000000090',
  'PACKAGE-APPT-001',
  '30000000-0000-0000-0000-000000000030',
  '30000000-0000-0000-0000-000000000040',
  '30000000-0000-0000-0000-000000000060',
  'CONFIRMED', 'NOT_STARTED',
  '2035-01-15 10:00:00-03', '2035-01-15 12:00:00-03', 120, 1
);

select is(
  (public.consume_hour_package_checkout('30000000-0000-0000-0000-000000000080', '30000000-0000-0000-0000-000000000090')->>'charged_seconds')::bigint,
  7200::bigint,
  'confirming reservation converts held seconds into exact ledger debit'
);

select is(
  (select ledger_seconds from public.hour_package_balances where hour_package_id = '30000000-0000-0000-0000-000000000070'),
  136800::bigint,
  'ledger reflects exact reservation debit'
);

do $$
begin
  perform public.reverse_hour_package_usage(
    '30000000-0000-0000-0000-000000000090',
    'TEST_CANCELLATION'
  );
end;
$$;

select is(
  (select ledger_seconds from public.hour_package_balances where hour_package_id = '30000000-0000-0000-0000-000000000070'),
  144000::bigint,
  'cancellation reversal restores exact consumed seconds'
);

select throws_ok(
  $$ update public.hour_package_movements set reason = 'illegal edit' where hour_package_id = '30000000-0000-0000-0000-000000000070' $$,
  'P0001', 'HOUR_PACKAGE_LEDGER_IS_IMMUTABLE',
  'ledger movements remain immutable'
);

select * from finish();
rollback;
