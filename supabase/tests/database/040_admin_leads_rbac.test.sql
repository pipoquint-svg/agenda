begin;
create extension if not exists pgtap with schema extensions;
set local search_path=public,extensions;
select plan(7);

insert into auth.users (id, instance_id, aud, role, email, encrypted_password, created_at, updated_at)
values
  ('13000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'owner-leads@example.test', '', now(), now()),
  ('13000000-0000-4000-8000-000000000002', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'operation-leads@example.test', '', now(), now());

insert into public.admin_users (id, auth_user_id, display_name, role)
values
  ('23000000-0000-4000-8000-000000000001', '13000000-0000-4000-8000-000000000001', 'Owner Leads', 'OWNER'),
  ('23000000-0000-4000-8000-000000000002', '13000000-0000-4000-8000-000000000002', 'Operation Leads', 'OPERATION');

select ok(public.service_admin_has_permission('23000000-0000-4000-8000-000000000001', 'LEADS_VIEW'), 'owner can view leads');
select ok(public.service_admin_has_permission('23000000-0000-4000-8000-000000000001', 'LEADS_MANAGE'), 'owner can manage leads');
select ok(not public.service_admin_has_permission('23000000-0000-4000-8000-000000000002', 'LEADS_VIEW'), 'operation does not receive lead PII access implicitly');
select ok(not public.service_admin_has_permission('23000000-0000-4000-8000-000000000002', 'LEADS_MANAGE'), 'operation does not receive lead mutation implicitly');

select lives_ok($$
  select public.service_admin_set_permission(
    '23000000-0000-4000-8000-000000000002', 'LEADS_VIEW', true,
    '23000000-0000-4000-8000-000000000001'
  )
$$, 'owner can explicitly grant leads view');

select ok(public.service_admin_has_permission('23000000-0000-4000-8000-000000000002', 'LEADS_VIEW'), 'explicit leads view grant takes effect');
select ok(
  (public.service_admin_get_access_profile('23000000-0000-4000-8000-000000000002')->'permissions') ? 'LEADS_VIEW'
  and (public.service_admin_get_access_profile('23000000-0000-4000-8000-000000000002')->'permissions') ? 'LEADS_MANAGE',
  'access profile exposes both leads permissions'
);

select * from finish();
rollback;
