begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(10);

insert into public.resources (id, name, resource_type)
values ('93000000-0000-0000-0000-000000000001', 'GOOGLE RUNTIME RESOURCE', 'PHYSICAL');

insert into public.google_connections (
  id, account_email, refresh_token_ciphertext, token_encryption_version, scopes, status
) values (
  '93000000-0000-0000-0000-000000000010',
  'runtime@example.com',
  'ciphertext-placeholder',
  1,
  array['calendar.events'],
  'ACTIVE'
);

insert into public.google_calendars (
  id, google_connection_id, google_calendar_id, name, timezone, is_active
) values (
  '93000000-0000-0000-0000-000000000020',
  '93000000-0000-0000-0000-000000000010',
  'runtime-calendar@example.com',
  'Runtime Calendar',
  'America/Sao_Paulo',
  true
);

insert into public.google_calendar_resources (google_calendar_id, resource_id)
values (
  '93000000-0000-0000-0000-000000000020',
  '93000000-0000-0000-0000-000000000001'
);

select public.upsert_google_calendar_event(
  '93000000-0000-0000-0000-000000000020',
  'runtime-event-1',
  'confirmed',
  'Runtime external event',
  false,
  '2035-01-15 10:00:00-03'::timestamptz,
  '2035-01-15 11:00:00-03'::timestamptz,
  null, null, null, null, null, null, null, null, null, false, null, null,
  '{"id":"runtime-event-1"}'::jsonb
);

select is(
  (select count(*)::integer from public.resource_allocations
   where external_event_id = 'runtime-event-1' and status = 'EXTERNAL_ACTIVE'),
  1,
  'external event initially blocks its mapped resource'
);

insert into public.google_sync_state (
  google_calendar_id, sync_token, health_status, last_success_at
) values (
  '93000000-0000-0000-0000-000000000020', 'old-token', 'HEALTHY', now()
) on conflict (google_calendar_id) do update
set sync_token = excluded.sync_token, health_status = excluded.health_status, last_success_at = excluded.last_success_at;

select public.prepare_google_full_sync('93000000-0000-0000-0000-000000000020');

select ok(
  exists (
    select 1 from public.google_sync_state
    where google_calendar_id = '93000000-0000-0000-0000-000000000020'
      and health_status = 'REBUILDING'
      and sync_token is null
  ),
  'full sync preparation makes the calendar fail-closed and clears sync token'
);

select ok(
  exists (
    select 1 from public.resource_allocations
    where external_event_id = 'runtime-event-1' and status = 'RELEASED'
  ),
  'full sync preparation releases only prior external allocations before replay'
);

create temporary table runtime_job as
select public.enqueue_google_calendar_sync(
  '93000000-0000-0000-0000-000000000020',
  'runtime-sync-idempotency',
  '{"source":"TEST"}'::jsonb
) as job_id;

select is(
  public.enqueue_google_calendar_sync(
    '93000000-0000-0000-0000-000000000020',
    'runtime-sync-idempotency',
    '{"source":"DUPLICATE"}'::jsonb
  ),
  (select job_id from runtime_job),
  'sync enqueue is idempotent by key'
);

select is(
  (select count(*)::integer from public.integration_jobs where idempotency_key = 'runtime-sync-idempotency'),
  1,
  'idempotent enqueue creates exactly one job'
);

create temporary table claimed_job as
select * from public.claim_integration_jobs('worker-test', array['GOOGLE_CALENDAR_SYNC'], 10);

select ok(
  exists (
    select 1 from claimed_job
    where status = 'PROCESSING'
      and attempt_count = 1
      and locked_by = 'worker-test'
      and locked_at is not null
  ),
  'claim atomically locks and increments attempt count'
);

select is(
  (select count(*)::integer from public.claim_integration_jobs('worker-other', array['GOOGLE_CALENDAR_SYNC'], 10)),
  0,
  'a processing job cannot be claimed by a second worker'
);

select public.finish_integration_job(
  (select id from claimed_job), 'worker-test', false, 'TRANSIENT', 30
);

select ok(
  exists (
    select 1 from public.integration_jobs
    where id = (select id from claimed_job)
      and status = 'PENDING'
      and run_after > now()
      and locked_by is null
  ),
  'transient failure schedules retry and releases worker lock'
);

update public.integration_jobs
set run_after = now() - interval '1 second'
where id = (select id from claimed_job);

create temporary table claimed_again as
select * from public.claim_integration_jobs('worker-test-2', array['GOOGLE_CALENDAR_SYNC'], 10);

select is(
  (select attempt_count from claimed_again),
  2,
  'retry claim increments the attempt count deterministically'
);

select public.finish_integration_job(
  (select id from claimed_again), 'worker-test-2', true, null, null
);

select ok(
  exists (
    select 1 from public.integration_jobs
    where id = (select id from claimed_again)
      and status = 'SUCCEEDED'
      and processed_at is not null
      and locked_at is null
  ),
  'successful completion is terminal and clears lock metadata'
);

select * from finish();
rollback;
