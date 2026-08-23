begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(5);

select ok(to_regprocedure('public.rls_auto_enable()') is not null,'automatic RLS helper is versioned');
select ok(exists(select 1 from pg_event_trigger where evtname='ensure_rls' and evtenabled<>'D'),'automatic RLS event trigger exists and is enabled');
select ok(not has_function_privilege('anon','public.rls_auto_enable()','EXECUTE'),'anon cannot invoke RLS event-trigger helper');
select ok(not has_function_privilege('authenticated','public.rls_auto_enable()','EXECUTE'),'authenticated cannot invoke RLS event-trigger helper');

create table public.__rls_guard_probe_20260823(id bigint primary key);
select ok(
  (select c.relrowsecurity from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname='__rls_guard_probe_20260823'),
  'new public table receives RLS automatically'
);

select * from finish();
rollback;
