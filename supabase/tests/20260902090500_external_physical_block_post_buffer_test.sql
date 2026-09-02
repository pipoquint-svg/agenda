begin;

-- Regression coverage for asymmetric buffering around external studio blocks.
-- Expected behavior with a 30-minute service post-buffer:
--   external 14:00-15:00 occupies PHYSICAL studio capacity until 15:30;
--   it does not move its lower bound earlier than 14:00;
--   PERSON-resource copies remain on the raw Google interval.

create temporary table _external_buffer_test_services (
  service_id uuid,
  physical_resource_id uuid,
  person_resource_id uuid
) on commit drop;

with physical_resource as (
  insert into public.resources (name, resource_type, is_active)
  values ('TEST external buffer studio', 'PHYSICAL', true)
  returning id
), person_resource as (
  insert into public.resources (name, resource_type, is_active)
  values ('TEST external buffer person', 'PERSON', true)
  returning id
), service_row as (
  insert into public.services (
    name,
    slug,
    base_duration_minutes,
    price,
    buffer_before_minutes,
    buffer_after_minutes,
    minimum_people,
    maximum_people,
    minimum_booking_notice_minutes,
    maximum_booking_horizon_days,
    duration_mode,
    booking_block_minutes,
    min_duration_blocks,
    max_duration_blocks,
    price_per_block,
    is_active
  )
  values (
    'TEST external buffer rental',
    'test-external-buffer-rental-' || replace(gen_random_uuid()::text, '-', ''),
    60,
    100,
    0,
    30,
    1,
    10,
    0,
    365,
    'BLOCKS',
    30,
    1,
    8,
    50,
    true
  )
  returning id
), service_physical as (
  insert into public.service_resources (service_id, resource_id, is_required)
  select service_row.id, physical_resource.id, true
  from service_row, physical_resource
  returning service_id, resource_id
)
insert into _external_buffer_test_services(service_id, physical_resource_id, person_resource_id)
select service_row.id, physical_resource.id, person_resource.id
from service_row, physical_resource, person_resource;

-- New external PHYSICAL allocation: upper bound must extend by 30 minutes only.
insert into public.resource_allocations (
  resource_id,
  allocation_type,
  status,
  occupied_range,
  external_source,
  external_calendar_id,
  external_event_id
)
select
  physical_resource_id,
  'EXTERNAL_BLOCK',
  'EXTERNAL_ACTIVE',
  tstzrange('2026-09-03 14:00:00-03'::timestamptz, '2026-09-03 15:00:00-03'::timestamptz, '[)'),
  'TEST',
  'test-calendar',
  'physical-event'
from _external_buffer_test_services;

do $test$
declare
  v_range tstzrange;
begin
  select ra.occupied_range
  into v_range
  from public.resource_allocations ra
  where ra.external_source = 'TEST'
    and ra.external_event_id = 'physical-event';

  if lower(v_range) <> '2026-09-03 14:00:00-03'::timestamptz then
    raise exception 'external physical lower bound changed unexpectedly: %', v_range;
  end if;

  if upper(v_range) <> '2026-09-03 15:30:00-03'::timestamptz then
    raise exception 'external physical post-buffer missing: %', v_range;
  end if;
end;
$test$;

-- Metadata/status-only update must not stack a second buffer.
update public.resource_allocations
set reason = 'metadata-only change'
where external_source = 'TEST'
  and external_event_id = 'physical-event';

do $test$
declare
  v_upper timestamptz;
begin
  select upper(ra.occupied_range)
  into v_upper
  from public.resource_allocations ra
  where ra.external_source = 'TEST'
    and ra.external_event_id = 'physical-event';

  if v_upper <> '2026-09-03 15:30:00-03'::timestamptz then
    raise exception 'external physical buffer stacked on metadata update: %', v_upper;
  end if;
end;
$test$;

-- A Google-style reconciliation update writes the raw range again. The trigger
-- must normalize it back to 15:30, not to 16:00.
update public.resource_allocations
set occupied_range = tstzrange(
  '2026-09-03 14:00:00-03'::timestamptz,
  '2026-09-03 15:00:00-03'::timestamptz,
  '[)'
)
where external_source = 'TEST'
  and external_event_id = 'physical-event';

do $test$
declare
  v_upper timestamptz;
begin
  select upper(ra.occupied_range)
  into v_upper
  from public.resource_allocations ra
  where ra.external_source = 'TEST'
    and ra.external_event_id = 'physical-event';

  if v_upper <> '2026-09-03 15:30:00-03'::timestamptz then
    raise exception 'external physical buffer was not idempotent on raw-range reconciliation: %', v_upper;
  end if;
end;
$test$;

-- PERSON allocation must remain exactly on the external event range.
insert into public.resource_allocations (
  resource_id,
  allocation_type,
  status,
  occupied_range,
  external_source,
  external_calendar_id,
  external_event_id
)
select
  person_resource_id,
  'EXTERNAL_BLOCK',
  'EXTERNAL_ACTIVE',
  tstzrange('2026-09-03 14:00:00-03'::timestamptz, '2026-09-03 15:00:00-03'::timestamptz, '[)'),
  'TEST',
  'test-calendar',
  'person-event'
from _external_buffer_test_services;

do $test$
declare
  v_range tstzrange;
begin
  select ra.occupied_range
  into v_range
  from public.resource_allocations ra
  where ra.external_source = 'TEST'
    and ra.external_event_id = 'person-event';

  if lower(v_range) <> '2026-09-03 14:00:00-03'::timestamptz
     or upper(v_range) <> '2026-09-03 15:00:00-03'::timestamptz then
    raise exception 'PERSON external block should remain raw: %', v_range;
  end if;
end;
$test$;

rollback;
