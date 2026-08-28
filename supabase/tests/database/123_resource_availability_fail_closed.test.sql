begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(6);

create temporary table _resource_availability_function_def as
select pg_get_functiondef(
  'public.list_available_slots_for_duration_without_google_sync_gate(uuid,uuid,integer,jsonb,integer,date,text)'::regprocedure
) as def;

select ok(
  exists (select 1 from _resource_availability_function_def where def is not null),
  'duration availability function exists'
);

select ok(
  exists (
    select 1 from _resource_availability_function_def
    where def like '%calculate_booking_resource_ranges_for_duration%'
      and def like '%resource_availability_rules%'
  ),
  'required booking resource ranges are evaluated against explicit resource availability rules'
);

select ok(
  exists (
    select 1 from _resource_availability_function_def
    where def like '%exception_type = ''OPEN''%'
  ),
  'resource OPEN exceptions can explicitly open a resource window'
);

select ok(
  exists (
    select 1 from _resource_availability_function_def
    where def like '%exception_type = ''BLOCK''%'
  ),
  'resource BLOCK exceptions explicitly close a resource window'
);

select ok(
  exists (
    select 1 from _resource_availability_function_def
    where def like '%resource_allocations%'
      and def like '%AWAITING_PAYMENT%'
  ),
  'active resource allocations participate in slot blocking'
);

select ok(
  exists (
    select 1 from _resource_availability_function_def
    where def like '%hold_expires_at%'
      and def like '%v_now%'
  ),
  'expired awaiting-payment holds do not block resources forever'
);

select * from finish();
rollback;
