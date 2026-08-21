begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(7);

insert into public.resources (id, name, resource_type)
values ('20000000-0000-0000-0000-000000000001', 'AVAIL TEST STUDIO', 'PHYSICAL');

insert into public.employees (id, name)
values ('20000000-0000-0000-0000-000000000010', 'Availability Employee');

insert into public.categories (id, name, slug)
values ('20000000-0000-0000-0000-000000000020', 'Availability', 'availability-test');

insert into public.services (
  id, category_id, name, slug, base_duration_minutes, base_price,
  minimum_people, maximum_people, maximum_booking_horizon_days
) values (
  '20000000-0000-0000-0000-000000000030',
  '20000000-0000-0000-0000-000000000020',
  'Availability Service',
  'availability-service',
  60,
  100.00,
  1,
  10,
  5000
);

insert into public.service_employees (id, service_id, employee_id)
values (
  '20000000-0000-0000-0000-000000000040',
  '20000000-0000-0000-0000-000000000030',
  '20000000-0000-0000-0000-000000000010'
);

insert into public.service_resources (service_id, resource_id)
values (
  '20000000-0000-0000-0000-000000000030',
  '20000000-0000-0000-0000-000000000001'
);

insert into public.availability_rules (
  service_employee_id, weekday, start_local_time, end_local_time, slot_interval_minutes
) values (
  '20000000-0000-0000-0000-000000000040',
  1,
  '09:00',
  '12:00',
  30
);

select is(
  (select count(*)::integer
   from public.list_available_slots(
     '20000000-0000-0000-0000-000000000030',
     '20000000-0000-0000-0000-000000000040',
     '[]'::jsonb,
     1,
     '2035-01-15'::date,
     null
   )),
  5,
  '09:00-12:00 with 60-minute service and 30-minute grid yields five slots'
);

insert into public.resource_allocations (
  resource_id, allocation_type, status, occupied_range, reason
) values (
  '20000000-0000-0000-0000-000000000001',
  'MANUAL_BLOCK',
  'BLOCKED',
  tstzrange('2035-01-15 10:00:00-03'::timestamptz, '2035-01-15 11:00:00-03'::timestamptz, '[)'),
  'Availability test block'
);

select is(
  (select count(*)::integer
   from public.list_available_slots(
     '20000000-0000-0000-0000-000000000030',
     '20000000-0000-0000-0000-000000000040',
     '[]'::jsonb,
     1,
     '2035-01-15'::date,
     null
   )),
  2,
  'blocking allocation removes every overlapping candidate while preserving boundary slots'
);

select ok(
  exists (
    select 1
    from public.list_available_slots(
      '20000000-0000-0000-0000-000000000030',
      '20000000-0000-0000-0000-000000000040',
      '[]'::jsonb,
      1,
      '2035-01-15'::date,
      null
    )
    where slot_start_at = '2035-01-15 09:00:00-03'::timestamptz
  ),
  '[start,end) allows a slot ending exactly when a block begins'
);

create temporary table created_hold as
select public.create_checkout_hold(
  '20000000-0000-0000-0000-000000000030',
  '20000000-0000-0000-0000-000000000040',
  '[]'::jsonb,
  1,
  '2035-01-15 09:00:00-03'::timestamptz
) as payload;

select is(
  (select payload->>'status' from created_hold),
  'ACTIVE',
  'choosing a slot creates an active checkout hold'
);

select is(
  (select count(*)::integer
   from public.resource_allocations ra
   join public.checkout_holds ch on ch.id = ra.checkout_hold_id
   where ch.id = ((select payload->>'checkout_hold_id' from created_hold))::uuid
     and ra.allocation_type = 'CHECKOUT_HOLD'
     and ra.status = 'HELD'),
  1,
  'checkout hold occupies required resource through resource_allocations'
);

select throws_ok(
  $$
    select public.create_checkout_hold(
      '20000000-0000-0000-0000-000000000030',
      '20000000-0000-0000-0000-000000000040',
      '[]'::jsonb,
      1,
      '2035-01-15 09:00:00-03'::timestamptz
    )
  $$,
  'P0001',
  'SLOT_NO_LONGER_AVAILABLE',
  'second checkout hold for same resource/slot is rejected'
);

update public.checkout_holds
set created_at = now() - interval '2 minutes',
    expires_at = now() - interval '1 minute'
where id = ((select payload->>'checkout_hold_id' from created_hold))::uuid;

select public.expire_due_checkout_holds();

select ok(
  exists (
    select 1
    from public.checkout_holds ch
    join public.resource_allocations ra on ra.checkout_hold_id = ch.id
    where ch.id = ((select payload->>'checkout_hold_id' from created_hold))::uuid
      and ch.status = 'EXPIRED'
      and ra.status = 'EXPIRED'
  ),
  'expired checkout hold releases its allocation from blocking status'
);

select * from finish();
rollback;
