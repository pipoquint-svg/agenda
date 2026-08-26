begin;
create extension if not exists pgtap with schema extensions;
set local search_path=public,extensions;
select plan(7);

select ok(
  exists (
    select 1
    from pg_constraint c
    join pg_type t on t.oid = c.contypid
    join pg_namespace n on n.oid = t.typnamespace
    where n.nspname='public'
      and t.typname='resource_type'
      and c.contype='c'
      and pg_get_constraintdef(c.oid) like '%PHYSICAL%'
      and pg_get_constraintdef(c.oid) like '%PERSON%'
  ),
  'resources distinguish PHYSICAL and PERSON'
);

select ok(
  exists (
    select 1 from pg_constraint c
    where c.conrelid='public.employees'::regclass
      and c.contype='f'
      and pg_get_constraintdef(c.oid) like '%(resource_id)%'
      and pg_get_constraintdef(c.oid) like '%REFERENCES resources(id)%'
  ),
  'employee can map to an independent PERSON resource'
);

select ok(
  exists (
    select 1 from pg_constraint c
    where c.conrelid='public.service_resources'::regclass
      and c.contype='p'
      and pg_get_constraintdef(c.oid) like '%service_id%'
      and pg_get_constraintdef(c.oid) like '%resource_id%'
  ),
  'service_resources is many-to-many by service and resource'
);

select col_type_is('public','service_resources','is_required','boolean',
  'service can require each mapped resource');

select ok(
  exists (
    select 1 from pg_constraint c
    where c.conrelid='public.resource_allocations'::regclass
      and c.contype='x'
      and pg_get_constraintdef(c.oid) like '%resource_id WITH =%'
      and pg_get_constraintdef(c.oid) like '%occupied_range WITH &&%'
  ),
  'shared resource allocation has structural no-overlap exclusion'
);

select ok(
  exists (
    select 1 from pg_constraint c
    where c.conrelid='public.google_calendar_resources'::regclass
      and c.contype='f'
      and pg_get_constraintdef(c.oid) like '%resource_id%'
      and pg_get_constraintdef(c.oid) like '%REFERENCES resources(id)%'
  ),
  'Google blocking calendar can map to a resource'
);

select ok(
  exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='employees'
      and column_name='resource_id' and is_nullable='YES'
  ),
  'employee resource mapping can be staged without forcing legacy fixtures'
);

select * from finish();
rollback;
