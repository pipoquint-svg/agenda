begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(16);

insert into public.categories(id, name, slug)
values ('98300000-0000-0000-0000-000000000001', 'Range Anchor Test', 'range-anchor-test');

insert into public.resources(id, name, resource_type)
values
  ('98300000-0000-0000-0000-000000000002', 'RANGE ANCHOR PERSON', 'PERSON'),
  ('98300000-0000-0000-0000-000000000003', 'RANGE ANCHOR STUDIO', 'PHYSICAL');

insert into public.employees(id, name, resource_id)
values ('98300000-0000-0000-0000-000000000004', 'Range Anchor Photographer', '98300000-0000-0000-0000-000000000002');

insert into public.services(
  id, category_id, name, slug,
  base_duration_minutes, base_price,
  buffer_before_minutes, buffer_after_minutes,
  minimum_people, maximum_people, maximum_booking_horizon_days,
  slot_interval_minutes
) values
(
  '98300000-0000-0000-0000-000000000010',
  '98300000-0000-0000-0000-000000000001',
  'Natal Range Anchor', 'natal-range-anchor',
  60, 100.00, 0, 0, 1, 10, 5000, 90
),
(
  '98300000-0000-0000-0000-000000000011',
  '98300000-0000-0000-0000-000000000001',
  'Outro Serviço Mesmo Fotógrafo', 'outro-servico-mesmo-fotografo',
  60, 100.00, 0, 0, 1, 10, 5000, 60
);

-- This service intentionally omits slot_interval_minutes to prove the default.
insert into public.services(
  id, category_id, name, slug,
  base_duration_minutes, base_price,
  buffer_before_minutes, buffer_after_minutes,
  minimum_people, maximum_people, maximum_booking_horizon_days
) values (
  '98300000-0000-0000-0000-000000000012',
  '98300000-0000-0000-0000-000000000001',
  'Serviço Passo Padrão', 'servico-passo-padrao',
  60, 100.00, 0, 0, 1, 10, 5000
);

insert into public.service_employees(id, service_id, employee_id)
values
  ('98300000-0000-0000-0000-000000000020', '98300000-0000-0000-0000-000000000010', '98300000-0000-0000-0000-000000000004'),
  ('98300000-0000-0000-0000-000000000021', '98300000-0000-0000-0000-000000000011', '98300000-0000-0000-0000-000000000004'),
  ('98300000-0000-0000-0000-000000000022', '98300000-0000-0000-0000-000000000012', '98300000-0000-0000-0000-000000000004');

-- 2030-01-05 is Saturday (PostgreSQL DOW 6).
-- Rule-level cadence is intentionally 30 to prove service cadence has precedence.
insert into public.availability_rules(
  service_employee_id, weekday, start_local_time, end_local_time, slot_interval_minutes
) values
  ('98300000-0000-0000-0000-000000000020', 6, '08:30', '13:00', 30),
  ('98300000-0000-0000-0000-000000000020', 6, '14:00', '20:00', 30),
  ('98300000-0000-0000-0000-000000000021', 6, '09:15', '12:15', 30),
  ('98300000-0000-0000-0000-000000000022', 6, '08:30', '10:30', 90);

select is(
  (select slot_interval_minutes from public.services where id = '98300000-0000-0000-0000-000000000010'),
  90,
  'service stores its own 90-minute candidate cadence'
);

select is(
  (
    select array_agg(to_char(core_start_at at time zone 'America/Sao_Paulo', 'HH24:MI') order by core_start_at)
    from public.list_available_slots_without_google_sync_gate(
      '98300000-0000-0000-0000-000000000010',
      '98300000-0000-0000-0000-000000000020',
      '[]'::jsonb, 1, '2030-01-05'::date, null
    )
    where (core_start_at at time zone 'America/Sao_Paulo')::time < '13:00'::time
  ),
  array['08:30','10:00','11:30']::text[],
  '08:30-13:00 range anchors its own 90-minute series at 08:30'
);

select is(
  (
    select array_agg(to_char(core_start_at at time zone 'America/Sao_Paulo', 'HH24:MI') order by core_start_at)
    from public.list_available_slots_without_google_sync_gate(
      '98300000-0000-0000-0000-000000000010',
      '98300000-0000-0000-0000-000000000020',
      '[]'::jsonb, 1, '2030-01-05'::date, null
    )
    where (core_start_at at time zone 'America/Sao_Paulo')::time >= '14:00'::time
  ),
  array['14:00','15:30','17:00','18:30']::text[],
  '14:00-20:00 range independently restarts the 90-minute series at 14:00'
);

select is(
  (
    select array_agg(to_char(core_start_at at time zone 'America/Sao_Paulo', 'HH24:MI') order by core_start_at)
    from public.list_available_slots_for_duration_without_google_sync_gate(
      '98300000-0000-0000-0000-000000000010',
      '98300000-0000-0000-0000-000000000020',
      null, '[]'::jsonb, 1, '2030-01-05'::date, null
    )
  ),
  array['08:30','10:00','11:30','14:00','15:30','17:00','18:30']::text[],
  'duration-aware function uses the same independently anchored employee+service ranges'
);

select ok(
  not exists (
    select 1
    from public.list_available_slots_without_google_sync_gate(
      '98300000-0000-0000-0000-000000000010',
      '98300000-0000-0000-0000-000000000021',
      '[]'::jsonb, 1, '2030-01-05'::date, null
    )
  ),
  'a service cannot accidentally consume another service_employee pair'
);

select is(
  (
    select array_agg(to_char(core_start_at at time zone 'America/Sao_Paulo', 'HH24:MI') order by core_start_at)
    from public.list_available_slots_without_google_sync_gate(
      '98300000-0000-0000-0000-000000000011',
      '98300000-0000-0000-0000-000000000021',
      '[]'::jsonb, 1, '2030-01-05'::date, null
    )
  ),
  array['09:15','10:15','11:15']::text[],
  'same employee with another service uses only that service journey and cadence'
);

select is(
  (
    select array_agg(to_char(core_start_at at time zone 'America/Sao_Paulo', 'HH24:MI') order by core_start_at)
    from public.list_available_slots_without_google_sync_gate(
      '98300000-0000-0000-0000-000000000010',
      '98300000-0000-0000-0000-000000000020',
      '[]'::jsonb, 1, '2030-01-05'::date, null
    )
  ),
  array['08:30','10:00','11:30','14:00','15:30','17:00','18:30']::text[],
  'other service journeys on the same employee do not alter this service grid'
);

select is(
  (select slot_interval_minutes from public.availability_rules where service_employee_id = '98300000-0000-0000-0000-000000000020' limit 1),
  30,
  'fixture keeps a conflicting 30-minute rule cadence for precedence coverage'
);

select ok(
  not exists (
    select 1
    from public.list_available_slots_without_google_sync_gate(
      '98300000-0000-0000-0000-000000000010',
      '98300000-0000-0000-0000-000000000020',
      '[]'::jsonb, 1, '2030-01-05'::date, null
    ) s
    where to_char(s.core_start_at at time zone 'America/Sao_Paulo', 'HH24:MI') in ('09:00','09:30','10:30')
  ),
  'service cadence overrides availability_rules.slot_interval_minutes'
);

insert into public.availability_exceptions(service_employee_id, exception_type, start_at, end_at, reason)
values (
  '98300000-0000-0000-0000-000000000020',
  'OPEN',
  '2030-01-05 10:00:00 America/Sao_Paulo'::timestamptz,
  '2030-01-05 13:00:00 America/Sao_Paulo'::timestamptz,
  'overlap-dedup-test'
);

select is(
  (
    select count(*)::integer
    from public.list_available_slots_without_google_sync_gate(
      '98300000-0000-0000-0000-000000000010',
      '98300000-0000-0000-0000-000000000020',
      '[]'::jsonb, 1, '2030-01-05'::date, null
    )
    where to_char(core_start_at at time zone 'America/Sao_Paulo', 'HH24:MI') = '10:00'
  ),
  1,
  'overlapping OPEN range does not duplicate a candidate already produced by the weekly range'
);

insert into public.service_resources(service_id, resource_id, is_required)
values ('98300000-0000-0000-0000-000000000010', '98300000-0000-0000-0000-000000000003', true);

insert into public.resource_availability_rules(resource_id, weekday, start_local_time, end_local_time)
values ('98300000-0000-0000-0000-000000000003', 6, '08:00', '22:00');

select is(
  (
    select array_agg(to_char(core_start_at at time zone 'America/Sao_Paulo', 'HH24:MI') order by core_start_at)
    from public.list_available_slots_for_duration_without_google_sync_gate(
      '98300000-0000-0000-0000-000000000010',
      '98300000-0000-0000-0000-000000000020',
      null, '[]'::jsonb, 1, '2030-01-05'::date, null
    )
  ),
  array['08:30','10:00','11:30','14:00','15:30','17:00','18:30']::text[],
  'physical space open 08:00-22:00 only filters and does not shift employee+service cadence'
);

update public.resource_availability_rules
set start_local_time = '09:00'
where resource_id = '98300000-0000-0000-0000-000000000003' and weekday = 6;

select is(
  (
    select array_agg(to_char(core_start_at at time zone 'America/Sao_Paulo', 'HH24:MI') order by core_start_at)
    from public.list_available_slots_for_duration_without_google_sync_gate(
      '98300000-0000-0000-0000-000000000010',
      '98300000-0000-0000-0000-000000000020',
      null, '[]'::jsonb, 1, '2030-01-05'::date, null
    )
  ),
  array['10:00','11:30','14:00','15:30','17:00','18:30']::text[],
  'space opening at 09:00 removes 08:30 without re-anchoring or shifting remaining candidates'
);

insert into public.resource_allocations(
  resource_id, allocation_type, status, occupied_range, reason
) values (
  '98300000-0000-0000-0000-000000000003',
  'MANUAL_BLOCK', 'BLOCKED',
  tstzrange(
    '2030-01-05 15:15:00 America/Sao_Paulo'::timestamptz,
    '2030-01-05 16:45:00 America/Sao_Paulo'::timestamptz,
    '[)'
  ),
  'candidate-conflict-regression'
);

select is(
  (
    select array_agg(to_char(core_start_at at time zone 'America/Sao_Paulo', 'HH24:MI') order by core_start_at)
    from public.list_available_slots_for_duration_without_google_sync_gate(
      '98300000-0000-0000-0000-000000000010',
      '98300000-0000-0000-0000-000000000020',
      null, '[]'::jsonb, 1, '2030-01-05'::date, null
    )
  ),
  array['10:00','11:30','14:00','17:00','18:30']::text[],
  'existing resource conflict filter removes only the overlapping candidate after grid generation'
);

select is(
  (select slot_interval_minutes from public.services where id = '98300000-0000-0000-0000-000000000012'),
  30,
  'service without explicit slot cadence defaults to 30 minutes'
);

select is(
  (
    select array_agg(to_char(core_start_at at time zone 'America/Sao_Paulo', 'HH24:MI') order by core_start_at)
    from public.list_available_slots_without_google_sync_gate(
      '98300000-0000-0000-0000-000000000012',
      '98300000-0000-0000-0000-000000000022',
      '[]'::jsonb, 1, '2030-01-05'::date, null
    )
  ),
  array['08:30','09:00','09:30']::text[],
  'service default 30 wins even when its availability rule carries another cadence'
);

select ok(
  pg_get_functiondef('public.list_available_slots_without_google_sync_gate(uuid,uuid,jsonb,integer,date,text)'::regprocedure)
    like '%checkout_holds%'
  and pg_get_functiondef('public.list_available_slots_for_duration_without_google_sync_gate(uuid,uuid,integer,jsonb,integer,date,text)'::regprocedure)
    like '%hold_expires_at%'
  and pg_get_functiondef('public.list_available_slots_for_duration_without_google_sync_gate(uuid,uuid,integer,jsonb,integer,date,text)'::regprocedure)
    like '%resource_allocations%',
  'hold, conflict and resource filters remain in the two core availability functions'
);

select ok(
  pg_get_functiondef('public.list_available_slots_without_google_sync_gate(uuid,uuid,jsonb,integer,date,text)'::regprocedure)
    like '%where ar.service_employee_id = p_service_employee_id%'
  and pg_get_functiondef('public.list_available_slots_for_duration_without_google_sync_gate(uuid,uuid,integer,jsonb,integer,date,text)'::regprocedure)
    like '%where ar.service_employee_id = p_service_employee_id%',
  'candidate source remains scoped to the selected employee+service pair in both core functions'
);

select * from finish();
rollback;
