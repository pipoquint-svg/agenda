begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(5);

insert into public.categories (id, name, slug)
values ('97000000-0000-0000-0000-000000000001', 'Slot Grid Test', 'slot-grid-test');

insert into public.resources (id, name, resource_type)
values
  ('97000000-0000-0000-0000-000000000002', 'SLOT GRID ESTUDIO', 'PHYSICAL'),
  ('97000000-0000-0000-0000-000000000003', 'SLOT GRID PESSOA', 'PERSON');

insert into public.employees (id, name, resource_id)
values (
  '97000000-0000-0000-0000-000000000004',
  'Slot Grid Profissional',
  '97000000-0000-0000-0000-000000000003'
);

insert into public.services (
  id, category_id, name, slug, base_duration_minutes, base_price,
  minimum_people, maximum_people, maximum_booking_horizon_days
) values (
  '97000000-0000-0000-0000-000000000005',
  '97000000-0000-0000-0000-000000000001',
  'Locação 4 horas',
  'locacao-quatro-horas-slot-grid-test',
  240, 720.00, 1, 1, 5000
);

insert into public.service_employees (id, service_id, employee_id)
values (
  '97000000-0000-0000-0000-000000000006',
  '97000000-0000-0000-0000-000000000005',
  '97000000-0000-0000-0000-000000000004'
);

insert into public.service_resources (service_id, resource_id, is_required)
values
  ('97000000-0000-0000-0000-000000000005', '97000000-0000-0000-0000-000000000002', true),
  ('97000000-0000-0000-0000-000000000005', '97000000-0000-0000-0000-000000000003', true);

-- 2030-01-01 is Tuesday. Intentionally omit slot_interval_minutes:
-- the schema default must provide the canonical 30-minute cadence.
insert into public.availability_rules (
  service_employee_id, weekday, start_local_time, end_local_time
) values (
  '97000000-0000-0000-0000-000000000006', 2, '08:00', '16:00'
);

insert into public.resource_availability_rules (
  resource_id, weekday, start_local_time, end_local_time
) values
  ('97000000-0000-0000-0000-000000000002', 2, '08:00', '16:00'),
  ('97000000-0000-0000-0000-000000000003', 2, '08:00', '16:00');

insert into public.booking_page_services (booking_page_id, service_id, sort_order)
select id, '97000000-0000-0000-0000-000000000005', 10
from public.booking_pages
where slug = 'blacksheep';

select is(
  (select slot_interval_minutes from public.availability_rules where service_employee_id = '97000000-0000-0000-0000-000000000006'),
  30,
  'new availability rules default to 30-minute starts'
);

create temporary table slot_grid as
select row_number() over (order by core_start_at) as rn, *
from public.public_list_available_slots(
  'blacksheep',
  '97000000-0000-0000-0000-000000000005',
  '97000000-0000-0000-0000-000000000006',
  '[]'::jsonb,
  1,
  '2030-01-01'::date
);

select is(
  (select to_char(slot_start_at at time zone 'America/Sao_Paulo', 'HH24:MI') || '–' || to_char(slot_end_at at time zone 'America/Sao_Paulo', 'HH24:MI') from slot_grid where rn = 1),
  '08:00–12:00',
  'four-hour rental first option is 08:00–12:00'
);

select is(
  (select to_char(slot_start_at at time zone 'America/Sao_Paulo', 'HH24:MI') || '–' || to_char(slot_end_at at time zone 'America/Sao_Paulo', 'HH24:MI') from slot_grid where rn = 2),
  '08:30–12:30',
  'four-hour rental second option is 08:30–12:30'
);

select is(
  (select to_char(slot_start_at at time zone 'America/Sao_Paulo', 'HH24:MI') || '–' || to_char(slot_end_at at time zone 'America/Sao_Paulo', 'HH24:MI') from slot_grid where rn = 3),
  '09:00–13:00',
  'four-hour rental third option is 09:00–13:00'
);

select is(
  (select extract(epoch from (slot_end_at - slot_start_at))::integer / 60 from slot_grid where rn = 2),
  240,
  'displayed range preserves the complete four-hour duration'
);

select * from finish();
rollback;
