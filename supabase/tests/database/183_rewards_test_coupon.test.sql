begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(14);

insert into auth.users(id, email, created_at, updated_at) values
  ('18300000-0000-4000-8000-000000000001', 'r183-owner@example.test', now(), now()),
  ('18300000-0000-4000-8000-000000000003', 'r183-operation@example.test', now(), now());
insert into public.admin_users(id, auth_user_id, display_name, role, is_active) values
  ('18300000-0000-4000-8000-000000000002', '18300000-0000-4000-8000-000000000001', 'R183 Owner', 'OWNER', true),
  ('18300000-0000-4000-8000-000000000004', '18300000-0000-4000-8000-000000000003', 'R183 Operation', 'OPERATION', true);
insert into public.categories(id, name, slug) values ('18300000-0000-4000-8000-000000000005', 'R183', 'r183');
insert into public.services(id, category_id, name, slug, base_duration_minutes, base_price, minimum_people, maximum_people, operation_scope)
values ('18300000-0000-4000-8000-000000000010', '18300000-0000-4000-8000-000000000005', 'R183 rental', 'r183-rental', 60, 100, 1, 10, 'BLACKSHEEP');
insert into public.customers(id, name, email, phone) values
  ('18300000-0000-4000-8000-0000000000a1', 'R183 Tester', 'r183-tester@example.test', '(48) 98183-0001'),
  ('18300000-0000-4000-8000-0000000000b1', 'R183 Twin 1', 'r183-twin1@example.test', '+5548981830002'),
  ('18300000-0000-4000-8000-0000000000b2', 'R183 Twin 2', 'r183-twin2@example.test', '48981830002');

select set_config('r183.c', (public.service_admin_create_marketing_campaign(
  '8fba3c57-c0e6-4a37-b7d3-4cf41e5fb65f', 'r183-cashback', 'R183 Cashback', null, null,
  jsonb_build_object('trigger_kind','RENTAL_COMPLETED_FINANCIALLY_CLEARED','discount_type','PERCENT','discount_value',15,
    'discount_scope','SERVICE_ONLY','validity_basis','BOOKING_CONFIRMATION','validity_days',30,
    'eligibility_rules',jsonb_build_object('service_ids',jsonb_build_array('18300000-0000-4000-8000-000000000010'))),
  '18300000-0000-4000-8000-000000000002', gen_random_uuid())->>'campaign_id'), true);

select ok(
  has_function_privilege('service_role', 'public.service_admin_issue_rewards_test_coupon(uuid,uuid,text,uuid,boolean)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.service_admin_issue_rewards_test_coupon(uuid,uuid,text,uuid,boolean)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.service_admin_issue_rewards_test_coupon(uuid,uuid,text,uuid,boolean)', 'EXECUTE'),
  'only the trusted backend issues test coupons'
);
select set_config('r183.t', public.service_admin_issue_rewards_test_coupon(
  '8fba3c57-c0e6-4a37-b7d3-4cf41e5fb65f', current_setting('r183.c')::uuid, '5548981830001', '18300000-0000-4000-8000-000000000002')::text, true);
select is((current_setting('r183.t')::jsonb->>'customer_id')::uuid, '18300000-0000-4000-8000-0000000000a1'::uuid, 'the customer is found by phone, whatever the format');
select is(
  (select row(customer_id, source, discount_type, discount_value::text, max_uses, max_uses_per_customer, discount_scope, validity_basis, is_active)::text
   from public.coupons where id = (current_setting('r183.t')::jsonb->>'coupon_id')::uuid),
  row('18300000-0000-4000-8000-0000000000a1'::uuid, 'PROMOTION', 'PERCENT', '15.00', 1, 1, 'SERVICE_ONLY', 'BOOKING_CONFIRMATION', true)::text,
  'a real single-use coupon from the campaign offer, bound to the customer'
);
select ok((select valid_until between now() + interval '29 days' and now() + interval '31 days' from public.coupons where id = (current_setting('r183.t')::jsonb->>'coupon_id')::uuid), 'with the campaign validity');
select is((select array_agg(service_id) from public.coupon_services where coupon_id = (current_setting('r183.t')::jsonb->>'coupon_id')::uuid),
  array['18300000-0000-4000-8000-000000000010'::uuid], 'for the campaign services');
select is((select count(*)::integer from public.marketing_campaign_issuances where campaign_id = current_setting('r183.c')::uuid), 0, 'it is not a campaign issuance');
select is((select count(*)::integer from public.audit_logs where action = 'REWARDS_TEST_COUPON_ISSUED' and entity_id = (current_setting('r183.t')::jsonb->>'coupon_id')::uuid), 1, 'it is audited');
select throws_ok($$select public.service_admin_issue_rewards_test_coupon('8fba3c57-c0e6-4a37-b7d3-4cf41e5fb65f', current_setting('r183.c')::uuid, '5548981830009', '18300000-0000-4000-8000-000000000002')$$,
  'P0001', 'REWARDS_TEST_CUSTOMER_NOT_FOUND', 'an unknown phone is refused');
select throws_ok($$select public.service_admin_issue_rewards_test_coupon('8fba3c57-c0e6-4a37-b7d3-4cf41e5fb65f', current_setting('r183.c')::uuid, '48981830002', '18300000-0000-4000-8000-000000000002')$$,
  'P0001', 'REWARDS_TEST_CUSTOMER_AMBIGUOUS', 'two records with the same phone are refused');
select throws_ok($$select public.service_admin_issue_rewards_test_coupon('8fba3c57-c0e6-4a37-b7d3-4cf41e5fb65f', current_setting('r183.c')::uuid, '5548981830001', '18300000-0000-4000-8000-000000000004')$$,
  '42501', 'MARKETING_CAMPAIGN_ADMIN_PERMISSION_DENIED', 'only OWNER and ADMIN');

-- The reminder reuses the coupon the customer already has.
select throws_ok($$select public.service_admin_issue_rewards_test_coupon('8fba3c57-c0e6-4a37-b7d3-4cf41e5fb65f', current_setting('r183.c')::uuid, '48981830002', '18300000-0000-4000-8000-000000000002', true)$$,
  'P0001', 'REWARDS_TEST_CUSTOMER_AMBIGUOUS', 'the reminder still needs exactly one customer');
select set_config('r183.r', public.service_admin_issue_rewards_test_coupon(
  '8fba3c57-c0e6-4a37-b7d3-4cf41e5fb65f', current_setting('r183.c')::uuid, '5548981830001', '18300000-0000-4000-8000-000000000002', true)::text, true);
select is(current_setting('r183.r')::jsonb->>'coupon_id', current_setting('r183.t')::jsonb->>'coupon_id', 'the reminder test reuses the same coupon');
select is((select count(*)::integer from public.coupons where customer_id = '18300000-0000-4000-8000-0000000000a1'), 1, 'no new coupon for a reminder');
update public.coupons set used_count = 1 where id = (current_setting('r183.t')::jsonb->>'coupon_id')::uuid;
select throws_ok($$select public.service_admin_issue_rewards_test_coupon('8fba3c57-c0e6-4a37-b7d3-4cf41e5fb65f', current_setting('r183.c')::uuid, '5548981830001', '18300000-0000-4000-8000-000000000002', true)$$,
  'P0001', 'REWARDS_TEST_NO_COUPON_TO_REMIND', 'a used coupon has nothing to remind');

select * from finish();
rollback;
