begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(31);

-- Fixture: employee with Mon–Fri 13:15–19:15; default parameters 120/660/1440/60/15/120.
insert into auth.users(id, instance_id, aud, role, email, encrypted_password, created_at, updated_at)
values
  ('17400000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'wfa-owner-a@example.test', '', now(), now()),
  ('17400000-0000-4000-8000-000000000002', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'wfa-owner-b@example.test', '', now(), now()),
  ('17400000-0000-4000-8000-000000000003', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'wfa-e1@example.test', '', now(), now());
insert into public.admin_users(id, auth_user_id, display_name, role, is_active)
values
  ('17400000-0000-4000-8000-000000000011', '17400000-0000-4000-8000-000000000001', 'Owner A', 'OWNER', true),
  ('17400000-0000-4000-8000-000000000012', '17400000-0000-4000-8000-000000000002', 'Owner B', 'OWNER', true),
  ('17400000-0000-4000-8000-000000000013', '17400000-0000-4000-8000-000000000003', 'E1', 'OPERATION', true);
insert into public.tenants(id, name, slug) values
  ('17400000-0000-4000-8000-000000000021', 'WFA Tenant A', 'wfa-tenant-a'),
  ('17400000-0000-4000-8000-000000000022', 'WFA Tenant B', 'wfa-tenant-b');
insert into public.tenant_members(tenant_id, user_id, role) values
  ('17400000-0000-4000-8000-000000000021', '17400000-0000-4000-8000-000000000001', 'OWNER'),
  ('17400000-0000-4000-8000-000000000022', '17400000-0000-4000-8000-000000000002', 'OWNER');

create temp table wfa_ids(k text primary key, v uuid not null) on commit drop;
insert into wfa_ids
select 'employer', (r -> 'employer' ->> 'employer_id')::uuid
from public.service_workforce_owner_save_employer('17400000-0000-4000-8000-000000000011', gen_random_uuid(),
  '{"legal_name":"Empregadora WFA","workplace_city":"Palhoça","workplace_state":"SC"}') r;
insert into wfa_ids
select 'e1', (r -> 'employee' ->> 'employee_id')::uuid
from public.service_workforce_owner_save_employee('17400000-0000-4000-8000-000000000011', gen_random_uuid(),
  jsonb_build_object('employer_id', (select v from wfa_ids where k = 'employer'), 'admin_user_id', '17400000-0000-4000-8000-000000000013')) r;
select public.service_workforce_owner_create_schedule_version('17400000-0000-4000-8000-000000000011', gen_random_uuid(),
  jsonb_build_object('employee_id', (select v from wfa_ids where k = 'e1'), 'effective_from', '2026-01-01',
    'days', '[{"iso_weekday":1,"start_time":"13:15","end_time":"19:15"},{"iso_weekday":2,"start_time":"13:15","end_time":"19:15"},
              {"iso_weekday":3,"start_time":"13:15","end_time":"19:15"},{"iso_weekday":4,"start_time":"13:15","end_time":"19:15"},
              {"iso_weekday":5,"start_time":"13:15","end_time":"19:15"}]'::jsonb));

create function pg_temp.rec(p_start text, p_end text) returns uuid language sql as $$
  select (public.service_workforce_employee_record_exception('17400000-0000-4000-8000-000000000013', gen_random_uuid(),
    jsonb_build_object('exception_type', 'EXTRA_WORK', 'start_local', p_start, 'end_local', p_end)) -> 'exception' ->> 'exception_id')::uuid;
$$;
create function pg_temp.alert(p_type text, p_date date) returns workforce.compliance_alerts language sql as $$
  select a.* from workforce.compliance_alerts a
  where a.employee_id = (select v from wfa_ids where k = 'e1') and a.alert_type = p_type and a.reference_date = p_date;
$$;
create function pg_temp.evaluate(p_month text) returns int language sql as $$
  select (public.service_workforce_owner_manage_compliance('17400000-0000-4000-8000-000000000011', gen_random_uuid(),
    jsonb_build_object('action', 'EVALUATE', 'employee_id', (select v from wfa_ids where k = 'e1'), 'month', p_month)) ->> 'changes')::int;
$$;

insert into wfa_ids values ('x_tue', pg_temp.rec('2026-09-22T19:15', '2026-09-22T22:30'));
insert into wfa_ids values ('x_wed', pg_temp.rec('2026-09-23T06:00', '2026-09-23T08:00'));
insert into wfa_ids values ('x_sun27', pg_temp.rec('2026-09-27T09:00', '2026-09-27T14:00'));
insert into wfa_ids values ('x_sat3', pg_temp.rec('2026-10-03T09:00', '2026-10-03T13:00'));
insert into wfa_ids values ('x_sun4', pg_temp.rec('2026-10-04T09:00', '2026-10-04T14:00'));

-- ---------------------------------------------------------------------------
-- 1. Detection (recording an exception triggers evaluation).
-- ---------------------------------------------------------------------------
select is((pg_temp.alert('EXTRA_DAILY_LIMIT_REVIEW', '2026-09-22')).measured_minutes, 195,
  '>2h extra on a day raises EXTRA_DAILY_LIMIT_REVIEW (195 > 120)');
select is((pg_temp.alert('EXTRA_DAILY_LIMIT_REVIEW', '2026-09-22')).threshold_minutes, 120, 'threshold comes from parameters');
select is((pg_temp.alert('INTERJOURNEY_REST_REVIEW', '2026-09-23')).measured_minutes, 450,
  'reduced interjourney rest raises INTERJOURNEY_REST_REVIEW (22:30 → 06:00 = 450 < 660)');
select is((pg_temp.alert('INTRAJOURNEY_INTERVAL_REVIEW', '2026-09-22')).threshold_minutes, 60,
  '9h15 worked without interval raises INTRAJOURNEY_INTERVAL_REVIEW (requires 60 min)');
select is((pg_temp.alert('SPLIT_SHIFT_REVIEW', '2026-09-23')).measured_minutes, 315,
  'a 5h15 gap inside the journey raises SPLIT_SHIFT_REVIEW (review, not violation)');
select ok((pg_temp.alert('INTRAJOURNEY_INTERVAL_REVIEW', '2026-09-23')).id is null,
  'a day with a long enough gap does not raise an intrajourney alert');
select ok((pg_temp.alert('EXTRA_DAILY_LIMIT_REVIEW', '2026-09-23')).id is null, 'exactly 120 min extra is not above the limit');
select is((pg_temp.alert('WEEKLY_REST_REVIEW', '2026-09-28')).measured_minutes, 1395,
  'no 24h continuous rest in the week of 2026-09-28 raises WEEKLY_REST_REVIEW (1395 < 1440)');
select ok((pg_temp.alert('WEEKLY_REST_REVIEW', '2026-09-21')).id is null, 'the week of 2026-09-21 had a 24h rest');
select ok(not exists (
  select 1 from workforce.compliance_alerts a
  where a.employee_id = (select v from wfa_ids where k = 'e1') and a.reference_date in ('2026-09-24', '2026-09-25')
), 'habitual days without exception raise nothing (exception premise)');
select ok(not exists (
  select 1 from workforce.compliance_alerts a
  where a.employee_id = (select v from wfa_ids where k = 'e1') and a.alert_type not like '%\_REVIEW'
), 'every alert type is a REVIEW');

-- ---------------------------------------------------------------------------
-- 2. Idempotency.
-- ---------------------------------------------------------------------------
-- Weekend extra of 4–5h also exceeds the daily extra limit, and 5h without a
-- break needs the 15-min interval: 10 alerts in total, each once.
select is((select string_agg(alert_type || '@' || reference_date, ',' order by reference_date, alert_type)
  from workforce.compliance_alerts where employee_id = (select v from wfa_ids where k = 'e1')),
  'EXTRA_DAILY_LIMIT_REVIEW@2026-09-22,INTRAJOURNEY_INTERVAL_REVIEW@2026-09-22,INTERJOURNEY_REST_REVIEW@2026-09-23,SPLIT_SHIFT_REVIEW@2026-09-23,'
  || 'EXTRA_DAILY_LIMIT_REVIEW@2026-09-27,INTRAJOURNEY_INTERVAL_REVIEW@2026-09-27,WEEKLY_REST_REVIEW@2026-09-28,'
  || 'EXTRA_DAILY_LIMIT_REVIEW@2026-10-03,EXTRA_DAILY_LIMIT_REVIEW@2026-10-04,INTRAJOURNEY_INTERVAL_REVIEW@2026-10-04',
  'exactly the expected alerts are detected');
select is(pg_temp.evaluate('2026-09'), 0, 'refreshing September changes nothing');
select is(pg_temp.evaluate('2026-09'), 0, 'refreshing again changes nothing');
select is(pg_temp.evaluate('2026-10'), 0, 'refreshing October (overlapping week) changes nothing');
select is((select count(*) from workforce.compliance_alerts where employee_id = (select v from wfa_ids where k = 'e1')), 10::bigint,
  'refresh does not duplicate alerts');

-- ---------------------------------------------------------------------------
-- 3. Owner acknowledgement and closure blocking.
-- ---------------------------------------------------------------------------
select ok(position('COMPLIANCE_ALERT_OPEN' in (
  select string_agg(blocker, ',') from workforce.review_blockers((select v from wfa_ids where k = 'e1'), '2026-09-01', '2026-09-30'))) > 0,
  'an OPEN alert blocks the closure');
select is(
  public.service_workforce_owner_manage_compliance('17400000-0000-4000-8000-000000000011', gen_random_uuid(),
    jsonb_build_object('action', 'ACKNOWLEDGE', 'alert_id', (pg_temp.alert('INTERJOURNEY_REST_REVIEW', '2026-09-23')).id,
      'note', 'Evento de cliente combinado')) -> 'alert' ->> 'status',
  'ACKNOWLEDGED', 'owner acknowledges an alert'
);
select is(pg_temp.evaluate('2026-09'), 0, 'refresh keeps the acknowledgement when nothing changed');
select is((pg_temp.alert('INTERJOURNEY_REST_REVIEW', '2026-09-23')).status, 'ACKNOWLEDGED', 'acknowledged alert stays acknowledged');
select throws_ok(
  format($$select public.service_workforce_owner_manage_compliance('17400000-0000-4000-8000-000000000012', gen_random_uuid(),
    '{"action":"ACKNOWLEDGE","alert_id":"%s"}')$$, (pg_temp.alert('SPLIT_SHIFT_REVIEW', '2026-09-23')).id),
  'P0001', 'WORKFORCE_ALERT_NOT_FOUND', 'tenant B owner cannot acknowledge tenant A alerts'
);
select throws_ok(
  format($$select public.service_workforce_owner_list_compliance_alerts('17400000-0000-4000-8000-000000000013', '%s', '2026-09')$$,
    (select v from wfa_ids where k = 'e1')),
  'P0001', 'WORKFORCE_OWNER_REQUIRED', 'the employee cannot acknowledge or list compliance alerts'
);
select throws_ok(
  format($$delete from workforce.compliance_alerts where id = '%s'$$, (pg_temp.alert('SPLIT_SHIFT_REVIEW', '2026-09-23')).id),
  'P0001', 'WORKFORCE_IMMUTABLE:compliance_alerts', 'alerts cannot be deleted'
);

-- ---------------------------------------------------------------------------
-- 4. Data changes: resolution and reopening.
-- ---------------------------------------------------------------------------
select public.service_workforce_employee_review_exception('17400000-0000-4000-8000-000000000013', gen_random_uuid(),
  jsonb_build_object('action', 'WITHDRAW_EXCEPTION', 'exception_id', (select v from wfa_ids where k = 'x_tue')));
select is((pg_temp.alert('EXTRA_DAILY_LIMIT_REVIEW', '2026-09-22')).status, 'RESOLVED',
  'withdrawing the Tuesday extra resolves its daily-limit alert');
select is((pg_temp.alert('INTRAJOURNEY_INTERVAL_REVIEW', '2026-09-22')).status, 'RESOLVED',
  'and its intrajourney alert');
select is((pg_temp.alert('INTERJOURNEY_REST_REVIEW', '2026-09-23')).measured_minutes, 645,
  'interjourney rest is re-measured (19:15 → 06:00 = 645 < 660)');
select is((pg_temp.alert('INTERJOURNEY_REST_REVIEW', '2026-09-23')).status, 'OPEN',
  'a changed measurement reopens an acknowledged alert (new ciência required)');
select ok((pg_temp.alert('INTERJOURNEY_REST_REVIEW', '2026-09-23')).acknowledged_at is null, 'the previous acknowledgement is cleared');

-- ---------------------------------------------------------------------------
-- 5. Parameters drive the rules.
-- ---------------------------------------------------------------------------
select public.service_workforce_owner_save_payroll_settings('17400000-0000-4000-8000-000000000011', gen_random_uuid(),
  jsonb_build_object('employer_id', (select v from wfa_ids where k = 'employer'),
    'minimum_interjourney_rest_minutes', 600, 'split_shift_review_threshold_minutes', 360));
select ok(pg_temp.evaluate('2026-09') > 0, 'changing parameters changes the evaluation');
select is((pg_temp.alert('INTERJOURNEY_REST_REVIEW', '2026-09-23')).status, 'RESOLVED', '645 ≥ 600: interjourney alert resolved');
select is((pg_temp.alert('SPLIT_SHIFT_REVIEW', '2026-09-23')).status, 'RESOLVED', '315 ≤ 360: split-shift review resolved');

select * from finish();
rollback;
