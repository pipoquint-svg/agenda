begin;
select plan(2);

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
