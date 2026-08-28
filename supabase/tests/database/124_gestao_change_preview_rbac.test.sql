begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(5);

select is(
  (select p.prosecdef from pg_proc p where p.oid = 'public.calculate_reservation_change(uuid,text,timestamptz,text,numeric)'::regprocedure),
  true,
  'reservation change calculator crosses hardened tables as SECURITY DEFINER'
);

select ok(
  (select coalesce(p.proconfig, '{}'::text[]) @> array['search_path=public, pg_temp']::text[]
   from pg_proc p
   where p.oid = 'public.calculate_reservation_change(uuid,text,timestamptz,text,numeric)'::regprocedure),
  'reservation change calculator pins search_path to public, pg_temp'
);

select ok(
  not has_function_privilege('anon', 'public.calculate_reservation_change(uuid,text,timestamptz,text,numeric)', 'EXECUTE'),
  'anon cannot execute reservation change calculator'
);

select ok(
  not has_function_privilege('authenticated', 'public.calculate_reservation_change(uuid,text,timestamptz,text,numeric)', 'EXECUTE'),
  'authenticated cannot execute reservation change calculator'
);

select ok(
  has_function_privilege('service_role', 'public.calculate_reservation_change(uuid,text,timestamptz,text,numeric)', 'EXECUTE'),
  'service_role can execute reservation change calculator'
);

select * from finish();
rollback;
