begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(24);

-- Fixtures -------------------------------------------------------------------
insert into auth.users(id, email, created_at, updated_at)
values ('18200000-0000-4000-8000-000000000001', 'rewards-182-owner@example.test', now(), now());
insert into public.admin_users(id, auth_user_id, display_name, role, is_active)
values ('18200000-0000-4000-8000-000000000002', '18200000-0000-4000-8000-000000000001', 'Rewards 182 Owner', 'OWNER', true);
insert into public.employees(id, name) values ('18200000-0000-4000-8000-000000000003', 'Rewards 182 staff');
insert into public.categories(id, name, slug) values ('18200000-0000-4000-8000-000000000004', 'Rewards 182', 'rewards-182');
insert into public.services(
  id, category_id, name, slug, base_duration_minutes, base_price, buffer_before_minutes, buffer_after_minutes,
  minimum_people, maximum_people, minimum_booking_notice_minutes, maximum_booking_horizon_days, requires_terms,
  duration_mode, operation_scope, booking_product_type, service_type_id
) values ('18200000-0000-4000-8000-000000000010', '18200000-0000-4000-8000-000000000004', 'R182 rental', 'r182-rental', 60, 100, 0, 0, 1, 10, 0, 365, false,
  'FIXED', 'BLACKSHEEP', 'STANDARD', (select id from public.service_type where key = 'LOCACAO'));
insert into public.service_employees(id, service_id, employee_id)
values ('18200000-0000-4000-8000-000000000020', '18200000-0000-4000-8000-000000000010', '18200000-0000-4000-8000-000000000003');
insert into public.service_change_policies(service_id, notice_hours, reschedule_first_early_percent, reschedule_first_late_percent, reschedule_repeat_percent, cancellation_late_percent)
values ('18200000-0000-4000-8000-000000000010', 48, 0, 20, 30, 30);

-- R refers F and G; both first rentals are realized and paid.
insert into public.customers(id, name, email, phone, cpf_cnpj) values
  ('18200000-0000-4000-8000-0000000000a1', 'R182 Referrer', 'r182-referrer@example.test', '+5548999820101', '11111111182'),
  ('18200000-0000-4000-8000-0000000000b1', 'R182 Friend F', 'r182-f@example.test', '+5548999820102', '22222222182'),
  ('18200000-0000-4000-8000-0000000000c1', 'R182 Friend G', 'r182-g@example.test', '+5548999820103', '33333333182');
insert into public.appointments(
  id, public_code, service_id, service_employee_id, primary_customer_id, status, financial_status,
  start_at, end_at, duration_minutes, people_count, service_name_snapshot, commercial_value, confirmed_at
) values
  ('18200000-0000-4000-8000-0000000000a2', 'R182-R-OLD', '18200000-0000-4000-8000-000000000010', '18200000-0000-4000-8000-000000000020', '18200000-0000-4000-8000-0000000000a1',
   'CONFIRMED', 'PAID', now() - interval '30 days', now() - interval '30 days' + interval '1 hour', 60, 1, 'R182 rental', 100, now() - interval '40 days'),
  ('18200000-0000-4000-8000-0000000000b2', 'R182-F-FIRST', '18200000-0000-4000-8000-000000000010', '18200000-0000-4000-8000-000000000020', '18200000-0000-4000-8000-0000000000b1',
   'CONFIRMED', 'PAID', now() - interval '5 days', now() - interval '5 days' + interval '1 hour', 60, 1, 'R182 rental', 85, now() - interval '10 days'),
  ('18200000-0000-4000-8000-0000000000c2', 'R182-G-FIRST', '18200000-0000-4000-8000-000000000010', '18200000-0000-4000-8000-000000000020', '18200000-0000-4000-8000-0000000000c1',
   'CONFIRMED', 'PAID', now() - interval '3 days', now() - interval '3 days' + interval '1 hour', 60, 1, 'R182 rental', 85, now() - interval '8 days');

-- Referral campaign: the friend gets 15%, the referrer earns 2 free hours, no monthly limit.
create temporary table r182(campaign_id uuid, version_id uuid) on commit drop;
do $$
declare v_created jsonb;
begin
  v_created := public.service_admin_create_marketing_campaign(
    '8fba3c57-c0e6-4a37-b7d3-4cf41e5fb65f', 'r182-referral-hours', 'R182 Indicação em horas', null, null,
    jsonb_build_object(
      'trigger_kind', 'REFERRAL_FIRST_RENTAL', 'discount_type', 'PERCENT', 'discount_value', 15, 'discount_scope', 'SERVICE_ONLY',
      'validity_basis', 'BOOKING_CONFIRMATION', 'validity_days', 180, 'max_uses', 1, 'max_uses_per_customer', 1,
      'applies_to_extras', false, 'applies_to_hour_packages', false, 'stacking_policy', 'EXCLUSIVE', 'recurring_after_discounted_rental', true,
      'eligibility_rules', jsonb_build_object('service_ids', jsonb_build_array('18200000-0000-4000-8000-000000000010')),
      'trigger_rules', jsonb_build_object('referred_discount_type', 'PERCENT', 'referred_discount_value', 15, 'monthly_cap', null,
        'referrer_reward', 'HOURS', 'referrer_reward_minutes', 120, 'referrer_reward_validity_days', 180)
    ),
    '18200000-0000-4000-8000-000000000002', gen_random_uuid()
  );
  perform public.service_admin_transition_marketing_campaign(
    (v_created->>'campaign_id')::uuid, 'ACTIVE', (v_created->>'version_id')::uuid, 'R182 fixture',
    '18200000-0000-4000-8000-000000000002', gen_random_uuid()
  );
  insert into r182 values ((v_created->>'campaign_id')::uuid, (v_created->>'version_id')::uuid);
end
$$;
create function pg_temp.campaign() returns uuid language sql as $$ select campaign_id from r182 $$;
select set_config('agenda.r182.code', public.service_ensure_marketing_referral_code(pg_temp.campaign(), '18200000-0000-4000-8000-0000000000a1')::text, true);
insert into public.appointment_discounts(appointment_id, coupon_id, code_snapshot, discount_type_snapshot, discount_value_snapshot, calculated_discount_amount)
values ('18200000-0000-4000-8000-0000000000b2', (current_setting('agenda.r182.code')::jsonb->>'coupon_id')::uuid, 'IND', 'PERCENT', 15, 15),
       ('18200000-0000-4000-8000-0000000000c2', (current_setting('agenda.r182.code')::jsonb->>'coupon_id')::uuid, 'IND', 'PERCENT', 15, 15);

-- Tests --------------------------------------------------------------------------
select ok(
  has_function_privilege('service_role', 'public.service_issue_marketing_referral_hours(uuid,uuid,text)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.service_issue_marketing_referral_hours(uuid,uuid,text)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.service_issue_marketing_referral_hours(uuid,uuid,text)', 'EXECUTE'),
  'hour rewards are issued by the trusted backend only'
);

select set_config('agenda.r182.f', public.service_issue_marketing_referral_hours(pg_temp.campaign(), '18200000-0000-4000-8000-0000000000b2', 'r182-reward-f')::text, true);
select is((current_setting('agenda.r182.f')::jsonb->>'customer_id')::uuid, '18200000-0000-4000-8000-0000000000a1'::uuid, 'the referrer earns the hours');
select is((current_setting('agenda.r182.f')::jsonb->>'minutes')::integer, 120, 'two hours per referral');
select is(
  (select row(origin, purchased_value::text, total_minutes, special_surcharge_percent::text, standard_start_local_time::text, standard_end_local_time::text, status)::text
   from public.hour_packages where id = (current_setting('agenda.r182.f')::jsonb->>'hour_package_id')::uuid),
  row('REWARDS', '0.00', 120, '0.00', '00:00:00', '23:59:59', 'ACTIVE')::text,
  'a free hour package: zero value, any time of day, no surcharge'
);
select ok(
  (select valid_until between now() + interval '179 days' and now() + interval '181 days' from public.hour_packages
   where id = (current_setting('agenda.r182.f')::jsonb->>'hour_package_id')::uuid),
  'valid for 180 days'
);
select is(
  (select available_minutes from public.hour_package_balances where hour_package_id = (current_setting('agenda.r182.f')::jsonb->>'hour_package_id')::uuid),
  120::bigint, 'the hours are available to use'
);
select is(
  (select array_agg(service_id) from public.hour_package_services where hour_package_id = (current_setting('agenda.r182.f')::jsonb->>'hour_package_id')::uuid),
  array['18200000-0000-4000-8000-000000000010'::uuid], 'it pays the campaign services'
);
select ok(
  (select coupon_id is null and hour_package_id is not null and reward_minutes = 120 from public.marketing_campaign_issuances where idempotency_key = 'r182-reward-f'),
  'the issuance records the minutes added to the hour balance, not a coupon'
);
select is(
  (public.service_issue_marketing_referral_hours(pg_temp.campaign(), '18200000-0000-4000-8000-0000000000b2', 'r182-reward-f')->>'hour_package_id'),
  current_setting('agenda.r182.f')::jsonb->>'hour_package_id', 'the same request is a replay'
);
select throws_ok(
  $$select public.service_issue_marketing_referral_hours(pg_temp.campaign(), '18200000-0000-4000-8000-0000000000b2', 'r182-reward-f-again')$$,
  'P0001', 'MARKETING_CAMPAIGN_ISSUANCE_INELIGIBLE', 'one reward per referred rental'
);
select lives_ok(
  $$select public.service_issue_marketing_referral_hours(pg_temp.campaign(), '18200000-0000-4000-8000-0000000000c2', 'r182-reward-g')$$,
  'no monthly limit: a second referral in the same month also pays'
);
select is(
  (select sum(available_minutes) from public.hour_package_balances where customer_id = '18200000-0000-4000-8000-0000000000a1'),
  240::numeric, 'the hours add up: two referrals, four free hours'
);
select is(
  (select count(*)::integer from public.hour_packages where customer_id = '18200000-0000-4000-8000-0000000000a1' and origin = 'REWARDS'),
  1, 'in one balance, so a single booking can use all four hours'
);
select is(
  (select row(m.minutes_delta, m.reason)::text from public.hour_package_movements m
   where m.hour_package_id = (current_setting('agenda.r182.f')::jsonb->>'hour_package_id')::uuid and m.movement_type = 'ADMIN_ADJUSTMENT'),
  row(120, 'REWARDS_REFERRAL')::text, 'the second reward is a recorded top-up'
);
select throws_ok(
  $$insert into public.hour_packages(customer_id, name, total_minutes, purchased_value, valid_from, valid_until, standard_start_local_time, standard_end_local_time)
    values ('18200000-0000-4000-8000-0000000000a1', 'Zero', 60, 0, now(), now() + interval '1 day', '09:00', '18:00')$$,
  '23514', null, 'a purchased package still needs a value'
);

-- Using the free hours at checkout: a 1-hour booking next Saturday night uses part of the balance.
insert into public.checkout_holds(id, public_token_hash, service_id, service_employee_id, selection_hash, people_count, requested_start_at, requested_end_at, expires_at, primary_customer_id, duration_minutes)
values ('18200000-0000-4000-8000-000000000030', repeat('c', 64), '18200000-0000-4000-8000-000000000010', '18200000-0000-4000-8000-000000000020', repeat('d', 64), 1,
        (date_trunc('week', now() at time zone 'America/Sao_Paulo') + interval '12 days 21 hours') at time zone 'America/Sao_Paulo',
        (date_trunc('week', now() at time zone 'America/Sao_Paulo') + interval '12 days 22 hours') at time zone 'America/Sao_Paulo',
        now() + interval '20 minutes', '18200000-0000-4000-8000-0000000000a1', 60);
select set_config('agenda.r182.quote', public.calculate_hour_package_quote(
  (current_setting('agenda.r182.f')::jsonb->>'hour_package_id')::uuid, '18200000-0000-4000-8000-000000000030', '18200000-0000-4000-8000-0000000000a1')::text, true);
select is(
  (select row(q->>'covered_minutes', q->>'surcharge_seconds', q->>'covered_reference_value')::text from (select current_setting('agenda.r182.quote')::jsonb q) x),
  row('60', '0', '0.00')::text,
  'the free hour pays a Saturday-night hour with no surcharge and no revenue'
);
select lives_ok(
  $$select public.reserve_hour_package_for_checkout((current_setting('agenda.r182.f')::jsonb->>'hour_package_id')::uuid, '18200000-0000-4000-8000-000000000030', '18200000-0000-4000-8000-0000000000a1')$$,
  'and can be held for the booking'
);

-- The referral reward message: scheduled after the end and queued on payment.
select set_config('agenda.r182.msg', public.service_admin_upsert_rewards_message_template(
  '8fba3c57-c0e6-4a37-b7d3-4cf41e5fb65f', pg_temp.campaign(), 'REWARDS_REFERRAL_REWARD', 'Indicação premiada',
  'Oi {{customer.name}}, você ganhou {{reward.hours}}.', '["customer.name","reward.hours"]'::jsonb,
  '18200000-0000-4000-8000-000000000002')::text, true);
select lives_ok(
  $$select public.service_admin_update_notification_trigger_v1(current_setting('agenda.r182.msg')::uuid, 'AFTER_END', 30, '{}', '18200000-0000-4000-8000-000000000002')$$,
  'the referral reward message goes after the reservation ends'
);
select lives_ok(
  $$update public.notification_template_configs set is_active = true where id = current_setting('agenda.r182.msg')::uuid$$,
  'and can be turned on'
);
insert into public.customers(id, name, email, phone) values ('18200000-0000-4000-8000-0000000000d1', 'R182 Friend H', 'r182-h@example.test', '+5548999820104');
insert into public.appointments(
  id, public_code, service_id, service_employee_id, primary_customer_id, status, financial_status,
  start_at, end_at, duration_minutes, people_count, service_name_snapshot, commercial_value, confirmed_at
) values ('18200000-0000-4000-8000-0000000000d2', 'R182-H-FIRST', '18200000-0000-4000-8000-000000000010', '18200000-0000-4000-8000-000000000020', '18200000-0000-4000-8000-0000000000d1',
   'CONFIRMED', 'PARTIALLY_PAID', now() - interval '2 hours', now() - interval '1 hour', 60, 1, 'R182 rental', 85, now() - interval '3 days');
update public.appointments set financial_status = 'PAID' where id = '18200000-0000-4000-8000-0000000000d2';
select is(
  (select payload_json->>'event_key' from public.integration_jobs
   where idempotency_key = 'rewards-paid:' || current_setting('agenda.r182.msg') || ':18200000-0000-4000-8000-0000000000d2'),
  'REWARDS_REFERRAL_REWARD', 'paying a referred rental after its end queues the reward message'
);

-- The referral send audience: whoever already rented; a future booking alone does not count.
insert into public.customers(id, name, email, phone) values ('18200000-0000-4000-8000-0000000000e1', 'R182 Future only', 'r182-e@example.test', '+5548999820105');
insert into public.appointments(
  id, public_code, service_id, service_employee_id, primary_customer_id, status, financial_status,
  start_at, end_at, duration_minutes, people_count, service_name_snapshot, commercial_value, confirmed_at
) values ('18200000-0000-4000-8000-0000000000e2', 'R182-E-FUTURE', '18200000-0000-4000-8000-000000000010', '18200000-0000-4000-8000-000000000020', '18200000-0000-4000-8000-0000000000e1',
   'CONFIRMED', 'PAID', now() + interval '3 days', now() + interval '3 days 1 hour', 60, 1, 'R182 rental', 100, now());
select ok(
  has_function_privilege('service_role', 'public.service_list_marketing_referral_candidates(uuid,integer)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.service_list_marketing_referral_candidates(uuid,integer)', 'EXECUTE'),
  'the referral audience is read by the trusted backend only'
);
select ok(
  public.service_list_marketing_referral_candidates(pg_temp.campaign(), 5000) @> jsonb_build_array(jsonb_build_object('customer_id', '18200000-0000-4000-8000-0000000000a1')),
  'a customer who already rented is in the audience'
);
select ok(
  not (public.service_list_marketing_referral_candidates(pg_temp.campaign(), 5000) @> jsonb_build_array(jsonb_build_object('customer_id', '18200000-0000-4000-8000-0000000000e1'))),
  'a customer with only a future booking is not'
);
select throws_ok(
  $$select public.service_list_marketing_referral_candidates(gen_random_uuid(), 10)$$,
  'P0001', 'MARKETING_CAMPAIGN_NOT_FOUND', 'only for an existing referral campaign'
);

select * from finish();
rollback;
