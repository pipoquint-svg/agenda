begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(8);

insert into public.resources (id, name, resource_type)
values ('93200000-0000-0000-0000-000000000001', 'TESTE Resource Mapping', 'PHYSICAL');

insert into public.google_connections (
  id, account_email, refresh_token_ciphertext, token_encryption_version, scopes, status
) values (
  '93200000-0000-0000-0000-000000000010',
  'teste-mapping@example.com', 'ciphertext-placeholder', 1, array['calendar.events'], 'ACTIVE'
);

insert into public.google_calendars (
  id, google_connection_id, google_calendar_id, name, timezone, access_role, is_active
) values (
  '93200000-0000-0000-0000-000000000020',
  '93200000-0000-0000-0000-000000000010',
  'teste-mapping-calendar@example.com',
  'TESTE Mapping Calendar', 'America/Sao_Paulo', 'reader', true
);

select throws_ok(
  $$ select public.service_admin_add_google_calendar_resource_mapping(
    '93200000-0000-0000-0000-000000000020',
    '93200000-0000-0000-0000-000000000001',
    null
  ) $$,
  'P0001',
  'GOOGLE_CALENDAR_WRITE_ACCESS_REQUIRED',
  'read-only Google calendar cannot be mapped as an Agenda resource mirror'
);

update public.google_calendars set access_role = 'writer'
where id = '93200000-0000-0000-0000-000000000020';

select lives_ok(
  $$ select public.service_admin_add_google_calendar_resource_mapping(
    '93200000-0000-0000-0000-000000000020',
    '93200000-0000-0000-0000-000000000001',
    null
  ) $$,
  'writer calendar can be mapped'
);

select ok(
  exists(
    select 1 from public.google_calendar_resources
    where google_calendar_id = '93200000-0000-0000-0000-000000000020'
      and resource_id = '93200000-0000-0000-0000-000000000001'
  ),
  'mapping is persisted'
);

select ok(
  exists(
    select 1 from public.audit_logs
    where entity_type = 'RESOURCE'
      and entity_id = '93200000-0000-0000-0000-000000000001'
      and action = 'GOOGLE_CALENDAR_RESOURCE_MAPPED'
  ),
  'mapping emits an audit event'
);

insert into public.google_calendar_events (
  id, google_calendar_id, google_event_id, status, summary, start_at, end_at,
  qualification, normalized_payload
) values (
  '93200000-0000-0000-0000-000000000030',
  '93200000-0000-0000-0000-000000000020',
  'external-test-event', 'confirmed', 'TESTE external block',
  now() + interval '1 day', now() + interval '1 day 1 hour',
  'BLOCKING', '{}'::jsonb
);

insert into public.resource_allocations (
  resource_id, allocation_type, status, occupied_range,
  external_source, external_calendar_id, external_event_id, google_calendar_event_id
) values (
  '93200000-0000-0000-0000-000000000001',
  'EXTERNAL_BLOCK', 'EXTERNAL_ACTIVE',
  tstzrange(now() + interval '1 day', now() + interval '1 day 1 hour', '[)'),
  'GOOGLE', 'teste-mapping-calendar@example.com', 'external-test-event',
  '93200000-0000-0000-0000-000000000030'
);

select lives_ok(
  $$ select public.service_admin_remove_google_calendar_resource_mapping(
    '93200000-0000-0000-0000-000000000020',
    '93200000-0000-0000-0000-000000000001',
    null,
    'TEST_CLEANUP'
  ) $$,
  'mapping can be removed transactionally'
);

select ok(
  not exists(
    select 1 from public.google_calendar_resources
    where google_calendar_id = '93200000-0000-0000-0000-000000000020'
      and resource_id = '93200000-0000-0000-0000-000000000001'
  ),
  'mapping is removed'
);

select is(
  (select status::text from public.resource_allocations where google_calendar_event_id = '93200000-0000-0000-0000-000000000030'),
  'RELEASED',
  'unmapping releases existing external allocation from that calendar/resource'
);

select ok(
  exists(
    select 1 from public.audit_logs
    where entity_type = 'RESOURCE'
      and entity_id = '93200000-0000-0000-0000-000000000001'
      and action = 'GOOGLE_CALENDAR_RESOURCE_UNMAPPED'
  ),
  'unmapping emits an audit event'
);

select * from finish();
rollback;
