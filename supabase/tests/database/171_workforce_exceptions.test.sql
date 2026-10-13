begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(42);

-- ---------------------------------------------------------------------------
-- Fixture: tenant A (owner, employee E1, employee E2), tenant B (owner).
-- ---------------------------------------------------------------------------
insert into auth.users(id, instance_id, aud, role, email, encrypted_password, created_at, updated_at)
values
  ('17100000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'wfx-owner-a@example.test', '', now(), now()),
  ('17100000-0000-4000-8000-000000000002', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'wfx-owner-b@example.test', '', now(), now()),
  ('17100000-0000-4000-8000-000000000003', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'wfx-e1@example.test', '', now(), now()),
  ('17100000-0000-4000-8000-000000000004', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'wfx-e2@example.test', '', now(), now()),
  ('17100000-0000-4000-8000-000000000005', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'wfx-member@example.test', '', now(), now());
insert into public.admin_users(id, auth_user_id, display_name, role, is_active)
values
  ('17100000-0000-4000-8000-000000000011', '17100000-0000-4000-8000-000000000001', 'Owner A', 'OWNER', true),
  ('17100000-0000-4000-8000-000000000012', '17100000-0000-4000-8000-000000000002', 'Owner B', 'OWNER', true),
  ('17100000-0000-4000-8000-000000000013', '17100000-0000-4000-8000-000000000003', 'E1', 'OPERATION', true),
  ('17100000-0000-4000-8000-000000000014', '17100000-0000-4000-8000-000000000004', 'E2', 'OPERATION', true),
  ('17100000-0000-4000-8000-000000000015', '17100000-0000-4000-8000-000000000005', 'Member', 'OPERATION', true);
insert into public.tenants(id, name, slug) values
  ('17100000-0000-4000-8000-000000000021', 'WFX Tenant A', 'wfx-tenant-a'),
  ('17100000-0000-4000-8000-000000000022', 'WFX Tenant B', 'wfx-tenant-b');
insert into public.tenant_members(tenant_id, user_id, role) values
  ('17100000-0000-4000-8000-000000000021', '17100000-0000-4000-8000-000000000001', 'OWNER'),
  ('17100000-0000-4000-8000-000000000022', '17100000-0000-4000-8000-000000000002', 'OWNER');

create temp table wfx_ids(k text primary key, v uuid not null) on commit drop;

insert into wfx_ids
select 'employer_a', (r -> 'employer' ->> 'employer_id')::uuid
from public.service_workforce_owner_save_employer(
  '17100000-0000-4000-8000-000000000011', gen_random_uuid(),
  '{"legal_name":"Empregadora WFX","workplace_city":"Palhoça","workplace_state":"SC"}') r;
insert into wfx_ids
select 'e1', (r -> 'employee' ->> 'employee_id')::uuid
from public.service_workforce_owner_save_employee(
  '17100000-0000-4000-8000-000000000011', gen_random_uuid(),
  jsonb_build_object('employer_id', (select v from wfx_ids where k = 'employer_a'),
    'admin_user_id', '17100000-0000-4000-8000-000000000013', 'hired_on', '2026-01-01')) r;
insert into wfx_ids
select 'e2', (r -> 'employee' ->> 'employee_id')::uuid
from public.service_workforce_owner_save_employee(
  '17100000-0000-4000-8000-000000000011', gen_random_uuid(),
  jsonb_build_object('employer_id', (select v from wfx_ids where k = 'employer_a'),
    'admin_user_id', '17100000-0000-4000-8000-000000000014', 'hired_on', '2026-01-01')) r;

-- ---------------------------------------------------------------------------
-- 1. Live start/finish with server time and a single OPEN period.
-- ---------------------------------------------------------------------------
insert into wfx_ids
select 'open_1', (r -> 'exception' ->> 'exception_id')::uuid
from public.service_workforce_employee_start_extra(
  '17100000-0000-4000-8000-000000000013', '17100000-0000-4000-8000-0000000000a1', '{}') r;
select ok(exists (
  select 1 from workforce.work_exceptions x join wfx_ids i on i.v = x.id
  where i.k = 'open_1' and x.status = 'OPEN' and x.source = 'EMPLOYEE' and x.exception_type = 'EXTRA_WORK'
    and x.reported_start = now() and x.reported_end is null
    and x.employee_id = (select v from wfx_ids where k = 'e1')
), 'start extra opens a period with the authoritative server timestamp');
select is(
  (public.service_workforce_employee_start_extra(
    '17100000-0000-4000-8000-000000000013', '17100000-0000-4000-8000-0000000000a1', '{}') ->> 'replayed')::boolean,
  true, 'double click with the same idempotency key replays instead of opening again'
);
select throws_ok(
  $$select public.service_workforce_employee_start_extra(
    '17100000-0000-4000-8000-000000000013', '17100000-0000-4000-8000-0000000000a2', '{}')$$,
  'P0001', 'WORKFORCE_EXTRA_ALREADY_OPEN', 'a second start with a new key does not create a second OPEN'
);
select is((select count(*) from workforce.work_exceptions where employee_id = (select v from wfx_ids where k = 'e1') and status = 'OPEN'),
  1::bigint, 'exactly one OPEN period per employee');
select throws_ok(
  format($$insert into workforce.work_exceptions(tenant_id, employer_id, employee_id, exception_type, source, status,
      event_date, reported_start, recorded_by_admin_id)
    values ('17100000-0000-4000-8000-000000000021', '%s', '%s', 'EXTRA_WORK', 'EMPLOYEE', 'OPEN', current_date,
      now() - interval '1 hour', '17100000-0000-4000-8000-000000000013')$$,
    (select v from wfx_ids where k = 'employer_a'), (select v from wfx_ids where k = 'e1')),
  '23P01', null, 'the database itself rejects a second OPEN period'
);
select ok(exists (
  select 1 from pg_indexes
  where schemaname = 'workforce' and indexname = 'work_exceptions_single_open_key'
    and indexdef like 'CREATE UNIQUE INDEX%' and indexdef like '%WHERE (status = ''OPEN''::text)%'
), 'a unique partial index guarantees a single OPEN period per employee');
select throws_ok(
  $$select public.service_workforce_employee_start_extra(
    '17100000-0000-4000-8000-000000000013', '17100000-0000-4000-8000-0000000000a3', '{"reported_start":"2026-01-01T08:00"}')$$,
  'P0001', 'WORKFORCE_PAYLOAD_FIELD_FORBIDDEN:reported_start', 'the browser cannot choose the start timestamp'
);

-- Move the open period one hour into the past so finish has a positive duration
-- (the transaction clock is frozen). This is test-only setup on raw data.
alter table workforce.work_exceptions disable trigger work_exceptions_guard;
update workforce.work_exceptions set reported_start = reported_start - interval '1 hour'
where id = (select v from wfx_ids where k = 'open_1');
alter table workforce.work_exceptions enable trigger work_exceptions_guard;

select is(
  public.service_workforce_employee_finish_extra(
    '17100000-0000-4000-8000-000000000013', '17100000-0000-4000-8000-0000000000b1', '{}') -> 'exception' ->> 'status',
  'RECORDED', 'finish closes the OPEN period'
);
select ok(exists (
  select 1 from workforce.work_exceptions x join wfx_ids i on i.v = x.id
  where i.k = 'open_1' and x.reported_end = now() and x.finished_at = now()
), 'finish uses the server timestamp');
select throws_ok(
  $$select public.service_workforce_employee_finish_extra(
    '17100000-0000-4000-8000-000000000013', '17100000-0000-4000-8000-0000000000b2', '{}')$$,
  'P0001', 'WORKFORCE_EXTRA_NOT_OPEN', 'finish without an OPEN period fails'
);
select throws_ok(
  $$select public.service_workforce_employee_finish_extra(
    '17100000-0000-4000-8000-000000000013', '17100000-0000-4000-8000-0000000000b3', '{"reported_end":"2026-01-01T20:00"}')$$,
  'P0001', 'WORKFORCE_PAYLOAD_FIELD_FORBIDDEN:reported_end', 'the browser cannot choose the end timestamp'
);

-- ---------------------------------------------------------------------------
-- 2. Retroactive employee records.
-- ---------------------------------------------------------------------------
insert into wfx_ids
select 'retro_1', (r -> 'exception' ->> 'exception_id')::uuid
from public.service_workforce_employee_record_exception(
  '17100000-0000-4000-8000-000000000013', '17100000-0000-4000-8000-0000000000c1',
  '{"exception_type":"EXTRA_WORK","start_local":"2026-10-05T09:00","end_local":"2026-10-05T11:00","note":"Montagem de cenário"}') r;
select ok(exists (
  select 1 from workforce.work_exceptions x join wfx_ids i on i.v = x.id
  where i.k = 'retro_1' and x.source = 'RETROACTIVE_EMPLOYEE' and x.status = 'PENDING_REVIEW'
    and x.event_date = '2026-10-05'
    and x.reported_start = '2026-10-05 09:00:00-03' and x.reported_end = '2026-10-05 11:00:00-03'
    and x.created_at = now()
), 'retroactive record keeps the referenced period (local time) and the real registration time');
select throws_ok(
  $$select public.service_workforce_employee_record_exception(
    '17100000-0000-4000-8000-000000000013', '17100000-0000-4000-8000-0000000000c2',
    '{"exception_type":"EXTRA_WORK","start_local":"2026-10-05T10:00","end_local":"2026-10-05T12:00"}')$$,
  'P0001', 'WORKFORCE_EXTRA_PERIOD_OVERLAP', 'overlapping extra periods are rejected (no double counting)'
);
select throws_ok(
  $$select public.service_workforce_employee_record_exception(
    '17100000-0000-4000-8000-000000000013', '17100000-0000-4000-8000-0000000000c3',
    '{"exception_type":"EXTRA_WORK","start_local":"2099-01-01T09:00","end_local":"2099-01-01T10:00"}')$$,
  'P0001', 'WORKFORCE_PERIOD_IN_FUTURE', 'future work cannot be declared'
);
select throws_ok(
  $$select public.service_workforce_employee_record_exception(
    '17100000-0000-4000-8000-000000000013', '17100000-0000-4000-8000-0000000000c4',
    '{"exception_type":"EXTRA_WORK","start_local":"2026-10-05T12:00","end_local":"2026-10-05T11:00"}')$$,
  'P0001', 'WORKFORCE_PERIOD_INVALID', 'end before start is rejected'
);
select throws_ok(
  $$select public.service_workforce_employee_record_exception(
    '17100000-0000-4000-8000-000000000013', '17100000-0000-4000-8000-0000000000c5',
    '{"exception_type":"EXTRA_WORK","start_local":"2025-12-01T09:00","end_local":"2025-12-01T10:00"}')$$,
  'P0001', 'WORKFORCE_PERIOD_BEFORE_EMPLOYMENT', 'records before hiring are rejected'
);
select lives_ok(
  $$select public.service_workforce_employee_record_exception(
    '17100000-0000-4000-8000-000000000013', '17100000-0000-4000-8000-0000000000c6',
    '{"exception_type":"EXTRA_WORK","start_local":"2026-10-02T23:00","end_local":"2026-10-03T02:00"}')$$,
  'a period across midnight is accepted'
);
select is(
  (select event_date from workforce.work_exceptions
   where employee_id = (select v from wfx_ids where k = 'e1') and reported_start = '2026-10-02 23:00:00-03'),
  '2026-10-02'::date, 'event_date is the local date of the start'
);
select lives_ok(
  $$select public.service_workforce_employee_record_exception(
    '17100000-0000-4000-8000-000000000013', '17100000-0000-4000-8000-0000000000c7',
    '{"exception_type":"EARLY_LEAVE","start_local":"2026-10-06T17:30","end_local":"2026-10-06T19:15","note":"buscar filho"}')$$,
  'early leave is recorded as an occurrence (no negative balance)'
);
select lives_ok(
  $$select public.service_workforce_employee_record_exception(
    '17100000-0000-4000-8000-000000000013', '17100000-0000-4000-8000-0000000000c8',
    '{"exception_type":"MEDICAL_LEAVE","all_day":true,"event_date":"2026-10-07","event_end_date":"2026-10-08"}')$$,
  'medical leave is a plain all-day occurrence (no attachment, no CID)'
);
select throws_ok(
  $$select public.service_workforce_employee_record_exception(
    '17100000-0000-4000-8000-000000000013', '17100000-0000-4000-8000-0000000000c9',
    '{"exception_type":"EXTRA_WORK","all_day":true,"event_date":"2026-10-07"}')$$,
  'P0001', 'WORKFORCE_FIELD_INVALID:all_day', 'extra work must have a timed period'
);

-- ---------------------------------------------------------------------------
-- 3. Forged identity/state fields from the browser.
-- ---------------------------------------------------------------------------
select throws_ok(
  format($$select public.service_workforce_employee_record_exception(
    '17100000-0000-4000-8000-000000000013', '17100000-0000-4000-8000-0000000000d1',
    '{"exception_type":"ABSENCE","all_day":true,"event_date":"2026-10-01","employee_id":"%s"}')$$, (select v from wfx_ids where k = 'e2')),
  'P0001', 'WORKFORCE_PAYLOAD_FIELD_FORBIDDEN:employee_id', 'forged employee_id fails'
);
select throws_ok(
  $$select public.service_workforce_employee_record_exception(
    '17100000-0000-4000-8000-000000000013', '17100000-0000-4000-8000-0000000000d2',
    '{"exception_type":"ABSENCE","all_day":true,"event_date":"2026-10-01","employer_id":"17100000-0000-4000-8000-000000000021"}')$$,
  'P0001', 'WORKFORCE_PAYLOAD_FIELD_FORBIDDEN:employer_id', 'forged employer_id fails'
);
select throws_ok(
  $$select public.service_workforce_employee_record_exception(
    '17100000-0000-4000-8000-000000000013', '17100000-0000-4000-8000-0000000000d3',
    '{"exception_type":"ABSENCE","all_day":true,"event_date":"2026-10-01","status":"VALIDATED"}')$$,
  'P0001', 'WORKFORCE_PAYLOAD_FIELD_FORBIDDEN:status', 'forged status fails'
);
select throws_ok(
  $$select public.service_workforce_employee_record_exception(
    '17100000-0000-4000-8000-000000000013', '17100000-0000-4000-8000-0000000000d4',
    '{"exception_type":"ABSENCE","all_day":true,"event_date":"2026-10-01","source":"MANAGER"}')$$,
  'P0001', 'WORKFORCE_PAYLOAD_FIELD_FORBIDDEN:source', 'forged source fails'
);
select throws_ok(
  $$select public.service_workforce_employee_record_exception(
    '17100000-0000-4000-8000-000000000013', '17100000-0000-4000-8000-0000000000d5',
    '{"exception_type":"EXTRA_WORK","start_local":"2026-10-01T08:00","end_local":"2026-10-01T09:00","duration_minutes":600}')$$,
  'P0001', 'WORKFORCE_PAYLOAD_FIELD_FORBIDDEN:duration_minutes', 'forged duration fails'
);
select throws_ok(
  $$select public.service_workforce_employee_record_exception(
    '17100000-0000-4000-8000-000000000013', '17100000-0000-4000-8000-0000000000d6',
    '{"exception_type":"EXTRA_WORK","start_local":"2026-10-01T08:00","end_local":"2026-10-01T09:00","classification":"EXTRA_HOLIDAY"}')$$,
  'P0001', 'WORKFORCE_PAYLOAD_FIELD_FORBIDDEN:classification', 'forged classification fails'
);
select throws_ok(
  $$select public.service_workforce_employee_record_exception(
    '17100000-0000-4000-8000-000000000013', '17100000-0000-4000-8000-0000000000d7',
    '{"exception_type":"EXTRA_WORK","start_local":"2026-10-01T08:00","end_local":"2026-10-01T09:00","created_by":"17100000-0000-4000-8000-000000000011"}')$$,
  'P0001', 'WORKFORCE_PAYLOAD_FIELD_FORBIDDEN:created_by', 'forged created_by fails'
);

-- ---------------------------------------------------------------------------
-- 4. Isolation between employees and tenants.
-- ---------------------------------------------------------------------------
select is(
  jsonb_array_length(public.service_workforce_employee_list_exceptions('17100000-0000-4000-8000-000000000014', '2026-10') -> 'exceptions'),
  0, 'employee E2 does not see employee E1 records'
);
select ok(
  jsonb_array_length(public.service_workforce_employee_list_exceptions('17100000-0000-4000-8000-000000000013', '2026-10') -> 'exceptions') >= 5,
  'employee E1 sees her own records'
);
select ok(
  not ((public.service_workforce_employee_list_exceptions('17100000-0000-4000-8000-000000000013', '2026-10') -> 'exceptions' -> 0) ? 'manager_note'),
  'employee view never exposes manager notes'
);
select throws_ok(
  format($$select public.service_workforce_owner_list_exceptions('17100000-0000-4000-8000-000000000012', '%s', '2026-10')$$,
    (select v from wfx_ids where k = 'e1')),
  'P0001', 'WORKFORCE_EMPLOYEE_NOT_FOUND', 'tenant B owner cannot read tenant A records'
);
select throws_ok(
  $$select public.service_workforce_employee_list_exceptions('17100000-0000-4000-8000-000000000015', '2026-10')$$,
  'P0001', 'WORKFORCE_EMPLOYEE_REQUIRED', 'a login without employment cannot read Minha Jornada'
);

-- ---------------------------------------------------------------------------
-- 5. Manager events.
-- ---------------------------------------------------------------------------
select is(
  public.service_workforce_owner_record_exception(
    '17100000-0000-4000-8000-000000000011', '17100000-0000-4000-8000-0000000000e1',
    jsonb_build_object('employee_id', (select v from wfx_ids where k = 'e1'),
      'exception_type', 'LATE_ARRIVAL', 'start_local', '2026-10-01T13:15', 'end_local', '2026-10-01T13:40',
      'note', 'nota interna')) -> 'exception' ->> 'source',
  'RETROACTIVE_MANAGER', 'owner records an administrative occurrence'
);
select throws_ok(
  format($$select public.service_workforce_owner_record_exception(
    '17100000-0000-4000-8000-000000000012', '17100000-0000-4000-8000-0000000000e2',
    '{"employee_id":"%s","exception_type":"ABSENCE","all_day":true,"event_date":"2026-10-01"}')$$, (select v from wfx_ids where k = 'e1')),
  'P0001', 'WORKFORCE_EMPLOYEE_NOT_FOUND', 'tenant B owner cannot record on a tenant A employee'
);
select throws_ok(
  format($$select public.service_workforce_owner_record_exception(
    '17100000-0000-4000-8000-000000000013', '17100000-0000-4000-8000-0000000000e3',
    '{"employee_id":"%s","exception_type":"ABSENCE","all_day":true,"event_date":"2026-10-01"}')$$, (select v from wfx_ids where k = 'e2')),
  'P0001', 'WORKFORCE_OWNER_REQUIRED', 'an employee cannot call the owner record endpoint'
);

-- ---------------------------------------------------------------------------
-- 6. Raw data is immutable and never deleted.
-- ---------------------------------------------------------------------------
select throws_ok(
  format($$update workforce.work_exceptions set reported_start = reported_start - interval '1 hour' where id = '%s'$$,
    (select v from wfx_ids where k = 'retro_1')),
  'P0001', 'WORKFORCE_IMMUTABLE:work_exceptions', 'raw start time cannot be updated'
);
select throws_ok(
  format($$update workforce.work_exceptions set reported_end = reported_end + interval '1 hour' where id = '%s'$$,
    (select v from wfx_ids where k = 'retro_1')),
  'P0001', 'WORKFORCE_IMMUTABLE:work_exceptions', 'raw end time cannot be updated once set'
);
select throws_ok(
  format($$delete from workforce.work_exceptions where id = '%s'$$, (select v from wfx_ids where k = 'retro_1')),
  'P0001', 'WORKFORCE_IMMUTABLE:work_exceptions', 'employee hours cannot be deleted, not even by the owner role'
);
select throws_ok(
  format($$update workforce.work_exceptions set status = 'OPEN' where id = '%s'$$, (select v from wfx_ids where k = 'retro_1')),
  'P0001', 'WORKFORCE_STATUS_TRANSITION_INVALID:pending_review_to_open', 'status follows the transition table only'
);
set local role authenticated;
select throws_ok(
  $$update workforce.work_exceptions set status = 'VALIDATED'$$,
  '42501', null, 'authenticated cannot update raw records directly'
);
reset role;
select ok(
  not exists (
    select 1 from workforce.audit_log a
    where a.entity_type = 'work_exception'
      and (a.after_state::text like '%buscar filho%' or a.after_state::text like '%nota interna%'
           or a.after_state::text like '%Montagem%')
  ),
  'free-text notes never reach the audit log'
);

select * from finish();
rollback;
