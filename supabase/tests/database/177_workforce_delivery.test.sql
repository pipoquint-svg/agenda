begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(42);

insert into auth.users(id, instance_id, aud, role, email, encrypted_password, created_at, updated_at)
values
  ('17700000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'wfd-owner@example.test', '', now(), now()),
  ('17700000-0000-4000-8000-000000000003', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'wfd-employee@example.test', '', now(), now());
insert into public.admin_users(id, auth_user_id, display_name, role, is_active)
values
  ('17700000-0000-4000-8000-000000000011', '17700000-0000-4000-8000-000000000001', 'Owner', 'OWNER', true),
  ('17700000-0000-4000-8000-000000000013', '17700000-0000-4000-8000-000000000003', 'Employee', 'OPERATION', true);
insert into public.tenants(id, name, slug) values ('17700000-0000-4000-8000-000000000021', 'WFD Tenant', 'wfd-tenant');
insert into public.tenant_members(tenant_id, user_id, role) values
  ('17700000-0000-4000-8000-000000000021', '17700000-0000-4000-8000-000000000001', 'OWNER');

create temp table wfd_ids(k text primary key, v uuid not null) on commit drop;
insert into wfd_ids
select 'employer', (r -> 'employer' ->> 'employer_id')::uuid
from public.service_workforce_owner_save_employer('17700000-0000-4000-8000-000000000011', gen_random_uuid(),
  '{"legal_name":"Pierri Quint Produções","trade_name":"BlackSheep Estúdio Criativo","workplace_city":"Palhoça","workplace_state":"SC"}') r;
insert into wfd_ids
select 'e1', (r -> 'employee' ->> 'employee_id')::uuid
from public.service_workforce_owner_save_employee('17700000-0000-4000-8000-000000000011', gen_random_uuid(),
  jsonb_build_object('employer_id', (select v from wfd_ids where k = 'employer'), 'admin_user_id', '17700000-0000-4000-8000-000000000013',
    'display_name', 'Jheneffe Teste', 'hired_on', '2026-09-01')) r;
select public.service_workforce_owner_create_schedule_version('17700000-0000-4000-8000-000000000011', gen_random_uuid(),
  jsonb_build_object('employee_id', (select v from wfd_ids where k = 'e1'), 'effective_from', '2026-01-01',
    'days', '[{"iso_weekday":1,"start_time":"13:15","end_time":"19:15"},{"iso_weekday":2,"start_time":"13:15","end_time":"19:15"},
              {"iso_weekday":3,"start_time":"13:15","end_time":"19:15"},{"iso_weekday":4,"start_time":"13:15","end_time":"19:15"},
              {"iso_weekday":5,"start_time":"13:15","end_time":"19:15"}]'::jsonb));

create function pg_temp.delivery(p_payload jsonb) returns jsonb language sql as $$
  select public.service_workforce_owner_manage_delivery('17700000-0000-4000-8000-000000000011', gen_random_uuid(), p_payload);
$$;
create function pg_temp.cycle(p_at text) returns jsonb language sql as $$
  select workforce.run_cycle(p_at::timestamptz);
$$;
-- Claim/retry phases run on the real clock (deliveries are queued at now()).
create function pg_temp.cycle_now(p_offset interval default '0'::interval) returns jsonb language sql as $$
  select workforce.run_cycle(now() + p_offset);
$$;
create function pg_temp.period_status(p_month date) returns text language sql as $$
  select wp.status from workforce.work_periods wp where wp.employee_id = (select v from wfd_ids where k = 'e1') and wp.period_start = p_month;
$$;
create function pg_temp.result(p_id uuid, p_ok boolean, p_error text default null) returns jsonb language sql as $$
  select workforce.record_send_result('DELIVERY', p_id, p_ok, case when p_ok then 're_123' end, p_error, now());
$$;

-- ---------------------------------------------------------------------------
-- 1. Business calendar: 16:00 of the 2nd business day of the next month.
-- ---------------------------------------------------------------------------
select is(workforce.nth_business_day((select v from wfd_ids where k = 'employer'), '2026-11-01', 2), '2026-11-04'::date,
  'Nov 2026: 2nd business day is Wed 04 (02 is Finados, a Monday)');
select is(workforce.nth_business_day((select v from wfd_ids where k = 'employer'), '2027-01-01', 2), '2027-01-05'::date,
  'Jan 2027: holiday on Friday 01 and weekend are skipped');
select is(workforce.nth_business_day((select v from wfd_ids where k = 'employer'), '2026-10-01', 2), '2026-10-02'::date,
  'Oct 2026: Thu 01, Fri 02');
select public.service_workforce_owner_manage_holiday('17700000-0000-4000-8000-000000000011', gen_random_uuid(),
  jsonb_build_object('action', 'ADD', 'employer_id', (select v from wfd_ids where k = 'employer'), 'scope', 'MUNICIPAL',
    'name', 'Feriado municipal teste', 'rule_kind', 'DATE', 'holiday_date', '2026-10-02'));
select is(workforce.nth_business_day((select v from wfd_ids where k = 'employer'), '2026-10-01', 2), '2026-10-05'::date,
  'a municipal holiday of the establishment moves the 2nd business day');
select is(workforce.report_due_at((select v from wfd_ids where k = 'employer'), '2026-10-01'), '2026-11-04 16:00:00-03'::timestamptz,
  'competência outubro/2026 is due at 16:00 (America/Sao_Paulo) of 04/11/2026');

-- ---------------------------------------------------------------------------
-- 2. Automatic delivery is opt-in per employer and requires accountant + CNPJ.
-- ---------------------------------------------------------------------------
select throws_ok(
  format($$select pg_temp.delivery('{"action":"SET_AUTO_SEND","employer_id":"%s","enabled":true}')$$, (select v from wfd_ids where k = 'employer')),
  'P0001', 'WORKFORCE_AUTO_SEND_REQUIRES_ACCOUNTANT_AND_CNPJ', 'automatic delivery needs a configured accountant and CNPJ'
);
select public.service_workforce_owner_save_employer('17700000-0000-4000-8000-000000000011', gen_random_uuid(),
  jsonb_build_object('employer_id', (select v from wfd_ids where k = 'employer'), 'cnpj', '11222333000181'));
select public.service_workforce_owner_save_payroll_settings('17700000-0000-4000-8000-000000000011', gen_random_uuid(),
  jsonb_build_object('employer_id', (select v from wfd_ids where k = 'employer'), 'accountant_name', 'Contadora',
    'accountant_email', 'contadora@example.test', 'accountant_email_secondary', 'backup@example.test'));
select is((pg_temp.delivery(jsonb_build_object('action', 'SET_AUTO_SEND', 'employer_id', (select v from wfd_ids where k = 'employer'), 'enabled', true))
  -> 'employer' -> 'payroll_settings' ->> 'auto_send_enabled')::boolean, true, 'owner enables automatic delivery');
select pg_temp.delivery(jsonb_build_object('action', 'SET_EMPLOYEE_RECEIPTS', 'employer_id', (select v from wfd_ids where k = 'employer'), 'enabled', true));

-- September records: one pending review (blocks), one fine.
insert into wfd_ids
select 'x_sep', (r -> 'exception' ->> 'exception_id')::uuid
from public.service_workforce_employee_record_exception('17700000-0000-4000-8000-000000000013', gen_random_uuid(),
  '{"exception_type":"EXTRA_WORK","start_local":"2026-09-22T19:15","end_local":"2026-09-22T20:00","note":"NOTA-SECRETA"}') r;

-- ---------------------------------------------------------------------------
-- 3. Due time: nothing before 16:00, blocked month is not sent.
-- ---------------------------------------------------------------------------
-- September is due at 16:00 of the 2nd business day of October = Mon 05/10 (02/10 is a municipal holiday here).
select is((pg_temp.cycle('2026-10-05 15:59:00-03') ->> 'closed_periods')::int, 0, '15:59 on the due day: nothing happens yet');
select ok(pg_temp.period_status('2026-09-01') is null, 'the competência is not even evaluated before the due instant');
select is((pg_temp.cycle('2026-10-05 16:00:00-03') ->> 'blocked_periods')::int, 1, '16:00: the pending review blocks the competência');
select is(pg_temp.period_status('2026-09-01'), 'BLOCKED', 'status = BLOCKED');
select is((select count(*) from workforce.work_report_deliveries), 0::bigint, 'a blocked competência sends nothing');

-- Resolution after the due time: next cycle closes and sends (no waiting for next month).
select public.service_workforce_owner_review_exception('17700000-0000-4000-8000-000000000011', gen_random_uuid(),
  jsonb_build_object('action', 'VALIDATE', 'exception_id', (select v from wfd_ids where k = 'x_sep')));
select ok(exists (
  select 1 from workforce.work_periods wp, jsonb_array_elements(wp.blockers) bl
  where wp.employee_id = (select v from wfd_ids where k = 'e1') and bl ->> 'blocker' = 'COMPLIANCE_ALERT_OPEN'
), 'the 6h45 day without interval also awaits the owner acknowledgement');
select public.service_workforce_owner_manage_compliance('17700000-0000-4000-8000-000000000011', gen_random_uuid(),
  jsonb_build_object('action', 'ACKNOWLEDGE', 'alert_id', a.id))
from workforce.compliance_alerts a where a.employee_id = (select v from wfd_ids where k = 'e1') and a.status = 'OPEN';
select is((pg_temp.cycle('2026-10-05 16:15:00-03') ->> 'closed_periods')::int, 1, 'next cycle after resolution closes automatically');
select is(pg_temp.period_status('2026-09-01'), 'CLOSED', 'competência CLOSED by SYSTEM');
select is((select closed_by_kind from workforce.work_period_closures c join workforce.work_periods wp on wp.id = c.period_id
  where wp.employee_id = (select v from wfd_ids where k = 'e1')), 'SYSTEM', 'the closure is attributed to SYSTEM');
select is(
  (select string_agg(recipient_kind || ':' || recipient_email, ',' order by recipient_kind) from workforce.work_report_deliveries),
  'ACCOUNTANT:contadora@example.test,ACCOUNTANT_SECONDARY:backup@example.test,EMPLOYEE:wfd-employee@example.test',
  'accountant (from configuration), secondary and employee mirror are queued'
);

-- ---------------------------------------------------------------------------
-- 4. Claiming: only once, payload is safe.
-- ---------------------------------------------------------------------------
create temp table wfd_claim as select pg_temp.cycle_now() as r;
select is(jsonb_array_length((select r -> 'deliveries' from wfd_claim)), 3, 'the three deliveries are claimed');
select is(jsonb_array_length(pg_temp.cycle_now(interval '1 minute') -> 'deliveries'), 0,
  'a claimed delivery is not claimed again while being sent (no duplicate send)');
select ok(
  (select bool_and((d -> 'report' -> 'employer' ->> 'legal_name') = 'Pierri Quint Produções'
                   and (d -> 'report' -> 'employer' ->> 'cnpj') = '11222333000181')
   from jsonb_array_elements((select r -> 'deliveries' from wfd_claim)) d),
  'report payload carries razão social and CNPJ'
);
select ok(not ((select r from wfd_claim)::text ~* '(NOTA-SECRETA|note|reason)'), 'claimed payload carries no notes or reasons');
select ok(
  (select bool_and(d ->> 'idempotency_key' like 'workforce-report:%:1:%') from jsonb_array_elements((select r -> 'deliveries' from wfd_claim)) d),
  'idempotency key = closure + version + recipient (+ kind)'
);
select throws_ok(
  $$insert into workforce.work_report_deliveries(tenant_id, closure_id, version, report_kind, recipient_kind, recipient_email)
    select tenant_id, closure_id, version, report_kind, recipient_kind, recipient_email from workforce.work_report_deliveries limit 1$$,
  '23505', null, 'the same report cannot be queued twice for the same recipient'
);

-- Accountant: success. Secondary: fails 3 times. Employee: success.
select pg_temp.result((select (d ->> 'delivery_id')::uuid from jsonb_array_elements((select r -> 'deliveries' from wfd_claim)) d where d ->> 'recipient_kind' = 'ACCOUNTANT'), true);
select pg_temp.result((select (d ->> 'delivery_id')::uuid from jsonb_array_elements((select r -> 'deliveries' from wfd_claim)) d where d ->> 'recipient_kind' = 'EMPLOYEE'), true);
select pg_temp.result((select (d ->> 'delivery_id')::uuid from jsonb_array_elements((select r -> 'deliveries' from wfd_claim)) d where d ->> 'recipient_kind' = 'ACCOUNTANT_SECONDARY'), false, 'EMAIL_PROVIDER_HTTP_500');
select is((select status from workforce.work_report_deliveries where recipient_kind = 'ACCOUNTANT'), 'SENT', 'accountant delivery SENT');
select throws_ok(
  format($$select pg_temp.result('%s', true)$$, (select id from workforce.work_report_deliveries where recipient_kind = 'ACCOUNTANT')),
  'P0001', 'WORKFORCE_SEND_NOT_CLAIMED', 'a SENT delivery cannot be recorded again'
);
select is((select status from workforce.work_report_deliveries where recipient_kind = 'ACCOUNTANT_SECONDARY'), 'FAILED', 'failed delivery is FAILED');
select is(pg_temp.period_status('2026-09-01'), 'CLOSED', 'a delivery failure never reopens the competência');
select is((select count(*) from workforce.work_period_closures c join workforce.work_periods wp on wp.id = c.period_id
  where wp.employee_id = (select v from wfd_ids where k = 'e1') and c.reopened_at is null), 1::bigint, 'the closure is untouched');

-- Retry: not before the backoff; then attempts 2 and 3; then stop.
select is(jsonb_array_length(pg_temp.cycle_now(interval '1 minute') -> 'deliveries'), 0, 'no retry before the backoff (15 min)');
update workforce.work_report_deliveries set next_attempt_at = now() - interval '1 minute' where recipient_kind = 'ACCOUNTANT_SECONDARY';
select is(
  (select (d ->> 'attempt')::int from jsonb_array_elements(pg_temp.cycle_now() -> 'deliveries') d),
  2, 'failed delivery is retried automatically (attempt 2)'
);
select pg_temp.result((select id from workforce.work_report_deliveries where recipient_kind = 'ACCOUNTANT_SECONDARY'), false, 'EMAIL_PROVIDER_TIMEOUT');
update workforce.work_report_deliveries set next_attempt_at = now() - interval '1 minute' where recipient_kind = 'ACCOUNTANT_SECONDARY';
select is(
  (select (d ->> 'attempt')::int from jsonb_array_elements(pg_temp.cycle_now() -> 'deliveries') d),
  3, 'third and last automatic attempt'
);
select pg_temp.result((select id from workforce.work_report_deliveries where recipient_kind = 'ACCOUNTANT_SECONDARY'), false, 'EMAIL_PROVIDER_TIMEOUT');
update workforce.work_report_deliveries set next_attempt_at = now() - interval '1 minute' where recipient_kind = 'ACCOUNTANT_SECONDARY';
select is(jsonb_array_length(pg_temp.cycle_now() -> 'deliveries'), 0, 'no automatic attempt after 3 failures');
select is((select attempts from workforce.work_report_deliveries where recipient_kind = 'ACCOUNTANT_SECONDARY'), 3, 'attempts capped at 3');
select is(
  pg_temp.delivery(jsonb_build_object('action', 'RETRY', 'delivery_id', (select id from workforce.work_report_deliveries where recipient_kind = 'ACCOUNTANT_SECONDARY'))) ->> 'status',
  'FAILED', 'owner can grant one manual retry after the automatic attempts'
);
select is(
  (select last_error_code from workforce.work_report_deliveries where recipient_kind = 'ACCOUNTANT_SECONDARY'),
  'EMAIL_PROVIDER_TIMEOUT', 'only a shaped error code is stored'
);

-- ---------------------------------------------------------------------------
-- 5. Reopened competências are re-closed by the owner, never automatically.
-- ---------------------------------------------------------------------------
select public.service_workforce_owner_manage_period('17700000-0000-4000-8000-000000000011', gen_random_uuid(),
  jsonb_build_object('action', 'REOPEN', 'employee_id', (select v from wfd_ids where k = 'e1'), 'month', '2026-09', 'reason', 'Ajuste informado'));
select is((pg_temp.cycle('2026-10-07 16:00:00-03') ->> 'closed_periods')::int, 0, 'the scheduler never re-closes a reopened competência');
select is(
  public.service_workforce_owner_manage_period('17700000-0000-4000-8000-000000000011', gen_random_uuid(),
    jsonb_build_object('action', 'CLOSE', 'employee_id', (select v from wfd_ids where k = 'e1'), 'month', '2026-09')) -> 'period' ->> 'current_version',
  '2', 'owner re-closes (version 2)'
);
select is((select count(*) from workforce.work_report_deliveries where version = 2), 3::bigint,
  'the rectified version 2 is delivered as a new report (new idempotency key)');

-- ---------------------------------------------------------------------------
-- 6. Employee receipts: concluded events only, no free text.
-- ---------------------------------------------------------------------------
select is((select count(*) from workforce.work_notifications where event_kind = 'RECORD_COMPLETED'), 1::bigint,
  'a concluded employee record produces one receipt');
select public.service_workforce_employee_start_extra('17700000-0000-4000-8000-000000000013', gen_random_uuid(), '{}');
select is((select count(*) from workforce.work_notifications where event_kind = 'RECORD_COMPLETED'), 1::bigint,
  'starting a live period (intermediate click) sends nothing');
select public.service_workforce_owner_record_exception('17700000-0000-4000-8000-000000000011', gen_random_uuid(),
  jsonb_build_object('employee_id', (select v from wfd_ids where k = 'e1'), 'exception_type', 'LATE_ARRIVAL',
    'start_local', '2026-10-06T13:15', 'end_local', '2026-10-06T13:40', 'note', 'NOTA-INTERNA'));
select is((select count(*) from workforce.work_notifications where event_kind = 'OWNER_OCCURRENCE'), 1::bigint,
  'an owner occurrence about her produces a receipt');
select ok(not exists (select 1 from workforce.work_notifications where payload::text ~* '(NOTA-SECRETA|NOTA-INTERNA|note)'),
  'receipt payloads carry no notes');

select * from finish();
rollback;
