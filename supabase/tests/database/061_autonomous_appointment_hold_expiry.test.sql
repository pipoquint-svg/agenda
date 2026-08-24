begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
set local agenda.test_now = '2029-12-31 12:00:00-03';

select plan(8);

insert into public.categories(id, name, slug)
values ('96100000-0000-0000-0000-000000000001', 'Autonomous Expiry', 'autonomous-expiry-test');

insert into public.resources(id, name, resource_type)
values
  ('96100000-0000-0000-0000-000000000002', 'AUTONOMOUS EXPIRY STUDIO', 'PHYSICAL'),
  ('96100000-0000-0000-0000-000000000003', 'AUTONOMOUS EXPIRY PERSON', 'PERSON');

insert into public.employees(id, name, resource_id)
values ('96100000-0000-0000-0000-000000000004', 'Autonomous Expiry Employee', '96100000-0000-0000-0000-000000000003');

insert into public.services(
  id, category_id, name, slug,
  base_duration_minutes, base_price,
  buffer_before_minutes, buffer_after_minutes,
  minimum_people, maximum_people, maximum_booking_horizon_days,
  duration_mode, booking_block_minutes,
  minimum_booking_blocks, maximum_booking_blocks, price_per_block
) values (
  '96100000-0000-0000-0000-000000000005',
  '96100000-0000-0000-0000-000000000001',
  'Autonomous Expiry Rental', 'autonomous-expiry-rental',
  30, 90.00,
  0, 30,
  1, 20, 5000,
  'BLOCKS', 30, 2, 12, 90.00
);

insert into public.service_employees(id, service_id, employee_id)
values (
  '96100000-0000-0000-0000-000000000006',
  '96100000-0000-0000-0000-000000000005',
  '96100000-0000-0000-0000-000000000004'
);

insert into public.service_resources(service_id, resource_id, is_required)
values ('96100000-0000-0000-0000-000000000005', '96100000-0000-0000-0000-000000000002', true);

-- Tuesday, 2030-01-01. The resource stays open through the service's final buffer.
insert into public.availability_rules(service_employee_id, weekday, start_local_time, end_local_time)
values ('96100000-0000-0000-0000-000000000006', 2, '08:00', '14:00');

insert into public.resource_availability_rules(resource_id, weekday, start_local_time, end_local_time)
values ('96100000-0000-0000-0000-000000000002', 2, '08:00', '14:30');

insert into public.customers(id, name, email, phone)
values ('96100000-0000-0000-0000-000000000007', 'Abandoned Customer', 'abandoned@example.com', '+5548999996100');

insert into public.appointments(
  id, public_code, service_id, service_employee_id, primary_customer_id,
  status, financial_status, start_at, end_at, duration_minutes, people_count,
  hold_expires_at, commercial_value, duration_blocks, contracted_minutes
) values (
  '96100000-0000-0000-0000-000000000008', 'ABANDONED-HOLD',
  '96100000-0000-0000-0000-000000000005',
  '96100000-0000-0000-0000-000000000006',
  '96100000-0000-0000-0000-000000000007',
  'AWAITING_PAYMENT', 'PENDING',
  '2030-01-01 08:00:00-03', '2030-01-01 10:00:00-03',
  120, 1,
  '2029-12-31 12:10:00-03', 360.00,
  4, 120
);

insert into public.resource_allocations(
  resource_id, appointment_id, allocation_type, status, occupied_range
) values (
  '96100000-0000-0000-0000-000000000002',
  '96100000-0000-0000-0000-000000000008',
  'APPOINTMENT', 'AWAITING_PAYMENT',
  tstzrange('2030-01-01 08:00:00-03', '2030-01-01 10:30:00-03', '[)')
);

select ok(
  not exists (
    select 1 from public.list_available_slots_for_duration(
      '96100000-0000-0000-0000-000000000005',
      '96100000-0000-0000-0000-000000000006',
      4, '[]'::jsonb, 1, '2030-01-01'::date, null
    ) s where s.core_start_at = '2030-01-01 08:00:00-03'::timestamptz
  ),
  'live AWAITING_PAYMENT hold blocks the duration slot'
);

set local agenda.test_now = '2029-12-31 12:11:00-03';

select ok(
  exists (
    select 1 from public.list_available_slots_for_duration(
      '96100000-0000-0000-0000-000000000005',
      '96100000-0000-0000-0000-000000000006',
      4, '[]'::jsonb, 1, '2030-01-01'::date, null
    ) s where s.core_start_at = '2030-01-01 08:00:00-03'::timestamptz
  ),
  'expired AWAITING_PAYMENT hold stops hiding the slot before physical cleanup'
);

select is(
  (select status::text from public.appointments where id = '96100000-0000-0000-0000-000000000008'),
  'AWAITING_PAYMENT',
  'synthetic abandonment remains untouched until periodic maintenance runs'
);

select is(
  public.expire_due_appointment_holds(),
  1,
  'periodic maintenance expires one abandoned appointment without any payment event'
);

select is(
  (select status::text from public.appointments where id = '96100000-0000-0000-0000-000000000008'),
  'EXPIRED',
  'abandoned appointment becomes EXPIRED'
);

select is(
  (select status::text from public.resource_allocations where appointment_id = '96100000-0000-0000-0000-000000000008'),
  'EXPIRED',
  'abandoned appointment allocation becomes EXPIRED'
);

select ok(
  exists (
    select 1 from public.list_available_slots_for_duration(
      '96100000-0000-0000-0000-000000000005',
      '96100000-0000-0000-0000-000000000006',
      4, '[]'::jsonb, 1, '2030-01-01'::date, null
    ) s where s.core_start_at = '2030-01-01 08:00:00-03'::timestamptz
  ),
  'slot remains available after authoritative expiry cleanup'
);

select is(
  public.expire_due_appointment_holds(),
  0,
  'periodic expiry is idempotent after the abandoned hold is released'
);

select * from finish();
rollback;
