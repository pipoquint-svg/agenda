begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(13);

insert into public.categories (id, name, slug)
values ('00000000-0000-0000-0000-000000000311', 'Locação', 'locacao-pacote')
on conflict do nothing;

insert into public.services (
  id, category_id, name, slug, base_duration_minutes, base_price, minimum_people, maximum_people
)
values (
  '00000000-0000-0000-0000-000000000411',
  '00000000-0000-0000-0000-000000000311',
  'Locação por pacote', 'locacao-pacote', 60, 180, 1, 20
)
on conflict do nothing;

insert into public.service_employees (id, service_id, employee_id)
values (
  '00000000-0000-0000-0000-000000000511',
  '00000000-0000-0000-0000-000000000411',
  '00000000-0000-0000-0000-000000000201'
)
on conflict do nothing;

insert into public.availability_rules (
  service_employee_id, weekday, start_local_time, end_local_time, slot_interval_minutes, availability_class
)
values
  (
    '00000000-0000-0000-0000-000000000511',
    6, '09:00', '18:00', 30, 'REGULAR'
  ),
  (
    '00000000-0000-0000-0000-000000000511',
    1, '18:00', '22:00', 30, 'SPECIAL'
  );

insert into public.extras (id, name, price, duration_delta_minutes)
values (
  '00000000-0000-0000-0000-000000000911',
  'Extra equipamento',
  80,
  0
);

insert into public.service_extras (service_id, extra_id, max_quantity)
values (
  '00000000-0000-0000-0000-000000000411',
  '00000000-0000-0000-0000-000000000911',
  1
);

insert into public.customers (id, name, email, phone)
values (
  '00000000-0000-0000-0000-000000000611',
  'Cliente Pacote', 'pacote@example.com', '+5548999999999'
);

insert into public.customer_time_packages (
  id, customer_id, name, total_minutes, valid_from, expires_at, purchase_amount
)
values (
  '00000000-0000-0000-0000-000000000711',
  '00000000-0000-0000-0000-000000000611',
  'Pacote 40 horas',
  2400,
  '2000-01-01 00:00:00+00',
  '2100-01-01 00:00:00+00',
  4000
);

insert into public.time_package_services (package_id, service_id)
values (
  '00000000-0000-0000-0000-000000000711',
  '00000000-0000-0000-0000-000000000411'
);

select is(
  (select special_time_surcharge_percent
   from public.customer_time_packages
   where id = '00000000-0000-0000-0000-000000000711'::uuid),
  15.00::numeric,
  'package special-time surcharge defaults to 15 percent'
);

select is(
  (select covered_value from public.calculate_time_package_quote(
    '00000000-0000-0000-0000-000000000711'::uuid,
    120,
    '2035-01-13 10:00:00-03'::timestamptz,
    'REGULAR',
    0
  )),
  200.00::numeric,
  'two hours consume proportional package value of R$200'
);

select is(
  (select surcharge_amount from public.calculate_time_package_quote(
    '00000000-0000-0000-0000-000000000711'::uuid,
    120,
    '2035-01-13 10:00:00-03'::timestamptz,
    'REGULAR',
    0
  )),
  30.00::numeric,
  'weekend charges 15 percent cash surcharge'
);

select is(
  (select surcharge_amount from public.calculate_time_package_quote(
    '00000000-0000-0000-0000-000000000711'::uuid,
    120,
    '2035-01-15 19:00:00-03'::timestamptz,
    'SPECIAL',
    0
  )),
  30.00::numeric,
  'special weekday hours charge 15 percent cash surcharge'
);

select is(
  (select surcharge_amount from public.calculate_time_package_quote(
    '00000000-0000-0000-0000-000000000711'::uuid,
    120,
    '2035-01-13 19:00:00-03'::timestamptz,
    'SPECIAL',
    0
  )),
  30.00::numeric,
  'weekend plus special hours charges 15 percent once, not twice'
);

select is(
  (select surcharge_amount from public.calculate_time_package_quote(
    '00000000-0000-0000-0000-000000000711'::uuid,
    120,
    '2035-01-15 10:00:00-03'::timestamptz,
    'REGULAR',
    0
  )),
  0.00::numeric,
  'regular weekday package use has no surcharge'
);

select is(
  (select cash_due from public.calculate_time_package_quote(
    '00000000-0000-0000-0000-000000000711'::uuid,
    120,
    '2035-01-13 10:00:00-03'::timestamptz,
    'REGULAR',
    80
  )),
  110.00::numeric,
  'cash due is surcharge plus extras outside package'
);

insert into public.checkout_holds (
  id, public_token_hash, service_id, service_employee_id, selection_hash,
  customer_id, extra_selections, people_count,
  requested_start_at, requested_end_at, expires_at
)
values (
  '00000000-0000-0000-0000-000000000811',
  'time-package-test-hash',
  '00000000-0000-0000-0000-000000000411',
  '00000000-0000-0000-0000-000000000511',
  'selection-time-package-test',
  '00000000-0000-0000-0000-000000000611',
  '[{"extra_id":"00000000-0000-0000-0000-000000000911","quantity":1}]'::jsonb,
  2,
  '2035-01-13 10:00:00-03',
  '2035-01-13 12:00:00-03',
  now() + interval '10 minutes'
);

select ok(
  (public.reserve_time_package_minutes(
    '00000000-0000-0000-0000-000000000711'::uuid,
    '00000000-0000-0000-0000-000000000811'::uuid
  )).id is not null,
  'package minutes can be reserved only from the identified active checkout hold'
);

select is(
  (select available_minutes
   from public.customer_time_package_balances
   where package_id = '00000000-0000-0000-0000-000000000711'::uuid),
  2280,
  'held package minutes are removed from available balance'
);

select is(
  (select surcharge_amount_snapshot
   from public.time_package_usages
   where checkout_hold_id = '00000000-0000-0000-0000-000000000811'::uuid),
  30.00::numeric,
  'usage snapshots the R$30 special-time surcharge derived from held slot'
);

select is(
  (select cash_due_snapshot
   from public.time_package_usages
   where checkout_hold_id = '00000000-0000-0000-0000-000000000811'::uuid),
  110.00::numeric,
  'usage snapshots R$30 surcharge plus R$80 held extras'
);

select is(
  public.release_time_package_hold(
    '00000000-0000-0000-0000-000000000811'::uuid,
    'TEST_RELEASE'
  ),
  1,
  'releasing checkout hold releases package minutes'
);

select is(
  (select available_minutes
   from public.customer_time_package_balances
   where package_id = '00000000-0000-0000-0000-000000000711'::uuid),
  2400,
  'released package minutes return to balance'
);

select * from finish();
rollback;
