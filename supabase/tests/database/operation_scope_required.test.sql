begin;
select plan(6);

select ok(
  exists (
    select 1 from pg_constraint
    where conname = 'services_operation_scope_required_ck'
      and conrelid = 'public.services'::regclass
      and convalidated
  ),
  'services operation_scope required constraint exists and is validated'
);

select ok(
  exists (
    select 1 from pg_constraint
    where conname = 'categories_operation_scope_required_ck'
      and conrelid = 'public.categories'::regclass
      and convalidated
  ),
  'categories operation_scope required constraint exists and is validated'
);

select like(
  pg_get_constraintdef((select oid from pg_constraint where conname = 'services_operation_scope_required_ck' and conrelid = 'public.services'::regclass)),
  '%97000000-0000-0000-0000-000000000010%',
  'service constraint preserves only Token Evidence service exception'
);

select like(
  pg_get_constraintdef((select oid from pg_constraint where conname = 'categories_operation_scope_required_ck' and conrelid = 'public.categories'::regclass)),
  '%97000000-0000-0000-0000-000000000001%',
  'category constraint preserves only Token Evidence category exception'
);

select like(
  pg_get_functiondef('public.service_admin_update_operation_scope(uuid,text,uuid)'::regprocedure),
  '%SERVICE_OPERATION_SCOPE_REQUIRED%',
  'admin mutation rejects clearing operation scope'
);

select like(
  pg_get_functiondef('public.service_admin_update_operation_scope(uuid,text,uuid)'::regprocedure),
  '%TOKEN_EVIDENCE_OPERATION_SCOPE_IMMUTABLE%',
  'admin mutation cannot classify Token Evidence fixture arbitrarily'
);

select * from finish();
rollback;
