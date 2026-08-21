begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(11);

select ok(to_regclass('public.customers') is not null, 'customers exists');
select ok(to_regclass('public.appointment_participants') is not null, 'appointment_participants exists');
select ok(to_regclass('public.appointment_extras') is not null, 'appointment_extras exists');
select ok(to_regclass('public.appointment_answers') is not null, 'appointment_answers exists');
select ok(to_regclass('public.coupons') is not null, 'coupons exists');
select ok(to_regclass('public.payment_transactions') is not null, 'payment_transactions exists');
select ok(to_regclass('public.integration_jobs') is not null, 'integration_jobs exists');
select ok(to_regclass('public.audit_logs') is not null, 'audit_logs exists');

select is(
  (select data_type from information_schema.columns
   where table_schema = 'public' and table_name = 'appointments' and column_name = 'commercial_value'),
  'numeric',
  'appointment commercial value uses numeric'
);

select is(
  (select data_type from information_schema.columns
   where table_schema = 'public' and table_name = 'integration_jobs' and column_name = 'entity_version'),
  'integer',
  'outbox carries entity_version'
);

select ok(
  exists (
    select 1 from pg_indexes
    where schemaname = 'public'
      and tablename = 'integration_jobs'
      and indexname = 'integration_jobs_idempotency_uq'
  ),
  'outbox idempotency key is unique'
);

select * from finish();
rollback;
