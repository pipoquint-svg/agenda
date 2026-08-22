begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(11);

select has_function(
  'public', 'service_admin_update_operation_scope', array['uuid','text','uuid'],
  'admin can update explicit service operation scope through service-role RPC'
);

select ok(
  not has_function_privilege('authenticated', 'public.service_admin_update_operation_scope(uuid,text,uuid)', 'EXECUTE'),
  'browser cannot call scope mutation directly'
);

select ok(
  has_function_privilege('service_role', 'public.service_admin_update_operation_scope(uuid,text,uuid)', 'EXECUTE'),
  'service role can call scope mutation after edge authorization'
);

insert into public.services(id,name,slug,base_duration_minutes,base_price)
values ('11111111-1111-4111-8111-111111111111','Scope Test Service','scope-test-service',60,0);

select is(
  (select operation_scope from public.services where id='11111111-1111-4111-8111-111111111111'),
  null,
  'new service remains unclassified unless explicitly configured'
);

select is(
  public.service_admin_update_operation_scope(
    '11111111-1111-4111-8111-111111111111','blacksheep','22222222-2222-4222-8222-222222222222'
  )->>'operation_scope',
  'BLACKSHEEP',
  'scope mutation normalizes explicit BlackSheep value'
);

select is(
  (select operation_scope from public.services where id='11111111-1111-4111-8111-111111111111'),
  'BLACKSHEEP',
  'service stores explicit operation scope'
);

select is(
  (select count(*)::integer from public.audit_logs where entity_id='11111111-1111-4111-8111-111111111111' and action='OPERATION_SCOPE_CHANGED'),
  1,
  'actual scope change creates one audit event'
);

select is(
  (public.service_admin_update_operation_scope(
    '11111111-1111-4111-8111-111111111111','BLACKSHEEP','22222222-2222-4222-8222-222222222222'
  )->>'changed')::boolean,
  false,
  'idempotent replay reports no change'
);

select is(
  (select count(*)::integer from public.audit_logs where entity_id='11111111-1111-4111-8111-111111111111' and action='OPERATION_SCOPE_CHANGED'),
  1,
  'idempotent replay does not create duplicate audit event'
);

select is(
  public.service_admin_update_operation_scope(
    '11111111-1111-4111-8111-111111111111',null,'22222222-2222-4222-8222-222222222222'
  )->'operation_scope',
  'null'::jsonb,
  'scope can be explicitly cleared back to unclassified'
);

select throws_ok(
  $$ select public.service_admin_update_operation_scope('11111111-1111-4111-8111-111111111111','INFERRED','22222222-2222-4222-8222-222222222222') $$,
  'P0001','SERVICE_OPERATION_SCOPE_INVALID',
  'invented operation scope is rejected'
);

select * from finish();
rollback;
