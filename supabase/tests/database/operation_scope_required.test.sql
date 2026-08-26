begin;
select plan(4);

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

select is(
  has_function_privilege('anon', 'public.service_admin_update_operation_scope(uuid,text,uuid)', 'EXECUTE'),
  false,
  'anon cannot execute operation scope mutation'
);

select is(
  has_function_privilege('authenticated', 'public.service_admin_update_operation_scope(uuid,text,uuid)', 'EXECUTE'),
  false,
  'authenticated cannot execute operation scope mutation directly'
);

select * from finish();
rollback;
