begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(10);

select has_function('public', 'public_get_studio_stats', array[]::text[], 'studio stats RPC exists');
select ok(
  has_function_privilege('anon', 'public.public_get_studio_stats()', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.public_get_studio_stats()', 'EXECUTE'),
  'the home page can read studio stats anonymously'
);
select ok(
  not has_table_privilege('anon', 'public.studio_stats_baselines', 'SELECT')
  and not has_table_privilege('authenticated', 'public.studio_stats_baselines', 'SELECT')
  and not has_table_privilege('service_role', 'public.studio_stats_baselines', 'INSERT'),
  'the Google baseline is reachable only through the aggregate RPC'
);
select is(
  (select count(*)::integer from public.studio_stats_baselines),
  1,
  'one Google Calendar baseline row is seeded'
);

-- Live counting starts at the cutoff; earlier reservations only tell who already produced here.
update public.studio_stats_baselines
set cutoff_at = now() - interval '30 days', productions = 100, hours = 200.5, professionals = 50;
select set_config('agenda.stats.before', public.public_get_studio_stats()::text, true);

insert into public.employees(id, name) values
  ('17300000-0000-4000-8000-000000000001', 'Studio Stats Staff'),
  ('17300000-0000-4000-8000-000000000002', 'Studio Stats Pro');
insert into public.categories(id, name, slug)
values ('17300000-0000-4000-8000-000000000003', 'Studio Stats category', 'studio-stats-category');
insert into public.services(
  id, category_id, name, slug, base_duration_minutes, base_price,
  buffer_before_minutes, buffer_after_minutes, minimum_people, maximum_people,
  minimum_booking_notice_minutes, maximum_booking_horizon_days, requires_terms,
  duration_mode, operation_scope, booking_product_type, service_type_id
) values
  ('17300000-0000-4000-8000-000000000010', '17300000-0000-4000-8000-000000000003', 'Stats rental', 'stats-rental', 60, 100,
   0, 0, 1, 10, 0, 365, false, 'FIXED', 'BLACKSHEEP', 'STANDARD', (select id from public.service_type where key = 'LOCACAO')),
  ('17300000-0000-4000-8000-000000000011', '17300000-0000-4000-8000-000000000003', 'Stats visit', 'stats-visit', 30, 0,
   0, 0, 1, 10, 0, 365, false, 'FIXED', 'BLACKSHEEP', 'FREE_VISIT', (select id from public.service_type where key = 'LOCACAO')),
  ('17300000-0000-4000-8000-000000000012', '17300000-0000-4000-8000-000000000003', 'Stats session', 'stats-session', 60, 500,
   0, 0, 1, 10, 0, 365, false, 'FIXED', 'SABRINA', 'STANDARD', (select id from public.service_type where key = 'LOCACAO'));
insert into public.service_employees(id, service_id, employee_id) values
  ('17300000-0000-4000-8000-000000000020', '17300000-0000-4000-8000-000000000010', '17300000-0000-4000-8000-000000000001'),
  ('17300000-0000-4000-8000-000000000021', '17300000-0000-4000-8000-000000000011', '17300000-0000-4000-8000-000000000001'),
  ('17300000-0000-4000-8000-000000000022', '17300000-0000-4000-8000-000000000012', '17300000-0000-4000-8000-000000000002');
insert into public.service_change_policies(
  service_id, notice_hours, reschedule_first_early_percent, reschedule_first_late_percent,
  reschedule_repeat_percent, cancellation_late_percent
) values
  ('17300000-0000-4000-8000-000000000010', 48, 0, 20, 30, 30),
  ('17300000-0000-4000-8000-000000000011', 48, 0, 20, 30, 30),
  ('17300000-0000-4000-8000-000000000012', 48, 0, 20, 30, 30);
insert into public.customers(id, name, email, phone) values
  ('17300000-0000-4000-8000-000000000030', 'Stats renter A', 'stats-a@example.test', '+5548999990173'),
  ('17300000-0000-4000-8000-000000000031', 'Stats renter B', 'stats-b@example.test', '+5548999991173'),
  ('17300000-0000-4000-8000-000000000032', 'Stats renter C', 'stats-c@example.test', '+5548999992173');

insert into public.appointments(
  id, public_code, service_id, service_employee_id, primary_customer_id,
  status, financial_status, start_at, end_at, duration_minutes, people_count, service_name_snapshot, commercial_value, is_test, confirmed_at
) values
  -- Counted: realized rentals and a Sabrina session.
  ('17300000-0000-4000-8000-000000000040', 'STATS-A-DONE', '17300000-0000-4000-8000-000000000010', '17300000-0000-4000-8000-000000000020', '17300000-0000-4000-8000-000000000030',
   'COMPLETED', 'PAID', now() - interval '10 days', now() - interval '10 days' + interval '2 hours', 120, 1, 'Stats rental', 200, false, now() - interval '41 days'),
  ('17300000-0000-4000-8000-000000000041', 'STATS-A-ELAPSED', '17300000-0000-4000-8000-000000000010', '17300000-0000-4000-8000-000000000020', '17300000-0000-4000-8000-000000000030',
   'CONFIRMED', 'PAID', now() - interval '9 days', now() - interval '9 days' + interval '1 hour', 60, 1, 'Stats rental', 100, false, now() - interval '41 days'),
  ('17300000-0000-4000-8000-000000000042', 'STATS-SESSION', '17300000-0000-4000-8000-000000000012', '17300000-0000-4000-8000-000000000022', '17300000-0000-4000-8000-000000000031',
   'COMPLETED', 'PAID', now() - interval '6 days', now() - interval '6 days' + interval '3 hours', 180, 1, 'Stats session', 500, false, now() - interval '41 days'),
  ('17300000-0000-4000-8000-000000000043', 'STATS-C-RETURN', '17300000-0000-4000-8000-000000000010', '17300000-0000-4000-8000-000000000020', '17300000-0000-4000-8000-000000000032',
   'COMPLETED', 'PAID', now() - interval '4 days', now() - interval '4 days' + interval '1 hour', 60, 1, 'Stats rental', 100, false, now() - interval '41 days'),
  -- Not counted: future, free visit, cancelled, test, and before the cutoff.
  ('17300000-0000-4000-8000-000000000044', 'STATS-B-FUTURE', '17300000-0000-4000-8000-000000000010', '17300000-0000-4000-8000-000000000020', '17300000-0000-4000-8000-000000000031',
   'CONFIRMED', 'PAID', now() + interval '3 days', now() + interval '3 days' + interval '1 hour', 60, 1, 'Stats rental', 100, false, now() - interval '41 days'),
  ('17300000-0000-4000-8000-000000000045', 'STATS-B-VISIT', '17300000-0000-4000-8000-000000000011', '17300000-0000-4000-8000-000000000021', '17300000-0000-4000-8000-000000000031',
   'COMPLETED', 'PAID', now() - interval '8 days', now() - interval '8 days' + interval '1 hour', 60, 1, 'Stats visit', 0, false, now() - interval '41 days'),
  ('17300000-0000-4000-8000-000000000046', 'STATS-B-CANCELLED', '17300000-0000-4000-8000-000000000010', '17300000-0000-4000-8000-000000000020', '17300000-0000-4000-8000-000000000031',
   'CANCELLED', 'NOT_STARTED', now() - interval '7 days', now() - interval '7 days' + interval '1 hour', 60, 1, 'Stats rental', 100, false, now() - interval '41 days'),
  ('17300000-0000-4000-8000-000000000047', 'STATS-A-TEST', '17300000-0000-4000-8000-000000000010', '17300000-0000-4000-8000-000000000020', '17300000-0000-4000-8000-000000000030',
   'COMPLETED', 'PAID', now() - interval '5 days', now() - interval '5 days' + interval '1 hour', 60, 1, 'Stats rental', 100, true, now() - interval '41 days'),
  ('17300000-0000-4000-8000-000000000048', 'STATS-C-BEFORE', '17300000-0000-4000-8000-000000000010', '17300000-0000-4000-8000-000000000020', '17300000-0000-4000-8000-000000000032',
   'COMPLETED', 'PAID', now() - interval '40 days', now() - interval '40 days' + interval '1 hour', 60, 1, 'Stats rental', 100, false, now() - interval '41 days');

insert into public.legacy_amelia_bookings(
  amelia_booking_id, customer_name, customer_email, service_name, employee_name, start_at, end_at, status_raw
) values
  ('stats-173-rental', 'Stats renter A', 'STATS-A@example.test', '1 hora - Locação de Estúdio', 'BlackSheep Estudio Criativo',
   now() - interval '3 days', now() - interval '3 days' + interval '1 hour', 'Aprovado'),
  ('stats-173-visit', 'Stats visitor', 'stats-visit@example.test', 'Conhecer o estudio (visita sem compromisso)', 'BlackSheep Estudio Criativo',
   now() - interval '3 days', now() - interval '3 days' + interval '30 minutes', 'Aprovado'),
  ('stats-173-cancelled', 'Stats cancelled', 'stats-cancel@example.test', '2 Horas - Locação de Estúdio', 'BlackSheep Estudio Criativo',
   now() - interval '2 days', now() - interval '2 days' + interval '2 hours', 'Cancelado');

insert into public.google_connections(id, account_email, status)
values ('17300000-0000-4000-8000-000000000050', 'studio-stats@example.invalid', 'ACTIVE');
insert into public.google_calendars(id, google_connection_id, google_calendar_id, name, is_active)
values ('17300000-0000-4000-8000-000000000051', '17300000-0000-4000-8000-000000000050', 'atendimento@sabrinapierri.com.br', 'ESTÚDIO', true);
insert into public.google_calendar_events(
  id, google_calendar_id, google_event_id, status, summary, start_at, end_at, qualification, normalized_payload
) values
  -- Counted: an Essencial session booked outside the Agenda (Jheneffe, new professional).
  ('17300000-0000-4000-8000-000000000060', '17300000-0000-4000-8000-000000000051', 'stats-173-essencial', 'confirmed',
   'Essencial - 20 fotos -- Jheneffe + Cliente', now() - interval '2 days', now() - interval '2 days' + interval '1 hour', 'BLOCKING', '{}'),
  -- Not counted: a meeting, an upcoming session and a free-time event.
  ('17300000-0000-4000-8000-000000000061', '17300000-0000-4000-8000-000000000051', 'stats-173-meeting', 'confirmed',
   'Reunião com parceiro', now() - interval '1 day', now() - interval '1 day' + interval '1 hour', 'BLOCKING', '{}'),
  ('17300000-0000-4000-8000-000000000062', '17300000-0000-4000-8000-000000000051', 'stats-173-upcoming', 'confirmed',
   'Natal - Cliente', now() + interval '1 day', now() + interval '1 day' + interval '1 hour', 'BLOCKING', '{}'),
  ('17300000-0000-4000-8000-000000000063', '17300000-0000-4000-8000-000000000051', 'stats-173-transparent', 'confirmed',
   'Aniversário', now() - interval '1 day', now() - interval '1 day' + interval '2 hours', 'IGNORED_TRANSPARENT', '{}');

select set_config('agenda.stats.after', public.public_get_studio_stats()::text, true);

select is(
  (current_setting('agenda.stats.after')::jsonb->>'productions')::integer
    - (current_setting('agenda.stats.before')::jsonb->>'productions')::integer,
  6,
  'counts realized rentals, sessions, Amelia history and outside-Agenda sessions since the cutoff'
);
select is(
  (current_setting('agenda.stats.after')::jsonb->>'hours')::integer
    - (current_setting('agenda.stats.before')::jsonb->>'hours')::integer,
  9,
  'adds the booked hours of every counted production'
);
select is(
  (current_setting('agenda.stats.after')::jsonb->>'professionals')::integer
    - (current_setting('agenda.stats.before')::jsonb->>'professionals')::integer,
  3,
  'counts renter A once across Agenda and Amelia, plus the two session professionals; renter C already produced before the cutoff'
);
select ok(
  (current_setting('agenda.stats.after')::jsonb->>'productions')::integer >= 100
  and (current_setting('agenda.stats.after')::jsonb->>'hours')::integer >= 200
  and (current_setting('agenda.stats.after')::jsonb->>'professionals')::integer >= 50,
  'live totals start from the Google Calendar baseline'
);
select is(
  (select array_agg(key order by key) from jsonb_object_keys(public.public_get_studio_stats()) key),
  array['hours', 'productions', 'professionals', 'updated_at'],
  'returns only aggregate numbers'
);

set local role anon;
select ok(
  (public.public_get_studio_stats()->>'productions')::integer >= 106,
  'anon reads the same totals'
);
reset role;

select * from finish();
rollback;
