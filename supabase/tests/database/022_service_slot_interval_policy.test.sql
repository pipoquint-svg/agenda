begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(15);

select is(
  (select default_slot_interval_minutes from public.operation_settings where id = 1),
  30,
  'system default offered-start cadence is 30 minutes'
);

insert into public.categories (id, name, slug)
values ('97000000-0000-0000-0000-000000000001', 'Duration Policy Test', 'duration-policy-test');

-- Two Sabrina-style fixed services prove that buffers are configured per service.
insert into public.services (
  id, category_id, name, slug, base_duration_minutes, base_price,
  buffer_before_minutes, buffer_after_minutes,
  minimum_people, maximum_people, maximum_booking_horizon_days
) values
(
  '97000000-0000-0000-0000-000000000005',
  '97000000-0000-0000-0000-000000000001',
  'Sabrina Fixo A', 'sabrina-fixo-a',
  60, 500.00, 0, 15, 1, 1, 5000
),
(
  '97000000-0000-0000-0000-000000000006',
  '97000000-0000-0000-0000-000000000001',
  'Sabrina Fixo B', 'sabrina-fixo-b',
  90, 700.00, 20, 45, 1, 1, 5000
);

select is(
  public.resolve_service_contracted_minutes('97000000-0000-0000-0000-000000000005', null),
  60,
  'fixed Sabrina service uses its configured base duration'
);

select is(
  (extract(epoch from (
    upper(public.service_resource_envelope(
      '97000000-0000-0000-0000-000000000005',
      '2030-01-01 09:00:00-03'::timestamptz,
      null
    )) - lower(public.service_resource_envelope(
      '97000000-0000-0000-0000-000000000005',
      '2030-01-01 09:00:00-03'::timestamptz,
      null
    ))
  )) / 60)::integer,
  75,
  'fixed Sabrina service A applies its 15-minute post buffer once'
);

select ok(
  lower(public.service_resource_envelope(
    '97000000-0000-0000-0000-000000000006',
    '2030-01-01 14:00:00-03'::timestamptz,
    null
  )) = '2030-01-01 13:40:00-03'::timestamptz
  and upper(public.service_resource_envelope(
    '97000000-0000-0000-0000-000000000006',
    '2030-01-01 14:00:00-03'::timestamptz,
    null
  )) = '2030-01-01 16:15:00-03'::timestamptz,
  'another Sabrina service independently applies 20m before and 45m after'
);

-- BlackSheep rental: the contract is made of 30-minute blocks.
insert into public.services (
  id, category_id, name, slug,
  base_duration_minutes, base_price,
  buffer_before_minutes, buffer_after_minutes,
  minimum_people, maximum_people, maximum_booking_horizon_days,
  duration_mode, booking_block_minutes,
  minimum_booking_blocks, maximum_booking_blocks, price_per_block
) values (
  '97000000-0000-0000-0000-000000000007',
  '97000000-0000-0000-0000-000000000001',
  'Locação por blocos', 'locacao-por-blocos',
  30, 0.00,
  0, 30,
  1, 20, 5000,
  'BLOCKS', 30, 1, 12, 90.00
);

select is(
  public.resolve_service_contracted_minutes('97000000-0000-0000-0000-000000000007', 4),
  120,
  'four 30-minute blocks contract two hours'
);

select is(
  (extract(epoch from (
    upper(public.service_resource_envelope(
      '97000000-0000-0000-0000-000000000007',
      '2030-01-01 08:00:00-03'::timestamptz,
      4
    )) - lower(public.service_resource_envelope(
      '97000000-0000-0000-0000-000000000007',
      '2030-01-01 08:00:00-03'::timestamptz,
      4
    ))
  )) / 60)::integer,
  150,
  '2h rental occupies 2h plus one 30-minute post buffer, not four buffers'
);

select is(
  public.resolve_service_contracted_minutes('97000000-0000-0000-0000-000000000007', 6),
  180,
  'six 30-minute blocks contract three hours'
);

select ok(
  lower(public.service_resource_envelope(
    '97000000-0000-0000-0000-000000000007',
    '2030-01-01 08:00:00-03'::timestamptz,
    6
  )) = '2030-01-01 08:00:00-03'::timestamptz
  and upper(public.service_resource_envelope(
    '97000000-0000-0000-0000-000000000007',
    '2030-01-01 08:00:00-03'::timestamptz,
    6
  )) = '2030-01-01 11:30:00-03'::timestamptz,
  '3h rental ends for the customer at 11:00 and blocks the studio only until 11:30'
);

select throws_ok(
  $$ select public.resolve_service_contracted_minutes('97000000-0000-0000-0000-000000000007', 0) $$,
  'P0001', 'INVALID_DURATION_BLOCKS',
  'zero rental blocks are rejected'
);

select throws_ok(
  $$ select public.resolve_service_contracted_minutes('97000000-0000-0000-0000-000000000007', 13) $$,
  'P0001', 'INVALID_DURATION_BLOCKS',
  'rental blocks above the configured maximum are rejected'
);

select throws_ok(
  $$ select public.resolve_service_contracted_minutes('97000000-0000-0000-0000-000000000005', 2) $$,
  'P0001', 'DURATION_BLOCKS_NOT_ALLOWED',
  'fixed Sabrina services cannot accidentally receive rental block counts'
);

insert into public.resources (id, name, resource_type)
values ('97000000-0000-0000-0000-000000000010', 'DEFAULT INTERVAL PERSON', 'PERSON');
insert into public.employees (id, name, resource_id)
values (
  '97000000-0000-0000-0000-000000000011',
  'Default Interval Employee',
  '97000000-0000-0000-0000-000000000010'
);
insert into public.service_employees (id, service_id, employee_id)
values (
  '97000000-0000-0000-0000-000000000012',
  '97000000-0000-0000-0000-000000000005',
  '97000000-0000-0000-0000-000000000011'
);
insert into public.availability_rules(service_employee_id, weekday, start_local_time, end_local_time)
values ('97000000-0000-0000-0000-000000000012', 2, '09:00', '10:00');

select is(
  (select slot_interval_minutes from public.availability_rules where service_employee_id = '97000000-0000-0000-0000-000000000012'),
  30,
  'new availability windows inherit the 30-minute system start cadence by default'
);

select lives_ok(
  $$ select public.set_service_duration_policy(
    '97000000-0000-0000-0000-000000000005',
    'FIXED', 10, 25, null, null, null, null
  ) $$,
  'Sabrina service buffers can be changed individually by admin configuration'
);

select ok(
  (select buffer_before_minutes = 10 and buffer_after_minutes = 25
   from public.services where id = '97000000-0000-0000-0000-000000000005'),
  'updated Sabrina buffers remain attached only to that service'
);

select throws_ok(
  $$ select public.set_service_duration_policy(
    '97000000-0000-0000-0000-000000000007',
    'BLOCKS', 0, 30, 60, 1, 12, 90.00
  ) $$,
  'P0001', 'RENTAL_BLOCK_MUST_BE_30_MINUTES',
  'V1 rental duration units cannot be changed from 30 minutes'
);

select is(
  (extract(epoch from (
    upper(public.service_resource_envelope(
      '97000000-0000-0000-0000-000000000007',
      '2030-01-01 08:00:00-03'::timestamptz,
      8
    )) - lower(public.service_resource_envelope(
      '97000000-0000-0000-0000-000000000007',
      '2030-01-01 08:00:00-03'::timestamptz,
      8
    ))
  )) / 60)::integer,
  270,
  '8 blocks contract 4h and still add only one 30-minute post buffer'
);

select * from finish();
rollback;
