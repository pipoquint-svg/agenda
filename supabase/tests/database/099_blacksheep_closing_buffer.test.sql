begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(2);

insert into public.resources (id, name, resource_type)
values ('29900000-0000-0000-0000-000000000001', 'CLOSING BUFFER TEST STUDIO', 'PHYSICAL');

insert into public.employees (id, name)
values ('29900000-0000-0000-0000-000000000010', 'Closing Buffer Employee');

insert into public.categories (id, name, slug)
values ('29900000-0000-0000-0000-000000000020', 'Closing Buffer', 'closing-buffer-test');

insert into public.services (
  id, category_id, name, slug, base_duration_minutes, buffer_after_minutes,
  base_price, minimum_people, maximum_people, maximum_booking_horizon_days
) values (
  '29900000-0000-0000-0000-000000000030',
  '29900000-0000-0000-0000-000000000020',
  'Closing Buffer Service',
  'closing-buffer-service',
  60,
  30,
  100.00,
  1,
  10,
  5000
);

insert into public.service_employees (id, service_id, employee_id)
values (
  '29900000-0000-0000-0000-000000000040',
  '29900000-0000-0000-0000-000000000030',
  '29900000-0000-0000-0000-000000000010'
);

insert into public.service_resources (service_id, resource_id, is_required)
values (
  '29900000-0000-0000-0000-000000000030',
  '29900000-0000-0000-0000-000000000001',
  true
);

insert into public.availability_rules (
  service_employee_id, weekday, start_local_time, end_local_time, slot_interval_minutes
) values (
  '29900000-0000-0000-0000-000000000040',
  1,
  '09:00',
  '22:00',
  30
);

insert into public.resource_availability_rules (
  resource_id, weekday, start_local_time, end_local_time
) values (
  '29900000-0000-0000-0000-000000000001',
  1,
  '09:00',
  '22:30'
);

select ok(
  exists (
    select 1
    from public.list_available_slots(
      '29900000-0000-0000-0000-000000000030',
      '29900000-0000-0000-0000-000000000040',
      '[]'::jsonb,
      1,
      '2035-01-15'::date,
      null
    )
    where core_start_at = '2035-01-15 21:00:00-03'::timestamptz
      and core_end_at = '2035-01-15 22:00:00-03'::timestamptz
      and slot_end_at = '2035-01-15 22:30:00-03'::timestamptz
      and post_service_minutes = 30
  ),
  'service may end exactly at 22:00 while hidden post-buffer occupies resource until 22:30'
);

select ok(
  not exists (
    select 1
    from public.list_available_slots(
      '29900000-0000-0000-0000-000000000030',
      '29900000-0000-0000-0000-000000000040',
      '[]'::jsonb,
      1,
      '2035-01-15'::date,
      null
    )
    where core_start_at = '2035-01-15 21:30:00-03'::timestamptz
  ),
  'client-facing contracted time may not extend past the 22:00 service closing time'
);

select * from finish();
rollback;
