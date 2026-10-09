begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(41);

-- Fixture: employee with the habitual journey Mon–Fri 13:15–19:15 (America/Sao_Paulo).
insert into auth.users(id, instance_id, aud, role, email, encrypted_password, created_at, updated_at)
values
  ('17200000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'wfc-owner@example.test', '', now(), now()),
  ('17200000-0000-4000-8000-000000000003', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'wfc-employee@example.test', '', now(), now()),
  ('17200000-0000-4000-8000-000000000004', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'wfc-split@example.test', '', now(), now());
insert into public.admin_users(id, auth_user_id, display_name, role, is_active)
values
  ('17200000-0000-4000-8000-000000000011', '17200000-0000-4000-8000-000000000001', 'Owner', 'OWNER', true),
  ('17200000-0000-4000-8000-000000000013', '17200000-0000-4000-8000-000000000003', 'Employee', 'OPERATION', true),
  ('17200000-0000-4000-8000-000000000014', '17200000-0000-4000-8000-000000000004', 'Split', 'OPERATION', true);
insert into public.tenants(id, name, slug) values ('17200000-0000-4000-8000-000000000021', 'WFC Tenant', 'wfc-tenant');
insert into public.tenant_members(tenant_id, user_id, role) values
  ('17200000-0000-4000-8000-000000000021', '17200000-0000-4000-8000-000000000001', 'OWNER');

create temp table wfc_ids(k text primary key, v uuid not null) on commit drop;
insert into wfc_ids
select 'employer', (r -> 'employer' ->> 'employer_id')::uuid
from public.service_workforce_owner_save_employer('17200000-0000-4000-8000-000000000011', gen_random_uuid(),
  '{"legal_name":"Empregadora WFC","workplace_city":"Palhoça","workplace_state":"SC"}') r;
insert into wfc_ids
select 'employee', (r -> 'employee' ->> 'employee_id')::uuid
from public.service_workforce_owner_save_employee('17200000-0000-4000-8000-000000000011', gen_random_uuid(),
  jsonb_build_object('employer_id', (select v from wfc_ids where k = 'employer'), 'admin_user_id', '17200000-0000-4000-8000-000000000013')) r;
insert into wfc_ids
select 'split', (r -> 'employee' ->> 'employee_id')::uuid
from public.service_workforce_owner_save_employee('17200000-0000-4000-8000-000000000011', gen_random_uuid(),
  jsonb_build_object('employer_id', (select v from wfc_ids where k = 'employer'), 'admin_user_id', '17200000-0000-4000-8000-000000000014')) r;
select public.service_workforce_owner_create_schedule_version('17200000-0000-4000-8000-000000000011', gen_random_uuid(),
  jsonb_build_object('employee_id', (select v from wfc_ids where k = 'employee'), 'effective_from', '2026-01-01',
    'days', '[{"iso_weekday":1,"start_time":"13:15","end_time":"19:15"},{"iso_weekday":2,"start_time":"13:15","end_time":"19:15"},
              {"iso_weekday":3,"start_time":"13:15","end_time":"19:15"},{"iso_weekday":4,"start_time":"13:15","end_time":"19:15"},
              {"iso_weekday":5,"start_time":"13:15","end_time":"19:15"}]'::jsonb));
-- A two-block journey (09:00–12:00, 14:00–18:00) to cover gaps between blocks.
select public.service_workforce_owner_create_schedule_version('17200000-0000-4000-8000-000000000011', gen_random_uuid(),
  jsonb_build_object('employee_id', (select v from wfc_ids where k = 'split'), 'effective_from', '2026-01-01',
    'days', '[{"iso_weekday":2,"start_time":"09:00","end_time":"12:00"},{"iso_weekday":2,"start_time":"14:00","end_time":"18:00"}]'::jsonb));

create function pg_temp.seg(p_start text, p_end text, p_who text default 'employee')
returns table(segment_date date, day_class text, segment_kind text, classification text, minutes int, start_local text, end_local text)
language sql as $$
  select c.segment_date, c.day_class, c.segment_kind, c.classification, c.duration_seconds / 60,
         to_char(c.segment_start at time zone 'America/Sao_Paulo', 'HH24:MI'),
         to_char(c.segment_end at time zone 'America/Sao_Paulo', 'HH24:MI')
  from workforce.calculate_segments((select v from wfc_ids where k = p_who),
    (p_start::timestamp at time zone 'America/Sao_Paulo'), (p_end::timestamp at time zone 'America/Sao_Paulo')) c
  order by c.segment_start;
$$;
create function pg_temp.extra(p_start text, p_end text, p_who text default 'employee')
returns int language sql as $$
  select coalesce(sum(minutes), 0)::int from pg_temp.seg(p_start, p_end, p_who) where segment_kind <> 'REGULAR_OVERLAP';
$$;
create function pg_temp.kinds(p_start text, p_end text, p_who text default 'employee')
returns text language sql as $$
  select string_agg(segment_kind || ':' || classification || ':' || start_local || '-' || end_local || ':' || minutes, ' | ')
  from pg_temp.seg(p_start, p_end, p_who);
$$;

-- ---------------------------------------------------------------------------
-- Mandatory matrix (spec §8).
-- ---------------------------------------------------------------------------
-- Case 1 — Tuesday 08:00–10:00 = 120 min extra before the journey.
select is(pg_temp.extra('2026-10-06 08:00', '2026-10-06 10:00'), 120, 'case 1: Tue 08:00–10:00 = 120 min extra');
select is(pg_temp.kinds('2026-10-06 08:00', '2026-10-06 10:00'),
  'EXTRA_BEFORE:EXTRA_WEEKDAY:08:00-10:00:120', 'case 1: single EXTRA_BEFORE / EXTRA_WEEKDAY segment');

-- Case 2 — Tuesday 18:00–20:00 with the journey ending 19:15 = 45 min extra (never end - start).
select is(pg_temp.extra('2026-10-06 18:00', '2026-10-06 20:00'), 45, 'case 2: Tue 18:00–20:00 = 45 min extra, not 120');
select is(pg_temp.kinds('2026-10-06 18:00', '2026-10-06 20:00'),
  'REGULAR_OVERLAP:REGULAR:18:00-19:15:75 | EXTRA_AFTER:EXTRA_WEEKDAY:19:15-20:00:45',
  'case 2: 18:00–19:15 REGULAR_OVERLAP + 19:15–20:00 EXTRA_AFTER');

-- Case 3 — Tuesday 12:00–14:00 = 75 min before + 45 min regular overlap.
select is(pg_temp.extra('2026-10-06 12:00', '2026-10-06 14:00'), 75, 'case 3: Tue 12:00–14:00 = 75 min extra');
select is(pg_temp.kinds('2026-10-06 12:00', '2026-10-06 14:00'),
  'EXTRA_BEFORE:EXTRA_WEEKDAY:12:00-13:15:75 | REGULAR_OVERLAP:REGULAR:13:15-14:00:45',
  'case 3: 12:00–13:15 EXTRA_BEFORE + 13:15–14:00 REGULAR_OVERLAP');

-- Case 4 — Saturday 09:00–13:00 = 240 min EXTRA_SATURDAY.
select is(pg_temp.extra('2026-10-10 09:00', '2026-10-10 13:00'), 240, 'case 4: Sat 09:00–13:00 = 240 min');
select is(pg_temp.kinds('2026-10-10 09:00', '2026-10-10 13:00'),
  'EXTRA_NON_WORKDAY:EXTRA_SATURDAY:09:00-13:00:240', 'case 4: whole Saturday period is EXTRA_SATURDAY');

-- Case 5 — Sunday 09:00–13:00 = 240 min EXTRA_SUNDAY.
select is(pg_temp.kinds('2026-10-11 09:00', '2026-10-11 13:00'),
  'EXTRA_NON_WORKDAY:EXTRA_SUNDAY:09:00-13:00:240', 'case 5: Sun 09:00–13:00 = 240 min EXTRA_SUNDAY');

-- Case 6 — holiday Monday (Finados, 2026-11-02) 09:00–12:00 = 180 min EXTRA_HOLIDAY.
select is(pg_temp.kinds('2026-11-02 09:00', '2026-11-02 12:00'),
  'EXTRA_NON_WORKDAY:EXTRA_HOLIDAY:09:00-12:00:180', 'case 6: holiday Monday 09:00–12:00 = 180 min EXTRA_HOLIDAY');
select is(pg_temp.kinds('2026-11-02 13:15', '2026-11-02 19:15'),
  'EXTRA_NON_WORKDAY:EXTRA_HOLIDAY:13:15-19:15:360', 'case 6b: working the habitual hours on a holiday is all EXTRA_HOLIDAY');

-- Case 7 — Friday 23:00 to Saturday 02:00 across midnight.
select is(pg_temp.kinds('2026-10-09 23:00', '2026-10-10 02:00'),
  'EXTRA_AFTER:EXTRA_WEEKDAY:23:00-00:00:60 | EXTRA_NON_WORKDAY:EXTRA_SATURDAY:00:00-02:00:120',
  'case 7: midnight split — 60 min Friday EXTRA_AFTER + 120 min EXTRA_SATURDAY');
select is((select array_agg(distinct segment_date order by segment_date) from pg_temp.seg('2026-10-09 23:00', '2026-10-10 02:00')),
  array['2026-10-09'::date, '2026-10-10'::date], 'case 7: each piece is dated by its own local date');
-- Case 7b — Sunday 22:00 to Monday 14:00 (Monday is a workday).
select is(pg_temp.kinds('2026-10-11 22:00', '2026-10-12 14:00'),
  'EXTRA_NON_WORKDAY:EXTRA_SUNDAY:22:00-00:00:120 | EXTRA_NON_WORKDAY:EXTRA_HOLIDAY:00:00-14:00:840',
  'case 7b: 2026-10-12 is Nossa Senhora Aparecida (holiday) — whole Monday piece is EXTRA_HOLIDAY');
select is(pg_temp.kinds('2026-10-18 22:00', '2026-10-19 14:00'),
  'EXTRA_NON_WORKDAY:EXTRA_SUNDAY:22:00-00:00:120 | EXTRA_BEFORE:EXTRA_WEEKDAY:00:00-13:15:795 | REGULAR_OVERLAP:REGULAR:13:15-14:00:45',
  'case 7c: Sunday into a regular Monday splits into Sunday extra, Monday before-journey extra and overlap');

-- ---------------------------------------------------------------------------
-- Boundaries and full coverage.
-- ---------------------------------------------------------------------------
select is(pg_temp.extra('2026-10-06 13:15', '2026-10-06 19:15'), 0, 'exactly the habitual journey yields no extra');
select is(pg_temp.kinds('2026-10-06 13:15', '2026-10-06 19:15'),
  'REGULAR_OVERLAP:REGULAR:13:15-19:15:360', 'exactly the habitual journey is one REGULAR_OVERLAP');
select is(pg_temp.extra('2026-10-06 19:15', '2026-10-06 19:16'), 1, 'one minute after the journey is one extra minute');
select is(pg_temp.extra('2026-10-06 13:14', '2026-10-06 13:15'), 1, 'one minute before the journey is one extra minute');
select is(pg_temp.kinds('2026-10-06 12:00', '2026-10-06 20:00'),
  'EXTRA_BEFORE:EXTRA_WEEKDAY:12:00-13:15:75 | REGULAR_OVERLAP:REGULAR:13:15-19:15:360 | EXTRA_AFTER:EXTRA_WEEKDAY:19:15-20:00:45',
  'a period covering the whole journey has before + overlap + after');
select is(pg_temp.extra('2026-10-06 12:00', '2026-10-06 20:00'), 120, 'covering period: 75 + 45 = 120 min extra');
select is(pg_temp.kinds('2026-10-06 14:00', '2026-10-06 15:00'),
  'REGULAR_OVERLAP:REGULAR:14:00-15:00:60', 'a period inside the journey is all regular overlap');
select is(
  (select sum(minutes)::int from pg_temp.seg('2026-10-09 18:00', '2026-10-10 03:30')),
  570, 'segments always sum to the raw period (no minute lost or invented)'
);
select throws_ok(
  $$select * from workforce.calculate_segments((select v from wfc_ids where k = 'employee'), now(), now())$$,
  'P0001', 'WORKFORCE_PERIOD_INVALID', 'an empty period is rejected'
);

-- Two-block journey: gap between blocks counts as extra after the first block.
select is(pg_temp.kinds('2026-10-06 11:00', '2026-10-06 15:00', 'split'),
  'REGULAR_OVERLAP:REGULAR:11:00-12:00:60 | EXTRA_AFTER:EXTRA_WEEKDAY:12:00-14:00:120 | REGULAR_OVERLAP:REGULAR:14:00-15:00:60',
  'interval between two blocks is extra, both overlaps are regular');
select is(pg_temp.kinds('2026-10-06 07:00', '2026-10-06 19:00', 'split'),
  'EXTRA_BEFORE:EXTRA_WEEKDAY:07:00-09:00:120 | REGULAR_OVERLAP:REGULAR:09:00-12:00:180 | EXTRA_AFTER:EXTRA_WEEKDAY:12:00-14:00:120 | REGULAR_OVERLAP:REGULAR:14:00-18:00:240 | EXTRA_AFTER:EXTRA_WEEKDAY:18:00-19:00:60',
  'two-block journey fully covered');
select is(pg_temp.kinds('2026-10-07 09:00', '2026-10-07 10:00', 'split'),
  'EXTRA_NON_WORKDAY:EXTRA_WEEKDAY:09:00-10:00:60', 'a weekday without habitual journey is non-workday extra classified as weekday');

-- Schedule versions: the version valid on each date is used.
select public.service_workforce_owner_create_schedule_version('17200000-0000-4000-8000-000000000011', gen_random_uuid(),
  jsonb_build_object('employee_id', (select v from wfc_ids where k = 'employee'), 'effective_from', '2026-12-01',
    'days', '[{"iso_weekday":2,"start_time":"10:00","end_time":"16:00"}]'::jsonb));
select is(pg_temp.extra('2026-12-01 16:00', '2026-12-01 17:00'), 60, 'new schedule version applies from its start date');
select is(pg_temp.extra('2026-11-24 16:00', '2026-11-24 17:00'), 0, 'older dates keep the older schedule version');

-- ---------------------------------------------------------------------------
-- Persistence through the governed record flow (past dates: records cannot be in the future).
-- ---------------------------------------------------------------------------
insert into wfc_ids
select 'x_case2', (r -> 'exception' ->> 'exception_id')::uuid
from public.service_workforce_employee_record_exception('17200000-0000-4000-8000-000000000013', gen_random_uuid(),
  '{"exception_type":"EXTRA_WORK","start_local":"2026-09-22T18:00","end_local":"2026-09-22T20:00"}') r;
select is(
  (select string_agg(segment_kind || ':' || duration_seconds / 60, ',' order by segment_start)
   from workforce.work_exception_segments where exception_id = (select v from wfc_ids where k = 'x_case2')),
  'REGULAR_OVERLAP:75,EXTRA_AFTER:45', 'recorded exception persists its segments automatically'
);
select ok(exists (
  select 1 from workforce.work_exceptions x
  where x.id = (select v from wfc_ids where k = 'x_case2')
    and x.reported_start = '2026-09-22 18:00:00-03' and x.reported_end = '2026-09-22 20:00:00-03'
), 'raw period is stored untouched (no rounding)');
select public.service_workforce_employee_record_exception('17200000-0000-4000-8000-000000000013', gen_random_uuid(),
  '{"exception_type":"EXTRA_WORK","start_local":"2026-09-26T09:00","end_local":"2026-09-26T13:00"}');
select public.service_workforce_employee_record_exception('17200000-0000-4000-8000-000000000013', gen_random_uuid(),
  '{"exception_type":"EXTRA_WORK","start_local":"2026-09-27T09:00","end_local":"2026-09-27T13:00"}');
select public.service_workforce_employee_record_exception('17200000-0000-4000-8000-000000000013', gen_random_uuid(),
  '{"exception_type":"EARLY_LEAVE","start_local":"2026-09-23T17:30","end_local":"2026-09-23T19:15"}');

select is(
  public.service_workforce_employee_get_month_summary('17200000-0000-4000-8000-000000000013', '2026-09')
    - 'days' - 'exceptions',
  '{"month":"2026-09","period_start":"2026-09-01","period_end":"2026-09-30","extra_raw_minutes":525,"extra_counted_minutes":525,
    "extra_sunday_minutes":240,"extra_holiday_minutes":0,"extra_weekday_minutes":45,"extra_saturday_minutes":240}'::jsonb,
  'month summary totals: weekday 45, Saturday 240, Sunday 240 (early leave never creates negative balance)'
);
select throws_ok(
  $$insert into workforce.work_exception_segments(tenant_id, exception_id, employee_id, segment_date, day_class, segment_kind, classification, segment_start, segment_end, duration_seconds)
    select tenant_id, id, employee_id, event_date, 'WEEKDAY', 'EXTRA_AFTER', 'EXTRA_WEEKDAY', reported_start, reported_end, 7200
    from workforce.work_exceptions limit 1$$,
  'P0001', 'WORKFORCE_SEGMENTS_ENGINE_ONLY', 'segments can only be written by the engine'
);

-- ---------------------------------------------------------------------------
-- Tolerance layer (parametrized; defaults 0).
-- ---------------------------------------------------------------------------
select public.service_workforce_employee_record_exception('17200000-0000-4000-8000-000000000013', gen_random_uuid(),
  '{"exception_type":"EXTRA_WORK","start_local":"2026-09-24T19:15","end_local":"2026-09-24T19:19"}');
select is(
  (select extra_counted_seconds / 60 from workforce.day_summary((select v from wfc_ids where k = 'employee'), '2026-09-24', '2026-09-24')),
  4, 'without tolerance configured every extra minute counts'
);
select public.service_workforce_owner_save_payroll_settings('17200000-0000-4000-8000-000000000011', gen_random_uuid(),
  jsonb_build_object('employer_id', (select v from wfc_ids where k = 'employer'), 'tolerance_minutes_per_mark', 5, 'tolerance_minutes_daily_max', 10));
select is(
  (select extra_counted_seconds / 60 from workforce.day_summary((select v from wfc_ids where k = 'employee'), '2026-09-24', '2026-09-24')),
  0, 'within tolerance (4 min ≤ 5 per mark, ≤ 10 daily) the minutes are disregarded'
);
select is(
  (select extra_raw_seconds / 60 from workforce.day_summary((select v from wfc_ids where k = 'employee'), '2026-09-24', '2026-09-24')),
  4, 'tolerance never alters the raw extra minutes'
);
select is(
  (select extra_counted_seconds / 60 from workforce.day_summary((select v from wfc_ids where k = 'employee'), '2026-09-22', '2026-09-22')),
  45, 'beyond tolerance the whole extra counts (45 min)'
);
select is(
  (select extra_counted_seconds / 60 from workforce.day_summary((select v from wfc_ids where k = 'employee'), '2026-09-26', '2026-09-26')),
  240, 'tolerance never applies to non-workday extra'
);
select ok(exists (
  select 1 from workforce.work_exceptions x
  where x.employee_id = (select v from wfc_ids where k = 'employee')
    and x.reported_end = '2026-09-24 19:19:00-03'
), 'raw record keeps the original minutes under tolerance');

-- ---------------------------------------------------------------------------
-- Holiday added later + idempotent recalculation.
-- ---------------------------------------------------------------------------
select public.service_workforce_owner_manage_holiday('17200000-0000-4000-8000-000000000011', gen_random_uuid(),
  jsonb_build_object('action', 'ADD', 'employer_id', (select v from wfc_ids where k = 'employer'),
    'scope', 'MUNICIPAL', 'name', 'Feriado municipal teste', 'rule_kind', 'DATE', 'holiday_date', '2026-09-22'));
select is(
  (public.service_workforce_owner_recalculate_month('17200000-0000-4000-8000-000000000011', '17200000-0000-4000-8000-0000000000f1',
    jsonb_build_object('employee_id', (select v from wfc_ids where k = 'employee'), 'month', '2026-09')) -> 'summary' ->> 'extra_holiday_minutes')::int,
  120, 'after a municipal holiday is added, recalculation reclassifies Tue 18:00–20:00 as 120 min EXTRA_HOLIDAY'
);
select is(
  (public.service_workforce_owner_recalculate_month('17200000-0000-4000-8000-000000000011', gen_random_uuid(),
    jsonb_build_object('employee_id', (select v from wfc_ids where k = 'employee'), 'month', '2026-09')) -> 'summary' ->> 'extra_holiday_minutes')::int,
  120, 'recalculation is idempotent'
);

select * from finish();
rollback;
