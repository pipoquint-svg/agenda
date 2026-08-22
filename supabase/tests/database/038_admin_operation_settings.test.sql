begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(17);

select has_function('public', 'service_admin_get_operation_settings', array[]::text[], 'operation settings read model exists');
select has_function('public', 'service_admin_set_dashboard_occupancy_resource', array['uuid','uuid'], 'occupancy resource mutation exists');

select ok(
  not has_function_privilege('anon', 'public.service_admin_get_operation_settings()', 'EXECUTE'),
  'anonymous users cannot call operation settings RPC directly'
);
select ok(
  not has_function_privilege('authenticated', 'public.service_admin_set_dashboard_occupancy_resource(uuid,uuid)', 'EXECUTE'),
  'authenticated browsers cannot mutate operation settings RPC directly'
);

insert into auth.users (id, instance_id, aud, role, email, encrypted_password, created_at, updated_at)
values ('11000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'settings-owner@example.test', '', now(), now());
insert into public.admin_users (id, auth_user_id, display_name, role)
values ('21000000-0000-4000-8000-000000000001', '11000000-0000-4000-8000-000000000001', 'Settings Owner', 'OWNER');

insert into public.resources (id, name, resource_type, is_active) values
  ('31000000-0000-4000-8000-000000000001', 'Physical Active Test', 'PHYSICAL', true),
  ('31000000-0000-4000-8000-000000000002', 'Physical Inactive Test', 'PHYSICAL', false),
  ('31000000-0000-4000-8000-000000000003', 'Person Active Test', 'PERSON', true);

update public.operation_settings set dashboard_occupancy_resource_id = null where id = 1;

select is(
  public.service_admin_get_operation_settings()->'dashboard_occupancy_resource_id',
  'null'::jsonb,
  'read returns null when occupancy resource is not configured'
);
select ok(
  exists (
    select 1 from jsonb_array_elements(public.service_admin_get_operation_settings()->'eligible_occupancy_resources') x
    where x->>'id' = '31000000-0000-4000-8000-000000000001'
  )
  and not exists (
    select 1 from jsonb_array_elements(public.service_admin_get_operation_settings()->'eligible_occupancy_resources') x
    where x->>'id' in ('31000000-0000-4000-8000-000000000002','31000000-0000-4000-8000-000000000003')
  ),
  'eligible list includes active PHYSICAL and excludes inactive PHYSICAL and PERSON without assuming seed size'
);

select lives_ok(
  $$ select public.service_admin_set_dashboard_occupancy_resource(
    '31000000-0000-4000-8000-000000000001'::uuid,
    '21000000-0000-4000-8000-000000000001'::uuid
  ) $$,
  'valid active physical resource can be selected'
);
select is(
  public.service_admin_get_operation_settings()->>'dashboard_occupancy_resource_id',
  '31000000-0000-4000-8000-000000000001',
  'selected resource is persisted exactly'
);
select is(
  (select count(*)::integer from public.audit_logs
   where entity_type = 'DASHBOARD_OCCUPANCY_RESOURCE'
     and entity_id = '31000000-0000-4000-8000-000000000001'
     and action = 'DASHBOARD_OCCUPANCY_RESOURCE_CHANGED'
     and admin_user_id = '21000000-0000-4000-8000-000000000001'),
  1,
  'first state change writes one audit event against the involved resource'
);

select lives_ok(
  $$ select public.service_admin_set_dashboard_occupancy_resource(
    '31000000-0000-4000-8000-000000000001'::uuid,
    '21000000-0000-4000-8000-000000000001'::uuid
  ) $$,
  'repeating the same resource is idempotent'
);
select is(
  (select count(*)::integer from public.audit_logs
   where entity_type = 'DASHBOARD_OCCUPANCY_RESOURCE'
     and action = 'DASHBOARD_OCCUPANCY_RESOURCE_CHANGED'
     and admin_user_id = '21000000-0000-4000-8000-000000000001'),
  1,
  'idempotent repeat does not create duplicate audit event'
);

select throws_ok(
  $$ select public.service_admin_set_dashboard_occupancy_resource(
    '31000000-0000-4000-8000-000000000099'::uuid,
    '21000000-0000-4000-8000-000000000001'::uuid
  ) $$,
  'P0001', 'OCCUPANCY_RESOURCE_NOT_FOUND',
  'unknown resource is rejected'
);
select throws_ok(
  $$ select public.service_admin_set_dashboard_occupancy_resource(
    '31000000-0000-4000-8000-000000000002'::uuid,
    '21000000-0000-4000-8000-000000000001'::uuid
  ) $$,
  'P0001', 'OCCUPANCY_RESOURCE_NOT_ELIGIBLE',
  'inactive physical resource is rejected'
);
select throws_ok(
  $$ select public.service_admin_set_dashboard_occupancy_resource(
    '31000000-0000-4000-8000-000000000003'::uuid,
    '21000000-0000-4000-8000-000000000001'::uuid
  ) $$,
  'P0001', 'OCCUPANCY_RESOURCE_NOT_ELIGIBLE',
  'PERSON resource is rejected'
);

-- TESTE DE COSTURA: Configuracoes -> Dashboard.
select is(
  public.service_admin_get_dashboard(
    '2040-01-01 00:00:00-03'::timestamptz,
    '2040-01-02 00:00:00-03'::timestamptz,
    null
  )->'occupancy'->>'resource_id',
  '31000000-0000-4000-8000-000000000001',
  'stitch: dashboard uses exactly the resource selected in operation settings'
);

select lives_ok(
  $$ select public.service_admin_set_dashboard_occupancy_resource(
    null,
    '21000000-0000-4000-8000-000000000001'::uuid
  ) $$,
  'occupancy resource can be explicitly cleared'
);
select is(
  public.service_admin_get_dashboard(
    '2040-01-01 00:00:00-03'::timestamptz,
    '2040-01-02 00:00:00-03'::timestamptz,
    null
  )->'occupancy'->>'reason',
  'OCCUPANCY_RESOURCE_NOT_CONFIGURED',
  'stitch: clearing resource returns dashboard to explicit unconfigured state'
);

select * from finish();
rollback;
