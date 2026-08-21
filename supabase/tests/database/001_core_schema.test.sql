begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(8);

select ok(to_regclass('public.resources') is not null, 'resources table exists');
select ok(to_regclass('public.services') is not null, 'services table exists');
select ok(to_regclass('public.checkout_holds') is not null, 'checkout_holds table exists');
select ok(to_regclass('public.appointments') is not null, 'appointments table exists');
select ok(to_regclass('public.resource_allocations') is not null, 'resource_allocations table exists');

select ok(
  exists (
    select 1
    from pg_attribute a
    join pg_class c on c.oid = a.attrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname = 'resource_allocations'
      and a.attname = 'occupied_range'
      and format_type(a.atttypid, a.atttypmod) = 'tstzrange'
      and not a.attisdropped
  ),
  'occupied_range is tstzrange'
);

select ok(
  exists (
    select 1
    from pg_constraint con
    join pg_class c on c.oid = con.conrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname = 'resource_allocations'
      and con.conname = 'resource_allocations_no_overlap'
      and con.contype = 'x'
  ),
  'no-overlap exclusion constraint exists'
);

select is(
  (select count(*)::integer from public.resources where id in (
    '00000000-0000-0000-0000-000000000101'::uuid,
    '00000000-0000-0000-0000-000000000102'::uuid
  )),
  2,
  'core ESTÚDIO and SABRINA resources are seeded'
);

select * from finish();
rollback;
