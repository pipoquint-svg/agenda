begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
set local agenda.test_now = '2035-01-01 00:00:00-03';

select plan(7);

insert into public.employees (id, name)
values ('29000000-0000-0000-0000-000000000010', 'Monthly Availability Employee');

insert into public.categories (id, name, slug)
values ('29000000-0000-0000-0000-000000000020', 'Monthly Availability', 'monthly-availability-test');

insert into public.services (
  id, category_id, name, slug, base_duration_minutes, base_price,
  minimum_people, maximum_people, maximum_booking_horizon_days,
  duration_mode, slot_interval_minutes, public_minimum_booking_notice_hours
) values (
  '29000000-0000-0000-0000-000000000030',
  '29000000-0000-0000-0000-000000000020',
  'Monthly Availability Service',
  'monthly-availability-service',
  60,
  100.00,
  1,
  10,
  5000,
  'FIXED',
  30,
  0
);

insert into public.service_employees (id, service_id, employee_id)
values (
  '29000000-0000-0000-0000-000000000040',
  '29000000-0000-0000-0000-000000000030',
  '29000000-0000-0000-0000-000000000010'
);

insert into public.availability_rules (
  service_employee_id, weekday, start_local_time, end_local_time, slot_interval_minutes
) values (
  '29000000-0000-0000-0000-000000000040',
  1,
  '09:00',
  '12:00',
  30
);

insert into public.booking_pages (
  id, slug, display_name, title, brand_key
) values (
  '29000000-0000-0000-0000-000000000050',
  'monthly-fast-path-test',
  'Monthly Fast Path Test',
  'Monthly Fast Path Test',
  'BLACKSHEEP'
);

insert into public.booking_page_services (booking_page_id, service_id)
values (
  '29000000-0000-0000-0000-000000000050',
  '29000000-0000-0000-0000-000000000030'
);

select is(
  agenda_public_bridge.has_available_slot_for_duration_impl(
    '29000000-0000-0000-0000-000000000030',
    '29000000-0000-0000-0000-000000000040',
    null,
    '[]'::jsonb,
    1,
    '2035-01-01'::date,
    null
  ),
  exists (
    select 1
    from public.list_available_slots_for_duration(
      '29000000-0000-0000-0000-000000000030',
      '29000000-0000-0000-0000-000000000040',
      null,
      '[]'::jsonb,
      1,
      '2035-01-01'::date,
      null::text
    )
  ),
  'fast path matches authoritative daily availability on an open day'
);

select ok(
  agenda_public_bridge.has_available_slot_for_duration_impl(
    '29000000-0000-0000-0000-000000000030',
    '29000000-0000-0000-0000-000000000040',
    null,
    '[]'::jsonb,
    1,
    '2035-01-01'::date,
    null
  ),
  'open Monday has at least one slot'
);

select is(
  agenda_public_bridge.has_available_slot_for_duration_impl(
    '29000000-0000-0000-0000-000000000030',
    '29000000-0000-0000-0000-000000000040',
    null,
    '[]'::jsonb,
    1,
    '2035-01-02'::date,
    null
  ),
  exists (
    select 1
    from public.list_available_slots_for_duration(
      '29000000-0000-0000-0000-000000000030',
      '29000000-0000-0000-0000-000000000040',
      null,
      '[]'::jsonb,
      1,
      '2035-01-02'::date,
      null::text
    )
  ),
  'fast path matches authoritative daily availability on a closed weekday'
);

select is(
  agenda_public_bridge.has_available_slot_for_duration_impl(
    '29000000-0000-0000-0000-000000000030',
    '29000000-0000-0000-0000-000000000040',
    null,
    '[]'::jsonb,
    1,
    '2035-01-01'::date,
    '2035-01-01 11:00:01-03'::timestamptz
  ),
  exists (
    select 1
    from public.list_available_slots_for_duration(
      '29000000-0000-0000-0000-000000000030',
      '29000000-0000-0000-0000-000000000040',
      null,
      '[]'::jsonb,
      1,
      '2035-01-01'::date,
      null::text
    ) s
    where s.slot_start_at >= '2035-01-01 11:00:01-03'::timestamptz
  ),
  'fast path preserves the public earliest-slot cutoff semantics'
);

insert into public.availability_exceptions (
  service_employee_id, exception_type, start_at, end_at, reason
) values (
  '29000000-0000-0000-0000-000000000040',
  'BLOCK',
  '2035-01-15 09:00:00-03'::timestamptz,
  '2035-01-15 12:00:00-03'::timestamptz,
  'Monthly availability parity block'
);

select is(
  agenda_public_bridge.has_available_slot_for_duration_impl(
    '29000000-0000-0000-0000-000000000030',
    '29000000-0000-0000-0000-000000000040',
    null,
    '[]'::jsonb,
    1,
    '2035-01-15'::date,
    null
  ),
  exists (
    select 1
    from public.list_available_slots_for_duration(
      '29000000-0000-0000-0000-000000000030',
      '29000000-0000-0000-0000-000000000040',
      null,
      '[]'::jsonb,
      1,
      '2035-01-15'::date,
      null::text
    )
  ),
  'fast path matches the authoritative daily result after a full service-employee block'
);

select ok(
  not agenda_public_bridge.has_available_slot_for_duration_impl(
    '29000000-0000-0000-0000-000000000030',
    '29000000-0000-0000-0000-000000000040',
    null,
    '[]'::jsonb,
    1,
    '2035-01-15'::date,
    null
  ),
  'full service-employee block closes the day'
);

select is(
  (
    select array_agg(d.local_date order by d.local_date)
    from public.public_list_available_dates_month(
      'monthly-fast-path-test',
      '29000000-0000-0000-0000-000000000030',
      '29000000-0000-0000-0000-000000000040',
      60,
      '[]'::jsonb,
      1,
      '2035-01-01'::date
    ) d
  ),
  (
    select array_agg(day::date order by day::date)
    from generate_series('2035-01-01'::date, '2035-01-31'::date, interval '1 day') day
    where exists (
      select 1
      from public.list_available_slots_for_duration(
        '29000000-0000-0000-0000-000000000030',
        '29000000-0000-0000-0000-000000000040',
        null,
        '[]'::jsonb,
        1,
        day::date,
        null::text
      )
    )
  ),
  'monthly public contract returns exactly the dates produced by authoritative daily availability'
);

select * from finish();
rollback;
