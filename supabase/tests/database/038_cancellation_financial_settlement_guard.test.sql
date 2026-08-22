begin;
create extension if not exists pgtap with schema extensions;
set local search_path=public,extensions;
select plan(4);

insert into auth.users (id, instance_id, aud, role, email, encrypted_password, created_at, updated_at)
values
  ('11000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'owner-settlement@example.test', '', now(), now()),
  ('11000000-0000-4000-8000-000000000002', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'operation-settlement@example.test', '', now(), now());

insert into public.admin_users (id, auth_user_id, display_name, role)
values
  ('21000000-0000-4000-8000-000000000001', '11000000-0000-4000-8000-000000000001', 'Owner Settlement', 'OWNER'),
  ('21000000-0000-4000-8000-000000000002', '11000000-0000-4000-8000-000000000002', 'Operation Settlement', 'OPERATION');

select has_function(
  'public','service_admin_assert_financial_settlement_permission',array['uuid'],
  'financial settlement permission guard exists'
);
select has_trigger(
  'public','appointment_policy_actions','appointment_policy_actions_financial_settlement_guard',
  'cancellation settlement trigger exists'
);
select throws_ok(
  $$select public.service_admin_assert_financial_settlement_permission('21000000-0000-4000-8000-000000000002'::uuid)$$,
  'P0001','ADMIN_PERMISSION_DENIED',
  'operation user cannot choose refund or credit'
);
select lives_ok(
  $$select public.service_admin_assert_financial_settlement_permission('21000000-0000-4000-8000-000000000001'::uuid)$$,
  'owner can choose refund or credit'
);

select * from finish();
rollback;