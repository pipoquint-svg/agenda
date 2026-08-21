begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(10);

insert into public.resources (id, name, resource_type)
values ('94000000-0000-0000-0000-000000000001', 'MANAGED GOOGLE PERSON', 'PERSON');

insert into public.employees (id, name, resource_id)
values (
  '94000000-0000-0000-0000-000000000010',
  'Managed Google Employee',
  '94000000-0000-0000-0000-000000000001'
);

insert into public.categories (id, name, slug)
values ('94000000-0000-0000-0000-000000000020', 'Managed Google', 'managed-google-test');

insert into public.services (
  id, category_id, name, slug, base_duration_minutes, base_price,
  minimum_people, maximum_people, maximum_booking_horizon_days
) values (
  '94000000-0000-0000-0000-000000000030',
  '94000000-0000-0000-0000-000000000020',
  'Ensaio Managed Google',
  'ensaio-managed-google',
  60, 100.00, 1, 10, 5000
);

insert into public.service_employees (id, service_id, employee_id)
values (
  '94000000-0000-0000-0000-000000000040',
  '94000000-0000-0000-0000-000000000030',
  '94000000-0000-0000-0000-000000000010'
);

insert into public.google_connections (
  id, account_email, refresh_token_ciphertext, token_encryption_version, scopes, status
) values (
  '94000000-0000-0000-0000-000000000050',
  'managed@example.com', 'ciphertext-placeholder', 1, array['calendar.events'], 'ACTIVE'
);

insert into public.google_calendars (
  id, google_connection_id, google_calendar_id, name, timezone, is_active
) values (
  '94000000-0000-0000-0000-000000000060',
  '94000000-0000-0000-0000-000000000050',
  'managed-calendar@example.com', 'Managed Calendar', 'America/Sao_Paulo', true
);

insert into public.service_employee_calendar_write (
  service_employee_id, google_calendar_id
) values (
  '94000000-0000-0000-0000-000000000040',
  '94000000-0000-0000-0000-000000000060'
);

insert into public.appointments (
  id, public_code, service_id, service_employee_id,
  status, financial_status,
  start_at, end_at, core_start_at, core_end_at,
  duration_minutes, people_count, version,
  service_name_snapshot
) values (
  '94000000-0000-0000-0000-000000000070',
  'MG-001',
  '94000000-0000-0000-0000-000000000030',
  '94000000-0000-0000-0000-000000000040',
  'CONFIRMED', 'PARTIALLY_PAID',
  '2035-01-15 08:00:00-03'::timestamptz,
  '2035-01-15 10:00:00-03'::timestamptz,
  '2035-01-15 09:00:00-03'::timestamptz,
  '2035-01-15 10:00:00-03'::timestamptz,
  120, 1, 4,
  'Ensaio Gestante'
);

select is(
  (public.get_google_appointment_desired_state('94000000-0000-0000-0000-000000000070')->>'desired_action'),
  'PRESENT',
  'confirmed appointment must be present in managed Google calendar'
);

select is(
  (public.get_google_appointment_desired_state('94000000-0000-0000-0000-000000000070')->>'start_at')::timestamptz,
  '2035-01-15 08:00:00-03'::timestamptz,
  'FULL_APPOINTMENT writes the customer-visible envelope start'
);

update public.service_employee_calendar_write
set time_scope = 'CORE_ONLY'
where service_employee_id = '94000000-0000-0000-0000-000000000040';

select is(
  (public.get_google_appointment_desired_state('94000000-0000-0000-0000-000000000070')->>'start_at')::timestamptz,
  '2035-01-15 09:00:00-03'::timestamptz,
  'CORE_ONLY writes the immutable core start'
);

select is(
  (public.get_google_appointment_desired_state('94000000-0000-0000-0000-000000000070')->>'end_at')::timestamptz,
  '2035-01-15 10:00:00-03'::timestamptz,
  'CORE_ONLY writes the immutable core end'
);

select is(
  (public.get_google_appointment_desired_state('94000000-0000-0000-0000-000000000070')->>'summary'),
  'Ensaio Gestante',
  'managed event title uses service snapshot without customer PII'
);

update public.appointments
set status = 'CANCELLED', version = 5
where id = '94000000-0000-0000-0000-000000000070';

select is(
  (public.get_google_appointment_desired_state('94000000-0000-0000-0000-000000000070')->>'desired_action'),
  'ABSENT',
  'cancelled appointment desired state removes managed Google event'
);

insert into public.integration_jobs (
  job_type, entity_type, entity_id, entity_version, payload_json, idempotency_key
) values (
  'GOOGLE_APPOINTMENT_SYNC', 'APPOINTMENT',
  '94000000-0000-0000-0000-000000000070', 4,
  '{"reason":"OLD_RESCHEDULE"}'::jsonb,
  'managed-google-stale-v4'
);

create temporary table stale_claim as
select * from public.claim_integration_jobs(
  'managed-worker', array['GOOGLE_APPOINTMENT_SYNC'], 10
);

select is(
  (select entity_version from stale_claim),
  4,
  'old appointment version can be claimed before desired-state comparison'
);

select public.discard_integration_job_stale(
  (select id from stale_claim), 'managed-worker', 5
);

select ok(
  exists (
    select 1 from public.integration_jobs
    where id = (select id from stale_claim)
      and status = 'DISCARDED_STALE'
      and processed_at is not null
      and locked_by is null
  ),
  'older version is terminally discarded instead of executing stale Google state'
);

select has_index(
  'public', 'google_calendar_events',
  'google_calendar_events_active_managed_appointment_uq',
  'only one active managed Google event is allowed per appointment/calendar'
);

update public.appointments
set status = 'COMPLETED', version = 6
where id = '94000000-0000-0000-0000-000000000070';

select is(
  (public.get_google_appointment_desired_state('94000000-0000-0000-0000-000000000070')->>'desired_action'),
  'PRESENT',
  'completed appointments preserve their historical managed Google event'
);

select * from finish();
rollback;
