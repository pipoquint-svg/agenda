begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(14);

-- Fixtures -------------------------------------------------------------------
insert into auth.users(id, email, created_at, updated_at)
values ('18100000-0000-4000-8000-000000000001', 'rewards-181-owner@example.test', now(), now());
insert into public.admin_users(id, auth_user_id, display_name, role, is_active)
values ('18100000-0000-4000-8000-000000000002', '18100000-0000-4000-8000-000000000001', 'Rewards 181 Owner', 'OWNER', true);
insert into public.tenants(id, name, slug, status) values ('18100000-0000-4000-8000-000000000030', 'Rewards 181', 'rewards-181', 'ACTIVE');
insert into public.employees(id, name) values ('18100000-0000-4000-8000-000000000003', 'Rewards 181 staff');
insert into public.categories(id, name, slug) values ('18100000-0000-4000-8000-000000000004', 'Rewards 181', 'rewards-181');
insert into public.services(
  id, category_id, name, slug, base_duration_minutes, base_price, buffer_before_minutes, buffer_after_minutes,
  minimum_people, maximum_people, minimum_booking_notice_minutes, maximum_booking_horizon_days, requires_terms,
  duration_mode, operation_scope, booking_product_type, service_type_id
) values
  ('18100000-0000-4000-8000-000000000010', '18100000-0000-4000-8000-000000000004', 'R181 rental', 'r181-rental', 60, 100, 0, 0, 1, 10, 0, 365, false,
   'FIXED', 'BLACKSHEEP', 'STANDARD', (select id from public.service_type where key = 'LOCACAO')),
  ('18100000-0000-4000-8000-000000000011', '18100000-0000-4000-8000-000000000004', 'R181 Sabrina', 'r181-sabrina', 60, 100, 0, 0, 1, 10, 0, 365, false,
   'FIXED', 'SABRINA', 'STANDARD', (select id from public.service_type where key = 'LOCACAO'));
insert into public.service_employees(id, service_id, employee_id) values
  ('18100000-0000-4000-8000-000000000020', '18100000-0000-4000-8000-000000000010', '18100000-0000-4000-8000-000000000003'),
  ('18100000-0000-4000-8000-000000000021', '18100000-0000-4000-8000-000000000011', '18100000-0000-4000-8000-000000000003');
insert into public.service_change_policies(service_id, notice_hours, reschedule_first_early_percent, reschedule_first_late_percent, reschedule_repeat_percent, cancellation_late_percent)
values ('18100000-0000-4000-8000-000000000010', 48, 0, 20, 30, 30), ('18100000-0000-4000-8000-000000000011', 48, 0, 20, 30, 30);
insert into public.customers(id, name, email, phone) values
  ('18100000-0000-4000-8000-0000000000c1', 'R181 Cliente', 'r181@example.test', '+5548999810001');

-- F: future rental. P: ended 1 hour ago, balance open. O: ended 8 days ago, balance open.
-- Q: ended 2 hours ago, already paid. S: Sabrina service, ended 1 hour ago, balance open.
insert into public.appointments(
  id, public_code, service_id, service_employee_id, primary_customer_id, status, financial_status,
  start_at, end_at, duration_minutes, people_count, service_name_snapshot, commercial_value, confirmed_at
) values
  ('18100000-0000-4000-8000-0000000000f1', 'R181-F', '18100000-0000-4000-8000-000000000010', '18100000-0000-4000-8000-000000000020', '18100000-0000-4000-8000-0000000000c1',
   'CONFIRMED', 'PARTIALLY_PAID', now() + interval '2 days', now() + interval '2 days 1 hour', 60, 1, 'R181 rental', 100, now()),
  ('18100000-0000-4000-8000-0000000000a1', 'R181-P', '18100000-0000-4000-8000-000000000010', '18100000-0000-4000-8000-000000000020', '18100000-0000-4000-8000-0000000000c1',
   'CONFIRMED', 'PARTIALLY_PAID', now() - interval '2 hours', now() - interval '1 hour', 60, 1, 'R181 rental', 100, now() - interval '3 days'),
  ('18100000-0000-4000-8000-0000000000a2', 'R181-O', '18100000-0000-4000-8000-000000000010', '18100000-0000-4000-8000-000000000020', '18100000-0000-4000-8000-0000000000c1',
   'CONFIRMED', 'PARTIALLY_PAID', now() - interval '8 days 1 hour', now() - interval '8 days', 60, 1, 'R181 rental', 100, now() - interval '10 days'),
  ('18100000-0000-4000-8000-0000000000a3', 'R181-Q', '18100000-0000-4000-8000-000000000010', '18100000-0000-4000-8000-000000000020', '18100000-0000-4000-8000-0000000000c1',
   'CONFIRMED', 'PAID', now() - interval '3 hours', now() - interval '2 hours', 60, 1, 'R181 rental', 100, now() - interval '3 days'),
  ('18100000-0000-4000-8000-0000000000a4', 'R181-S', '18100000-0000-4000-8000-000000000011', '18100000-0000-4000-8000-000000000021', '18100000-0000-4000-8000-0000000000c1',
   'CONFIRMED', 'PARTIALLY_PAID', now() - interval '5 hours', now() - interval '4 hours', 60, 1, 'R181 Sabrina', 100, now() - interval '3 days');

select set_config('r181.campaign', (public.service_admin_create_marketing_campaign(
  '18100000-0000-4000-8000-000000000030', 'r181-cashback', 'R181 Cashback', null, null,
  jsonb_build_object('trigger_kind','RENTAL_COMPLETED_FINANCIALLY_CLEARED','discount_type','PERCENT','discount_value',15,
    'discount_scope','SERVICE_ONLY','validity_basis','BOOKING_CONFIRMATION','validity_days',30,
    'eligibility_rules',jsonb_build_object('service_ids',jsonb_build_array('18100000-0000-4000-8000-000000000010'))),
  '18100000-0000-4000-8000-000000000002', '18100000-0000-4000-8000-000000000101')->>'campaign_id'), true);
select set_config('r181.coupon_issued', public.service_admin_upsert_rewards_message_template(
  '18100000-0000-4000-8000-000000000030', current_setting('r181.campaign')::uuid, 'REWARDS_COUPON_ISSUED', 'Cupom',
  'Oi {{customer.name}}, seu cupom {{coupon.code}} chegou.', '["customer.name","coupon.code"]'::jsonb,
  '18100000-0000-4000-8000-000000000002')::text, true);
select set_config('r181.winback', public.service_admin_upsert_rewards_message_template(
  '18100000-0000-4000-8000-000000000030', current_setting('r181.campaign')::uuid, 'REWARDS_WINBACK', 'Volte',
  'Oi {{customer.name}}, volte.', '["customer.name"]'::jsonb,
  '18100000-0000-4000-8000-000000000002')::text, true);

-- Trigger rules ------------------------------------------------------------------
select has_trigger('public', 'appointments', 'appointments_enqueue_rewards_coupon_after_payment', 'payment trigger exists');
select throws_ok($$select public.service_admin_update_notification_trigger_v1(current_setting('r181.coupon_issued')::uuid, 'BEFORE_END', 30, '{}', '18100000-0000-4000-8000-000000000002')$$,
  '23514', null, 'the coupon message only goes after the reservation ends');
select throws_ok($$select public.service_admin_update_notification_trigger_v1(current_setting('r181.winback')::uuid, 'AFTER_END', 30, '{}', '18100000-0000-4000-8000-000000000002')$$,
  '23514', null, 'other Rewards messages have no reservation trigger');
select lives_ok($$select public.service_admin_update_notification_trigger_v1(current_setting('r181.coupon_issued')::uuid, 'AFTER_END', 30, '{}', '18100000-0000-4000-8000-000000000002')$$,
  'the coupon message goes 30 minutes after the end');

select is((select run_after from public.integration_jobs where entity_id = '18100000-0000-4000-8000-0000000000f1'
    and payload_json->>'template_id' = current_setting('r181.coupon_issued')),
  (select core_end_at + interval '30 minutes' from public.appointments where id = '18100000-0000-4000-8000-0000000000f1'),
  'a future reservation is scheduled 30 minutes after its end');
select is((select payload_json->>'event_key' from public.integration_jobs where entity_id = '18100000-0000-4000-8000-0000000000f1'
    and payload_json->>'template_id' = current_setting('r181.coupon_issued')), 'REWARDS_COUPON_ISSUED', 'the job carries the Rewards event');
select is(public.enqueue_scheduled_notification_templates('18100000-0000-4000-8000-0000000000f1'), 0, 'scheduling again adds no duplicate');

-- Activation rules ---------------------------------------------------------------
select lives_ok($$update public.notification_template_configs set is_active = true where id = current_setting('r181.coupon_issued')::uuid$$,
  'the coupon message can be turned on');
select throws_ok($$update public.notification_template_configs set is_active = true where id = current_setting('r181.winback')::uuid$$,
  '23514', null, 'other Rewards messages stay off');

-- Payment after the end ----------------------------------------------------------
update public.appointments set financial_status = 'PAID' where id in (
  '18100000-0000-4000-8000-0000000000a1', '18100000-0000-4000-8000-0000000000a2',
  '18100000-0000-4000-8000-0000000000a3', '18100000-0000-4000-8000-0000000000a4');
select ok((select run_after <= now() + interval '1 second' from public.integration_jobs
    where idempotency_key = 'rewards-paid:' || current_setting('r181.coupon_issued') || ':18100000-0000-4000-8000-0000000000a1'),
  'paying a reservation that ended 1 hour ago queues the coupon now');
select is((select payload_json->>'reason' from public.integration_jobs
    where idempotency_key = 'rewards-paid:' || current_setting('r181.coupon_issued') || ':18100000-0000-4000-8000-0000000000a1'), 'PAID', 'the job says why');
select is((select count(*)::integer from public.integration_jobs where entity_id = '18100000-0000-4000-8000-0000000000a2' and idempotency_key like 'rewards-paid:%'),
  0, 'more than 7 days after the end, payment queues nothing');
select is((select count(*)::integer from public.integration_jobs where entity_id = '18100000-0000-4000-8000-0000000000a3' and idempotency_key like 'rewards-paid:%'),
  0, 'a reservation that was already paid is not queued again');
select is((select count(*)::integer from public.integration_jobs where entity_id = '18100000-0000-4000-8000-0000000000a4' and idempotency_key like 'rewards-paid:%'),
  0, 'only BlackSheep reservations');

select * from finish();
rollback;
