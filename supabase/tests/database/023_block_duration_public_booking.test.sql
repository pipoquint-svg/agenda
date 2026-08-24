begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(14);

insert into public.categories(id, name, slug)
values ('97100000-0000-0000-0000-000000000001', 'Block Public Test', 'block-public-test');

insert into public.resources(id, name, resource_type)
values
  ('97100000-0000-0000-0000-000000000002', 'BLOCK TEST STUDIO', 'PHYSICAL'),
  ('97100000-0000-0000-0000-000000000003', 'BLOCK TEST PERSON', 'PERSON');

insert into public.employees(id, name, resource_id)
values ('97100000-0000-0000-0000-000000000004', 'Block Test Employee', '97100000-0000-0000-0000-000000000003');

insert into public.services(
  id, category_id, name, slug,
  base_duration_minutes, base_price,
  buffer_before_minutes, buffer_after_minutes,
  minimum_people, maximum_people, maximum_booking_horizon_days,
  duration_mode, booking_block_minutes,
  minimum_booking_blocks, maximum_booking_blocks, price_per_block
) values (
  '97100000-0000-0000-0000-000000000005',
  '97100000-0000-0000-0000-000000000001',
  'Locação Blocos Public Test', 'locacao-blocos-public-test',
  30, 90.00,
  0, 30,
  1, 20, 5000,
  'BLOCKS', 30, 2, 12, 90.00
);

insert into public.service_change_policies(
  service_id, notice_hours,
  reschedule_first_early_percent, reschedule_first_late_percent,
  reschedule_repeat_percent, cancellation_late_percent
) values ('97100000-0000-0000-0000-000000000005', 48, 0, 20, 20, 20);

insert into public.service_employees(id, service_id, employee_id)
values (
  '97100000-0000-0000-0000-000000000006',
  '97100000-0000-0000-0000-000000000005',
  '97100000-0000-0000-0000-000000000004'
);

insert into public.service_resources(service_id, resource_id, is_required)
values ('97100000-0000-0000-0000-000000000005', '97100000-0000-0000-0000-000000000002', true);

insert into public.availability_rules(service_employee_id, weekday, start_local_time, end_local_time)
values ('97100000-0000-0000-0000-000000000006', 2, '08:00', '14:00');

insert into public.resource_availability_rules(resource_id, weekday, start_local_time, end_local_time)
values ('97100000-0000-0000-0000-000000000002', 2, '08:00', '14:30');

insert into public.booking_page_services(booking_page_id, service_id, sort_order)
select id, '97100000-0000-0000-0000-000000000005', 10
from public.booking_pages where slug = 'blacksheep';

select is((public.public_get_booking_page('blacksheep')->'services'->0->>'duration_mode'),'BLOCKS','public catalog exposes block-duration mode');
select is((public.public_get_booking_page('blacksheep')->'services'->0->>'booking_block_minutes')::integer,30,'public catalog exposes 30-minute rental blocks');
select is((public.public_quote_booking_duration('blacksheep','97100000-0000-0000-0000-000000000005','97100000-0000-0000-0000-000000000006',4,'[]'::jsonb,1)->>'contracted_minutes')::integer,120,'four blocks quote two contracted hours');
select is((public.public_quote_booking_duration('blacksheep','97100000-0000-0000-0000-000000000005','97100000-0000-0000-0000-000000000006',4,'[]'::jsonb,1)->>'commercial_value')::numeric(12,2),360.00::numeric(12,2),'four blocks price four block units');
select throws_ok($$ select public.public_quote_booking_duration('blacksheep','97100000-0000-0000-0000-000000000005','97100000-0000-0000-0000-000000000006',1,'[]'::jsonb,1) $$,'P0001','INVALID_DURATION_BLOCKS','public request cannot bypass minimum rental blocks');
select is((select count(*)::integer from public.public_list_available_slots_duration('blacksheep','97100000-0000-0000-0000-000000000005','97100000-0000-0000-0000-000000000006',8,'[]'::jsonb,1,'2030-01-01'::date)),5,'4h rental offers 08:00, 08:30, 09:00, 09:30 and 10:00 starts');
select ok(exists (select 1 from public.public_list_available_slots_duration('blacksheep','97100000-0000-0000-0000-000000000005','97100000-0000-0000-0000-000000000006',8,'[]'::jsonb,1,'2030-01-01'::date) s where s.core_start_at='2030-01-01 08:00:00-03'::timestamptz and s.core_end_at='2030-01-01 12:00:00-03'::timestamptz and s.slot_end_at='2030-01-01 12:00:00-03'::timestamptz),'customer-visible 4h slot ends at 12:00 and does not display the service buffer');

create temporary table block_hold as
select public.public_create_checkout_hold_duration('blacksheep','97100000-0000-0000-0000-000000000005','97100000-0000-0000-0000-000000000006',4,'[]'::jsonb,1,'2030-01-01 08:00:00-03'::timestamptz) payload;

select is((select (payload->>'duration_blocks')::integer from block_hold),4,'hold snapshots four rental blocks');
select is((select (payload->>'contracted_minutes')::integer from block_hold),120,'hold snapshots 120 contracted minutes');
select is((select upper(ra.occupied_range) from public.resource_allocations ra join public.checkout_holds h on h.id=ra.checkout_hold_id where h.id=(select (payload->>'checkout_hold_id')::uuid from block_hold) and ra.resource_id='97100000-0000-0000-0000-000000000002'),'2030-01-01 10:30:00-03'::timestamptz,'studio allocation ends once at 10:30: 2h contract plus one 30m buffer');
select ok(not exists (select 1 from public.public_list_available_slots_duration('blacksheep','97100000-0000-0000-0000-000000000005','97100000-0000-0000-0000-000000000006',2,'[]'::jsonb,1,'2030-01-01'::date) s where s.core_start_at='2030-01-01 10:00:00-03'::timestamptz),'a new rental cannot start inside the previous rental final buffer');
select ok(exists (select 1 from public.public_list_available_slots_duration('blacksheep','97100000-0000-0000-0000-000000000005','97100000-0000-0000-0000-000000000006',2,'[]'::jsonb,1,'2030-01-01'::date) s where s.core_start_at='2030-01-01 10:30:00-03'::timestamptz),'a new rental may start exactly when the single final buffer ends');
select is((extract(epoch from (upper(public.service_resource_envelope('97100000-0000-0000-0000-000000000005','2030-01-01 08:00:00-03'::timestamptz,6))-lower(public.service_resource_envelope('97100000-0000-0000-0000-000000000005','2030-01-01 08:00:00-03'::timestamptz,6))))/60)::integer,210,'six blocks create 3h contract plus exactly one 30m buffer');
select is((extract(epoch from (upper(public.service_resource_envelope('97100000-0000-0000-0000-000000000005','2030-01-01 08:00:00-03'::timestamptz,8))-lower(public.service_resource_envelope('97100000-0000-0000-0000-000000000005','2030-01-01 08:00:00-03'::timestamptz,8))))/60)::integer,270,'eight blocks create 4h contract plus exactly one 30m buffer');

select * from finish();
rollback;
