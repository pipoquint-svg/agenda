begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(6);

create temporary table notice_clock as
with notice as (
  select (
    24
    + mod(
        12 - extract(hour from now() at time zone 'America/Sao_Paulo')::integer + 24,
        24
      )
  )::integer as notice_hours
)
select
  notice_hours,
  now() + make_interval(hours => notice_hours) as cutoff,
  now() + make_interval(hours => notice_hours) - interval '30 minutes' as pre_cutoff,
  now() + make_interval(hours => notice_hours) + interval '30 minutes' as post_cutoff,
  ((now() + make_interval(hours => notice_hours)) at time zone 'America/Sao_Paulo')::date as local_date
from notice;

insert into public.categories(id, name, slug)
values ('98400000-0000-0000-0000-000000000001', 'Public Notice Test', 'public-notice-test');

insert into public.resources(id, name, resource_type)
values ('98400000-0000-0000-0000-000000000002', 'PUBLIC NOTICE PERSON', 'PERSON');

insert into public.employees(id, name, resource_id)
values (
  '98400000-0000-0000-0000-000000000003',
  'Public Notice Employee',
  '98400000-0000-0000-0000-000000000002'
);

insert into public.services(
  id, category_id, name, slug,
  base_duration_minutes, base_price,
  buffer_before_minutes, buffer_after_minutes,
  minimum_people, maximum_people, maximum_booking_horizon_days,
  slot_interval_minutes
) values (
  '98400000-0000-0000-0000-000000000004',
  '98400000-0000-0000-0000-000000000001',
  'Public Notice Service', 'public-notice-service',
  30, 100.00,
  0, 0,
  1, 5, 5000,
  30
);

insert into public.service_change_policies(
  service_id, notice_hours,
  reschedule_first_early_percent, reschedule_first_late_percent,
  reschedule_repeat_percent, cancellation_late_percent
) values (
  '98400000-0000-0000-0000-000000000004',
  48, 0, 20, 20, 20
);

insert into public.service_employees(id, service_id, employee_id)
values (
  '98400000-0000-0000-0000-000000000005',
  '98400000-0000-0000-0000-000000000004',
  '98400000-0000-0000-0000-000000000003'
);

insert into public.booking_page_services(booking_page_id, service_id, sort_order)
select id, '98400000-0000-0000-0000-000000000004', 999
from public.booking_pages
where slug = 'blacksheep';

insert into public.availability_exceptions(
  service_employee_id, exception_type, start_at, end_at, reason
)
select
  '98400000-0000-0000-0000-000000000005',
  'OPEN',
  pre_cutoff,
  cutoff + interval '2 hours',
  'public-minimum-booking-notice-regression'
from notice_clock;

select ok(
  exists (
    select 1
    from notice_clock c,
    lateral public.public_list_available_slots(
      'blacksheep',
      '98400000-0000-0000-0000-000000000004',
      '98400000-0000-0000-0000-000000000005',
      '[]'::jsonb,
      1,
      c.local_date
    ) s
    where s.slot_start_at = c.pre_cutoff
  ),
  'default zero preserves the existing public availability behavior'
);

update public.services
set public_minimum_booking_notice_hours = (select notice_hours from notice_clock)
where id = '98400000-0000-0000-0000-000000000004';

select ok(
  not exists (
    select 1
    from notice_clock c,
    lateral public.public_list_available_slots(
      'blacksheep',
      '98400000-0000-0000-0000-000000000004',
      '98400000-0000-0000-0000-000000000005',
      '[]'::jsonb,
      1,
      c.local_date
    ) s
    where s.slot_start_at = c.pre_cutoff
  ),
  'public wrapper hides a slot before the native timestamptz cutoff'
);

select ok(
  exists (
    select 1
    from notice_clock c,
    lateral public.public_list_available_slots(
      'blacksheep',
      '98400000-0000-0000-0000-000000000004',
      '98400000-0000-0000-0000-000000000005',
      '[]'::jsonb,
      1,
      c.local_date
    ) s
    where s.slot_start_at = c.cutoff
  ),
  'slot exactly at the cutoff remains available (inclusive boundary)'
);

select ok(
  exists (
    select 1
    from notice_clock c,
    lateral public.public_list_available_slots(
      'blacksheep',
      '98400000-0000-0000-0000-000000000004',
      '98400000-0000-0000-0000-000000000005',
      '[]'::jsonb,
      1,
      c.local_date
    ) s
    where s.slot_start_at = c.post_cutoff
  ),
  'slot after the cutoff remains available'
);

select ok(
  (
    select count(*) = 3
       and bool_and(position('public_minimum_booking_notice_hours' in pg_get_functiondef(p.oid)) > 0)
       and bool_and(position('slot_start_at >=' in pg_get_functiondef(p.oid)) > 0)
       and bool_and(position('-03:00' in pg_get_functiondef(p.oid)) = 0)
       and bool_and(position('::text' in pg_get_functiondef(p.oid)) = 0)
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in (
        'public_list_available_slots',
        'public_list_available_slots_duration',
        'public_list_available_slots_minutes'
      )
  ),
  'all three public wrappers own the native timestamptz filter without text or fixed-offset comparison'
);

select ok(
  coalesce((
    select md5(pg_get_functiondef(p.oid)) = '215204b4acfb76e0f036ee29a583a2a4'
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'list_available_slots_without_google_sync_gate'
  ), false)
  and
  coalesce((
    select md5(pg_get_functiondef(p.oid)) = '018933b63df4fcdecfab01c73764964d'
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'list_available_slots_for_duration_without_google_sync_gate'
  ), false),
  'internal availability functions remain byte-for-byte definition-equivalent to the approved baseline'
);

select * from finish();
rollback;
