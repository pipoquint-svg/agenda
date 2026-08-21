begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(11);

select is(
  (select default_slot_interval_minutes from public.operation_settings where id = 1),
  30,
  'system default slot cadence is 30 minutes'
);

insert into public.categories (id, name, slug)
values ('97000000-0000-0000-0000-000000000001', 'Slot Policy Test', 'slot-policy-test');

insert into public.resources (id, name, resource_type)
values
  ('97000000-0000-0000-0000-000000000002', 'SLOT POLICY ESTUDIO', 'PHYSICAL'),
  ('97000000-0000-0000-0000-000000000003', 'SLOT POLICY PROFISSIONAL', 'PERSON');

insert into public.employees (id, name, resource_id)
values (
  '97000000-0000-0000-0000-000000000004',
  'Profissional Slot Policy',
  '97000000-0000-0000-0000-000000000003'
);

-- BlackSheep-style service: no override, therefore system default = 30 minutes.
insert into public.services (
  id, category_id, name, slug, base_duration_minutes, base_price,
  minimum_people, maximum_people, maximum_booking_horizon_days
) values (
  '97000000-0000-0000-0000-000000000005',
  '97000000-0000-0000-0000-000000000001',
  'Locação 4h Slot Policy',
  'locacao-4h-slot-policy',
  240, 720.00, 1, 10, 5000
);

insert into public.service_employees (id, service_id, employee_id)
values (
  '97000000-0000-0000-0000-000000000006',
  '97000000-0000-0000-0000-000000000005',
  '97000000-0000-0000-0000-000000000004'
);

insert into public.service_resources(service_id, resource_id, is_required)
values (
  '97000000-0000-0000-0000-000000000005',
  '97000000-0000-0000-0000-000000000002',
  true
);

-- 2030-01-01 Tuesday. Intentionally request 15m in the availability row;
-- the service/system policy must normalize it to 30m.
insert into public.availability_rules(
  service_employee_id, weekday, start_local_time, end_local_time, slot_interval_minutes
) values (
  '97000000-0000-0000-0000-000000000006', 2, '08:00', '14:00', 15
);

select is(
  (select slot_interval_minutes from public.availability_rules where service_employee_id = '97000000-0000-0000-0000-000000000006'),
  30,
  'BlackSheep-style availability is normalized to 30-minute starts'
);

select is(
  (select count(*)::integer from public.list_available_slots(
    '97000000-0000-0000-0000-000000000005',
    '97000000-0000-0000-0000-000000000006',
    '[]'::jsonb, 1, '2030-01-01'::date, null
  )),
  5,
  '4h rental in an 08:00-14:00 window yields five 30-minute start options'
);

select ok(
  exists (
    select 1 from public.list_available_slots(
      '97000000-0000-0000-0000-000000000005',
      '97000000-0000-0000-0000-000000000006',
      '[]'::jsonb, 1, '2030-01-01'::date, null
    ) s
    where s.core_start_at = '2030-01-01 08:00:00-03'::timestamptz
      and s.core_end_at = '2030-01-01 12:00:00-03'::timestamptz
  ),
  'BlackSheep grid includes 08:00-12:00'
);

select ok(
  exists (
    select 1 from public.list_available_slots(
      '97000000-0000-0000-0000-000000000005',
      '97000000-0000-0000-0000-000000000006',
      '[]'::jsonb, 1, '2030-01-01'::date, null
    ) s
    where s.core_start_at = '2030-01-01 08:30:00-03'::timestamptz
      and s.core_end_at = '2030-01-01 12:30:00-03'::timestamptz
  ),
  'BlackSheep grid includes 08:30-12:30'
);

select ok(
  exists (
    select 1 from public.list_available_slots(
      '97000000-0000-0000-0000-000000000005',
      '97000000-0000-0000-0000-000000000006',
      '[]'::jsonb, 1, '2030-01-01'::date, null
    ) s
    where s.core_start_at = '2030-01-01 09:00:00-03'::timestamptz
      and s.core_end_at = '2030-01-01 13:00:00-03'::timestamptz
  ),
  'BlackSheep grid includes 09:00-13:00'
);

-- Sabrina-style policy: configure cadence directly on the service.
select lives_ok(
  $$ select public.set_service_public_slot_interval('97000000-0000-0000-0000-000000000005', 60) $$,
  'service-level cadence can be configured administratively'
);

select is(
  (select public_slot_interval_minutes from public.services where id = '97000000-0000-0000-0000-000000000005'),
  60,
  'service stores its own public cadence override'
);

select is(
  (select slot_interval_minutes from public.availability_rules where service_employee_id = '97000000-0000-0000-0000-000000000006'),
  60,
  'changing service cadence propagates to its availability windows'
);

select is(
  (select count(*)::integer from public.list_available_slots(
    '97000000-0000-0000-0000-000000000005',
    '97000000-0000-0000-0000-000000000006',
    '[]'::jsonb, 1, '2030-01-01'::date, null
  )),
  3,
  'Sabrina-style 60-minute service cadence yields 08:00, 09:00 and 10:00 starts'
);

select ok(
  not exists (
    select 1 from public.list_available_slots(
      '97000000-0000-0000-0000-000000000005',
      '97000000-0000-0000-0000-000000000006',
      '[]'::jsonb, 1, '2030-01-01'::date, null
    ) s
    where s.core_start_at = '2030-01-01 08:30:00-03'::timestamptz
  ),
  'service-level 60-minute cadence removes the 08:30 start'
);

select * from finish();
rollback;
