begin;

select plan(10);

select has_function(
  'public',
  'service_admin_get_access_profile_by_auth_user',
  array['uuid'],
  'service-role admin Auth resolver exists'
);

select is(
  (select prosecdef from pg_proc where oid = 'public.service_admin_get_access_profile_by_auth_user(uuid)'::regprocedure),
  true,
  'admin Auth resolver is SECURITY DEFINER'
);

select ok(
  (select position('search_path=' in array_to_string(proconfig, ',')) > 0
   from pg_proc
   where oid = 'public.service_admin_get_access_profile_by_auth_user(uuid)'::regprocedure),
  'admin Auth resolver fixes its search_path'
);

select is(
  has_function_privilege('anon', 'public.service_admin_get_access_profile_by_auth_user(uuid)', 'EXECUTE'),
  false,
  'anon cannot execute the admin Auth resolver'
);

select is(
  has_function_privilege('authenticated', 'public.service_admin_get_access_profile_by_auth_user(uuid)', 'EXECUTE'),
  false,
  'authenticated cannot execute the admin Auth resolver'
);

select is(
  has_function_privilege('service_role', 'public.service_admin_get_access_profile_by_auth_user(uuid)', 'EXECUTE'),
  true,
  'service_role can execute the admin Auth resolver'
);

select is(
  has_table_privilege('service_role', 'public.admin_users', 'SELECT'),
  false,
  'service_role still cannot select admin_users directly'
);

insert into auth.users (id, instance_id, aud, role, email, encrypted_password, created_at, updated_at)
values (
  '10000000-0000-4000-8000-000000000124',
  '00000000-0000-0000-0000-000000000000',
  'authenticated',
  'authenticated',
  'admin-auth-resolver@example.test',
  '',
  now(),
  now()
);

insert into public.admin_users (id, auth_user_id, display_name, role, is_active)
values (
  '20000000-0000-4000-8000-000000000124',
  '10000000-0000-4000-8000-000000000124',
  'Admin Auth Resolver',
  'ADMIN',
  true
);

select is(
  public.service_admin_get_access_profile_by_auth_user('10000000-0000-4000-8000-000000000124'::uuid)->>'admin_user_id',
  '20000000-0000-4000-8000-000000000124',
  'resolver maps the validated Auth user to the administrative profile'
);

select is(
  public.service_admin_get_access_profile_by_auth_user('10000000-0000-4000-8000-000000000124'::uuid)->'permissions'->>'AGENDA_VIEW',
  'true',
  'resolver returns the authoritative RBAC permissions'
);

update public.admin_users
set is_active = false
where id = '20000000-0000-4000-8000-000000000124'::uuid;

select is(
  public.service_admin_get_access_profile_by_auth_user('10000000-0000-4000-8000-000000000124'::uuid),
  null,
  'inactive administrators fail closed'
);

select * from finish();
rollback;
