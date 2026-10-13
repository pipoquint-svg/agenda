begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(6);

insert into auth.users(id,email,created_at,updated_at) values
  ('16800000-0000-4000-8000-000000000001','active-admin@example.test',now(),now()),
  ('16800000-0000-4000-8000-000000000002','inactive-admin@example.test',now(),now()),
  ('16800000-0000-4000-8000-000000000003','not-admin@example.test',now(),now());
insert into public.admin_users(id,auth_user_id,display_name,role,is_active) values
  ('16800000-0000-4000-8000-000000000011','16800000-0000-4000-8000-000000000001','Ativo','OWNER',true),
  ('16800000-0000-4000-8000-000000000012','16800000-0000-4000-8000-000000000002','Inativo','OWNER',false);

select is(
  public.service_admin_resolve_access_profile('16800000-0000-4000-8000-000000000001'),
  public.service_admin_get_access_profile('16800000-0000-4000-8000-000000000011'),
  'same profile as resolving the admin and reading the access profile');
select is(
  public.service_admin_resolve_access_profile('16800000-0000-4000-8000-000000000001')->>'admin_user_id',
  '16800000-0000-4000-8000-000000000011', 'profile carries the admin id');
select is(public.service_admin_resolve_access_profile('16800000-0000-4000-8000-000000000002'), null::jsonb, 'inactive admin is not resolved');
select is(public.service_admin_resolve_access_profile('16800000-0000-4000-8000-000000000003'), null::jsonb, 'non-admin user is not resolved');
select ok(
  has_function_privilege('service_role','public.service_admin_resolve_access_profile(uuid)','EXECUTE')
  and not has_function_privilege('anon','public.service_admin_resolve_access_profile(uuid)','EXECUTE')
  and not has_function_privilege('authenticated','public.service_admin_resolve_access_profile(uuid)','EXECUTE'),
  'executable only by service_role');
select ok(
  (select prosecdef and pg_get_userbyid(proowner) = 'postgres' from pg_proc
   where oid = 'public.service_admin_resolve_access_profile(uuid)'::regprocedure),
  'security definer owned by postgres');

select * from finish();
rollback;
