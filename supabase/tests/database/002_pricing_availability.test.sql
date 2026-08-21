begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(10);

select ok(to_regclass('public.pricing_rules') is not null, 'pricing_rules exists');
select ok(to_regclass('public.availability_rules') is not null, 'availability_rules exists');
select ok(to_regclass('public.resource_availability_rules') is not null, 'resource_availability_rules exists');
select ok(to_regclass('public.availability_exceptions') is not null, 'availability_exceptions exists');

select is(
  (select data_type from information_schema.columns
   where table_schema = 'public' and table_name = 'availability_rules' and column_name = 'start_local_time'),
  'time without time zone',
  'availability uses local time without timezone'
);

insert into public.categories (id, name, slug)
values ('00000000-0000-0000-0000-000000000301', 'Teste', 'teste')
on conflict do nothing;

insert into public.services (
  id, category_id, name, slug, base_duration_minutes, base_price, minimum_people, maximum_people
)
values (
  '00000000-0000-0000-0000-000000000401',
  '00000000-0000-0000-0000-000000000301',
  'Serviço Teste', 'servico-teste', 60, 180, 1, 20
)
on conflict do nothing;

insert into public.service_employees (id, service_id, employee_id)
values (
  '00000000-0000-0000-0000-000000000501',
  '00000000-0000-0000-0000-000000000401',
  '00000000-0000-0000-0000-000000000201'
)
on conflict do nothing;

insert into public.pricing_rules (
  service_id, name, rule_scope, days_of_week, action_type, amount, priority
)
values (
  '00000000-0000-0000-0000-000000000401',
  'Sábado +20',
  'DAY_TIME',
  array[6]::smallint[],
  'ADD_AMOUNT',
  20,
  10
);

insert into public.pricing_rules (
  service_id, name, rule_scope, min_people, max_people, action_type, amount, priority
)
values (
  '00000000-0000-0000-0000-000000000401',
  '6 a 10 pessoas +100',
  'PEOPLE',
  6,
  10,
  'ADD_AMOUNT',
  100,
  20
);

select is(
  (select count(*)::integer from public.pricing_rules
   where service_id = '00000000-0000-0000-0000-000000000401'::uuid),
  2,
  'day/time and people pricing rules coexist'
);

select is(
  (select array_agg(rule_scope::text order by priority) from public.pricing_rules
   where service_id = '00000000-0000-0000-0000-000000000401'::uuid),
  array['DAY_TIME','PEOPLE']::text[],
  'pricing priority is deterministic'
);

insert into public.availability_rules (
  service_employee_id, weekday, start_local_time, end_local_time, slot_interval_minutes
)
values (
  '00000000-0000-0000-0000-000000000501',
  6, '09:00', '18:00', 30
);

select is(
  (select slot_interval_minutes from public.availability_rules
   where service_employee_id = '00000000-0000-0000-0000-000000000501'::uuid),
  30,
  'slot interval persists'
);

insert into public.resource_availability_rules (
  resource_id, weekday, start_local_time, end_local_time
)
values (
  '00000000-0000-0000-0000-000000000101',
  6, '08:00', '20:00'
);

select is(
  (select count(*)::integer from public.resource_availability_rules
   where resource_id = '00000000-0000-0000-0000-000000000101'::uuid),
  1,
  'resource may have its own availability'
);

insert into public.availability_exceptions (
  resource_id, exception_type, start_at, end_at, reason
)
values (
  '00000000-0000-0000-0000-000000000101',
  'BLOCK',
  '2035-01-15 12:00:00+00',
  '2035-01-15 13:00:00+00',
  'Teste'
);

select is(
  (select exception_type from public.availability_exceptions
   where resource_id = '00000000-0000-0000-0000-000000000101'::uuid limit 1),
  'BLOCK',
  'resource exception persists'
);

select * from finish();
rollback;
