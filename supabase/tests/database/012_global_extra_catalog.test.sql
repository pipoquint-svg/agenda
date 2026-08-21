begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(8);

insert into public.categories (id, name, slug)
values ('93000000-0000-0000-0000-000000000001', 'Extra Catalog Test', 'extra-catalog-test');

insert into public.services (
  id, category_id, name, slug, base_duration_minutes, base_price,
  minimum_people, maximum_people, maximum_booking_horizon_days
) values
  (
    '93000000-0000-0000-0000-000000000010',
    '93000000-0000-0000-0000-000000000001',
    'Gestante Catalog Test',
    'gestante-catalog-test',
    60, 100.00, 1, 10, 5000
  ),
  (
    '93000000-0000-0000-0000-000000000011',
    '93000000-0000-0000-0000-000000000001',
    'Corporativo Catalog Test',
    'corporativo-catalog-test',
    60, 100.00, 1, 10, 5000
  );

insert into public.extras (
  id, name, description, price, duration_delta_minutes
) values (
  '93000000-0000-0000-0000-000000000020',
  'Maquiagem Catalog Test',
  'Extra global reutilizável',
  190.00,
  60
);

select is(
  (public.set_extra_service_assignments(
    '93000000-0000-0000-0000-000000000020',
    array[
      '93000000-0000-0000-0000-000000000010'::uuid,
      '93000000-0000-0000-0000-000000000011'::uuid,
      '93000000-0000-0000-0000-000000000010'::uuid
    ],
    null
  )->>'assigned_count')::integer,
  2,
  'one global extra can be assigned to multiple services and duplicate ids are deduplicated'
);

select is(
  (select count(*)::integer from public.extras where id = '93000000-0000-0000-0000-000000000020'),
  1,
  'assigning to two services does not duplicate the global extra'
);

select is(
  (select count(*)::integer from public.service_extras where extra_id = '93000000-0000-0000-0000-000000000020'),
  2,
  'two service assignments are represented by two junction rows'
);

update public.service_extras
set schedule_placement = 'PREPEND',
    default_schedule_minutes = 45,
    max_quantity = 2
where service_id = '93000000-0000-0000-0000-000000000010'
  and extra_id = '93000000-0000-0000-0000-000000000020';

select public.set_extra_service_assignments(
  '93000000-0000-0000-0000-000000000020',
  array['93000000-0000-0000-0000-000000000010'::uuid],
  null
);

select ok(
  exists (
    select 1
    from public.service_extras
    where service_id = '93000000-0000-0000-0000-000000000010'
      and extra_id = '93000000-0000-0000-0000-000000000020'
      and schedule_placement = 'PREPEND'
      and default_schedule_minutes = 45
      and max_quantity = 2
  ),
  'reselecting services preserves per-service configuration for links that remain assigned'
);

select is(
  (select count(*)::integer
   from public.service_extras
   where service_id = '93000000-0000-0000-0000-000000000011'
     and extra_id = '93000000-0000-0000-0000-000000000020'),
  0,
  'unchecking a service removes only that assignment'
);

select is(
  (select count(*)::integer from public.extras where id = '93000000-0000-0000-0000-000000000020'),
  1,
  'removing a service assignment never deletes the reusable global extra'
);

select ok(
  exists (
    select 1
    from public.extra_catalog_admin
    where id = '93000000-0000-0000-0000-000000000020'
      and assigned_service_count = 1
      and jsonb_array_length(assigned_services) = 1
  ),
  'admin catalog view exposes the extra with its current service selections'
);

select throws_ok(
  $$
    select public.set_extra_service_assignments(
      '93000000-0000-0000-0000-000000000020',
      array['93000000-0000-0000-0000-000000009999'::uuid],
      null
    )
  $$,
  'P0001',
  'SERVICE_NOT_FOUND',
  'invalid service id fails closed instead of creating a broken assignment'
);

select * from finish();
rollback;