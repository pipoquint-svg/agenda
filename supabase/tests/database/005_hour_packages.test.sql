begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(16);

insert into public.resources (id, name, resource_type)
values ('30000000-0000-0000-0000-000000000001', 'PACKAGE TEST STUDIO', 'PHYSICAL');

insert into public.employees (id, name)
values ('30000000-0000-0000-0000-000000000010', 'Package Employee');

insert into public.categories (id, name, slug)
values ('30000000-0000-0000-0000-000000000020', 'Package', 'package-test');

insert into public.services (
  id, category_id, name, slug, base_duration_minutes, base_price,
  minimum_people, maximum_people, maximum_booking_horizon_days
) values (
  '30000000-0000-0000-0000-000000000030',
  '30000000-0000-0000-0000-000000000020',
  'Package Service',
  'package-service',
  120,
  240.00,
  1,
  20,
  5000
), (
  '30000000-0000-0000-0000-000000000031',
  '30000000-0000-0000-0000-000000000020',
  'Ineligible Service',
  'package-ineligible-service',
  120,
  240.00,
  1,
  20,
  5000
);

insert into public.service_employees (id, service_id, employee_id)
values
  ('30000000-0000-0000-0000-000000000040', '30000000-0000-0000-0000-000000000030', '30000000-0000-0000-0000-000000000010'),
  ('30000000-0000-0000-0000-000000000041', '30000000-0000-0000-0000-000000000031', '30000000-0000-0000-0000-000000000010');

insert into public.service_resources (service_id, resource_id)
values
  ('30000000-0000-0000-0000-000000000030', '30000000-0000-0000-0000-000000000001'),
  ('30000000-0000-0000-0000-000000000031', '30000000-0000-0000-0000-000000000001');

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
) values (
  '30000000-0000-0000-0000-000000000070',
  '30000000-0000-0000-0000-000000000060',
  '40h Package',
  2400,
  4000.00,
  '2034-01-01 00:00:00-03',
  '2036-01-01 00:00:00-03',
  '09:00',
  '18:00'
), (
  '30000000-0000-0000-0000-000000000071',
  '30000000-0000-0000-0000-000000000060',
  'Partial Package',
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
  ('30000000-0000-0000-0000-000000000071', '30000000-0000-0000-0000-000000000030');

insert into public.hour_package_movements (
  hour_package_id, movement_type, minutes_delta, reason
) values (
  '30000000-0000-0000-0000-000000000071',
  'ADMIN_ADJUSTMENT',
  -60,
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
  ('30000000-0000-0000-0000-000000000084', 'pkg-hold-partial', '30000000-0000-0000-0000-000000000030', '30000000-0000-0000-0000-000000000040', 'pkg-partial', 1, '2035-01-15 10:00:00-03', '2035-01-15 12:00:00-03', now() + interval '10 minutes', '[{"extra_id":"30000000-0000-0000-0000-000000000050","quantity":1}]', 290.00, 'pkg-test', 120, array['30000000-0000-0000-0000-000000000001'::uuid]),
  ('30000000-0000-0000-0000-000000000085', 'pkg-hold-ineligible', '30000000-0000-0000-0000-000000000031', '30000000-0000-0000-0000-000000000041', 'pkg-ineligible', 1, '2035-01-15 10:00:00-03', '2035-01-15 12:00:00-03', now() + interval '10 minutes', '[]', 240.00, 'pkg-test', 120, array['30000000-0000-0000-0000-000000000001'::uuid]);

select is(
  (select ledger_minutes from public.hour_package_balances where hour_package_id = '30000000-0000-0000-0000-000000000070'),
  2400,
  '40-hour package starts with immutable 2400-minute credit'
);

select is(
  (public.calculate_hour_package_quote('30000000-0000-0000-0000-000000000070', '30000000-0000-0000-0000-000000000080', '30000000-0000-0000-0000-000000000060')->>'covered_minutes')::integer,
  120,
  'regular two-hour reservation is fully covered by package'
);

select is(
  (public.calculate_hour_package_quote('30000000-0000-0000-0000-000000000070', '30000000-0000-0000-0000-000000000080', '30000000-0000-0000-0000-000000000060')->>'special_surcharge_amount')::numeric,
  0.00::numeric,
  'regular weekday inside package hours has no surcharge'
);

select is(
  (public.calculate_hour_package_quote('30000000-0000-0000-0000-000000000070', '30000000-0000-0000-0000-000000000081', '30000000-0000-0000-0000-000000000060')->>'special_surcharge_amount')::numeric,
  30.00::numeric,
  'Saturday charges 15 percent over covered package reference value'
);

select is(
  (public.calculate_hour_package_quote('30000000-0000-0000-0000-000000000070', '30000000-0000-0000-0000-000000000082', '30000000-0000-0000-0000-000000000060')->>'special_surcharge_amount')::numeric,
  30.00::numeric,
  'outside standard package hours charges 15 percent'
);

select is(
  (public.calculate_hour_package_quote('30000000-0000-0000-0000-000000000070', '30000000-0000-0000-0000-000000000083', '30000000-0000-0000-0000-000000000060')->>'special_surcharge_amount')::numeric,
  30.00::numeric,
  'Saturday plus outside hours remains one 15 percent surcharge'
);

select is(
  (public.calculate_hour_package_quote('30000000-0000-0000-0000-000000000071', '30000000-0000-0000-0000-000000000084', '30000000-0000-0000-0000-000000000060')->>'covered_minutes')::integer,
  60,
  'partial package uses all 60 available minutes'
);

select is(
  (public.calculate_hour_package_quote('30000000-0000-0000-0000-000000000071', '30000000-0000-0000-0000-000000000084', '30000000-0000-0000-0000-000000000060')->>'cash_due')::numeric,
  170.00::numeric,
  'partial package charges uncovered hour at current rate plus R$50 extra'
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
  (public.reserve_hour_package_for_checkout('30000000-0000-0000-0000-000000000070', '30000000-0000-0000-0000-000000000080', '30000000-0000-0000-0000-000000000060')->>'covered_minutes')::integer,
  120,
  'checkout can reserve package minutes atomically'
);

select is(
  (select available_minutes from public.hour_package_balances where hour_package_id = '30000000-0000-0000-0000-000000000070'),
  2280,
  'held package minutes are removed from available balance'
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
  (public.consume_hour_package_checkout('30000000-0000-0000-0000-000000000080', '30000000-0000-0000-0000-000000000090')->>'covered_minutes')::integer,
  120,
  'confirming reservation converts held package minutes into ledger debit'
);

select is(
  (select sum(minutes_delta)::integer from public.hour_package_movements where hour_package_id = '30000000-0000-0000-0000-000000000070'),
  2280,
  'ledger balance reflects 120-minute reservation debit'
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
  (select ledger_minutes from public.hour_package_balances where hour_package_id = '30000000-0000-0000-0000-000000000070'),
  2400,
  'cancellation creates compensating ledger movement and restores minutes'
);

select throws_ok(
  $$ update public.hour_package_movements set reason = 'illegal edit' where hour_package_id = '30000000-0000-0000-0000-000000000070' $$,
  'P0001', 'HOUR_PACKAGE_LEDGER_IS_IMMUTABLE',
  'ledger movements cannot be edited in place'
);

select * from finish();
rollback;
