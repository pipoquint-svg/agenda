begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(12);

select ok(
  to_regprocedure('public.public_list_available_dates_month(text,uuid,uuid,integer,jsonb,integer,date)') is not null,
  'monthly public availability wrapper exists'
);

select is(
  (select p.provolatile::text
   from pg_proc p
   join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.oid = to_regprocedure('public.public_list_available_dates_month(text,uuid,uuid,integer,jsonb,integer,date)')),
  's',
  'monthly public availability is stable'
);

select ok(
  not (select p.prosecdef
       from pg_proc p
       where p.oid = to_regprocedure('public.public_list_available_dates_month(text,uuid,uuid,integer,jsonb,integer,date)')),
  'monthly public availability wrapper is security invoker'
);

select ok(
  has_function_privilege('anon', 'public.public_list_available_dates_month(text,uuid,uuid,integer,jsonb,integer,date)', 'EXECUTE'),
  'anon may execute monthly availability wrapper'
);

select ok(
  has_function_privilege('authenticated', 'public.public_list_available_dates_month(text,uuid,uuid,integer,jsonb,integer,date)', 'EXECUTE'),
  'authenticated may execute monthly availability wrapper'
);

select ok(
  has_function_privilege('service_role', 'public.public_list_available_dates_month(text,uuid,uuid,integer,jsonb,integer,date)', 'EXECUTE'),
  'service role may execute monthly availability wrapper'
);

select ok(
  to_regprocedure('agenda_internal.list_available_dates_month_impl(text,uuid,uuid,integer,jsonb,integer,date)') is not null,
  'monthly privileged implementation exists in internal schema'
);

select ok(
  (select p.prosecdef
   from pg_proc p
   where p.oid = to_regprocedure('agenda_internal.list_available_dates_month_impl(text,uuid,uuid,integer,jsonb,integer,date)')),
  'monthly privileged implementation is security definer'
);

select is(
  (select p.provolatile::text
   from pg_proc p
   where p.oid = to_regprocedure('agenda_internal.list_available_dates_month_impl(text,uuid,uuid,integer,jsonb,integer,date)')),
  's',
  'monthly privileged implementation is stable'
);

select ok(
  has_schema_privilege('anon', 'agenda_internal', 'USAGE')
  and has_function_privilege('anon', 'agenda_internal.list_available_dates_month_impl(text,uuid,uuid,integer,jsonb,integer,date)', 'EXECUTE'),
  'anon has only the internal call capability required by the invoker wrapper'
);

select ok(
  has_schema_privilege('authenticated', 'agenda_internal', 'USAGE')
  and has_function_privilege('authenticated', 'agenda_internal.list_available_dates_month_impl(text,uuid,uuid,integer,jsonb,integer,date)', 'EXECUTE'),
  'authenticated has only the internal call capability required by the invoker wrapper'
);

select ok(
  not exists (
    select 1
    from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
    where p.oid = to_regprocedure('agenda_internal.list_available_dates_month_impl(text,uuid,uuid,integer,jsonb,integer,date)')
      and a.grantee = 0
      and a.privilege_type = 'EXECUTE'
  )
  from pg_proc p
  where p.oid = to_regprocedure('agenda_internal.list_available_dates_month_impl(text,uuid,uuid,integer,jsonb,integer,date)'),
  'internal privileged implementation is not executable by PUBLIC'
);

select * from finish();
rollback;
