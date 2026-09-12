begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(10);

select ok(
  to_regprocedure('public.public_list_available_slots_range(text,uuid,uuid,date,date,jsonb,integer,integer)') is not null,
  'public bounded slot-range lookup exists'
);

select ok(
  to_regprocedure('agenda_public_bridge.list_available_slots_range_impl(text,uuid,uuid,date,date,jsonb,integer,integer)') is not null,
  'private bridge implementation exists'
);

select is(
  (
    select p.prosecdef
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'public_list_available_slots_range'
      and pg_get_function_identity_arguments(p.oid) = 'p_booking_page_slug text, p_service_id uuid, p_service_employee_id uuid, p_start_date date, p_end_date date, p_extra_selections jsonb, p_people_count integer, p_limit integer'
  ),
  false,
  'public wrapper is security invoker'
);

select is(
  (
    select p.prosecdef
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'agenda_public_bridge'
      and p.proname = 'list_available_slots_range_impl'
      and pg_get_function_identity_arguments(p.oid) = 'p_booking_page_slug text, p_service_id uuid, p_service_employee_id uuid, p_start_date date, p_end_date date, p_extra_selections jsonb, p_people_count integer, p_limit integer'
  ),
  true,
  'bridge implementation is security definer'
);

select ok(
  has_function_privilege(
    'anon',
    'public.public_list_available_slots_range(text,uuid,uuid,date,date,jsonb,integer,integer)',
    'EXECUTE'
  ),
  'anon can execute the validated public wrapper'
);

select ok(
  has_function_privilege(
    'authenticated',
    'public.public_list_available_slots_range(text,uuid,uuid,date,date,jsonb,integer,integer)',
    'EXECUTE'
  ),
  'authenticated can execute the validated public wrapper'
);

select throws_ok(
  $$
    select *
    from public.public_list_available_slots_range(
      'invalid', null::uuid, null::uuid,
      date '2026-09-12', date '2026-09-11',
      '[]'::jsonb, 1, 5
    )
  $$,
  '22023',
  'DATE_RANGE_INVALID',
  'inverted date ranges fail before any availability lookup'
);

select throws_ok(
  $$
    select *
    from public.public_list_available_slots_range(
      'invalid', null::uuid, null::uuid,
      date '2026-09-01', date '2026-11-03',
      '[]'::jsonb, 1, 5
    )
  $$,
  '22023',
  'DATE_RANGE_TOO_WIDE',
  'public range lookup is capped at 62 days'
);

select throws_ok(
  $$
    select *
    from public.public_list_available_slots_range(
      'invalid', null::uuid, null::uuid,
      date '2026-09-11', date '2026-09-12',
      '[]'::jsonb, 1, 0
    )
  $$,
  '22023',
  'LIMIT_INVALID',
  'zero result limit is rejected'
);

select throws_ok(
  $$
    select *
    from public.public_list_available_slots_range(
      'invalid', null::uuid, null::uuid,
      date '2026-09-11', date '2026-09-12',
      '[]'::jsonb, 1, 11
    )
  $$,
  '22023',
  'LIMIT_INVALID',
  'result limit above ten is rejected'
);

select * from finish();
rollback;
