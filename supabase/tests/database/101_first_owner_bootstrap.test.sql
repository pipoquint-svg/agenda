begin;

select plan(12);

select has_function(
  'public',
  'service_bootstrap_first_owner',
  array['uuid','text','uuid'],
  'first owner bootstrap function exists'
);

select is(
  (select prosecdef from pg_proc where oid = 'public.service_bootstrap_first_owner(uuid,text,uuid)'::regprocedure),
  true,
  'bootstrap is SECURITY DEFINER'
);

select is(
  (select proconfig @> array['search_path=public'] from pg_proc where oid = 'public.service_bootstrap_first_owner(uuid,text,uuid)'::regprocedure),
  true,
  'bootstrap fixes search_path to public'
);

select is(
  has_function_privilege('anon', 'public.service_bootstrap_first_owner(uuid,text,uuid)', 'EXECUTE'),
  false,
  'anon cannot execute bootstrap'
);

select is(
  has_function_privilege('authenticated', 'public.service_bootstrap_first_owner(uuid,text,uuid)', 'EXECUTE'),
  false,
  'authenticated cannot execute bootstrap'
);

select is(
  has_function_privilege('service_role', 'public.service_bootstrap_first_owner(uuid,text,uuid)', 'EXECUTE'),
  true,
  'service_role can execute bootstrap'
);

insert into auth.users (id, instance_id, aud, role, email, encrypted_password, created_at, updated_at)
values (
  '10000000-0000-4000-8000-000000000101',
  '00000000-0000-0000-0000-000000000000',
  'authenticated',
  'authenticated',
  'first-owner-bootstrap@example.test',
  '',
  now(),
  now()
);

select is(
  public.service_bootstrap_first_owner(
    '10000000-0000-4000-8000-000000000101'::uuid,
    ' First Owner ',
    '30000000-0000-4000-8000-000000000101'::uuid
  )->>'role',
  'OWNER',
  'bootstrap creates an OWNER profile'
);

select is(
  (select display_name from public.admin_users where auth_user_id = '10000000-0000-4000-8000-000000000101'::uuid),
  'First Owner',
  'bootstrap normalizes display name'
);

select is(
  (select public.service_admin_has_permission(id, 'TEAM_MANAGE') from public.admin_users where auth_user_id = '10000000-0000-4000-8000-000000000101'::uuid),
  true,
  'first OWNER inherits TEAM_MANAGE without explicit overrides'
);

select is(
  (select count(*)::integer from public.admin_user_permissions),
  0,
  'bootstrap does not create redundant permission overrides'
);

select is(
  (select count(*)::integer from public.audit_logs where action = 'FIRST_OWNER_BOOTSTRAPPED' and request_id = '30000000-0000-4000-8000-000000000101'::uuid),
  1,
  'bootstrap is recorded in append-only audit log'
);

update public.admin_users
set is_active = false
where auth_user_id = '10000000-0000-4000-8000-000000000101'::uuid;

select throws_ok(
  $$select public.service_bootstrap_first_owner(
    '10000000-0000-4000-8000-000000000101'::uuid,
    'First Owner Again',
    '30000000-0000-4000-8000-000000000102'::uuid
  )$$,
  'P0001',
  'ADMIN_BOOTSTRAP_CLOSED',
  'deactivating the first owner never reopens bootstrap'
);

select * from finish();
rollback;
