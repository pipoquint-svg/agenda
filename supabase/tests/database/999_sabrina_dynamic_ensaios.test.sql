begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(5);

insert into public.categories (id, name, slug, is_active, sort_order)
select
  '95100000-0000-0000-0000-000000000001'::uuid,
  'Ensaios',
  'ensaios',
  true,
  10
where not exists (
  select 1 from public.categories where slug = 'ensaios'
);

update public.categories
set is_active = true
where slug = 'ensaios';

insert into public.resources (id, name, resource_type)
values ('95100000-0000-0000-0000-000000000002', 'DYNAMIC ENSAIO PROFISSIONAL', 'PERSON');

insert into public.employees (id, name, resource_id)
values (
  '95100000-0000-0000-0000-000000000003',
  'Profissional Dynamic Ensaio',
  '95100000-0000-0000-0000-000000000002'
);

insert into public.services (
  id,
  category_id,
  name,
  slug,
  short_description,
  base_duration_minutes,
  base_price,
  minimum_people,
  maximum_people,
  maximum_booking_horizon_days,
  checkout_hold_minutes,
  sort_order
)
select
  '95100000-0000-0000-0000-000000000004'::uuid,
  c.id,
  'Dynamic Ensaio Public Test',
  'dynamic-ensaio-public-test',
  'Serviço de teste não vinculado manualmente à página Sabrina',
  60,
  123.00,
  1,
  3,
  5000,
  10,
  987
from public.categories c
where c.slug = 'ensaios';

insert into public.service_employees (id, service_id, employee_id)
values (
  '95100000-0000-0000-0000-000000000005',
  '95100000-0000-0000-0000-000000000004',
  '95100000-0000-0000-0000-000000000003'
);

select ok(
  exists (
    select 1
    from jsonb_array_elements(public.public_get_booking_page('sabrina')->'services') item
    where item->>'id' = '95100000-0000-0000-0000-000000000004'
  ),
  'Sabrina page automatically exposes an active unlinked service from ensaios'
);

select ok(
  not exists (
    select 1
    from jsonb_array_elements(public.public_get_booking_page('blacksheep')->'services') item
    where item->>'id' = '95100000-0000-0000-0000-000000000004'
  ),
  'BlackSheep page does not inherit Sabrina ensaios category behavior'
);

select is(
  (public.public_quote_booking(
    'sabrina',
    '95100000-0000-0000-0000-000000000004',
    '95100000-0000-0000-0000-000000000005',
    '[]'::jsonb,
    1
  )->>'commercial_value')::numeric(12,2),
  123.00::numeric(12,2),
  'dynamic ensaio passes the public Sabrina validation and authoritative quote path'
);

select throws_ok(
  $$
    select public.public_quote_booking(
      'blacksheep',
      '95100000-0000-0000-0000-000000000004',
      '95100000-0000-0000-0000-000000000005',
      '[]'::jsonb,
      1
    )
  $$,
  'P0001',
  'PUBLIC_SERVICE_NOT_AVAILABLE_ON_PAGE',
  'dynamic Sabrina ensaio remains unavailable through BlackSheep'
);

select is(
  (public.public_create_service_waitlist_entry_v2(
    'sabrina',
    '95100000-0000-0000-0000-000000000004',
    'Cliente Dynamic Test',
    'dynamic-test@example.com',
    '48999999999',
    null
  )->>'service_id'),
  '95100000-0000-0000-0000-000000000004',
  'waitlist accepts the same dynamic Sabrina ensaio without a manual page link'
);

select * from finish();
rollback;
