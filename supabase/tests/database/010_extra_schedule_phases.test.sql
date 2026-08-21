begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(13);

insert into public.resources (id, name, resource_type)
values
  ('91000000-0000-0000-0000-000000000001', 'PHASE Sabrina', 'PERSON'),
  ('91000000-0000-0000-0000-000000000002', 'PHASE Studio', 'PHYSICAL'),
  ('91000000-0000-0000-0000-000000000003', 'PHASE Makeup Artist', 'PERSON');

insert into public.employees (id, name, resource_id)
values (
  '91000000-0000-0000-0000-000000000010',
  'Phase Sabrina Employee',
  '91000000-0000-0000-0000-000000000001'
);

insert into public.categories (id, name, slug)
values ('91000000-0000-0000-0000-000000000020', 'Phase Test', 'phase-test');

insert into public.services (
  id, category_id, name, slug, base_duration_minutes, base_price,
  minimum_people, maximum_people, maximum_booking_horizon_days
) values (
  '91000000-0000-0000-0000-000000000030',
  '91000000-0000-0000-0000-000000000020',
  'Ensaio Sabrina Phase Test',
  'ensaio-sabrina-phase-test',
  60,
  100.00,
  1,
  10,
  5000
);

insert into public.service_employees (id, service_id, employee_id)
values (
  '91000000-0000-0000-0000-000000000040',
  '91000000-0000-0000-0000-000000000030',
  '91000000-0000-0000-0000-000000000010'
);

insert into public.service_resources (service_id, resource_id)
values
  ('91000000-0000-0000-0000-000000000030', '91000000-0000-0000-0000-000000000001'),
  ('91000000-0000-0000-0000-000000000030', '91000000-0000-0000-0000-000000000002');

insert into public.availability_rules (
  service_employee_id, weekday, start_local_time, end_local_time, slot_interval_minutes
) values
  ('91000000-0000-0000-0000-000000000040', 1, '09:00', '10:00', 30),
  ('91000000-0000-0000-0000-000000000040', 1, '14:00', '15:00', 30);

insert into public.resource_availability_rules (
  resource_id, weekday, start_local_time, end_local_time
) values
  ('91000000-0000-0000-0000-000000000001', 1, '09:00', '15:00'),
  ('91000000-0000-0000-0000-000000000002', 1, '07:00', '15:00'),
  ('91000000-0000-0000-0000-000000000003', 1, '07:00', '14:00');

insert into public.extras (id, name, price, duration_delta_minutes)
values
  ('91000000-0000-0000-0000-000000000050', 'Maquiagem Phase', 190.00, 60),
  ('91000000-0000-0000-0000-000000000051', 'Maquiagem + Cabelo Phase', 290.00, 90);

insert into public.service_extras (
  service_id, extra_id, sort_order, schedule_placement, default_schedule_minutes
) values
  ('91000000-0000-0000-0000-000000000030', '91000000-0000-0000-0000-000000000050', 10, 'PREPEND', 60),
  ('91000000-0000-0000-0000-000000000030', '91000000-0000-0000-0000-000000000051', 20, 'PREPEND', 90);

insert into public.extra_resources (extra_id, resource_id)
values
  ('91000000-0000-0000-0000-000000000050', '91000000-0000-0000-0000-000000000002'),
  ('91000000-0000-0000-0000-000000000050', '91000000-0000-0000-0000-000000000003'),
  ('91000000-0000-0000-0000-000000000051', '91000000-0000-0000-0000-000000000002'),
  ('91000000-0000-0000-0000-000000000051', '91000000-0000-0000-0000-000000000003');

insert into public.service_extra_schedule_rules (
  service_id, extra_id,
  days_of_week, anchor_start_local_time, anchor_end_local_time,
  schedule_placement, schedule_minutes, priority
) values (
  '91000000-0000-0000-0000-000000000030',
  '91000000-0000-0000-0000-000000000050',
  array[1]::smallint[],
  '14:00',
  '15:00',
  'PREPEND',
  30,
  10
);

insert into public.pricing_rules (
  service_id, name, rule_scope, days_of_week,
  start_local_time, end_local_time,
  action_type, amount, priority
) values (
  '91000000-0000-0000-0000-000000000030',
  'Before 9 surcharge should use core anchor',
  'DAY_TIME',
  array[1]::smallint[],
  '07:00',
  '09:00',
  'ADD_AMOUNT',
  50.00,
  10
);

select is(
  (select count(*)::integer
   from public.list_available_slots(
     '91000000-0000-0000-0000-000000000030',
     '91000000-0000-0000-0000-000000000040',
     '[]'::jsonb,
     1,
     '2035-01-15'::date,
     null
   )),
  2,
  'core availability exposes only the immutable 09:00 and 14:00 service anchors'
);

select ok(
  exists (
    select 1
    from public.list_available_slots(
      '91000000-0000-0000-0000-000000000030',
      '91000000-0000-0000-0000-000000000040',
      '[]'::jsonb, 1, '2035-01-15'::date, null
    )
    where slot_start_at = '2035-01-15 09:00:00-03'::timestamptz
      and core_start_at = '2035-01-15 09:00:00-03'::timestamptz
  ),
  'without prep extras visible start equals core start'
);

select is(
  (select count(*)::integer
   from public.list_available_slots(
     '91000000-0000-0000-0000-000000000030',
     '91000000-0000-0000-0000-000000000040',
     '[{"extra_id":"91000000-0000-0000-0000-000000000050","quantity":1}]'::jsonb,
     1, '2035-01-15'::date, null
   )),
  2,
  'selecting makeup preserves the two core anchors'
);

select ok(
  exists (
    select 1
    from public.list_available_slots(
      '91000000-0000-0000-0000-000000000030',
      '91000000-0000-0000-0000-000000000040',
      '[{"extra_id":"91000000-0000-0000-0000-000000000050","quantity":1}]'::jsonb,
      1, '2035-01-15'::date, null
    )
    where slot_start_at = '2035-01-15 08:00:00-03'::timestamptz
      and core_start_at = '2035-01-15 09:00:00-03'::timestamptz
      and pre_service_minutes = 60
  ),
  '09:00 core service becomes 08:00 customer arrival with 60-minute makeup prep'
);

select ok(
  exists (
    select 1
    from public.list_available_slots(
      '91000000-0000-0000-0000-000000000030',
      '91000000-0000-0000-0000-000000000040',
      '[{"extra_id":"91000000-0000-0000-0000-000000000050","quantity":1}]'::jsonb,
      1, '2035-01-15'::date, null
    )
    where slot_start_at = '2035-01-15 13:30:00-03'::timestamptz
      and core_start_at = '2035-01-15 14:00:00-03'::timestamptz
      and pre_service_minutes = 30
  ),
  '14:00 core service can override makeup prep to 30 minutes and show 13:30'
);

select ok(
  exists (
    select 1
    from public.list_available_slots(
      '91000000-0000-0000-0000-000000000030',
      '91000000-0000-0000-0000-000000000040',
      '[{"extra_id":"91000000-0000-0000-0000-000000000051","quantity":1}]'::jsonb,
      1, '2035-01-15'::date, null
    )
    where slot_start_at = '2035-01-15 07:30:00-03'::timestamptz
      and core_start_at = '2035-01-15 09:00:00-03'::timestamptz
      and pre_service_minutes = 90
  ),
  'makeup plus hair can prepend 90 minutes and show 07:30 for the 09:00 anchor'
);

select is(
  (select commercial_value
   from public.list_available_slots(
     '91000000-0000-0000-0000-000000000030',
     '91000000-0000-0000-0000-000000000040',
     '[{"extra_id":"91000000-0000-0000-0000-000000000050","quantity":1}]'::jsonb,
     1, '2035-01-15'::date, null
   )
   where slot_start_at = '2035-01-15 08:00:00-03'::timestamptz),
  290.00::numeric,
  'day/time pricing evaluates the 09:00 core anchor, not the earlier 08:00 prep arrival'
);

create temporary table phase_hold as
select public.create_checkout_hold(
  '91000000-0000-0000-0000-000000000030',
  '91000000-0000-0000-0000-000000000040',
  '[{"extra_id":"91000000-0000-0000-0000-000000000050","quantity":1}]'::jsonb,
  1,
  '2035-01-15 08:00:00-03'::timestamptz
) as payload;

select is(
  (select payload->>'status' from phase_hold),
  'ACTIVE',
  'customer-visible 08:00 time creates an active checkout hold'
);

select ok(
  exists (
    select 1
    from public.checkout_holds ch
    where ch.id = ((select payload->>'checkout_hold_id' from phase_hold))::uuid
      and ch.requested_start_at = '2035-01-15 08:00:00-03'::timestamptz
      and ch.core_start_at = '2035-01-15 09:00:00-03'::timestamptz
      and ch.requested_end_at = '2035-01-15 10:00:00-03'::timestamptz
      and ch.pre_service_minutes = 60
  ),
  'checkout hold stores customer envelope separately from the immutable core phase'
);

select ok(
  exists (
    select 1
    from public.resource_allocations ra
    join public.checkout_holds ch on ch.id = ra.checkout_hold_id
    where ch.id = ((select payload->>'checkout_hold_id' from phase_hold))::uuid
      and ra.resource_id = '91000000-0000-0000-0000-000000000001'
      and ra.occupied_range = tstzrange(
        '2035-01-15 09:00:00-03'::timestamptz,
        '2035-01-15 10:00:00-03'::timestamptz,
        '[)'
      )
  ),
  'Sabrina resource remains occupied only during the 09:00 core service when she is not an extra resource'
);

select ok(
  exists (
    select 1
    from public.resource_allocations ra
    join public.checkout_holds ch on ch.id = ra.checkout_hold_id
    where ch.id = ((select payload->>'checkout_hold_id' from phase_hold))::uuid
      and ra.resource_id = '91000000-0000-0000-0000-000000000002'
      and ra.occupied_range = tstzrange(
        '2035-01-15 08:00:00-03'::timestamptz,
        '2035-01-15 10:00:00-03'::timestamptz,
        '[)'
      )
  ),
  'studio resource merges prep and core phases into one protected interval'
);

select ok(
  exists (
    select 1
    from public.resource_allocations ra
    join public.checkout_holds ch on ch.id = ra.checkout_hold_id
    where ch.id = ((select payload->>'checkout_hold_id' from phase_hold))::uuid
      and ra.resource_id = '91000000-0000-0000-0000-000000000003'
      and ra.occupied_range = tstzrange(
        '2035-01-15 08:00:00-03'::timestamptz,
        '2035-01-15 09:00:00-03'::timestamptz,
        '[)'
      )
  ),
  'makeup resource is protected only in the prep phase'
);

insert into public.customers (id, name, email, phone)
values (
  '91000000-0000-0000-0000-000000000060',
  'Phase Customer',
  'phase@example.com',
  '+5548999999999'
);

create temporary table promoted_phase as
select public.promote_checkout_hold(
  ((select payload->>'checkout_hold_id' from phase_hold))::uuid,
  '91000000-0000-0000-0000-000000000060',
  null,
  '{}'::uuid[],
  '[]'::jsonb,
  '[]'::jsonb,
  null,
  null
) as payload;

select ok(
  exists (
    select 1
    from public.appointments a
    where a.id = ((select payload->>'appointment_id' from promoted_phase))::uuid
      and a.start_at = '2035-01-15 08:00:00-03'::timestamptz
      and a.core_start_at = '2035-01-15 09:00:00-03'::timestamptz
      and a.core_end_at = '2035-01-15 10:00:00-03'::timestamptz
      and a.pre_service_minutes = 60
  ),
  'promotion preserves both customer-visible start and core service anchor on the appointment'
);

select is(
  (select (payload->>'cash_due')::numeric from promoted_phase),
  290.00::numeric,
  'promotion keeps the quote based on the core anchor and selected extra'
);

select * from finish();
rollback;