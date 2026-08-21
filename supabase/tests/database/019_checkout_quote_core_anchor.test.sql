begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(2);

insert into public.categories (id, name, slug)
values ('95100000-0000-0000-0000-000000000001', 'Anchor Price Test', 'anchor-price-test');

insert into public.resources (id, name, resource_type)
values ('95100000-0000-0000-0000-000000000002', 'ANCHOR PRICE PERSON', 'PERSON');

insert into public.employees (id, name, resource_id)
values (
  '95100000-0000-0000-0000-000000000003',
  'Anchor Price Employee',
  '95100000-0000-0000-0000-000000000002'
);

insert into public.services (
  id, category_id, name, slug, base_duration_minutes, base_price,
  minimum_people, maximum_people, maximum_booking_horizon_days
) values (
  '95100000-0000-0000-0000-000000000004',
  '95100000-0000-0000-0000-000000000001',
  'Anchor Price Service',
  'anchor-price-service',
  60, 100.00, 1, 1, 5000
);

insert into public.service_employees (id, service_id, employee_id)
values (
  '95100000-0000-0000-0000-000000000005',
  '95100000-0000-0000-0000-000000000004',
  '95100000-0000-0000-0000-000000000003'
);

insert into public.pricing_rules (
  service_id, name, rule_scope, days_of_week,
  start_local_time, end_local_time,
  action_type, amount, priority
) values (
  '95100000-0000-0000-0000-000000000004',
  'Before 09 surcharge fixture',
  'DAY_TIME',
  array[2]::smallint[],
  '08:00', '09:00',
  'ADD_AMOUNT', 900.00, 10
);

insert into public.checkout_holds (
  public_token_hash,
  service_id,
  service_employee_id,
  selection_hash,
  people_count,
  requested_start_at,
  requested_end_at,
  core_start_at,
  core_end_at,
  pre_service_minutes,
  status,
  expires_at
) values (
  repeat('a', 64),
  '95100000-0000-0000-0000-000000000004',
  '95100000-0000-0000-0000-000000000005',
  'anchor-price-selection',
  1,
  '2030-01-01 08:30:00-03',
  '2030-01-01 10:00:00-03',
  '2030-01-01 09:00:00-03',
  '2030-01-01 10:00:00-03',
  30,
  'ACTIVE',
  now() + interval '10 minutes'
);

select is(
  (select (quote_snapshot->>'commercial_value')::numeric(12,2)
   from public.checkout_holds
   where selection_hash = 'anchor-price-selection'),
  100.00::numeric(12,2),
  'hold snapshot prices the 09:00 core, not the 08:30 PREPEND arrival'
);

select is(
  (select (quote_snapshot->>'day_time_adjustment')::numeric(12,2)
   from public.checkout_holds
   where selection_hash = 'anchor-price-selection'),
  0.00::numeric(12,2),
  'PREPEND alone does not trigger an earlier DAY_TIME price rule'
);

select * from finish();
rollback;
