begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(7);

insert into public.resources (id, name, resource_type)
values
  ('29200000-0000-0000-0000-000000000001', 'RESCHEDULE TEST STUDIO', 'PHYSICAL'),
  ('29200000-0000-0000-0000-000000000002', 'RESCHEDULE EMPLOYEE A', 'PERSON'),
  ('29200000-0000-0000-0000-000000000003', 'RESCHEDULE EMPLOYEE B', 'PERSON');

insert into public.employees (id, name, resource_id)
values
  ('29200000-0000-0000-0000-000000000010', 'Reschedule Employee A', '29200000-0000-0000-0000-000000000002'),
  ('29200000-0000-0000-0000-000000000011', 'Reschedule Employee B', '29200000-0000-0000-0000-000000000003');

insert into public.categories (id, name, slug)
values ('29200000-0000-0000-0000-000000000020', 'Reschedule Person Gate', 'reschedule-person-gate-test');

insert into public.services (
  id, category_id, name, slug, base_duration_minutes, base_price,
  minimum_people, maximum_people, maximum_booking_horizon_days
) values (
  '29200000-0000-0000-0000-000000000030',
  '29200000-0000-0000-0000-000000000020',
  'Reschedule Person Gate Service',
  'reschedule-person-gate-service',
  60,
  100.00,
  1,
  10,
  5000
);

insert into public.service_employees (id, service_id, employee_id)
values
  ('29200000-0000-0000-0000-000000000040', '29200000-0000-0000-0000-000000000030', '29200000-0000-0000-0000-000000000010'),
  ('29200000-0000-0000-0000-000000000041', '29200000-0000-0000-0000-000000000030', '29200000-0000-0000-0000-000000000011');

insert into public.service_resources (service_id, resource_id)
values ('29200000-0000-0000-0000-000000000030', '29200000-0000-0000-0000-000000000001');

insert into public.availability_rules (
  service_employee_id, weekday, start_local_time, end_local_time, slot_interval_minutes
) values
  ('29200000-0000-0000-0000-000000000040', 1, '09:00', '12:00', 30),
  ('29200000-0000-0000-0000-000000000041', 1, '09:00', '12:00', 30);

insert into public.resource_availability_rules (
  resource_id, weekday, start_local_time, end_local_time, is_active
) values (
  '29200000-0000-0000-0000-000000000001', 1, '09:00', '12:00', true
);

select is(
  (select count(*)::integer
   from public.list_available_slots_for_duration_reschedule_base(
     '29200000-0000-0000-0000-000000000030',
     '29200000-0000-0000-0000-000000000040',
     null, '[]'::jsonb, 1, '2035-01-15'::date, null, null
   )),
  5,
  'reschedule baseline exposes five candidates for employee A'
);

insert into public.resource_allocations (
  resource_id, allocation_type, status, occupied_range,
  external_source, external_calendar_id, external_event_id
) values (
  '29200000-0000-0000-0000-000000000002',
  'EXTERNAL_BLOCK', 'EXTERNAL_ACTIVE',
  tstzrange('2035-01-15 10:00:00-03', '2035-01-15 11:00:00-03', '[)'),
  'GOOGLE', 'reschedule-personal-a', 'reschedule-personal-event-a'
);

select is(
  (select count(*)::integer
   from public.list_available_slots_for_duration_reschedule_base(
     '29200000-0000-0000-0000-000000000030',
     '29200000-0000-0000-0000-000000000040',
     null, '[]'::jsonb, 1, '2035-01-15'::date, null, null
   )),
  2,
  'personal Google block removes overlapping reschedule slots for employee A'
);

select is(
  (select count(*)::integer
   from public.list_available_slots_for_duration_reschedule_base(
     '29200000-0000-0000-0000-000000000030',
     '29200000-0000-0000-0000-000000000041',
     null, '[]'::jsonb, 1, '2035-01-15'::date, null, null
   )),
  5,
  'employee A personal block does not block employee B reschedule slots'
);

update public.resource_allocations
set status = 'RELEASED', updated_at = now()
where external_source = 'GOOGLE'
  and external_event_id = 'reschedule-personal-event-a';

insert into public.google_connections (id, account_email, status)
values ('29200000-0000-0000-0000-000000000050', 'reschedule-person-gate@example.invalid', 'ACTIVE');

insert into public.google_calendars (
  id, google_connection_id, google_calendar_id, name, is_active
) values (
  '29200000-0000-0000-0000-000000000051',
  '29200000-0000-0000-0000-000000000050',
  'reschedule-person-gate-calendar',
  'Reschedule Person Gate Calendar',
  true
);

insert into public.google_calendar_events (
  id, google_calendar_id, google_event_id, status,
  start_at, end_at, qualification, normalized_payload
) values
  (
    '29200000-0000-0000-0000-000000000052',
    '29200000-0000-0000-0000-000000000051',
    'reschedule-physical-divergence-event',
    'confirmed',
    '2035-01-15 10:00:00-03',
    '2035-01-15 11:00:00-03',
    'BLOCKING', '{}'
  ),
  (
    '29200000-0000-0000-0000-000000000054',
    '29200000-0000-0000-0000-000000000051',
    'reschedule-person-divergence-event',
    'confirmed',
    '2035-01-15 10:00:00-03',
    '2035-01-15 11:00:00-03',
    'BLOCKING', '{}'
  );

insert into public.schedule_divergences (
  id, resource_id, google_calendar_event_id, desired_range, reason
) values (
  '29200000-0000-0000-0000-000000000053',
  '29200000-0000-0000-0000-000000000001',
  '29200000-0000-0000-0000-000000000052',
  tstzrange('2035-01-15 10:00:00-03', '2035-01-15 11:00:00-03', '[)'),
  'GOOGLE_EVENT_CONFLICT'
);

select is(
  (select count(*)::integer
   from public.list_available_slots_for_duration_reschedule_base(
     '29200000-0000-0000-0000-000000000030',
     '29200000-0000-0000-0000-000000000040',
     null, '[]'::jsonb, 1, '2035-01-15'::date, null, null
   )),
  2,
  'OPEN Google divergence on shared physical resource fails closed for employee A reschedule'
);

select is(
  (select count(*)::integer
   from public.list_available_slots_for_duration_reschedule_base(
     '29200000-0000-0000-0000-000000000030',
     '29200000-0000-0000-0000-000000000041',
     null, '[]'::jsonb, 1, '2035-01-15'::date, null, null
   )),
  2,
  'shared physical divergence also blocks employee B reschedule'
);

update public.schedule_divergences
set status = 'RESOLVED', resolved_at = now(), resolution_notes = 'test resolution'
where id = '29200000-0000-0000-0000-000000000053';

insert into public.schedule_divergences (
  id, resource_id, google_calendar_event_id, desired_range, reason
) values (
  '29200000-0000-0000-0000-000000000055',
  '29200000-0000-0000-0000-000000000002',
  '29200000-0000-0000-0000-000000000054',
  tstzrange('2035-01-15 10:00:00-03', '2035-01-15 11:00:00-03', '[)'),
  'GOOGLE_EVENT_CONFLICT'
);

select is(
  (select count(*)::integer
   from public.list_available_slots_for_duration_reschedule_base(
     '29200000-0000-0000-0000-000000000030',
     '29200000-0000-0000-0000-000000000040',
     null, '[]'::jsonb, 1, '2035-01-15'::date, null, null
   )),
  2,
  'OPEN Google divergence on employee A fails closed for reschedule slots'
);

select is(
  (select count(*)::integer
   from public.list_available_slots_for_duration_reschedule_base(
     '29200000-0000-0000-0000-000000000030',
     '29200000-0000-0000-0000-000000000041',
     null, '[]'::jsonb, 1, '2035-01-15'::date, null, null
   )),
  5,
  'employee A divergence does not block employee B reschedule slots'
);

select * from finish();
rollback;
