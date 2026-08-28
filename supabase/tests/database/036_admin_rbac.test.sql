begin;

select plan(19);

select has_table('public', 'admin_user_permissions', 'admin permission overrides table exists');
select has_function('public', 'service_admin_has_permission', array['uuid','text'], 'permission resolver exists');
select has_function('public', 'service_admin_get_access_profile', array['uuid'], 'access profile exists');
select has_function('public', 'service_admin_set_permission', array['uuid','text','boolean','uuid'], 'permission mutation exists');
select has_function('public', 'service_admin_resolve_auth_user', array['uuid'], 'auth user admin resolver exists');

insert into auth.users (id, instance_id, aud, role, email, encrypted_password, created_at, updated_at)
values
  ('10000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'owner-rbac@example.test', '', now(), now()),
  ('10000000-0000-4000-8000-000000000002', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'operation-rbac@example.test', '', now(), now());

insert into public.admin_users (id, auth_user_id, display_name, role)
values
  ('20000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000001', 'Owner Test', 'OWNER'),
  ('20000000-0000-4000-8000-000000000002', '10000000-0000-4000-8000-000000000002', 'Operation Test', 'OPERATION');

select is(public.service_admin_has_permission('20000000-0000-4000-8000-000000000001', 'FINANCE_VIEW'), true, 'owner can view finance');
select is(public.service_admin_has_permission('20000000-0000-4000-8000-000000000002', 'AGENDA_MANAGE'), true, 'operation can manage agenda by default');
select is(public.service_admin_has_permission('20000000-0000-4000-8000-000000000002', 'CUSTOMERS_MANAGE'), true, 'operation can manage customers by default');
select is(public.service_admin_has_permission('20000000-0000-4000-8000-000000000002', 'FINANCE_VIEW'), false, 'operation cannot view finance by default');
select is(public.service_admin_has_permission('20000000-0000-4000-8000-000000000002', 'FINANCE_MANAGE'), false, 'operation cannot manage finance by default');

select lives_ok(
  $$select public.service_admin_set_permission(
    '20000000-0000-4000-8000-000000000002'::uuid,
    'FINANCE_VIEW', true,
    '20000000-0000-4000-8000-000000000001'::uuid
  )$$,
  'owner can grant an explicit permission'
);

select is(public.service_admin_has_permission('20000000-0000-4000-8000-000000000002', 'FINANCE_VIEW'), true, 'explicit override grants finance view');
select is(
  (select count(*)::integer from public.audit_logs where entity_type = 'ADMIN_USER' and entity_id = '20000000-0000-4000-8000-000000000002' and action = 'PERMISSION_CHANGED'),
  1,
  'permission change is audited'
);

select is(
  (public.service_admin_get_access_profile('20000000-0000-4000-8000-000000000002')->>'role'),
  'OPERATION',
  'access profile exposes role'
);

select is(
  public.service_admin_resolve_auth_user('10000000-0000-4000-8000-000000000002'::uuid),
  '20000000-0000-4000-8000-000000000002'::uuid,
  'resolver maps an active auth user to the authoritative admin id'
);

update public.admin_users
set is_active = false
where id = '20000000-0000-4000-8000-000000000002';

select is(
  public.service_admin_resolve_auth_user('10000000-0000-4000-8000-000000000002'::uuid),
  null::uuid,
  'resolver fails closed for inactive administrative users'
);

select is(
  has_function_privilege('anon', 'public.service_admin_resolve_auth_user(uuid)', 'EXECUTE'),
  false,
  'anon cannot execute the administrative auth resolver'
);
select is(
  has_function_privilege('authenticated', 'public.service_admin_resolve_auth_user(uuid)', 'EXECUTE'),
  false,
  'authenticated clients cannot execute the administrative auth resolver'
);
select is(
  has_function_privilege('service_role', 'public.service_admin_resolve_auth_user(uuid)', 'EXECUTE'),
  true,
  'service_role can execute the administrative auth resolver'
);

select * from finish();
rollback;