begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(18);

select ok(
  to_regprocedure('public.public_list_available_dates_month(text,uuid,uuid,integer,jsonb,integer,date)') is not null,
  'monthly public availability wrapper exists'
);

select is(
  (select p.provolatile::text
   from pg_proc p
   where p.oid = to_regprocedure('public.public_list_available_dates_month(text,uuid,uuid,integer,jsonb,integer,date)')),
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
  exists (select 1 from pg_namespace where nspname = 'agenda_public_bridge'),
  'dedicated monthly bridge schema exists'
);

select is(
  (select count(*)::integer
   from pg_proc p
   join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'agenda_public_bridge'),
  1,
  'dedicated bridge schema contains only the reviewed monthly implementation'
);

select is(
  (select count(*)::integer
   from pg_class c
   join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'agenda_public_bridge'
     and c.relkind in ('r','p','v','m','S')),
  0,
  'dedicated bridge schema contains no relations or sequences'
);

select ok(
  has_schema_privilege('anon', 'agenda_public_bridge', 'USAGE')
  and not has_schema_privilege('anon', 'agenda_public_bridge', 'CREATE'),
  'anon may use but cannot create in bridge schema'
);

select ok(
  has_schema_privilege('authenticated', 'agenda_public_bridge', 'USAGE')
  and not has_schema_privilege('authenticated', 'agenda_public_bridge', 'CREATE'),
  'authenticated may use but cannot create in bridge schema'
);

select ok(
  not has_schema_privilege('public', 'agenda_public_bridge', 'USAGE')
  and not has_schema_privilege('public', 'agenda_public_bridge', 'CREATE'),
  'PUBLIC has no bridge schema privileges'
);

select ok(
  not has_schema_privilege('anon', 'agenda_internal', 'USAGE')
  and not has_schema_privilege('authenticated', 'agenda_internal', 'USAGE'),
  'existing internal schema remains inaccessible to app roles'
);

select ok(
  to_regprocedure('agenda_public_bridge.list_available_dates_month_impl(text,uuid,uuid,integer,jsonb,integer,date)') is not null,
  'monthly privileged implementation exists in dedicated bridge schema'
);

select ok(
  (select p.prosecdef
   from pg_proc p
   where p.oid = to_regprocedure('agenda_public_bridge.list_available_dates_month_impl(text,uuid,uuid,integer,jsonb,integer,date)')),
  'monthly privileged implementation is security definer'
);

select is(
  (select p.provolatile::text
   from pg_proc p
   where p.oid = to_regprocedure('agenda_public_bridge.list_available_dates_month_impl(text,uuid,uuid,integer,jsonb,integer,date)')),
  's',
  'monthly privileged implementation is stable'
);

select ok(
  (select not exists (
     select 1
     from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
     where a.grantee = 0
       and a.privilege_type = 'EXECUTE'
   )
   from pg_proc p
   where p.oid = to_regprocedure('agenda_public_bridge.list_available_dates_month_impl(text,uuid,uuid,integer,jsonb,integer,date)')),
  'bridge implementation is not executable by PUBLIC'
);

select ok(
  not exists (
    select 1
    from pg_default_acl d
    join pg_namespace n on n.oid = d.defaclnamespace
    cross join lateral aclexplode(d.defaclacl) a
    where n.nspname = 'agenda_public_bridge'
      and d.defaclobjtype = 'f'
      and a.grantee = 0
      and a.privilege_type = 'EXECUTE'
  ),
  'future postgres-created bridge functions do not default to PUBLIC EXECUTE'
);

select * from finish();
rollback;
