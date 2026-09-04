begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(5);

insert into public.resources (id, name, resource_type)
values ('29000000-0000-0000-0000-000000000001', 'GOOGLE DIVERGENCE TEST RESOURCE', 'PHYSICAL');

insert into public.employees (id, name)
values ('29000000-0000-0000-0000-000000000010', 'Google Divergence Employee');

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
values (
  '29000000-0000-0000-0000-000000000040',
  '29000000-0000-0000-0000-000000000030',
  '29000000-0000-0000-0000-000000000010'
);

insert into public.service_resources (service_id, resource_id)
values (
  '29000000-0000-0000-0000-000000000030',
  '29000000-0000-0000-0000-000000000001'
);

insert into public.availability_rules (
  service_employee_id, weekday, start_local_time, end_local_time, slot_interval_minutes
) values (
  '29000000-0000-0000-0000-000000000040',
  1,
  '09:00',
  '12:00',
  30
);

select is(
  (select count(*)::integer
   from public.list_available_slots(
     '29000000-0000-0000-0000-000000000030',
     '29000000-0000-0000-0000-000000000040',
     '[]'::jsonb,
     1,
     '2035-01-15'::date,
     null
   )),
  5,
  'baseline availability exposes all five candidates before a divergence exists'
);

insert into public.google_connections (
  id, account_email, status
) values (
  '29000000-0000-0000-0000-000000000050',
  'google-divergence-test@example.invalid',
  'ACTIVE'
);

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
  id,
  google_calendar_id,
  google_event_id,
  status,
  start_at,
  end_at,
  qualification,
  normalized_payload
) values (
  '29000000-0000-0000-0000-000000000052',
  '29000000-0000-0000-0000-000000000051',
  'google-divergence-test-event',
  'confirmed',
  '2035-01-15 10:00:00-03'::timestamptz,
  '2035-01-15 11:00:00-03'::timestamptz,
  'BLOCKING',
  '{}'::jsonb
);

insert into public.schedule_divergences (
  id,
  resource_id,
  google_calendar_event_id,
  desired_range,
  reason
) values (
  '29000000-0000-0000-0000-000000000053',
  '29000000-0000-0000-0000-000000000001',
  '29000000-0000-0000-0000-000000000052',
  tstzrange(
    '2035-01-15 10:00:00-03'::timestamptz,
    '2035-01-15 11:00:00-03'::timestamptz,
    '[)'
  ),
  'GOOGLE_EVENT_CONFLICT'
);

select is(
  (select count(*)::integer
   from public.list_available_slots(
     '29000000-0000-0000-0000-000000000030',
     '29000000-0000-0000-0000-000000000040',
     '[]'::jsonb,
     1,
     '2035-01-15'::date,
     null
   )),
  2,
  'OPEN Google divergence removes every candidate whose resource range overlaps desired_range'
);

select ok(
  exists (
    select 1
    from public.list_available_slots(
      '29000000-0000-0000-0000-000000000030',
      '29000000-0000-0000-0000-000000000040',
      '[]'::jsonb,
      1,
      '2035-01-15'::date,
      null
    )
    where slot_start_at = '2035-01-15 09:00:00-03'::timestamptz
  ),
  '[start,end) keeps the boundary slot that ends exactly when the divergence begins'
);

select throws_ok(
  $$
    select public.create_checkout_hold(
      '29000000-0000-0000-0000-000000000030',
      '29000000-0000-0000-0000-000000000040',
      '[]'::jsonb,
      1,
      '2035-01-15 10:00:00-03'::timestamptz
    )
  $$,
  'P0001',
  'SLOT_NO_LONGER_AVAILABLE',
  'checkout hold cannot bypass an OPEN Google divergence'
);

update public.schedule_divergences
set status = 'RESOLVED',
    resolved_at = now(),
    resolution_notes = 'test resolution'
where id = '29000000-0000-0000-0000-000000000053';

select is(
  (select count(*)::integer
   from public.list_available_slots(
     '29000000-0000-0000-0000-000000000030',
     '29000000-0000-0000-0000-000000000040',
     '[]'::jsonb,
     1,
     '2035-01-15'::date,
     null
   )),
  5,
  'resolved divergence stops blocking availability'
);

select * from finish();
rollback;
