begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(24);

-- Sensitive hour-package views are invoker-security and not directly exposed.
select ok(
  coalesce((select c.reloptions @> array['security_invoker=true'] from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname='hour_package_balances'), false),
  'hour_package_balances is security_invoker'
);
select ok(
  coalesce((select c.reloptions @> array['security_invoker=true'] from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname='hour_package_statement_entries'), false),
  'hour_package_statement_entries is security_invoker'
);
select ok(not has_table_privilege('anon','public.hour_package_balances','SELECT'),'anon cannot select hour package balances directly');
select ok(not has_table_privilege('authenticated','public.hour_package_balances','SELECT'),'authenticated cannot select hour package balances directly');
select ok(not has_table_privilege('anon','public.hour_package_statement_entries','SELECT'),'anon cannot select hour package statements directly');
select ok(not has_table_privilege('authenticated','public.hour_package_statement_entries','SELECT'),'authenticated cannot select hour package statements directly');
select ok(has_table_privilege('service_role','public.hour_package_balances','SELECT'),'service_role keeps internal balances access');
select ok(has_table_privilege('service_role','public.hour_package_statement_entries','SELECT'),'service_role keeps internal statement access');

-- Internal/admin SECURITY DEFINER functions are not callable from public client roles.
select ok(not has_function_privilege('anon','public.copy_checkout_attribution_to_appointment()','EXECUTE'),'anon cannot execute attribution trigger helper');
select ok(not has_function_privilege('authenticated','public.copy_checkout_attribution_to_appointment()','EXECUTE'),'authenticated cannot execute attribution trigger helper');
select ok(
  to_regprocedure('public.rls_auto_enable()') is null
    or coalesce(not has_function_privilege('anon',to_regprocedure('public.rls_auto_enable()'),'EXECUTE'),false),
  'hosted RLS event-trigger helper is absent or unavailable to anon'
);
select ok(
  to_regprocedure('public.rls_auto_enable()') is null
    or coalesce(not has_function_privilege('authenticated',to_regprocedure('public.rls_auto_enable()'),'EXECUTE'),false),
  'hosted RLS event-trigger helper is absent or unavailable to authenticated'
);
select ok(not has_function_privilege('anon','public.service_admin_cancel_appointment(uuid,text,text,timestamptz,uuid)','EXECUTE'),'anon cannot execute legacy cancellation admin overload');
select ok(not has_function_privilege('authenticated','public.service_admin_cancel_appointment(uuid,text,text,timestamptz,uuid)','EXECUTE'),'authenticated cannot execute legacy cancellation admin overload');
select ok(not has_function_privilege('anon','public.service_admin_create_reschedule_hold(uuid,timestamptz,timestamptz,uuid)','EXECUTE'),'anon cannot execute legacy reschedule admin overload');
select ok(not has_function_privilege('authenticated','public.service_admin_create_reschedule_hold(uuid,timestamptz,timestamptz,uuid)','EXECUTE'),'authenticated cannot execute legacy reschedule admin overload');
select ok(not has_function_privilege('anon','public.service_get_customer_commercial_terms(uuid)','EXECUTE'),'anon cannot read commercial terms directly');
select ok(not has_function_privilege('authenticated','public.service_get_customer_commercial_terms(uuid)','EXECUTE'),'authenticated cannot read commercial terms directly');

-- Public booking read functions intentionally remain callable.
select ok(has_function_privilege('anon','public.public_get_booking_page(text)','EXECUTE'),'public booking page lookup remains available');
select ok(has_function_privilege('anon','public.public_quote_booking(text,uuid,uuid,jsonb,integer)','EXECUTE'),'public booking quote remains available');
select ok(has_function_privilege('anon','public.public_list_available_slots(text,uuid,uuid,jsonb,integer,date)','EXECUTE'),'public slot listing remains available');

-- Mutable search-path findings are pinned explicitly.
select ok((select array_to_string(p.proconfig,',') like '%search_path=public, pg_temp%' from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.oid='public.format_duration_seconds(bigint)'::regprocedure),'duration formatter search_path is pinned');
select ok((select array_to_string(p.proconfig,',') like '%search_path=public, pg_temp%' from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.oid='public.is_valid_cpf(text)'::regprocedure),'CPF validator search_path is pinned');
select ok((select array_to_string(p.proconfig,',') like '%search_path=public, pg_temp%' from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.oid='public.prevent_hour_package_movement_mutation()'::regprocedure),'hour package mutation trigger search_path is pinned');

select * from finish();
rollback;
