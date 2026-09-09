begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(6);

select ok(
  to_regprocedure('public.public_list_available_dates_month(text,uuid,uuid,integer,jsonb,integer,date)') is not null,
  'monthly public availability function exists'
);

select is(
  (select p.provolatile::text
   from pg_proc p
   join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.oid = to_regprocedure('public.public_list_available_dates_month(text,uuid,uuid,integer,jsonb,integer,date)')),
  's',
  'monthly availability is stable'
);

select ok(
  (select p.prosecdef
   from pg_proc p
   where p.oid = to_regprocedure('public.public_list_available_dates_month(text,uuid,uuid,integer,jsonb,integer,date)')),
  'monthly availability is security definer'
);

select ok(
  has_function_privilege('anon', 'public.public_list_available_dates_month(text,uuid,uuid,integer,jsonb,integer,date)', 'EXECUTE'),
  'anon may execute monthly availability'
);

select ok(
  has_function_privilege('authenticated', 'public.public_list_available_dates_month(text,uuid,uuid,integer,jsonb,integer,date)', 'EXECUTE'),
  'authenticated may execute monthly availability'
);

select ok(
  has_function_privilege('service_role', 'public.public_list_available_dates_month(text,uuid,uuid,integer,jsonb,integer,date)', 'EXECUTE'),
  'service role may execute monthly availability'
);

select * from finish();
rollback;
