begin;

create extension if not exists pgtap with schema extensions;
set local search_path=public,extensions;

select plan(9);

select has_column(
  'public','appointments','is_test',
  'appointments expose an explicit server-side test marker'
);

select has_column(
  'public','payment_transactions','is_test',
  'payment transactions expose an explicit test marker'
);

select has_column(
  'public','customer_balance_movements','is_test',
  'customer balance movements expose an explicit test marker'
);

select ok(
  coalesce((
    select pg_get_functiondef(p.oid) ilike '%is_test%'
    from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='service_admin_finance_nfse_export'
    limit 1
  ),false),
  'NFS-e export explicitly excludes test data'
);

select ok(
  coalesce((
    select pg_get_functiondef(p.oid) ilike '%is_test%'
    from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='service_admin_finance_month_close'
    limit 1
  ),false),
  'finance month close explicitly excludes test data'
);

select ok(
  coalesce((
    select pg_get_functiondef(p.oid) ilike '%is_test%'
    from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='service_admin_list_receivable_appointments_page'
    limit 1
  ),false),
  'receivables report explicitly excludes test appointments'
);

select ok(
  coalesce((
    select pg_get_functiondef(p.oid) ilike '%is_test%'
    from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='service_admin_list_manual_receipts'
    limit 1
  ),false),
  'manual receipts report explicitly excludes test transactions'
);

select ok(
  coalesce((
    select pg_get_functiondef(p.oid) ilike '%is_test%'
    from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='service_admin_finance_pending_refunds'
    limit 1
  ),false),
  'pending refunds report explicitly excludes test appointments'
);

select ok(
  coalesce((
    select pg_get_functiondef(p.oid) ilike '%is_test%'
    from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='service_finance_customer_balance_report'
    limit 1
  ),false),
  'customer balance financial report explicitly excludes test movements'
);

select * from finish();
rollback;
