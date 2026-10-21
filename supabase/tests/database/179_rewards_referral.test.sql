begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(23);

-- Fixtures -------------------------------------------------------------------
insert into auth.users(id, email, created_at, updated_at)
values ('17900000-0000-4000-8000-000000000001', 'rewards-179-owner@example.test', now(), now());
insert into public.admin_users(id, auth_user_id, display_name, role, is_active)
values ('17900000-0000-4000-8000-000000000002', '17900000-0000-4000-8000-000000000001', 'Rewards 179 Owner', 'OWNER', true);
insert into public.employees(id, name) values ('17900000-0000-4000-8000-000000000003', 'Rewards 179 staff');
insert into public.categories(id, name, slug) values ('17900000-0000-4000-8000-000000000004', 'Rewards 179', 'rewards-179');
insert into public.services(
  id, category_id, name, slug, base_duration_minutes, base_price, buffer_before_minutes, buffer_after_minutes,
  minimum_people, maximum_people, minimum_booking_notice_minutes, maximum_booking_horizon_days, requires_terms,
  duration_mode, operation_scope, booking_product_type, service_type_id
) values ('17900000-0000-4000-8000-000000000010', '17900000-0000-4000-8000-000000000004', 'R179 rental', 'r179-rental', 60, 100, 0, 0, 1, 10, 0, 365, false,
  'FIXED', 'BLACKSHEEP', 'STANDARD', (select id from public.service_type where key = 'LOCACAO'));
insert into public.service_employees(id, service_id, employee_id)
values ('17900000-0000-4000-8000-000000000020', '17900000-0000-4000-8000-000000000010', '17900000-0000-4000-8000-000000000003');
insert into public.service_change_policies(service_id, notice_hours, reschedule_first_early_percent, reschedule_first_late_percent, reschedule_repeat_percent, cancellation_late_percent)
values ('17900000-0000-4000-8000-000000000010', 48, 0, 20, 30, 30);

-- R refers. F and G are friends who never rented. A rented in Amelia. S shares R's phone. N never rented.
insert into public.customers(id, name, email, phone, cpf_cnpj) values
  ('17900000-0000-4000-8000-0000000000a1', 'R179 Referrer', 'r179-referrer@example.test', '+5548999790001', '11111111111'),
  ('17900000-0000-4000-8000-0000000000b1', 'R179 Friend F', 'r179-f@example.test', '+5548999790002', '22222222222'),
  ('17900000-0000-4000-8000-0000000000c1', 'R179 Friend G', 'r179-g@example.test', '+5548999790003', '33333333333'),
  ('17900000-0000-4000-8000-0000000000d1', 'R179 Amelia A', 'r179-a@example.test', '+5548999790004', '44444444444'),
  ('17900000-0000-4000-8000-0000000000e1', 'R179 Same S', 'r179-s@example.test', '(48) 99979-0001', '55555555555'),
  ('17900000-0000-4000-8000-0000000000f1', 'R179 Never N', 'r179-n@example.test', '+5548999790006', '66666666666');

insert into public.appointments(
  id, public_code, service_id, service_employee_id, primary_customer_id, status, financial_status,
  start_at, end_at, duration_minutes, people_count, service_name_snapshot, commercial_value, confirmed_at
) values
  ('17900000-0000-4000-8000-0000000000a2', 'R179-R-OLD', '17900000-0000-4000-8000-000000000010', '17900000-0000-4000-8000-000000000020', '17900000-0000-4000-8000-0000000000a1',
   'CONFIRMED', 'PAID', now() - interval '30 days', now() - interval '30 days' + interval '1 hour', 60, 1, 'R179 rental', 100, now() - interval '40 days'),
  ('17900000-0000-4000-8000-0000000000b2', 'R179-F-FIRST', '17900000-0000-4000-8000-000000000010', '17900000-0000-4000-8000-000000000020', '17900000-0000-4000-8000-0000000000b1',
   'CONFIRMED', 'PAID', now() - interval '5 days', now() - interval '5 days' + interval '1 hour', 60, 1, 'R179 rental', 90, now() - interval '10 days'),
  ('17900000-0000-4000-8000-0000000000c2', 'R179-G-FIRST', '17900000-0000-4000-8000-000000000010', '17900000-0000-4000-8000-000000000020', '17900000-0000-4000-8000-0000000000c1',
   'CONFIRMED', 'PAID', now() - interval '3 days', now() - interval '3 days' + interval '1 hour', 60, 1, 'R179 rental', 90, now() - interval '8 days'),
  ('17900000-0000-4000-8000-0000000000a3', 'R179-R-NEXT', '17900000-0000-4000-8000-000000000010', '17900000-0000-4000-8000-000000000020', '17900000-0000-4000-8000-0000000000a1',
   'CONFIRMED', 'PAID', now() + interval '10 days', now() + interval '10 days' + interval '1 hour', 60, 1, 'R179 rental', 100, now() - interval '1 day');

insert into public.legacy_amelia_bookings(amelia_booking_id, matched_customer_id, customer_name, service_name, employee_name, start_at, end_at, status_raw)
values ('r179-a-old', '17900000-0000-4000-8000-0000000000d1', 'R179 Amelia A', '1 hora - Locação de Estúdio', 'BlackSheep Estudio Criativo',
        now() - interval '300 days', now() - interval '300 days' + interval '1 hour', 'Aprovado');

-- Referral campaign: the friend gets 10%, the referrer earns 20%, at most one reward a month.
create temporary table r179(campaign_id uuid, version_id uuid) on commit drop;
do $$
declare v_created jsonb;
begin
  v_created := public.service_admin_create_marketing_campaign(
    '8fba3c57-c0e6-4a37-b7d3-4cf41e5fb65f', 'r179-referral', 'R179 Indicação', null, null,
    jsonb_build_object(
      'trigger_kind', 'REFERRAL_FIRST_RENTAL', 'discount_type', 'PERCENT', 'discount_value', 20, 'discount_scope', 'SERVICE_ONLY',
      'validity_basis', 'BOOKING_CONFIRMATION', 'validity_days', 30, 'max_uses', 1, 'max_uses_per_customer', 1,
      'applies_to_extras', false, 'applies_to_hour_packages', false, 'stacking_policy', 'EXCLUSIVE', 'recurring_after_discounted_rental', true,
      'eligibility_rules', jsonb_build_object('service_ids', jsonb_build_array('17900000-0000-4000-8000-000000000010')),
      'trigger_rules', jsonb_build_object('referred_discount_type', 'PERCENT', 'referred_discount_value', 10, 'monthly_cap', 1)
    ),
    '17900000-0000-4000-8000-000000000002', gen_random_uuid()
  );
  perform public.service_admin_transition_marketing_campaign(
    (v_created->>'campaign_id')::uuid, 'ACTIVE', (v_created->>'version_id')::uuid, 'R179 fixture',
    '17900000-0000-4000-8000-000000000002', gen_random_uuid()
  );
  insert into r179 values ((v_created->>'campaign_id')::uuid, (v_created->>'version_id')::uuid);
end
$$;
create function pg_temp.campaign() returns uuid language sql as $$ select campaign_id from r179 $$;

-- ACL -------------------------------------------------------------------------
select ok(
  (select bool_and(has_function_privilege('service_role', f, 'EXECUTE')
     and not has_function_privilege('anon', f, 'EXECUTE') and not has_function_privilege('authenticated', f, 'EXECUTE'))
   from unnest(array['public.marketing_referral_same_person(uuid,uuid)', 'public.coupon_referral_violation(uuid,uuid,uuid)',
                     'public.service_ensure_marketing_referral_code(uuid,uuid)']::regprocedure[]) f)
  and has_table_privilege('service_role', 'public.marketing_referral_codes', 'SELECT')
  and not has_table_privilege('service_role', 'public.marketing_referral_codes', 'INSERT')
  and not has_table_privilege('anon', 'public.marketing_referral_codes', 'SELECT'),
  'referral functions and codes are service-only'
);

-- Personal code -----------------------------------------------------------------
select set_config('agenda.r179.code', public.service_ensure_marketing_referral_code(pg_temp.campaign(), '17900000-0000-4000-8000-0000000000a1')::text, true);
select ok(current_setting('agenda.r179.code')::jsonb->>'code' ~ '^IND-[A-Z0-9]{6}$', 'the referrer gets a personal IND- code');
select is(
  (select row(c.customer_id, c.discount_type, c.discount_value::text, c.discount_scope, c.max_uses_per_customer, c.is_active)::text
   from public.coupons c where c.id = (current_setting('agenda.r179.code')::jsonb->>'coupon_id')::uuid),
  row(null::uuid, 'PERCENT', '10.00', 'SERVICE_ONLY', 1, true)::text,
  'the code is a shareable 10% coupon, once per friend'
);
select is(
  (select array_agg(service_id) from public.coupon_services where coupon_id = (current_setting('agenda.r179.code')::jsonb->>'coupon_id')::uuid),
  array['17900000-0000-4000-8000-000000000010'::uuid],
  'the code applies to the campaign services only'
);
select is(
  public.service_ensure_marketing_referral_code(pg_temp.campaign(), '17900000-0000-4000-8000-0000000000a1')->>'code',
  current_setting('agenda.r179.code')::jsonb->>'code',
  'one code per referrer and campaign'
);
select throws_ok(
  $$select public.service_ensure_marketing_referral_code(pg_temp.campaign(), '17900000-0000-4000-8000-0000000000f1')$$,
  'P0001', 'MARKETING_REFERRAL_REFERRER_NEVER_RENTED',
  'only someone who has rented can refer'
);

create function pg_temp.coupon() returns uuid language sql as $$ select (current_setting('agenda.r179.code')::jsonb->>'coupon_id')::uuid $$;

-- Checkout rule -----------------------------------------------------------------
select is(public.coupon_referral_violation(pg_temp.coupon(), '17900000-0000-4000-8000-0000000000f1', null), null, 'someone who never rented can use the code');
select is(public.coupon_referral_violation(pg_temp.coupon(), '17900000-0000-4000-8000-0000000000a1', null), 'COUPON_REFERRAL_SELF', 'the referrer cannot use their own code');
select is(public.coupon_referral_violation(pg_temp.coupon(), '17900000-0000-4000-8000-0000000000e1', null), 'COUPON_REFERRAL_SELF', 'nor under another record with the same phone');
select is(public.coupon_referral_violation(pg_temp.coupon(), '17900000-0000-4000-8000-0000000000d1', null), 'COUPON_REFERRAL_NOT_FIRST_RENTAL', 'a customer who rented in Amelia is not a first-timer');
select is(
  public.coupon_referral_violation(pg_temp.coupon(), '17900000-0000-4000-8000-0000000000b1', '17900000-0000-4000-8000-0000000000b2'),
  null,
  'the friend''s first booking itself does not count against them'
);
insert into public.coupons(code, discount_type, discount_value, is_active, source)
values ('R179-PLAIN', 'PERCENT', 5, true, 'PROMOTION');
select is(
  public.coupon_referral_violation((select id from public.coupons where code = 'R179-PLAIN'), '17900000-0000-4000-8000-0000000000a1', null),
  null,
  'ordinary coupons are untouched'
);

-- Both checkout paths enforce it.
insert into public.checkout_holds(id, public_token_hash, service_id, service_employee_id, selection_hash, people_count, requested_start_at, requested_end_at, expires_at)
values ('17900000-0000-4000-8000-000000000030', repeat('a', 64), '17900000-0000-4000-8000-000000000010', '17900000-0000-4000-8000-000000000020', repeat('b', 64), 1,
        now() + interval '20 days', now() + interval '20 days' + interval '1 hour', now() + interval '20 minutes');
select throws_ok(
  $$update public.checkout_holds set primary_customer_id = '17900000-0000-4000-8000-0000000000a1', applied_coupon_id = pg_temp.coupon()
    where id = '17900000-0000-4000-8000-000000000030'$$,
  'P0001', 'COUPON_REFERRAL_SELF',
  'the online checkout refuses the referrer''s own code'
);
select lives_ok(
  $$update public.checkout_holds set primary_customer_id = '17900000-0000-4000-8000-0000000000f1', applied_coupon_id = pg_temp.coupon()
    where id = '17900000-0000-4000-8000-000000000030'$$,
  'the online checkout accepts the code for a first-timer'
);
select throws_ok(
  $$insert into public.appointment_discounts(appointment_id, coupon_id, code_snapshot, discount_type_snapshot, discount_value_snapshot, calculated_discount_amount)
    values ('17900000-0000-4000-8000-0000000000a3', pg_temp.coupon(), 'IND', 'PERCENT', 10, 10)$$,
  'P0001', 'COUPON_REFERRAL_SELF',
  'a reservation made in Gestão refuses the referrer''s own code too'
);

-- The friends' first rentals used the code.
insert into public.appointment_discounts(appointment_id, coupon_id, code_snapshot, discount_type_snapshot, discount_value_snapshot, calculated_discount_amount)
values ('17900000-0000-4000-8000-0000000000b2', pg_temp.coupon(), 'IND', 'PERCENT', 10, 10),
       ('17900000-0000-4000-8000-0000000000c2', pg_temp.coupon(), 'IND', 'PERCENT', 10, 10);

-- Referrer reward -----------------------------------------------------------------
select set_config('agenda.r179.f', public.service_evaluate_marketing_campaign_eligibility(pg_temp.campaign(), '17900000-0000-4000-8000-0000000000b2')::text, true);
select is(current_setting('agenda.r179.f')::jsonb->>'decision', 'ELIGIBLE', 'the friend''s realized, paid first rental earns the referrer a coupon');
select is(
  current_setting('agenda.r179.f')::jsonb->>'customer_id' || '|' || (current_setting('agenda.r179.f')::jsonb->>'referred_customer_id'),
  '17900000-0000-4000-8000-0000000000a1|17900000-0000-4000-8000-0000000000b1',
  'the reward goes to the referrer, not to the friend'
);
select ok(
  public.service_list_marketing_campaign_candidates(pg_temp.campaign(), 50)
    @> '[{"customer_id": "17900000-0000-4000-8000-0000000000a1", "source_appointment_id": "17900000-0000-4000-8000-0000000000b2"}]'::jsonb,
  'the candidate list names the referrer'
);
select is(
  public.service_evaluate_marketing_campaign_eligibility(pg_temp.campaign(), '17900000-0000-4000-8000-0000000000a2')->>'reason_code',
  'MARKETING_CAMPAIGN_SOURCE_NOT_REFERRED',
  'a rental without the code earns nothing'
);

select set_config('agenda.r179.reward', public.service_issue_marketing_campaign_coupon(pg_temp.campaign(), '17900000-0000-4000-8000-0000000000b2', 'r179-reward-f')::text, true);
select is(
  (select row(c.customer_id, c.discount_value::text)::text from public.coupons c where c.id = (current_setting('agenda.r179.reward')::jsonb->>'coupon_id')::uuid),
  row('17900000-0000-4000-8000-0000000000a1'::uuid, '20.00')::text,
  'the referrer receives the 20% reward coupon'
);
select is(
  public.service_evaluate_marketing_campaign_eligibility(pg_temp.campaign(), '17900000-0000-4000-8000-0000000000b2')->>'reason_code',
  'MARKETING_CAMPAIGN_SOURCE_ALREADY_ISSUED',
  'one reward per referred rental'
);
select is(
  public.service_evaluate_marketing_campaign_eligibility(pg_temp.campaign(), '17900000-0000-4000-8000-0000000000c2')->>'reason_code',
  'MARKETING_CAMPAIGN_REFERRAL_MONTHLY_CAP',
  'the monthly cap holds the second reward'
);

-- A friend who had already rented cannot pass the referral through a legacy path.
insert into public.customers(id, name, email, phone) values ('17900000-0000-4000-8000-0000000000d9', 'R179 Repeat', 'r179-repeat@example.test', '+5548999790009');
insert into public.appointments(
  id, public_code, service_id, service_employee_id, primary_customer_id, status, financial_status,
  start_at, end_at, duration_minutes, people_count, service_name_snapshot, commercial_value, confirmed_at
) values
  ('17900000-0000-4000-8000-0000000000d7', 'R179-REP-1', '17900000-0000-4000-8000-000000000010', '17900000-0000-4000-8000-000000000020', '17900000-0000-4000-8000-0000000000d9',
   'CONFIRMED', 'PAID', now() - interval '60 days', now() - interval '60 days' + interval '1 hour', 60, 1, 'R179 rental', 100, now() - interval '70 days'),
  ('17900000-0000-4000-8000-0000000000d8', 'R179-REP-2', '17900000-0000-4000-8000-000000000010', '17900000-0000-4000-8000-000000000020', '17900000-0000-4000-8000-0000000000d9',
   'CONFIRMED', 'PAID', now() - interval '2 days', now() - interval '2 days' + interval '1 hour', 60, 1, 'R179 rental', 90, now() - interval '9 days');
set local session_replication_role = replica;
insert into public.appointment_discounts(appointment_id, coupon_id, code_snapshot, discount_type_snapshot, discount_value_snapshot, calculated_discount_amount)
values ('17900000-0000-4000-8000-0000000000d8', pg_temp.coupon(), 'IND', 'PERCENT', 10, 10);
set local session_replication_role = origin;
select is(
  public.service_evaluate_marketing_campaign_eligibility(pg_temp.campaign(), '17900000-0000-4000-8000-0000000000d8')->>'reason_code',
  'MARKETING_CAMPAIGN_REFERRAL_NOT_FIRST_RENTAL',
  'no reward when the friend had rented before'
);

select * from finish();
rollback;
