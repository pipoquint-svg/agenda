begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(5);

with exposed as (
  select
    p.oid,
    format('%I(%s)', p.proname, pg_get_function_identity_arguments(p.oid)) as signature,
    p.proconfig,
    has_function_privilege('anon', p.oid, 'EXECUTE') as anon_exec,
    has_function_privilege('authenticated', p.oid, 'EXECUTE') as auth_exec
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.prosecdef
    and (
      has_function_privilege('anon', p.oid, 'EXECUTE')
      or has_function_privilege('authenticated', p.oid, 'EXECUTE')
    )
)
select is(
  (select count(*)::integer from exposed),
  8,
  'only seven public booking RPCs plus the explicitly protected admin appointment search are exposed'
);

with exposed as (
  select format('%I(%s)', p.proname, pg_get_function_identity_arguments(p.oid)) as signature
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.prosecdef
    and (
      has_function_privilege('anon', p.oid, 'EXECUTE')
      or has_function_privilege('authenticated', p.oid, 'EXECUTE')
    )
)
select is(
  (select string_agg(signature, E'\n' order by signature) from exposed),
  E'public_get_booking_page(p_slug text)\npublic_list_available_slots(p_booking_page_slug text, p_service_id uuid, p_service_employee_id uuid, p_extra_selections jsonb, p_people_count integer, p_local_date date)\npublic_list_available_slots_duration(p_booking_page_slug text, p_service_id uuid, p_service_employee_id uuid, p_duration_blocks integer, p_extra_selections jsonb, p_people_count integer, p_local_date date)\npublic_list_available_slots_minutes(p_booking_page_slug text, p_service_id uuid, p_service_employee_id uuid, p_contracted_minutes integer, p_extra_selections jsonb, p_people_count integer, p_local_date date)\npublic_quote_booking(p_booking_page_slug text, p_service_id uuid, p_service_employee_id uuid, p_extra_selections jsonb, p_people_count integer)\npublic_quote_booking_duration(p_booking_page_slug text, p_service_id uuid, p_service_employee_id uuid, p_duration_blocks integer, p_extra_selections jsonb, p_people_count integer)\npublic_quote_booking_minutes(p_booking_page_slug text, p_service_id uuid, p_service_employee_id uuid, p_contracted_minutes integer, p_extra_selections jsonb, p_people_count integer)\nservice_admin_search_appointments_global(p_search text, p_limit integer)',
  'SECURITY DEFINER exposure matches the explicit public/authenticated allowlist'
);

with exposed as (
  select p.oid, p.proconfig
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.prosecdef
    and (
      has_function_privilege('anon', p.oid, 'EXECUTE')
      or has_function_privilege('authenticated', p.oid, 'EXECUTE')
    )
)
select ok(
  not exists (
    select 1
    from exposed
    where not exists (
      select 1
      from unnest(coalesce(proconfig, '{}'::text[])) as config(value)
      where config.value in ('search_path=public', 'search_path=public, pg_temp')
    )
  ),
  'every exposed SECURITY DEFINER RPC pins search_path to public with optional pg_temp'
);

with booking_exposed as (
  select
    p.oid,
    has_function_privilege('anon', p.oid, 'EXECUTE') as anon_exec,
    has_function_privilege('authenticated', p.oid, 'EXECUTE') as auth_exec
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.prosecdef
    and p.proname like 'public_%'
    and (
      has_function_privilege('anon', p.oid, 'EXECUTE')
      or has_function_privilege('authenticated', p.oid, 'EXECUTE')
    )
)
select ok(
  not exists (
    select 1 from booking_exposed where not anon_exec or not auth_exec
  ),
  'the seven public booking RPCs keep the expected anon/authenticated contract'
);

select ok(
  to_regprocedure('public.service_bootstrap_first_owner_authenticated(text)') is null,
  'temporary first-owner bridge is retired after owner initialization'
);

select * from finish();
rollback;
