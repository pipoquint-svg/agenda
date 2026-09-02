begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(37);

-- Exactly these 11 tables are the Phase 2B sensitive set.
select ok((select c.relrowsecurity from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname='customers'),'RLS enabled on public.customers');
select ok((select c.relrowsecurity from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname='appointments'),'RLS enabled on public.appointments');
select ok((select c.relrowsecurity from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname='payment_transactions'),'RLS enabled on public.payment_transactions');
select ok((select c.relrowsecurity from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname='payment_provider_events'),'RLS enabled on public.payment_provider_events');
select ok((select c.relrowsecurity from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname='checkout_holds'),'RLS enabled on public.checkout_holds');
select ok((select c.relrowsecurity from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname='appointment_access_tokens'),'RLS enabled on public.appointment_access_tokens');
select ok((select c.relrowsecurity from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname='pre_reservation_access_tokens'),'RLS enabled on public.pre_reservation_access_tokens');
select ok((select c.relrowsecurity from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname='google_connections'),'RLS enabled on public.google_connections');
select ok((select c.relrowsecurity from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname='audit_logs'),'RLS enabled on public.audit_logs');
select ok((select c.relrowsecurity from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname='customer_balance_movements'),'RLS enabled on public.customer_balance_movements');
select ok((select c.relrowsecurity from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname='google_calendar_events'),'RLS enabled on public.google_calendar_events');

-- FORCE RLS is intentionally not part of Item 2B: service_role/postgres are the
-- audited internal paths and must retain their existing bypass semantics.
select ok(not (select c.relforcerowsecurity from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname='customers'),'FORCE RLS remains disabled on public.customers');
select ok(not (select c.relforcerowsecurity from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname='appointments'),'FORCE RLS remains disabled on public.appointments');
select ok(not (select c.relforcerowsecurity from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname='payment_transactions'),'FORCE RLS remains disabled on public.payment_transactions');
select ok(not (select c.relforcerowsecurity from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname='payment_provider_events'),'FORCE RLS remains disabled on public.payment_provider_events');
select ok(not (select c.relforcerowsecurity from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname='checkout_holds'),'FORCE RLS remains disabled on public.checkout_holds');
select ok(not (select c.relforcerowsecurity from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname='appointment_access_tokens'),'FORCE RLS remains disabled on public.appointment_access_tokens');
select ok(not (select c.relforcerowsecurity from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname='pre_reservation_access_tokens'),'FORCE RLS remains disabled on public.pre_reservation_access_tokens');
select ok(not (select c.relforcerowsecurity from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname='google_connections'),'FORCE RLS remains disabled on public.google_connections');
select ok(not (select c.relforcerowsecurity from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname='audit_logs'),'FORCE RLS remains disabled on public.audit_logs');
select ok(not (select c.relforcerowsecurity from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname='customer_balance_movements'),'FORCE RLS remains disabled on public.customer_balance_movements');
select ok(not (select c.relforcerowsecurity from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname='google_calendar_events'),'FORCE RLS remains disabled on public.google_calendar_events');

-- No direct RLS policy is needed on this set. service_role/postgres bypass RLS;
-- anon/authenticated have no relation ACL and public entrypoints remain narrow.
select is((select count(*)::integer from pg_policies where schemaname='public' and tablename='customers'),0,'no RLS policy on public.customers');
select is((select count(*)::integer from pg_policies where schemaname='public' and tablename='appointments'),0,'no RLS policy on public.appointments');
select is((select count(*)::integer from pg_policies where schemaname='public' and tablename='payment_transactions'),0,'no RLS policy on public.payment_transactions');
select is((select count(*)::integer from pg_policies where schemaname='public' and tablename='payment_provider_events'),0,'no RLS policy on public.payment_provider_events');
select is((select count(*)::integer from pg_policies where schemaname='public' and tablename='checkout_holds'),0,'no RLS policy on public.checkout_holds');
select is((select count(*)::integer from pg_policies where schemaname='public' and tablename='appointment_access_tokens'),0,'no RLS policy on public.appointment_access_tokens');
select is((select count(*)::integer from pg_policies where schemaname='public' and tablename='pre_reservation_access_tokens'),0,'no RLS policy on public.pre_reservation_access_tokens');
select is((select count(*)::integer from pg_policies where schemaname='public' and tablename='google_connections'),0,'no RLS policy on public.google_connections');
select is((select count(*)::integer from pg_policies where schemaname='public' and tablename='audit_logs'),0,'no RLS policy on public.audit_logs');
select is((select count(*)::integer from pg_policies where schemaname='public' and tablename='customer_balance_movements'),0,'no RLS policy on public.customer_balance_movements');
select is((select count(*)::integer from pg_policies where schemaname='public' and tablename='google_calendar_events'),0,'no RLS policy on public.google_calendar_events');

select ok(not exists (
  select 1
  from (values
    ('customers'),('appointments'),('payment_transactions'),('payment_provider_events'),('checkout_holds'),
    ('appointment_access_tokens'),('pre_reservation_access_tokens'),('google_connections'),('audit_logs'),
    ('customer_balance_movements'),('google_calendar_events')
  ) as target(table_name)
  where has_table_privilege('anon',format('public.%I',table_name),'SELECT')
     or has_table_privilege('anon',format('public.%I',table_name),'INSERT')
     or has_table_privilege('anon',format('public.%I',table_name),'UPDATE')
     or has_table_privilege('anon',format('public.%I',table_name),'DELETE')
),'anon has no direct CRUD relation privilege on the 11 sensitive tables');

select ok(not exists (
  select 1
  from (values
    ('customers'),('appointments'),('payment_transactions'),('payment_provider_events'),('checkout_holds'),
    ('appointment_access_tokens'),('pre_reservation_access_tokens'),('google_connections'),('audit_logs'),
    ('customer_balance_movements'),('google_calendar_events')
  ) as target(table_name)
  where has_table_privilege('authenticated',format('public.%I',table_name),'SELECT')
     or has_table_privilege('authenticated',format('public.%I',table_name),'INSERT')
     or has_table_privilege('authenticated',format('public.%I',table_name),'UPDATE')
     or has_table_privilege('authenticated',format('public.%I',table_name),'DELETE')
),'authenticated has no direct CRUD relation privilege on the 11 sensitive tables');

select ok(coalesce((select rolbypassrls from pg_roles where rolname='service_role'),false),'service_role keeps audited BYPASSRLS behavior');
select ok(coalesce((select rolbypassrls from pg_roles where rolname='postgres'),false),'postgres keeps audited BYPASSRLS behavior');

select * from finish();
rollback;
