begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(9);

select ok(to_regclass('public.customer_hour_packages') is not null, 'customer_hour_packages exists');
select ok(to_regclass('public.hour_package_services') is not null, 'hour_package_services exists');
select ok(to_regclass('public.hour_package_usages') is not null, 'hour_package_usages exists');
select ok(to_regclass('public.hour_package_adjustments') is not null, 'hour_package_adjustments exists');

insert into public.customers (id, name)
values ('00000000-0000-0000-0000-000000000301', 'Cliente Pacote');

insert into public.categories (id, name, slug)
values ('00000000-0000-0000-0000-000000000401', 'Locação', 'locacao-pacote');

insert into public.services (
  id, category_id, name, slug, base_duration_minutes, base_price, minimum_people, maximum_people
) values (
  '00000000-0000-0000-0000-000000000402',
  '00000000-0000-0000-0000-000000000401',
  'Locação pacote', 'locacao-pacote-test', 120, 200, 1, 20
);

insert into public.service_employees (id, service_id, employee_id)
values (
  '00000000-0000-0000-0000-000000000403',
  '00000000-0000-0000-0000-000000000402',
  '00000000-0000-0000-0000-000000000201'
);

insert into public.availability_rules (
  service_employee_id, weekday, start_local_time, end_local_time, slot_interval_minutes
) values (
  '00000000-0000-0000-0000-000000000403', 1, '09:00', '18:00', 30
);

insert into public.customer_hour_packages (
  id, customer_id, name, purchased_seconds, valid_from, expires_at
) values (
  '00000000-0000-0000-0000-000000000501',
  '00000000-0000-0000-0000-000000000301',
  'Pacote 40h',
  144000,
  '2034-01-01 00:00:00+00',
  '2036-01-01 00:00:00+00'
);

insert into public.hour_package_services (package_id, service_id)
values (
  '00000000-0000-0000-0000-000000000501',
  '00000000-0000-0000-0000-000000000402'
);

select is(
  public.hour_package_available_seconds('00000000-0000-0000-0000-000000000501'),
  144000::bigint,
  '40h package starts with 144000 seconds'
);

select is(
  public.hour_package_surcharge_percent_for_period(
    '00000000-0000-0000-0000-000000000403',
    '2035-01-15 15:00:00+00',
    '2035-01-15 17:00:00+00'
  ),
  0.00::numeric,
  'weekday inside standard hours has no surcharge'
);

select is(
  public.hour_package_surcharge_percent_for_period(
    '00000000-0000-0000-0000-000000000403',
    '2035-01-20 15:00:00+00',
    '2035-01-20 17:00:00+00'
  ),
  15.00::numeric,
  'weekend applies one 15 percent surcharge'
);

select is(
  public.hour_package_surcharge_percent_for_period(
    '00000000-0000-0000-0000-000000000403',
    '2035-01-15 22:00:00+00',
    '2035-01-16 00:00:00+00'
  ),
  15.00::numeric,
  'outside standard hours applies 15 percent surcharge'
);

insert into public.checkout_holds (
  id, public_token_hash, service_id, service_employee_id, selection_hash,
  people_count, requested_start_at, requested_end_at, expires_at
) values (
  '00000000-0000-0000-0000-000000000601', 'test-package-hold',
  '00000000-0000-0000-0000-000000000402',
  '00000000-0000-0000-0000-000000000403',
  'selection', 1,
  '2035-01-20 15:00:00+00', '2035-01-20 17:00:00+00',
  now() + interval '10 minutes'
);

insert into public.hour_package_usages (
  package_id, checkout_hold_id, status, base_seconds, surcharge_percent, surcharge_seconds
) values (
  '00000000-0000-0000-0000-000000000501',
  '00000000-0000-0000-0000-000000000601',
  'HELD', 7200, 15, 1080
);

select is(
  public.hour_package_available_seconds('00000000-0000-0000-0000-000000000501'),
  135720::bigint,
  'held package usage immediately reduces available balance by 2h18'
);

select * from finish();
rollback;
