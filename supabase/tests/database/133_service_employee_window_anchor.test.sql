begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(21);

insert into public.categories(id, name, slug)
values ('98600000-0000-0000-0000-000000000001', 'Service Employee Anchor Test', 'service-employee-anchor-test');

insert into public.resources(id, name, resource_type)
values
  ('98600000-0000-0000-0000-000000000002', 'ANCHOR TEST PERSON', 'PERSON'),
  ('98600000-0000-0000-0000-000000000003', 'ANCHOR TEST SPACE', 'PHYSICAL'),
  ('98600000-0000-0000-0000-000000000004', 'LOCACAO ANCHOR SPACE', 'PHYSICAL'),
  ('98600000-0000-0000-0000-000000000005', 'LOCACAO ANCHOR PERSON', 'PERSON');

insert into public.employees(id, name, resource_id)
values
  ('98600000-0000-0000-0000-000000000006', 'Same Employee Two Services', '98600000-0000-0000-0000-000000000002'),
  ('98600000-0000-0000-0000-000000000007', 'Locacao Regression Employee', '98600000-0000-0000-0000-000000000005');

insert into public.services(
  id, category_id, name, slug, base_duration_minutes, base_price,
  buffer_before_minutes, buffer_after_minutes,
  minimum_people, maximum_people, minimum_booking_notice_minutes,
  maximum_booking_horizon_days, slot_interval_minutes
) values
(
  '98600000-0000-0000-0000-000000000010',
  '98600000-0000-0000-0000-000000000001',
  'Anchor Service A', 'anchor-service-a',
  60, 100, 0, 0, 1, 10, 0, 5000, 90
),
(
  '98600000-0000-0000-0000-000000000011',
  '98600000-0000-0000-0000-000000000001',
  'Anchor Service B', 'anchor-service-b',
  60, 100, 0, 0, 1, 10, 0, 5000, 30
);

insert into public.services(
  id, category_id, name, slug, base_duration_minutes, base_price,
  buffer_before_minutes, buffer_after_minutes,
  minimum_people, maximum_people, minimum_booking_notice_minutes,
  maximum_booking_horizon_days
) values (
  '98600000-0000-0000-0000-000000000012',
  '98600000-0000-0000-0000-000000000001',
  'Default Cadence Service', 'default-cadence-service',
  60, 100, 0, 0, 1, 10, 0, 5000
);

insert into public.services(
  id, category_id, name, slug,
  base_duration_minutes, base_price,
  buffer_before_minutes, buffer_after_minutes,
  minimum_people, maximum_people, minimum_booking_notice_minutes,
  maximum_booking_horizon_days,
  duration_mode, booking_block_minutes,
  minimum_booking_blocks, maximum_booking_blocks, price_per_block,
  slot_interval_minutes
) values (
  '98600000-0000-0000-0000-000000000013',
  '98600000-0000-0000-0000-000000000001',
  'Locação do estúdio Anchor Regression', 'locacao-anchor-regression',
  30, 90, 0, 30, 1, 20, 0, 5000,
  'BLOCKS', 30, 2, 12, 90, 30
);

insert into public.service_employees(id, service_id, employee_id)
values
  ('98600000-0000-0000-0000-000000000020', '98600000-0000-0000-0000-000000000010', '98600000-0000-0000-0000-000000000006'),
  ('98600000-0000-0000-0000-000000000021', '98600000-0000-0000-0000-000000000011', '98600000-0000-0000-0000-000000000006'),
  ('98600000-0000-0000-0000-000000000022', '98600000-0000-0000-0000-000000000013', '98600000-0000-0000-0000-000000000007');

insert into public.service_resources(service_id, resource_id, is_required)
values
  ('98600000-0000-0000-0000-000000000010', '98600000-0000-0000-0000-000000000003', true),
  ('98600000-0000-0000-0000-000000000013', '98600000-0000-0000-0000-000000000004', true);

-- 2030-01-01 is Tuesday (weekday=2).
-- Rule cadence values intentionally differ from service cadence to prove that
-- availability_rules.slot_interval_minutes no longer commands candidate starts.
insert into public.availability_rules(
  service_employee_id, weekday, start_local_time, end_local_time, slot_interval_minutes
) values
  ('98600000-0000-0000-0000-000000000020', 2, '08:30', '13:00', 30),
  ('98600000-0000-0000-0000-000000000020', 2, '14:00', '20:00', 30),
  ('98600000-0000-0000-0000-000000000021', 2, '09:15', '12:15', 60),
  ('98600000-0000-0000-0000-000000000022', 2, '08:00', '14:00', 60);

insert into public.resource_availability_rules(resource_id, weekday, start_local_time, end_local_time)
values
  ('98600000-0000-0000-0000-000000000003', 2, '08:00', '22:00'),
  ('98600000-0000-0000-0000-000000000004', 2, '08:00', '14:30');

select is(
  (select slot_interval_minutes from public.services where id = '98600000-0000-0000-0000-000000000012'),
  30,
  'service without explicit cadence defaults to 30 minutes'
);

select is(
  (select slot_interval_minutes from public.services where id = '98600000-0000-0000-0000-000000000010'),
  90,
  'service cadence is stored on services, independently from availability-rule cadence'
);

select is(
  (
    select array_agg(to_char(core_start_at at time zone 'America/Sao_Paulo', 'HH24:MI') order by core_start_at)
    from public.list_available_slots_without_google_sync_gate(
      '98600000-0000-0000-0000-000000000010',
      '98600000-0000-0000-0000-000000000020',
      '[]'::jsonb, 1, '2030-01-01'::date, null
    )
    where (core_start_at at time zone 'America/Sao_Paulo')::time < '13:00'::time
  ),
  array['08:30','10:00','11:30']::text[],
  '08:30-13:00 employee/service range anchors 90-minute cadence at 08:30'
);

select is(
  (
    select array_agg(to_char(core_start_at at time zone 'America/Sao_Paulo', 'HH24:MI') order by core_start_at)
    from public.list_available_slots_without_google_sync_gate(
      '98600000-0000-0000-0000-000000000010',
      '98600000-0000-0000-0000-000000000020',
      '[]'::jsonb, 1, '2030-01-01'::date, null
    )
    where (core_start_at at time zone 'America/Sao_Paulo')::time >= '14:00'::time
  ),
  array['14:00','15:30','17:00','18:30']::text[],
  '14:00-20:00 employee/service range restarts 90-minute cadence independently at 14:00'
);

select is(
  (
    select array_agg(to_char(core_start_at at time zone 'America/Sao_Paulo', 'HH24:MI') order by core_start_at)
    from public.list_available_slots_without_google_sync_gate(
      '98600000-0000-0000-0000-000000000011',
      '98600000-0000-0000-0000-000000000021',
      '[]'::jsonb, 1, '2030-01-01'::date, null
    )
  ),
  array['09:15','09:45','10:15','10:45','11:15']::text[],
  'same employee with another service uses only that service_employee journey and its service cadence'
);

select ok(
  not exists (
    select 1
    from public.list_available_slots_without_google_sync_gate(
      '98600000-0000-0000-0000-000000000011',
      '98600000-0000-0000-0000-000000000021',
      '[]'::jsonb, 1, '2030-01-01'::date, null
    ) s
    where to_char(s.core_start_at at time zone 'America/Sao_Paulo','HH24:MI') in ('08:30','14:00')
  ),
  'ranges from another service assigned to the same employee never leak into this grid'
);

insert into public.availability_exceptions(service_employee_id, exception_type, start_at, end_at, reason)
values (
  '98600000-0000-0000-0000-000000000020', 'OPEN',
  '2030-01-01 08:30:00-03'::timestamptz,
  '2030-01-01 11:30:00-03'::timestamptz,
  'overlap dedupe regression'
);

select is(
  (
    select count(*)::integer
    from public.list_available_slots_without_google_sync_gate(
      '98600000-0000-0000-0000-000000000010',
      '98600000-0000-0000-0000-000000000020',
      '[]'::jsonb, 1, '2030-01-01'::date, null
    ) s
    where s.core_start_at = '2030-01-01 08:30:00-03'::timestamptz
  ),
  1,
  'overlapping employee/service OPEN exception does not duplicate a weekly candidate'
);

select is(
  (
    select count(*)::integer
    from public.list_available_slots_without_google_sync_gate(
      '98600000-0000-0000-0000-000000000010',
      '98600000-0000-0000-0000-000000000020',
      '[]'::jsonb, 1, '2030-01-01'::date, null
    )
  ),
  7,
  'overlapping OPEN exception leaves the seven expected candidates unchanged'
);

select ok(
  exists (
    select 1
    from public.list_available_slots_without_google_sync_gate(
      '98600000-0000-0000-0000-000000000010',
      '98600000-0000-0000-0000-000000000020',
      '[]'::jsonb, 1, '2030-01-01'::date, null
    ) s
    where s.core_start_at = '2030-01-01 08:30:00-03'::timestamptz
  ),
  'space open from 08:00 lets the employee/service 08:30 anchor through without shifting it'
);

update public.resource_availability_rules
set start_local_time = '09:00'
where resource_id = '98600000-0000-0000-0000-000000000003'
  and weekday = 2;

select is(
  (
    select array_agg(to_char(core_start_at at time zone 'America/Sao_Paulo', 'HH24:MI') order by core_start_at)
    from public.list_available_slots_without_google_sync_gate(
      '98600000-0000-0000-0000-000000000010',
      '98600000-0000-0000-0000-000000000020',
      '[]'::jsonb, 1, '2030-01-01'::date, null
    )
  ),
  array['10:00','11:30','14:00','15:30','17:00','18:30']::text[],
  'space opening at 09:00 filters 08:30 only; it does not reanchor the remaining employee/service cadence'
);

update public.resource_availability_rules
set start_local_time = '08:00'
where resource_id = '98600000-0000-0000-0000-000000000003'
  and weekday = 2;

insert into public.resource_allocations(resource_id, allocation_type, status, occupied_range, reason)
values (
  '98600000-0000-0000-0000-000000000003',
  'MANUAL_BLOCK', 'BLOCKED',
  tstzrange('2030-01-01 10:00:00-03','2030-01-01 11:00:00-03','[)'),
  'conflict regression'
);

select is(
  (
    select array_agg(to_char(core_start_at at time zone 'America/Sao_Paulo', 'HH24:MI') order by core_start_at)
    from public.list_available_slots_without_google_sync_gate(
      '98600000-0000-0000-0000-000000000010',
      '98600000-0000-0000-0000-000000000020',
      '[]'::jsonb, 1, '2030-01-01'::date, null
    )
  ),
  array['08:30','11:30','14:00','15:30','17:00','18:30']::text[],
  'existing conflict filtering removes the conflicting candidate without changing grid cadence'
);

delete from public.resource_allocations
where resource_id = '98600000-0000-0000-0000-000000000003'
  and reason = 'conflict regression';

select lives_ok(
  $$ select public.create_checkout_hold(
    '98600000-0000-0000-0000-000000000010',
    '98600000-0000-0000-0000-000000000020',
    '[]'::jsonb,
    1,
    '2030-01-01 10:00:00-03'::timestamptz
  ) $$,
  'existing checkout-hold path still accepts a valid anchored candidate'
);

select is(
  (
    select array_agg(to_char(core_start_at at time zone 'America/Sao_Paulo', 'HH24:MI') order by core_start_at)
    from public.list_available_slots_without_google_sync_gate(
      '98600000-0000-0000-0000-000000000010',
      '98600000-0000-0000-0000-000000000020',
      '[]'::jsonb, 1, '2030-01-01'::date, null
    )
  ),
  array['08:30','11:30','14:00','15:30','17:00','18:30']::text[],
  'active checkout hold excludes exactly the held candidate and does not alter neighboring anchors'
);

select is(
  (
    select array_agg(to_char(core_start_at at time zone 'America/Sao_Paulo', 'HH24:MI') order by core_start_at)
    from public.list_available_slots_for_duration_without_google_sync_gate(
      '98600000-0000-0000-0000-000000000013',
      '98600000-0000-0000-0000-000000000022',
      8, '[]'::jsonb, 1, '2030-01-01'::date, null
    )
  ),
  array['08:00','08:30','09:00','09:30','10:00']::text[],
  'Locação-style 30-minute grid remains identical even when availability-rule legacy cadence is 60'
);

select throws_ok(
  $$ update public.services set slot_interval_minutes = 45 where id = '98600000-0000-0000-0000-000000000010' $$,
  '23514',
  null,
  'service cadence rejects values outside 30-minute increments'
);

select ok(
  (select pg_get_functiondef('public.list_available_slots_without_google_sync_gate(uuid,uuid,jsonb,integer,date,text)'::regprocedure))
    like '%coalesce(v_service.slot_interval_minutes, 30)%',
  'fixed-duration candidate cadence is sourced from the service with 30-minute fallback'
);

select ok(
  (select pg_get_functiondef('public.list_available_slots_for_duration_without_google_sync_gate(uuid,uuid,integer,jsonb,integer,date,text)'::regprocedure))
    like '%coalesce(v_service.slot_interval_minutes, 30)%',
  'block-duration candidate cadence is sourced from the service with 30-minute fallback'
);

select ok(
  (select pg_get_functiondef('public.list_available_slots_without_google_sync_gate(uuid,uuid,jsonb,integer,date,text)'::regprocedure))
    like '%where ar.service_employee_id = p_service_employee_id%'
  and (select pg_get_functiondef('public.list_available_slots_without_google_sync_gate(uuid,uuid,jsonb,integer,date,text)'::regprocedure))
    like '%resource_availability_rules%'
  and (select pg_get_functiondef('public.list_available_slots_without_google_sync_gate(uuid,uuid,jsonb,integer,date,text)'::regprocedure))
    like '%resource_allocations%',
  'fixed-duration function still scopes series to service_employee and preserves downstream resource/conflict filters'
);

select ok(
  (select pg_get_functiondef('public.list_available_slots_for_duration_without_google_sync_gate(uuid,uuid,integer,jsonb,integer,date,text)'::regprocedure))
    like '%where ar.service_employee_id = p_service_employee_id%'
  and (select pg_get_functiondef('public.list_available_slots_for_duration_without_google_sync_gate(uuid,uuid,integer,jsonb,integer,date,text)'::regprocedure))
    like '%resource_availability_rules%'
  and (select pg_get_functiondef('public.list_available_slots_for_duration_without_google_sync_gate(uuid,uuid,integer,jsonb,integer,date,text)'::regprocedure))
    like '%hold_expires_at%',
  'block-duration function preserves service_employee scope, resource filters and existing hold semantics'
);

select ok(
  (select pg_get_functiondef('public.list_available_slots(uuid,uuid,jsonb,integer,date,text)'::regprocedure))
    like '%list_available_slots_without_google_sync_gate%',
  'public fixed-duration wrapper signature/dispatch remains unchanged'
);

select ok(
  (select pg_get_functiondef('public.list_available_slots_for_duration(uuid,uuid,integer,jsonb,integer,date,text)'::regprocedure))
    like '%list_available_slots_for_duration_without_google_sync_gate%',
  'public block-duration wrapper signature/dispatch remains unchanged'
);

select ok(
  (select count(*) from public.availability_rules where service_employee_id='98600000-0000-0000-0000-000000000020') = 2
  and (select count(*) from public.availability_rules where service_employee_id='98600000-0000-0000-0000-000000000021') = 1,
  'one employee can retain independent journeys for different services'
);

select is(
  (select slot_interval_minutes from public.services where id='98600000-0000-0000-0000-000000000013'),
  30,
  'Locação regression service keeps 30-minute cadence'
);

select * from finish();
rollback;
