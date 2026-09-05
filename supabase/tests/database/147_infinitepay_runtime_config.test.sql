begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(10);

select ok(
  to_regclass('agenda_internal.payment_provider_runtime_configs') is not null,
  'InfinitePay runtime table exists only in the private agenda_internal schema'
);

select ok(
  to_regprocedure('public.service_get_infinitepay_runtime_config()') is not null,
  'service-role runtime reader exists'
);

select ok(
  has_function_privilege('service_role','public.service_get_infinitepay_runtime_config()','EXECUTE'),
  'service_role can execute the runtime reader'
);

select ok(
  not has_function_privilege('anon','public.service_get_infinitepay_runtime_config()','EXECUTE'),
  'anon cannot execute the runtime reader'
);

select ok(
  not has_function_privilege('authenticated','public.service_get_infinitepay_runtime_config()','EXECUTE'),
  'authenticated cannot execute the runtime reader'
);

select ok(
  (select p.prosecdef from pg_proc p where p.oid=to_regprocedure('public.service_get_infinitepay_runtime_config()')),
  'runtime reader is SECURITY DEFINER'
);

select is(
  (select pg_get_userbyid(p.proowner) from pg_proc p where p.oid=to_regprocedure('public.service_get_infinitepay_runtime_config()')),
  'postgres',
  'runtime reader is owned by postgres'
);

select ok(
  not has_table_privilege('service_role','agenda_internal.payment_provider_runtime_configs','SELECT'),
  'service_role has no direct table read privilege'
);

select ok(
  not has_table_privilege('anon','agenda_internal.payment_provider_runtime_configs','SELECT')
  and not has_table_privilege('authenticated','agenda_internal.payment_provider_runtime_configs','SELECT'),
  'browser roles have no direct runtime-table read privilege'
);

insert into agenda_internal.payment_provider_runtime_configs(
  provider,handle,redirect_url,live_links_enabled
) values (
  'INFINITEPAY','pierri_quint_pro',
  'https://example.supabase.co/functions/v1/infinitepay-return',false
);

select is(
  public.service_get_infinitepay_runtime_config(),
  jsonb_build_object(
    'handle','pierri_quint_pro',
    'redirect_url','https://example.supabase.co/functions/v1/infinitepay-return',
    'live_links_enabled',false
  ),
  'runtime reader returns only the explicit fail-closed provider configuration'
);

select * from finish();
rollback;
