begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(10);

insert into public.resources (id, name, resource_type)
values
  ('29000000-0000-0000-0000-000000000001', 'GOOGLE DIVERGENCE TEST STUDIO', 'PHYSICAL'),
  ('29000000-0000-0000-0000-000000000002', 'GOOGLE DIVERGENCE EMPLOYEE A', 'PERSON'),
  ('29000000-0000-0000-0000-000000000003', 'GOOGLE DIVERGENCE EMPLOYEE B', 'PERSON');

insert into public.employees (id, name, resource_id)
values
  ('29000000-0000-0000-0000-000000000010', 'Google Divergence Employee A', '29000000-0000-0000-0000-000000000002'),
  ('29000000-0000-0000-0000-000000000011', 'Google Divergence Employee B', '29000000-0000-0000-0000-000000000003');

insert into public.categories (id, name, slug)
values ('29000000-0000-0000-0000-000000000020', 'Google Divergence', 'google-divergence-test');

insert into public.services (
  id, category_id, name, slug, base_duration_minutes, base_price,
  minimum_people, maximum_people, maximum_booking_horizon_days
) values (
  '29000000-0000-0000-0000-000000000030',
  '29000000-0000-0000-0000-000000000020',
  'Google Divergence Service',
  'google-divergence-service',
  60,
  100.00,
  1,
  10,
  5000
);

insert into public.service_employees (id, service_id, employee_id)
values
  ('29000000-0000-0000-0000-000000000040', '29000000-0000-0000-0000-000000000030', '29000000-0000-0000-0000-000000000010'),
  ('29000000-0000-0000-0000-000000000041', '29000000-0000-0000-0000-000000000030', '29000000-0000-0000-0000-000000000011');

insert into public.service_resources (service_id, resource_id)
values ('29000000-0000-0000-0000-000000000030', '29000000-0000-0000-0000-000000000001');

insert into public.availability_rules (
  service_employee_id, weekday, start_local_time, end_local_time, slot_interval_minutes
) values
  ('29000000-0000-0000-0000-000000000040', 1, '09:00', '12:00', 30),
  ('29000000-0000-0000-0000-000000000041', 1, '09:00', '12:00', 30);

insert into public.resource_availability_rules (
  resource_id, weekday, start_local_time, end_local_time, is_active
) values (
  '29000000-0000-0000-0000-000000000001', 1, '09:00', '12:00', true
);

select is(
  (select count(*)::integer
   from public.list_available_slots(
     '29000000-0000-0000-0000-000000000030',
     '29000000-0000-0000-0000-000000000040',
     '[]'::jsonb, 1, '2035-01-15'::date, null
   )),
  5,
  'baseline exposes all five candidates for employee A'
);

insert into public.resource_allocations (
  resource_id, allocation_type, status, occupied_range,
  external_source, external_calendar_id, external_event_id
) values (
  '29000000-0000-0000-0000-000000000002',
  'EXTERNAL_BLOCK',
  'EXTERNAL_ACTIVE',
  tstzrange('2035-01-15 10:00:00-03'::timestamptz, '2035-01-15 11:00:00-03'::timestamptz, '[)'),
  'GOOGLE', 'personal-calendar-a', 'personal-event-a'
);

select is(
  (select count(*)::integer
   from public.list_available_slots(
     '29000000-0000-0000-0000-000000000030',
     '29000000-0000-0000-0000-000000000040',
     '[]'::jsonb, 1, '2035-01-15'::date, null
   )),
  2,
  'personal external block removes overlapping slots for the selected employee'
);

select is(
  (select count(*)::integer
   from public.list_available_slots_for_duration(
     '29000000-0000-0000-0000-000000000030',
     '29000000-0000-0000-0000-000000000040',
     null,
     '[]'::jsonb, 1, '2035-01-15'::date, null
   )),
  2,
  'duration listing also respects the selected employee personal block'
);

select is(
  (select count(*)::integer
   from public.list_available_slots(
     '29000000-0000-0000-0000-000000000030',
     '29000000-0000-0000-0000-000000000041',
     '[]'::jsonb, 1, '2035-01-15'::date, null
   )),
  5,
  'employee A personal block does not block employee B'
);

update public.resource_allocations
set status = 'RELEASED', updated_at = now()
where external_source = 'GOOGLE' and external_event_id = 'personal-event-a';

insert into public.google_connections (id, account_email, status)
values ('29000000-0000-0000-0000-000000000050', 'google-divergence-test@example.invalid', 'ACTIVE');

insert into public.google_calendars (
  id, google_connection_id, google_calendar_id, name, is_active
) values (
  '29000000-0000-0000-0000-000000000051',
  '29000000-0000-0000-0000-000000000050',
  'google-divergence-test-calendar',
  'Google Divergence Test Calendar',
  true
);

insert into public.google_calendar_events (
  id, google_calendar_id, google_event_id, status,
  start_at, end_at, qualification, normalized_payload
) values
  (
    '29000000-0000-0000-0000-000000000052',
    '29000000-0000-0000-0000-000000000051',
    'google-divergence-physical-event',
    'confirmed',
    '2035-01-15 10:00:00-03'::timestamptz,
    '2035-01-15 11:00:00-03'::timestamptz,
    'BLOCKING', '{}'
  ),
  (
    '29000000-0000-0000-0000-000000000054',
    '29000000-0000-0000-0000-000000000051',
    'google-divergence-person-event',
    'confirmed',
    '2035-01-15 10:00:00-03'::timestamptz,
    '2035-01-15 11:00:00-03'::timestamptz,
    'BLOCKING', '{}'
  );

insert into public.schedule_divergences (
  id, resource_id, google_calendar_event_id, desired_range, reason
) values (
  '29000000-0000-0000-0000-000000000053',
  '29000000-0000-0000-0000-000000000001',
  '29000000-0000-0000-0000-000000000052',
  tstzrange('2035-01-15 10:00:00-03'::timestamptz, '2035-01-15 11:00:00-03'::timestamptz, '[)'),
  'GOOGLE_EVENT_CONFLICT'
);

select is(
  (select count(*)::integer
   from public.list_available_slots(
     '29000000-0000-0000-0000-000000000030',
     '29000000-0000-0000-0000-000000000040',
     '[]'::jsonb, 1, '2035-01-15'::date, null
   )),
  2,
  'OPEN Google divergence on shared studio fails closed'
);

select ok(
  exists (
    select 1
    from public.list_available_slots(
      '29000000-0000-0000-0000-000000000030',
      '29000000-0000-0000-0000-000000000040',
      '[]'::jsonb, 1, '2035-01-15'::date, null
    )
    where slot_start_at = '2035-01-15 09:00:00-03'::timestamptz
  ),
  '[start,end) preserves the slot ending exactly when the block begins'
);

select throws_ok(
  $$
    select public.create_checkout_hold(
      '29000000-0000-0000-0000-000000000030',
      '29000000-0000-0000-0000-000000000040',
      '[]'::jsonb, 1,
      '2035-01-15 10:00:00-03'::timestamptz
    )
  $$,
  'P0001',
  'SLOT_NO_LONGER_AVAILABLE',
  'checkout hold cannot bypass an OPEN Google divergence'
);

update public.schedule_divergences
set status = 'RESOLVED', resolved_at = now(), resolution_notes = 'test resolution'
where id = '29000000-0000-0000-0000-000000000053';

select is(
  (select count(*)::integer
   from public.list_available_slots(
     '29000000-0000-0000-0000-000000000030',
     '29000000-0000-0000-0000-000000000040',
     '[]'::jsonb, 1, '2035-01-15'::date, null
   )),
  5,
  'resolved shared-resource divergence stops blocking availability'
);

insert into public.schedule_divergences (
  id, resource_id, google_calendar_event_id, desired_range, reason
) values (
  '29000000-0000-0000-0000-000000000055',
  '29000000-0000-0000-0000-000000000002',
  '29000000-0000-0000-0000-000000000054',
  tstzrange('2035-01-15 10:00:00-03'::timestamptz, '2035-01-15 11:00:00-03'::timestamptz, '[)'),
  'GOOGLE_EVENT_CONFLICT'
);

select is(
  (select count(*)::integer
   from public.list_available_slots(
     '29000000-0000-0000-0000-000000000030',
     '29000000-0000-0000-0000-000000000040',
     '[]'::jsonb, 1, '2035-01-15'::date, null
   )),
  2,
  'OPEN divergence on selected employee also fails closed'
);

select is(
  (select count(*)::integer
   from public.list_available_slots(
     '29000000-0000-0000-0000-000000000030',
     '29000000-0000-0000-0000-000000000041',
     '[]'::jsonb, 1, '2035-01-15'::date, null
   )),
  5,
  'employee A divergence does not block employee B'
);

select * from finish();
rollback;
