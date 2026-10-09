begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(44);

insert into auth.users(id, instance_id, aud, role, email, encrypted_password, created_at, updated_at)
values
  ('17500000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'wfp-owner-a@example.test', '', now(), now()),
  ('17500000-0000-4000-8000-000000000002', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'wfp-owner-b@example.test', '', now(), now()),
  ('17500000-0000-4000-8000-000000000003', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'wfp-e1@example.test', '', now(), now());
insert into public.admin_users(id, auth_user_id, display_name, role, is_active)
values
  ('17500000-0000-4000-8000-000000000011', '17500000-0000-4000-8000-000000000001', 'Owner A', 'OWNER', true),
  ('17500000-0000-4000-8000-000000000012', '17500000-0000-4000-8000-000000000002', 'Owner B', 'OWNER', true),
  ('17500000-0000-4000-8000-000000000013', '17500000-0000-4000-8000-000000000003', 'E1', 'OPERATION', true);
insert into public.tenants(id, name, slug) values
  ('17500000-0000-4000-8000-000000000021', 'WFP Tenant A', 'wfp-tenant-a'),
  ('17500000-0000-4000-8000-000000000022', 'WFP Tenant B', 'wfp-tenant-b');
insert into public.tenant_members(tenant_id, user_id, role) values
  ('17500000-0000-4000-8000-000000000021', '17500000-0000-4000-8000-000000000001', 'OWNER'),
  ('17500000-0000-4000-8000-000000000022', '17500000-0000-4000-8000-000000000002', 'OWNER');

create temp table wfp_ids(k text primary key, v uuid not null) on commit drop;
insert into wfp_ids
select 'employer', (r -> 'employer' ->> 'employer_id')::uuid
from public.service_workforce_owner_save_employer('17500000-0000-4000-8000-000000000011', gen_random_uuid(),
  '{"legal_name":"Pierri Quint Produções","trade_name":"BlackSheep Estúdio Criativo","workplace_city":"Palhoça","workplace_state":"SC"}') r;
insert into wfp_ids
select 'e1', (r -> 'employee' ->> 'employee_id')::uuid
from public.service_workforce_owner_save_employee('17500000-0000-4000-8000-000000000011', gen_random_uuid(),
  jsonb_build_object('employer_id', (select v from wfp_ids where k = 'employer'), 'admin_user_id', '17500000-0000-4000-8000-000000000013',
    'display_name', 'Jheneffe Teste')) r;
select public.service_workforce_owner_create_schedule_version('17500000-0000-4000-8000-000000000011', gen_random_uuid(),
  jsonb_build_object('employee_id', (select v from wfp_ids where k = 'e1'), 'effective_from', '2026-01-01',
    'days', '[{"iso_weekday":1,"start_time":"13:15","end_time":"19:15"},{"iso_weekday":2,"start_time":"13:15","end_time":"19:15"},
              {"iso_weekday":3,"start_time":"13:15","end_time":"19:15"},{"iso_weekday":4,"start_time":"13:15","end_time":"19:15"},
              {"iso_weekday":5,"start_time":"13:15","end_time":"19:15"}]'::jsonb));

create function pg_temp.period(p_action text, p_month text default '2026-09', p_reason text default null) returns jsonb language sql as $$
  select public.service_workforce_owner_manage_period('17500000-0000-4000-8000-000000000011', gen_random_uuid(),
    jsonb_strip_nulls(jsonb_build_object('action', p_action, 'employee_id', (select v from wfp_ids where k = 'e1'),
      'month', p_month, 'reason', p_reason))) -> 'period';
$$;
create function pg_temp.blockers() returns text language sql as $$
  select coalesce(string_agg(distinct b ->> 'blocker', ',' order by b ->> 'blocker'), '')
  from jsonb_array_elements(pg_temp.period('EVALUATE') -> 'blockers') b;
$$;
create function pg_temp.own(p_payload jsonb) returns jsonb language sql as $$
  select public.service_workforce_owner_review_exception('17500000-0000-4000-8000-000000000011', gen_random_uuid(), p_payload);
$$;
create function pg_temp.emp(p_payload jsonb) returns jsonb language sql as $$
  select public.service_workforce_employee_review_exception('17500000-0000-4000-8000-000000000013', gen_random_uuid(), p_payload);
$$;
create function pg_temp.ack_alerts() returns void language plpgsql as $$
declare v_alert uuid;
begin
  for v_alert in select a.id from workforce.compliance_alerts a where a.employee_id = (select i.v from wfp_ids i where i.k = 'e1') and a.status = 'OPEN' loop
    perform public.service_workforce_owner_manage_compliance('17500000-0000-4000-8000-000000000011', gen_random_uuid(),
      jsonb_build_object('action', 'ACKNOWLEDGE', 'alert_id', v_alert));
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 1. Competência and blockers.
-- ---------------------------------------------------------------------------
select is(pg_temp.period('EVALUATE') ->> 'period_start', '2026-09-01', 'competência starts on the first day of the civil month');
select is(pg_temp.period('EVALUATE') ->> 'period_end', '2026-09-30', 'competência ends on the last day of the civil month');
select is(pg_temp.blockers(), 'EMPLOYER_CNPJ_MISSING', 'the accountant report requires the real CNPJ (critical inconsistency)');
select public.service_workforce_owner_save_employer('17500000-0000-4000-8000-000000000011', gen_random_uuid(),
  jsonb_build_object('employer_id', (select v from wfp_ids where k = 'employer'), 'cnpj', '11.222.333/0001-81'));
select is(pg_temp.period('EVALUATE') ->> 'status', 'READY_TO_CLOSE', 'a month without exceptions is ready (exception premise)');

-- Records for September.
insert into wfp_ids
select 'x_tue', (r -> 'exception' ->> 'exception_id')::uuid
from public.service_workforce_employee_record_exception('17500000-0000-4000-8000-000000000013', gen_random_uuid(),
  '{"exception_type":"EXTRA_WORK","start_local":"2026-09-22T18:00","end_local":"2026-09-22T20:00","note":"NOTA-SECRETA-FUNCIONARIA"}') r;
insert into wfp_ids
select 'x_sat', (r -> 'exception' ->> 'exception_id')::uuid
from public.service_workforce_employee_record_exception('17500000-0000-4000-8000-000000000013', gen_random_uuid(),
  '{"exception_type":"EXTRA_WORK","start_local":"2026-09-26T09:00","end_local":"2026-09-26T13:00"}') r;
insert into wfp_ids
select 'x_early', (r -> 'exception' ->> 'exception_id')::uuid
from public.service_workforce_owner_record_exception('17500000-0000-4000-8000-000000000011', gen_random_uuid(),
  jsonb_build_object('employee_id', (select v from wfp_ids where k = 'e1'), 'exception_type', 'EARLY_LEAVE',
    'start_local', '2026-09-29T17:30', 'end_local', '2026-09-29T19:15', 'note', 'NOTA-INTERNA-OWNER buscar filho')) r;

select ok(position('PENDING_REVIEW' in pg_temp.blockers()) > 0, 'unreviewed retroactive records (divergence) block the closure');
select ok(position('COMPLIANCE_ALERT_OPEN' in pg_temp.blockers()) > 0, 'an unacknowledged compliance alert blocks the closure');
select is(pg_temp.period('EVALUATE') ->> 'status', 'BLOCKED', 'pending items make the period BLOCKED');
select throws_ok($$select pg_temp.period('CLOSE')$$, 'P0001', 'WORKFORCE_PERIOD_NOT_READY:blocked', 'a BLOCKED period cannot be closed');

-- OPEN extra period from September blocks.
insert into wfp_ids
select 'x_open', (r -> 'exception' ->> 'exception_id')::uuid
from public.service_workforce_employee_start_extra('17500000-0000-4000-8000-000000000013', gen_random_uuid(), '{}') r;
alter table workforce.work_exceptions disable trigger work_exceptions_guard;
update workforce.work_exceptions set reported_start = '2026-09-30 21:00:00-03', event_date = '2026-09-30'
where id = (select v from wfp_ids where k = 'x_open');
alter table workforce.work_exceptions enable trigger work_exceptions_guard;
select ok(position('OPEN_EXTRA' in pg_temp.blockers()) > 0, 'an OPEN extra period blocks the closure');

-- Resolve: validate, contest and accept, correct, acknowledge alerts.
select pg_temp.own(jsonb_build_object('action', 'VALIDATE', 'exception_id', (select v from wfp_ids where k = 'x_tue')));
select pg_temp.own(jsonb_build_object('action', 'CONTEST', 'exception_id', (select v from wfp_ids where k = 'x_sat'), 'reason', 'Confirmar convocação'));
select ok(position('MANAGER_CONTESTED' in pg_temp.blockers()) > 0, 'an open contest blocks the closure');
select pg_temp.own(jsonb_build_object('action', 'RESOLVE_CONTEST', 'decision', 'ACCEPTED', 'reason', 'Convocação confirmada',
  'acknowledgement_id', (select id from workforce.work_exception_acknowledgements where exception_id = (select v from wfp_ids where k = 'x_sat') and status = 'OPEN')));
select pg_temp.emp(jsonb_build_object('action', 'REQUEST_CORRECTION', 'exception_id', (select v from wfp_ids where k = 'x_open'),
  'proposed_start_local', '2026-09-30T21:00', 'proposed_end_local', '2026-09-30T21:45', 'reason', 'Esqueci de finalizar'));
select ok(position('CORRECTION_PENDING' in pg_temp.blockers()) > 0, 'a pending correction blocks the closure');
select pg_temp.own(jsonb_build_object('action', 'REVIEW_CORRECTION', 'decision', 'APPROVE',
  'correction_id', (select id from workforce.work_exception_corrections where exception_id = (select v from wfp_ids where k = 'x_open'))));
select pg_temp.own(jsonb_build_object('action', 'CLASSIFY', 'exception_id', (select v from wfp_ids where k = 'x_early'), 'classification', 'INFORMATIONAL'));
select pg_temp.period('EVALUATE');
select pg_temp.ack_alerts();
select is(pg_temp.blockers(), '', 'all pending items resolved');
select is(pg_temp.period('EVALUATE') ->> 'status', 'READY_TO_CLOSE', 'period is READY_TO_CLOSE');

-- ---------------------------------------------------------------------------
-- 2. Closure v1: immutable snapshot and safe report.
-- ---------------------------------------------------------------------------
select is(pg_temp.period('CLOSE') ->> 'status', 'CLOSED', 'owner closes the competência');
insert into wfp_ids
select 'c1', c.id from workforce.work_period_closures c join workforce.work_periods wp on wp.id = c.period_id
where wp.employee_id = (select v from wfp_ids where k = 'e1') and c.version = 1;
select is((select version from workforce.work_period_closures where id = (select v from wfp_ids where k = 'c1')), 1, 'first closure is version 1');
select is((select count(*) from workforce.work_period_reports where closure_id = (select v from wfp_ids where k = 'c1')), 2::bigint,
  'accountant and employee mirrors are generated from the snapshot');
select is(
  (select report_payload -> 'employer' ->> 'legal_name' from workforce.work_period_closures where id = (select v from wfp_ids where k = 'c1')),
  'Pierri Quint Produções', 'report uses the razão social, not only the brand');
select is(
  (select report_payload -> 'employer' ->> 'cnpj' from workforce.work_period_closures where id = (select v from wfp_ids where k = 'c1')),
  '11222333000181', 'report carries the CNPJ');
select is(
  (select report_payload -> 'totals' from workforce.work_period_closures where id = (select v from wfp_ids where k = 'c1')),
  '{"extra_weekday_minutes":90,"extra_sunday_minutes":0,"extra_holiday_minutes":0,"extra_saturday_minutes":240}'::jsonb,
  'totals: weekday 45 + 45 (approved correction) = 90, Saturday 240; no monetary value'
);
select ok(
  not exists (
    select 1 from workforce.work_period_closures c
    where c.id = (select v from wfp_ids where k = 'c1')
      and (c.snapshot::text ~* '(NOTA-SECRETA|NOTA-INTERNA|buscar filho|Esqueci|Confirmar convoca|Convocação confirmada|employee_note|manager_note|reason)')
  )
  and not exists (
    select 1 from workforce.work_period_reports r
    where r.closure_id = (select v from wfp_ids where k = 'c1')
      and r.payload::text ~* '(NOTA-SECRETA|NOTA-INTERNA|buscar filho|Esqueci|convoca|reason|note)'
  ),
  'snapshot and reports carry no notes, reasons or internal text'
);
select ok(
  (select report_payload -> 'rows' from workforce.work_period_closures where id = (select v from wfp_ids where k = 'c1'))
    @> '[{"date":"2026-09-22","weekday":"terça-feira","period":"18:00–20:00","classification":"EXTRA_WEEKDAY","minutes":45,"status":"VALIDATED"}]',
  'row shows date, weekday, period, classification, calculated duration and status'
);
select is(
  (select snapshot_sha256 from workforce.work_period_closures where id = (select v from wfp_ids where k = 'c1')),
  (select encode(sha256(convert_to(snapshot::text, 'UTF8')), 'hex') from workforce.work_period_closures where id = (select v from wfp_ids where k = 'c1')),
  'snapshot hash matches its content'
);
select throws_ok(
  format($$update workforce.work_period_closures set report_payload = '{}' where id = '%s'$$, (select v from wfp_ids where k = 'c1')),
  'P0001', 'WORKFORCE_IMMUTABLE:work_period_closures', 'snapshot is immutable'
);
select throws_ok(
  format($$delete from workforce.work_period_reports where closure_id = '%s'$$, (select v from wfp_ids where k = 'c1')),
  'P0001', 'WORKFORCE_IMMUTABLE:work_period_reports', 'reports are immutable'
);
select throws_ok(
  $$select public.service_workforce_employee_record_exception('17500000-0000-4000-8000-000000000013', gen_random_uuid(),
    '{"exception_type":"EXTRA_WORK","start_local":"2026-09-30T19:15","end_local":"2026-09-30T20:10"}')$$,
  'P0001', 'WORKFORCE_PERIOD_CLOSED', 'a closed competência accepts no new record'
);
select throws_ok(
  format($$select pg_temp.own(jsonb_build_object('action','CLASSIFY','exception_id','%s','classification','EXCUSED'))$$, (select v from wfp_ids where k = 'x_early')),
  'P0001', 'WORKFORCE_PERIOD_CLOSED', 'a closed competência accepts no reclassification'
);
select throws_ok($$select pg_temp.period('CLOSE')$$, 'P0001', 'WORKFORCE_PERIOD_ALREADY_CLOSED', 'closing twice is rejected');

-- ---------------------------------------------------------------------------
-- 3. Reopen (reason required) and version 2 with diff.
-- ---------------------------------------------------------------------------
select throws_ok($$select pg_temp.period('REOPEN')$$, 'P0001', 'WORKFORCE_REASON_REQUIRED', 'reopening requires a reason');
select is(pg_temp.period('REOPEN', '2026-09', 'Funcionária informou trabalho em 30/09') ->> 'status', 'READY_TO_CLOSE',
  'reopened period is re-evaluated immediately');
select is((pg_temp.period('EVALUATE') ->> 'is_reopened')::boolean, true, 'the period is flagged as reopened until re-closed');
select ok(
  (select reopened_at is not null and reopen_reason = 'Funcionária informou trabalho em 30/09'
   from workforce.work_period_closures where id = (select v from wfp_ids where k = 'c1')),
  'the reopened version keeps its snapshot and records the reopening'
);
select public.service_workforce_owner_record_exception('17500000-0000-4000-8000-000000000011', gen_random_uuid(),
  jsonb_build_object('employee_id', (select v from wfp_ids where k = 'e1'), 'exception_type', 'EXTRA_WORK',
    'start_local', '2026-09-30T19:15', 'end_local', '2026-09-30T20:10'));
select pg_temp.own(jsonb_build_object('action', 'CLASSIFY', 'exception_id', (select v from wfp_ids where k = 'x_early'),
  'classification', 'EXCUSED', 'reason', 'Combinado'));
select pg_temp.period('EVALUATE');
select pg_temp.ack_alerts();
select is(pg_temp.period('CLOSE') ->> 'current_version', '2', 'reclosing creates version 2');
insert into wfp_ids
select 'c2', c.id from workforce.work_period_closures c join workforce.work_periods wp on wp.id = c.period_id
where wp.employee_id = (select v from wfp_ids where k = 'e1') and c.version = 2;
select is(
  (select jsonb_array_length(diff_from_previous -> 'added') from workforce.work_period_closures where id = (select v from wfp_ids where k = 'c2')),
  1, 'diff: one row added'
);
select ok(
  (select diff_from_previous -> 'added' from workforce.work_period_closures where id = (select v from wfp_ids where k = 'c2'))
    @> '[{"date":"2026-09-30","period":"19:15–20:10","minutes":55,"classification":"EXTRA_WEEKDAY"}]',
  'diff: added 30/09 19:15–20:10 +55 min'
);
select ok(
  (select diff_from_previous -> 'changed' from workforce.work_period_closures where id = (select v from wfp_ids where k = 'c2'))
    @> '[{"date":"2026-09-29","fields":{"administrative_classification":{"from":"INFORMATIONAL","to":"EXCUSED"}}}]',
  'diff: changed 29/09 INFORMATIONAL → EXCUSED'
);
select is(
  (select jsonb_array_length(diff_from_previous -> 'removed') from workforce.work_period_closures where id = (select v from wfp_ids where k = 'c2')),
  0, 'diff: nothing removed'
);
select is(
  (select (diff_from_previous -> 'totals' -> 'to' ->> 'extra_weekday_minutes')::int from workforce.work_period_closures where id = (select v from wfp_ids where k = 'c2')),
  145, 'diff totals: weekday 90 → 145'
);
select is((select count(*) from workforce.work_period_closures c join workforce.work_periods wp on wp.id = c.period_id
  where wp.employee_id = (select v from wfp_ids where k = 'e1')), 2::bigint, 'version 1 is preserved, not overwritten');

-- ---------------------------------------------------------------------------
-- 4. Employee mirror, month in progress and isolation.
-- ---------------------------------------------------------------------------
select is((public.service_workforce_employee_get_mirror('17500000-0000-4000-8000-000000000013', '2026-09') -> 'mirror' ->> 'version')::int,
  2, 'employee sees the latest closed mirror');
select ok(
  not (public.service_workforce_employee_get_mirror('17500000-0000-4000-8000-000000000013', '2026-09')::text ~* '(reopen_reason|NOTA-INTERNA)'),
  'employee mirror exposes no owner-internal data'
);
select is(
  public.service_workforce_employee_acknowledge_mirror('17500000-0000-4000-8000-000000000013', gen_random_uuid(),
    jsonb_build_object('closure_id', (select v from wfp_ids where k = 'c2'))) ->> 'acknowledged',
  'true', 'employee acknowledges the monthly mirror'
);
select throws_ok($$select pg_temp.period('CLOSE', '2026-10')$$, 'P0001', 'WORKFORCE_PERIOD_NOT_READY:open', 'a month in progress cannot be closed');
select throws_ok(
  format($$select public.service_workforce_owner_manage_period('17500000-0000-4000-8000-000000000012', gen_random_uuid(),
    '{"action":"REOPEN","employee_id":"%s","month":"2026-09","reason":"cross tenant"}')$$, (select v from wfp_ids where k = 'e1')),
  'P0001', 'WORKFORCE_EMPLOYEE_NOT_FOUND', 'tenant B owner cannot reopen tenant A competência'
);
select throws_ok(
  format($$select public.service_workforce_owner_manage_period('17500000-0000-4000-8000-000000000013', gen_random_uuid(),
    '{"action":"CLOSE","employee_id":"%s","month":"2026-09"}')$$, (select v from wfp_ids where k = 'e1')),
  'P0001', 'WORKFORCE_OWNER_REQUIRED', 'employee cannot close or reopen'
);

select * from finish();
rollback;
