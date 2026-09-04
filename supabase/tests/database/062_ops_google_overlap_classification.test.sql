begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(4);

insert into public.resources (id, name, resource_type)
values
  ('29100000-0000-0000-0000-000000000001', 'OPS GOOGLE ONLY', 'PERSON'),
  ('29100000-0000-0000-0000-000000000002', 'OPS MANUAL CONFLICT', 'PERSON'),
  ('29100000-0000-0000-0000-000000000003', 'OPS NO CURRENT OVERLAP', 'PERSON');

insert into public.google_connections (id, account_email, status)
values ('29100000-0000-0000-0000-000000000010', 'ops-overlap-test@example.invalid', 'ACTIVE');

insert into public.google_calendars (
  id, google_connection_id, google_calendar_id, name, is_active
) values (
  '29100000-0000-0000-0000-000000000011',
  '29100000-0000-0000-0000-000000000010',
  'ops-overlap-test-calendar',
  'Ops overlap test calendar',
  true
);

insert into public.google_calendar_events (
  id, google_calendar_id, google_event_id, status,
  start_at, end_at, qualification, normalized_payload
) values
  ('29100000-0000-0000-0000-000000000020', '29100000-0000-0000-0000-000000000011', 'incoming-google-only', 'confirmed', '2035-01-15 10:00:00-03', '2035-01-15 12:00:00-03', 'BLOCKING', '{}'),
  ('29100000-0000-0000-0000-000000000021', '29100000-0000-0000-0000-000000000011', 'existing-google-only', 'confirmed', '2035-01-15 10:30:00-03', '2035-01-15 11:00:00-03', 'BLOCKING', '{}'),
  ('29100000-0000-0000-0000-000000000022', '29100000-0000-0000-0000-000000000011', 'incoming-manual', 'confirmed', '2035-01-15 10:00:00-03', '2035-01-15 11:00:00-03', 'BLOCKING', '{}'),
  ('29100000-0000-0000-0000-000000000023', '29100000-0000-0000-0000-000000000011', 'incoming-no-overlap', 'confirmed', '2035-01-15 10:00:00-03', '2035-01-15 11:00:00-03', 'BLOCKING', '{}');

insert into public.resource_allocations (
  id, resource_id, allocation_type, status, occupied_range,
  external_source, external_calendar_id, external_event_id, google_calendar_event_id
) values (
  '29100000-0000-0000-0000-000000000030',
  '29100000-0000-0000-0000-000000000001',
  'EXTERNAL_BLOCK', 'EXTERNAL_ACTIVE',
  tstzrange('2035-01-15 10:30:00-03', '2035-01-15 11:00:00-03', '[)'),
  'GOOGLE', 'ops-overlap-test-calendar', 'existing-google-only',
  '29100000-0000-0000-0000-000000000021'
);

insert into public.resource_allocations (
  id, resource_id, allocation_type, status, occupied_range, reason
) values (
  '29100000-0000-0000-0000-000000000031',
  '29100000-0000-0000-0000-000000000002',
  'MANUAL_BLOCK', 'BLOCKED',
  tstzrange('2035-01-15 10:15:00-03', '2035-01-15 10:45:00-03', '[)'),
  'ops test manual block'
);

insert into public.schedule_divergences (
  id, resource_id, google_calendar_event_id, desired_range,
  source, status, reason, detected_at
) values
  ('29100000-0000-0000-0000-000000000040', '29100000-0000-0000-0000-000000000001', '29100000-0000-0000-0000-000000000020', tstzrange('2035-01-15 10:00:00-03', '2035-01-15 12:00:00-03', '[)'), 'GOOGLE', 'OPEN', 'GOOGLE_EVENT_CONFLICT', now() - interval '30 minutes'),
  ('29100000-0000-0000-0000-000000000041', '29100000-0000-0000-0000-000000000002', '29100000-0000-0000-0000-000000000022', tstzrange('2035-01-15 10:00:00-03', '2035-01-15 11:00:00-03', '[)'), 'GOOGLE', 'OPEN', 'GOOGLE_EVENT_CONFLICT', now() - interval '30 minutes'),
  ('29100000-0000-0000-0000-000000000042', '29100000-0000-0000-0000-000000000003', '29100000-0000-0000-0000-000000000023', tstzrange('2035-01-15 10:00:00-03', '2035-01-15 11:00:00-03', '[)'), 'GOOGLE', 'OPEN', 'GOOGLE_EVENT_CONFLICT', now() - interval '30 minutes');

select ok(
  not exists (
    select 1 from public.service_list_ops_actionable_schedule_divergences(now() - interval '15 minutes')
    where id = '29100000-0000-0000-0000-000000000040'
  ),
  'Google x Google overlap is retained as technical divergence but excluded from critical ops alert'
);

select ok(
  exists (
    select 1 from public.service_list_ops_actionable_schedule_divergences(now() - interval '15 minutes')
    where id = '29100000-0000-0000-0000-000000000041'
  ),
  'Google divergence against manual block remains actionable'
);

select ok(
  exists (
    select 1 from public.service_list_ops_actionable_schedule_divergences(now() - interval '15 minutes')
    where id = '29100000-0000-0000-0000-000000000042'
  ),
  'open Google divergence with no provable current blocker remains actionable'
);

update public.schedule_divergences
set detected_at = now() - interval '5 minutes'
where id = '29100000-0000-0000-0000-000000000041';

select ok(
  not exists (
    select 1 from public.service_list_ops_actionable_schedule_divergences(now() - interval '15 minutes')
    where id = '29100000-0000-0000-0000-000000000041'
  ),
  'actionable divergence still respects Item C fifteen-minute SLA'
);

select * from finish();
rollback;
