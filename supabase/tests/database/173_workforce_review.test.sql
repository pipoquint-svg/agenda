begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(45);

-- Fixture: tenant A (owner, employee E1 with Mon–Fri 13:15–19:15), tenant B (owner).
insert into auth.users(id, instance_id, aud, role, email, encrypted_password, created_at, updated_at)
values
  ('17300000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'wfr-owner-a@example.test', '', now(), now()),
  ('17300000-0000-4000-8000-000000000002', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'wfr-owner-b@example.test', '', now(), now()),
  ('17300000-0000-4000-8000-000000000003', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'wfr-e1@example.test', '', now(), now()),
  ('17300000-0000-4000-8000-000000000004', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'wfr-e2@example.test', '', now(), now());
insert into public.admin_users(id, auth_user_id, display_name, role, is_active)
values
  ('17300000-0000-4000-8000-000000000011', '17300000-0000-4000-8000-000000000001', 'Owner A', 'OWNER', true),
  ('17300000-0000-4000-8000-000000000012', '17300000-0000-4000-8000-000000000002', 'Owner B', 'OWNER', true),
  ('17300000-0000-4000-8000-000000000013', '17300000-0000-4000-8000-000000000003', 'E1', 'OPERATION', true),
  ('17300000-0000-4000-8000-000000000014', '17300000-0000-4000-8000-000000000004', 'E2', 'OPERATION', true);
insert into public.tenants(id, name, slug) values
  ('17300000-0000-4000-8000-000000000021', 'WFR Tenant A', 'wfr-tenant-a'),
  ('17300000-0000-4000-8000-000000000022', 'WFR Tenant B', 'wfr-tenant-b');
insert into public.tenant_members(tenant_id, user_id, role) values
  ('17300000-0000-4000-8000-000000000021', '17300000-0000-4000-8000-000000000001', 'OWNER'),
  ('17300000-0000-4000-8000-000000000022', '17300000-0000-4000-8000-000000000002', 'OWNER');

create temp table wfr_ids(k text primary key, v uuid not null) on commit drop;
insert into wfr_ids
select 'employer', (r -> 'employer' ->> 'employer_id')::uuid
from public.service_workforce_owner_save_employer('17300000-0000-4000-8000-000000000011', gen_random_uuid(),
  '{"legal_name":"Empregadora WFR","workplace_city":"Palhoça","workplace_state":"SC"}') r;
insert into wfr_ids
select 'e1', (r -> 'employee' ->> 'employee_id')::uuid
from public.service_workforce_owner_save_employee('17300000-0000-4000-8000-000000000011', gen_random_uuid(),
  jsonb_build_object('employer_id', (select v from wfr_ids where k = 'employer'), 'admin_user_id', '17300000-0000-4000-8000-000000000013')) r;
insert into wfr_ids
select 'e2', (r -> 'employee' ->> 'employee_id')::uuid
from public.service_workforce_owner_save_employee('17300000-0000-4000-8000-000000000011', gen_random_uuid(),
  jsonb_build_object('employer_id', (select v from wfr_ids where k = 'employer'), 'admin_user_id', '17300000-0000-4000-8000-000000000014')) r;
select public.service_workforce_owner_create_schedule_version('17300000-0000-4000-8000-000000000011', gen_random_uuid(),
  jsonb_build_object('employee_id', (select v from wfr_ids where k = 'e1'), 'effective_from', '2026-01-01',
    'days', '[{"iso_weekday":1,"start_time":"13:15","end_time":"19:15"},{"iso_weekday":2,"start_time":"13:15","end_time":"19:15"},
              {"iso_weekday":3,"start_time":"13:15","end_time":"19:15"},{"iso_weekday":4,"start_time":"13:15","end_time":"19:15"},
              {"iso_weekday":5,"start_time":"13:15","end_time":"19:15"}]'::jsonb));

-- Employee records (all in the past: Sep 2026).
insert into wfr_ids
select 'x_extra', (r -> 'exception' ->> 'exception_id')::uuid
from public.service_workforce_employee_record_exception('17300000-0000-4000-8000-000000000013', gen_random_uuid(),
  '{"exception_type":"EXTRA_WORK","start_local":"2026-09-22T18:00","end_local":"2026-09-22T20:00","note":"evento cliente"}') r;
insert into wfr_ids
select 'x_contested', (r -> 'exception' ->> 'exception_id')::uuid
from public.service_workforce_employee_record_exception('17300000-0000-4000-8000-000000000013', gen_random_uuid(),
  '{"exception_type":"EXTRA_WORK","start_local":"2026-09-26T09:00","end_local":"2026-09-26T13:00"}') r;
insert into wfr_ids
select 'x_withdraw', (r -> 'exception' ->> 'exception_id')::uuid
from public.service_workforce_employee_record_exception('17300000-0000-4000-8000-000000000013', gen_random_uuid(),
  '{"exception_type":"EXTRA_WORK","start_local":"2026-09-24T08:00","end_local":"2026-09-24T09:00"}') r;
insert into wfr_ids
select 'x_owner', (r -> 'exception' ->> 'exception_id')::uuid
from public.service_workforce_owner_record_exception('17300000-0000-4000-8000-000000000011', gen_random_uuid(),
  jsonb_build_object('employee_id', (select v from wfr_ids where k = 'e1'), 'exception_type', 'EARLY_LEAVE',
    'start_local', '2026-09-23T17:30', 'end_local', '2026-09-23T19:15', 'note', 'nota interna owner')) r;

create function pg_temp.emp(p_payload jsonb) returns jsonb language sql as $$
  select public.service_workforce_employee_review_exception('17300000-0000-4000-8000-000000000013', gen_random_uuid(), p_payload);
$$;
create function pg_temp.own(p_payload jsonb) returns jsonb language sql as $$
  select public.service_workforce_owner_review_exception('17300000-0000-4000-8000-000000000011', gen_random_uuid(), p_payload);
$$;
create function pg_temp.status(p_key text) returns text language sql as $$
  select x.status from workforce.work_exceptions x where x.id = (select v from wfr_ids where k = p_key);
$$;
create function pg_temp.blockers(p_month text) returns text language sql as $$
  select coalesce(string_agg(b ->> 'blocker', ',' order by b ->> 'blocker'), '')
  from jsonb_array_elements(public.service_workforce_owner_list_review_queue(
    '17300000-0000-4000-8000-000000000011', (select v from wfr_ids where k = 'e1'), p_month) -> 'blockers') b;
$$;

select is(regexp_count(pg_temp.blockers('2026-09'), 'PENDING_REVIEW'), 3,
  'retroactive employee records await owner review (divergence blocks closure)');

-- ---------------------------------------------------------------------------
-- 1. Owner validation and manager contest (never deletion).
-- ---------------------------------------------------------------------------
select is(pg_temp.own(jsonb_build_object('action', 'VALIDATE', 'exception_id', (select v from wfr_ids where k = 'x_extra'))) -> 'exception' ->> 'status',
  'VALIDATED', 'owner validates an employee record');
select throws_ok(
  format($$select pg_temp.own('{"action":"CONTEST","exception_id":"%s"}')$$, (select v from wfr_ids where k = 'x_contested')),
  'P0001', 'WORKFORCE_PAYLOAD_FIELD_REQUIRED:reason', 'manager contest requires a reason'
);
select is(
  pg_temp.own(jsonb_build_object('action', 'CONTEST', 'exception_id', (select v from wfr_ids where k = 'x_contested'),
    'reason', 'Sábado sem convocação registrada')) -> 'exception' ->> 'status',
  'MANAGER_CONTESTED', 'owner contests employee hours (MANAGER_CONTESTED)'
);
select ok(exists (
  select 1 from workforce.work_exceptions x
  where x.id = (select v from wfr_ids where k = 'x_contested')
    and x.reported_start = '2026-09-26 09:00:00-03' and x.reported_end = '2026-09-26 13:00:00-03'
), 'contested hours remain recorded as reported');
select ok(
  (select count(*) from workforce.work_exception_segments where exception_id = (select v from wfr_ids where k = 'x_contested')) > 0,
  'contested hours keep their calculation (nothing silently removed)'
);
select ok(position('MANAGER_CONTESTED' in pg_temp.blockers('2026-09')) > 0, 'an open manager contest blocks the closure');
select throws_ok(
  format($$delete from workforce.work_exceptions where id = '%s'$$, (select v from wfr_ids where k = 'x_contested')),
  'P0001', 'WORKFORCE_IMMUTABLE:work_exceptions', 'owner (or anyone) cannot delete employee hours'
);
select throws_ok(
  format($$select pg_temp.own('{"action":"CONTEST","exception_id":"%s","reason":"duplicado"}')$$, (select v from wfr_ids where k = 'x_owner')),
  'P0001', 'WORKFORCE_EXCEPTION_STATE_INVALID', 'owner contests employee records, not its own occurrences'
);
select throws_ok(
  format($$select public.service_workforce_owner_review_exception('17300000-0000-4000-8000-000000000012', gen_random_uuid(),
    '{"action":"CONTEST","exception_id":"%s","reason":"cross tenant"}')$$, (select v from wfr_ids where k = 'x_withdraw')),
  'P0001', 'WORKFORCE_EXCEPTION_NOT_FOUND', 'tenant B owner cannot contest tenant A records'
);
select throws_ok(
  format($$select public.service_workforce_owner_review_exception('17300000-0000-4000-8000-000000000013', gen_random_uuid(),
    '{"action":"VALIDATE","exception_id":"%s"}')$$, (select v from wfr_ids where k = 'x_withdraw')),
  'P0001', 'WORKFORCE_OWNER_REQUIRED', 'employee cannot validate (owner endpoint)'
);

-- ---------------------------------------------------------------------------
-- 2. Employee acknowledgement and contest of owner occurrences.
-- ---------------------------------------------------------------------------
select is((pg_temp.emp(jsonb_build_object('action', 'ACKNOWLEDGE', 'exception_id', (select v from wfr_ids where k = 'x_owner'))) -> 'exception' ->> 'acknowledged')::boolean,
  true, 'employee acknowledges an owner occurrence (ACKNOWLEDGED)');
select throws_ok(
  format($$select pg_temp.emp('{"action":"ACKNOWLEDGE","exception_id":"%s"}')$$, (select v from wfr_ids where k = 'x_owner')),
  'P0001', 'WORKFORCE_ALREADY_ACKNOWLEDGED', 'acknowledgement is recorded once'
);
select is(
  jsonb_array_length(pg_temp.emp(jsonb_build_object('action', 'CONTEST', 'exception_id', (select v from wfr_ids where k = 'x_owner'),
    'reason', 'Saí às 18:30, não às 17:30')) -> 'exception' -> 'open_contests'),
  1, 'employee contests an owner occurrence (CONTESTED)'
);
select ok(position('EMPLOYEE_CONTESTED' in pg_temp.blockers('2026-09')) > 0, 'an open employee contest blocks the closure');
select ok(
  not ((pg_temp.emp(jsonb_build_object('action', 'ACKNOWLEDGE', 'exception_id', (select v from wfr_ids where k = 'x_extra'))) -> 'exception') ? 'manager_note'),
  'employee read model never exposes the owner internal note'
);
select throws_ok(
  format($$select public.service_workforce_employee_review_exception('17300000-0000-4000-8000-000000000014', gen_random_uuid(),
    '{"action":"CONTEST","exception_id":"%s","reason":"não é meu"}')$$, (select v from wfr_ids where k = 'x_owner')),
  'P0001', 'WORKFORCE_EXCEPTION_NOT_FOUND', 'employee E2 cannot act on E1 records (forged exception_id)'
);
select throws_ok(
  format($$select pg_temp.emp('{"action":"ACKNOWLEDGE","exception_id":"%s","employee_id":"%s"}')$$,
    (select v from wfr_ids where k = 'x_owner'), (select v from wfr_ids where k = 'e2')),
  'P0001', 'WORKFORCE_PAYLOAD_FIELD_FORBIDDEN:employee_id', 'forged employee_id fails on review commands'
);
select lives_ok(
  format($$select pg_temp.own(jsonb_build_object('action','RESOLVE_CONTEST','acknowledgement_id',
    (select a.id from workforce.work_exception_acknowledgements a where a.exception_id = '%s' and a.status = 'OPEN'),
    'decision','MAINTAINED','reason','Registro de portaria confirma 17:30'))$$, (select v from wfr_ids where k = 'x_owner')),
  'owner resolves the employee contest keeping its position, with reason'
);
select ok(exists (
  select 1 from workforce.work_exception_acknowledgements a
  where a.exception_id = (select v from wfr_ids where k = 'x_owner') and a.kind = 'CONTESTED'
    and a.status = 'RESOLVED' and a.resolution = 'MAINTAINED' and a.reason = 'Saí às 18:30, não às 17:30'
), 'the contest stays on record after resolution');

-- ---------------------------------------------------------------------------
-- 3. Correction: request → pending (blocks) → approve; original stays auditable.
-- ---------------------------------------------------------------------------
select is(
  pg_temp.emp(jsonb_build_object('action', 'REQUEST_CORRECTION', 'exception_id', (select v from wfr_ids where k = 'x_contested'),
    'proposed_start_local', '2026-09-26T09:00', 'proposed_end_local', '2026-09-26T11:00',
    'reason', 'Saí às 11h, digitei errado')) -> 'exception' ->> 'status',
  'CORRECTION_REQUESTED', 'employee requests a correction'
);
select ok(position('CORRECTION_PENDING' in pg_temp.blockers('2026-09')) > 0, 'a pending correction blocks the closure');
select throws_ok(
  format($$select pg_temp.emp(jsonb_build_object('action','REQUEST_CORRECTION','exception_id','%s',
    'proposed_start_local','2026-09-26T09:00','proposed_end_local','2026-09-26T10:00','reason','outra'))$$,
    (select v from wfr_ids where k = 'x_contested')),
  'P0001', 'WORKFORCE_REVIEW_ALREADY_OPEN', 'only one pending correction per record'
);
insert into wfr_ids
select 'c1', c.id from workforce.work_exception_corrections c where c.exception_id = (select v from wfr_ids where k = 'x_contested');
select is(
  pg_temp.own(jsonb_build_object('action', 'REVIEW_CORRECTION', 'correction_id', (select v from wfr_ids where k = 'c1'),
    'decision', 'APPROVE')) -> 'exception' ->> 'status',
  'VALIDATED', 'owner approves the correction'
);
select ok(exists (
  select 1 from workforce.work_exceptions x
  where x.id = (select v from wfr_ids where k = 'x_contested')
    and x.reported_start = '2026-09-26 09:00:00-03' and x.reported_end = '2026-09-26 13:00:00-03'
), 'the original raw period stays untouched after approval');
select is(
  (select sum(duration_seconds) / 60 from workforce.work_exception_segments where exception_id = (select v from wfr_ids where k = 'x_contested'))::int,
  120, 'calculation now uses the approved interpretation (120 min, not 240)'
);
select is(
  (select resolution from workforce.work_exception_acknowledgements
   where exception_id = (select v from wfr_ids where k = 'x_contested') and kind = 'MANAGER_CONTESTED'),
  'CORRECTED', 'approving the correction resolves the manager contest'
);
select ok(
  (select count(*) from workforce.audit_log a
   where a.entity_id in ((select v from wfr_ids where k = 'x_contested'), (select v from wfr_ids where k = 'c1'))
      or (a.entity_type = 'work_exception_acknowledgement' and a.after_state ->> 'exception_id' = (select v from wfr_ids where k = 'x_contested')::text)) >= 3,
  'the whole original → contest → correction → review trail is audited'
);
select throws_ok(
  format($$update workforce.work_exception_corrections set proposed_end = proposed_end + interval '1 hour' where id = '%s'$$, (select v from wfr_ids where k = 'c1')),
  'P0001', 'WORKFORCE_IMMUTABLE:work_exception_corrections', 'an approved correction is immutable'
);

-- Reject and withdraw.
select pg_temp.emp(jsonb_build_object('action', 'REQUEST_CORRECTION', 'exception_id', (select v from wfr_ids where k = 'x_extra'),
  'proposed_start_local', '2026-09-22T18:00', 'proposed_end_local', '2026-09-22T21:00', 'reason', 'Fiquei até 21h'));
select throws_ok(
  format($$select pg_temp.own(jsonb_build_object('action','REVIEW_CORRECTION','correction_id',
    (select id from workforce.work_exception_corrections where exception_id = '%s' and status = 'PENDING'),'decision','REJECT'))$$,
    (select v from wfr_ids where k = 'x_extra')),
  'P0001', 'WORKFORCE_REASON_REQUIRED', 'rejecting a correction requires a reason'
);
select is(
  pg_temp.own(jsonb_build_object('action', 'REVIEW_CORRECTION', 'decision', 'REJECT', 'reason', 'Câmera mostra saída 20h',
    'correction_id', (select id from workforce.work_exception_corrections where exception_id = (select v from wfr_ids where k = 'x_extra') and status = 'PENDING')))
    -> 'exception' ->> 'status',
  'VALIDATED', 'rejection restores the previous status'
);
select is(
  (select sum(duration_seconds) / 60 from workforce.work_exception_segments
   where exception_id = (select v from wfr_ids where k = 'x_extra') and segment_kind <> 'REGULAR_OVERLAP')::int,
  45, 'a rejected correction does not change the calculation (45 min extra)'
);
select pg_temp.emp(jsonb_build_object('action', 'REQUEST_CORRECTION', 'exception_id', (select v from wfr_ids where k = 'x_withdraw'),
  'proposed_start_local', '2026-09-24T07:30', 'proposed_end_local', '2026-09-24T09:00', 'reason', 'Cheguei 7h30'));
select is(
  pg_temp.emp(jsonb_build_object('action', 'WITHDRAW_CORRECTION',
    'correction_id', (select id from workforce.work_exception_corrections where exception_id = (select v from wfr_ids where k = 'x_withdraw') and status = 'PENDING')))
    -> 'exception' ->> 'status',
  'PENDING_REVIEW', 'employee withdraws her correction request; status is restored'
);

-- Employee withdraws her own record (WITHDRAWN_BY_EMPLOYEE, never deleted).
select is(
  pg_temp.emp(jsonb_build_object('action', 'WITHDRAW_EXCEPTION', 'exception_id', (select v from wfr_ids where k = 'x_withdraw'))) -> 'exception' ->> 'status',
  'WITHDRAWN_BY_EMPLOYEE', 'employee withdraws her own record'
);
select is(
  (select count(*) from workforce.work_exception_segments where exception_id = (select v from wfr_ids where k = 'x_withdraw')),
  0::bigint, 'a withdrawn record no longer counts'
);
select ok(exists (select 1 from workforce.work_exceptions where id = (select v from wfr_ids where k = 'x_withdraw')),
  'the withdrawn record still exists for audit');
select throws_ok(
  format($$select pg_temp.emp('{"action":"WITHDRAW_EXCEPTION","exception_id":"%s"}')$$, (select v from wfr_ids where k = 'x_owner')),
  'P0001', 'WORKFORCE_EXCEPTION_NOT_OWNED', 'employee cannot withdraw an owner occurrence'
);

-- ---------------------------------------------------------------------------
-- 4. Versioned classification (append-only).
-- ---------------------------------------------------------------------------
select is(pg_temp.own(jsonb_build_object('action', 'CLASSIFY', 'exception_id', (select v from wfr_ids where k = 'x_owner'),
  'classification', 'INFORMATIONAL')) -> 'exception' ->> 'classification', 'INFORMATIONAL', 'owner classifies an occurrence');
select is(pg_temp.own(jsonb_build_object('action', 'CLASSIFY', 'exception_id', (select v from wfr_ids where k = 'x_owner'),
  'classification', 'EXCUSED', 'reason', 'Combinado previamente')) -> 'exception' ->> 'classification', 'EXCUSED', 'reclassification takes effect');
select is(
  (select string_agg(classification || ':' || (superseded_at is null)::text, ',' order by effective_at, superseded_at nulls last)
   from workforce.work_exception_classifications where exception_id = (select v from wfr_ids where k = 'x_owner')),
  'INFORMATIONAL:false,EXCUSED:true', 'the previous classification is superseded, not overwritten'
);
select throws_ok(
  format($$select pg_temp.own('{"action":"CLASSIFY","exception_id":"%s","classification":"EXTRA_HOLIDAY"}')$$, (select v from wfr_ids where k = 'x_owner')),
  'P0001', 'WORKFORCE_FIELD_INVALID:classification', 'operational classifications cannot be forced administratively'
);
select throws_ok(
  format($$select public.service_workforce_employee_review_exception('17300000-0000-4000-8000-000000000013', gen_random_uuid(),
    '{"action":"ACKNOWLEDGE","exception_id":"%s","classification":"EXCUSED"}')$$, (select v from wfr_ids where k = 'x_owner')),
  'P0001', 'WORKFORCE_PAYLOAD_FIELD_FORBIDDEN:classification', 'employee cannot classify'
);

-- ---------------------------------------------------------------------------
-- 5. Forgotten OPEN period closed through an approved correction.
-- ---------------------------------------------------------------------------
insert into wfr_ids
select 'x_open', (r -> 'exception' ->> 'exception_id')::uuid
from public.service_workforce_employee_start_extra('17300000-0000-4000-8000-000000000014', gen_random_uuid(), '{}') r;
alter table workforce.work_exceptions disable trigger work_exceptions_guard;
update workforce.work_exceptions set reported_start = '2026-09-25 19:15:00-03', event_date = '2026-09-25'
where id = (select v from wfr_ids where k = 'x_open');
alter table workforce.work_exceptions enable trigger work_exceptions_guard;
select throws_ok(
  $$select public.service_workforce_employee_finish_extra('17300000-0000-4000-8000-000000000014', gen_random_uuid(), '{}')$$,
  'P0001', 'WORKFORCE_EXTRA_OPEN_TOO_LONG', 'a period left open for days cannot be closed with the server clock'
);
select public.service_workforce_employee_review_exception('17300000-0000-4000-8000-000000000014', gen_random_uuid(),
  jsonb_build_object('action', 'REQUEST_CORRECTION', 'exception_id', (select v from wfr_ids where k = 'x_open'),
    'proposed_start_local', '2026-09-25T19:15', 'proposed_end_local', '2026-09-25T20:15', 'reason', 'Esqueci de finalizar'));
select is(
  pg_temp.own(jsonb_build_object('action', 'REVIEW_CORRECTION', 'decision', 'APPROVE',
    'correction_id', (select id from workforce.work_exception_corrections where exception_id = (select v from wfr_ids where k = 'x_open'))))
    -> 'exception' ->> 'status',
  'VALIDATED', 'approving the correction closes the forgotten OPEN period'
);
select ok(exists (
  select 1 from workforce.work_exceptions x
  where x.id = (select v from wfr_ids where k = 'x_open')
    and x.reported_end = '2026-09-25 20:15:00-03' and x.reported_end_source = 'CORRECTION_APPROVED'
), 'the closing end carries its provenance (CORRECTION_APPROVED)');

select * from finish();
rollback;
