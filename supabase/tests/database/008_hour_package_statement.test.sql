begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(11);

insert into public.resources (id, name, resource_type)
values ('80000000-0000-0000-0000-000000000001', 'STATEMENT TEST STUDIO', 'PHYSICAL');

insert into public.employees (id, name)
values ('80000000-0000-0000-0000-000000000002', 'Statement Employee');

insert into public.categories (id, name, slug)
values ('80000000-0000-0000-0000-000000000003', 'Statement', 'statement-test');

insert into public.services (
  id, category_id, name, slug, base_duration_minutes, base_price,
  minimum_people, maximum_people, maximum_booking_horizon_days
) values (
  '80000000-0000-0000-0000-000000000010',
  '80000000-0000-0000-0000-000000000003',
  'Locação pacote',
  'statement-package-service',
  50,
  100,
  1,
  20,
  5000
);

insert into public.service_employees (id, service_id, employee_id)
values (
  '80000000-0000-0000-0000-000000000020',
  '80000000-0000-0000-0000-000000000010',
  '80000000-0000-0000-0000-000000000002'
);

insert into public.service_resources (service_id, resource_id)
values (
  '80000000-0000-0000-0000-000000000010',
  '80000000-0000-0000-0000-000000000001'
);

insert into public.customers (id, name, email, phone)
values (
  '80000000-0000-0000-0000-000000000030',
  'Cliente Extrato',
  'extrato@example.com',
  '+5548999999200'
);

insert into public.hour_packages (
  id, customer_id, name, total_minutes, purchased_value,
  valid_from, valid_until, standard_start_local_time, standard_end_local_time
) values (
  '80000000-0000-0000-0000-000000000040',
  '80000000-0000-0000-0000-000000000030',
  'Pacote 10h',
  600,
  1000,
  '2034-01-01 00:00:00-03',
  '2036-01-01 00:00:00-03',
  '09:00',
  '18:00'
);

insert into public.hour_package_services (hour_package_id, service_id)
values (
  '80000000-0000-0000-0000-000000000040',
  '80000000-0000-0000-0000-000000000010'
);

insert into public.appointments (
  id, public_code, service_id, service_employee_id, primary_customer_id,
  status, financial_status, start_at, end_at, duration_minutes, people_count,
  service_name_snapshot, commercial_value, confirmed_at
) values (
  '80000000-0000-0000-0000-000000000050',
  'PKG-STATEMENT-001',
  '80000000-0000-0000-0000-000000000010',
  '80000000-0000-0000-0000-000000000020',
  '80000000-0000-0000-0000-000000000030',
  'CONFIRMED',
  'PAID',
  '2035-01-13 10:00:00-03',
  '2035-01-13 10:50:00-03',
  50,
  1,
  'Locação pacote',
  100,
  now()
);

insert into public.hour_package_movements (
  id, hour_package_id, appointment_id, movement_type,
  minutes_delta, seconds_delta, reason
) values (
  '80000000-0000-0000-0000-000000000060',
  '80000000-0000-0000-0000-000000000040',
  '80000000-0000-0000-0000-000000000050',
  'RESERVATION_DEBIT',
  -57.5,
  -3450,
  'APPOINTMENT_CONFIRMED'
);

insert into public.appointment_package_usage (
  appointment_id,
  hour_package_id,
  covered_minutes,
  uncovered_minutes,
  required_seconds,
  surcharge_seconds,
  charged_seconds,
  package_reference_minute_value,
  covered_reference_value,
  is_special_period,
  special_surcharge_percent,
  special_surcharge_amount,
  uncovered_time_amount,
  extras_cash_amount,
  cash_due,
  debit_movement_id
) values (
  '80000000-0000-0000-0000-000000000050',
  '80000000-0000-0000-0000-000000000040',
  50,
  0,
  3000,
  450,
  3450,
  1.666667,
  83.33,
  true,
  15,
  0,
  0,
  0,
  0,
  '80000000-0000-0000-0000-000000000060'
);

insert into public.checkout_holds (
  id, public_token_hash, service_id, service_employee_id, selection_hash,
  primary_customer_id, people_count, requested_start_at, requested_end_at,
  expires_at, extra_selections, commercial_value, pricing_version,
  duration_minutes, resource_ids
) values (
  '80000000-0000-0000-0000-000000000070',
  'statement-held-token',
  '80000000-0000-0000-0000-000000000010',
  '80000000-0000-0000-0000-000000000020',
  'statement-held',
  '80000000-0000-0000-0000-000000000030',
  1,
  '2035-01-14 10:00:00-03',
  '2035-01-14 11:00:00-03',
  now() + interval '10 minutes',
  '[]',
  100,
  'statement-test',
  60,
  array['80000000-0000-0000-0000-000000000001'::uuid]
);

insert into public.checkout_hour_package_reservations (
  checkout_hold_id,
  hour_package_id,
  required_minutes,
  covered_minutes,
  uncovered_minutes,
  required_seconds,
  surcharge_seconds,
  charged_seconds,
  package_reference_minute_value,
  covered_reference_value,
  is_special_period,
  special_surcharge_percent,
  special_surcharge_amount,
  uncovered_time_amount,
  extras_cash_amount,
  cash_due,
  status
) values (
  '80000000-0000-0000-0000-000000000070',
  '80000000-0000-0000-0000-000000000040',
  60,
  60,
  0,
  3600,
  0,
  3600,
  1.666667,
  100,
  false,
  0,
  0,
  0,
  0,
  0,
  'HELD'
);

select is(public.format_duration_seconds(3450), '00:57:30', 'exact seconds format preserves 57m30s');

select is(
  (select nominal_time from public.hour_package_statement_entries where movement_id='80000000-0000-0000-0000-000000000060'),
  '00:50:00',
  'statement shows nominal appointment time separately'
);

select is(
  (select surcharge_time from public.hour_package_statement_entries where movement_id='80000000-0000-0000-0000-000000000060'),
  '00:07:30',
  'statement shows 15 percent special-period surcharge as time'
);

select is(
  (select debited_time from public.hour_package_statement_entries where movement_id='80000000-0000-0000-0000-000000000060'),
  '00:57:30',
  'statement shows exact debited time'
);

select is(
  (select appointment_code from public.hour_package_statement_entries where movement_id='80000000-0000-0000-0000-000000000060'),
  'PKG-STATEMENT-001',
  'statement links use to booking code'
);

select is(
  (select service_name from public.hour_package_statement_entries where movement_id='80000000-0000-0000-0000-000000000060'),
  'Locação pacote',
  'statement exposes service snapshot for printing/export'
);

select is(
  (select balance_after_time from public.hour_package_statement_entries where movement_id='80000000-0000-0000-0000-000000000060'),
  '09:02:30',
  'running balance after use is exact'
);

select is(
  public.get_hour_package_statement('80000000-0000-0000-0000-000000000040')->'summary'->>'ledger_balance_time',
  '09:02:30',
  'statement summary exposes ledger balance'
);

select is(
  public.get_hour_package_statement('80000000-0000-0000-0000-000000000040')->'summary'->>'held_time',
  '01:00:00',
  'statement summary separates temporarily held package time'
);

select is(
  public.get_hour_package_statement('80000000-0000-0000-0000-000000000040')->'summary'->>'available_time',
  '08:02:30',
  'statement summary exposes actual available balance after holds'
);

select is(
  jsonb_array_length(public.get_hour_package_statement('80000000-0000-0000-0000-000000000040')->'entries'),
  2,
  'export payload contains initial credit plus confirmed usage only, not temporary hold'
);

select * from finish();
rollback;