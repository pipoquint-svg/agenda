begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(11);

insert into public.resources (id, name, resource_type)
values
  ('93100000-0000-0000-0000-000000000001', 'GOOGLE HEALTH RESOURCE', 'PHYSICAL'),
  ('93100000-0000-0000-0000-000000000002', 'UNMAPPED RESOURCE', 'PHYSICAL');

select ok(
  public.google_resource_sync_is_ready('93100000-0000-0000-0000-000000000002', 600),
  'resource without Google mapping is unaffected by the health gate'
);

insert into public.google_connections (
  id, account_email, refresh_token_ciphertext, token_encryption_version, scopes, status
) values (
  '93100000-0000-0000-0000-000000000010',
  'teste-health@example.com',
  'ciphertext-placeholder',
  1,
  array['calendar.events'],
  'ACTIVE'
);

insert into public.google_calendars (
  id, google_connection_id, google_calendar_id, name, timezone, is_active
) values (
  '93100000-0000-0000-0000-000000000020',
  '93100000-0000-0000-0000-000000000010',
  'teste-health-calendar@example.com',
  'TESTE Health Calendar',
  'America/Sao_Paulo',
  true
);

insert into public.google_calendar_resources (google_calendar_id, resource_id)
values ('93100000-0000-0000-0000-000000000020', '93100000-0000-0000-0000-000000000001');

select ok(
  not public.google_resource_sync_is_ready('93100000-0000-0000-0000-000000000001', 600),
  'mapped calendar without sync state fails closed'
);

insert into public.google_sync_state (
  google_calendar_id, sync_token, health_status, last_attempt_at, last_success_at, consecutive_failures
) values (
  '93100000-0000-0000-0000-000000000020', 'sync-token', 'HEALTHY', now(), now(), 0
);

select ok(
  public.google_resource_sync_is_ready('93100000-0000-0000-0000-000000000001', 600),
  'mapped ACTIVE calendar with recent HEALTHY sync is ready'
);

update public.google_sync_state
set last_success_at = now() - interval '11 minutes'
where google_calendar_id = '93100000-0000-0000-0000-000000000020';

select ok(
  not public.google_resource_sync_is_ready('93100000-0000-0000-0000-000000000001', 600),
  'sync older than two five-minute worker cycles fails closed'
);

update public.google_sync_state
set health_status = 'REBUILDING', last_success_at = now()
where google_calendar_id = '93100000-0000-0000-0000-000000000020';

select ok(
  not public.google_resource_sync_is_ready('93100000-0000-0000-0000-000000000001', 600),
  'full-sync rebuilding state fails closed even with recent timestamp'
);

update public.google_sync_state
set health_status = 'HEALTHY', last_success_at = now()
where google_calendar_id = '93100000-0000-0000-0000-000000000020';
update public.google_connections
set status = 'RECONNECT_REQUIRED'
where id = '93100000-0000-0000-0000-000000000010';

select ok(
  not public.google_resource_sync_is_ready('93100000-0000-0000-0000-000000000001', 600),
  'connection requiring OAuth reconnect fails closed'
);

update public.google_connections set status = 'ACTIVE'
where id = '93100000-0000-0000-0000-000000000010';
update public.google_sync_state
set last_success_at = now() - interval '7 minutes'
where google_calendar_id = '93100000-0000-0000-0000-000000000020';

select ok(
  public.google_resource_sync_is_ready('93100000-0000-0000-0000-000000000001', 600),
  'ten-minute threshold tolerates one delayed five-minute reconciliation cycle'
);

select ok(
  not public.google_resource_sync_is_ready('93100000-0000-0000-0000-000000000001', 300),
  'same state is stale under a single-cycle five-minute threshold'
);

select has_trigger(
  'public',
  'resource_allocations',
  'resource_allocations_google_sync_health_guard',
  'authoritative allocation insert path has Google health defense-in-depth trigger'
);

select ok(
  pg_get_functiondef('public.list_available_slots(uuid,uuid,jsonb,integer,date,text)'::regprocedure)
    like '%google_resource_sync_is_ready%',
  'fixed-duration slot engine is wrapped by Google health gate'
);

select ok(
  pg_get_functiondef('public.list_available_slots_for_duration(uuid,uuid,integer,jsonb,integer,date,text)'::regprocedure)
    like '%google_resource_sync_is_ready%',
  'variable/minutes/reschedule slot engine is wrapped by Google health gate'
);

select * from finish();
rollback;
