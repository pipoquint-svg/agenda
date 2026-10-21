begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(28);

-- Fixtures -------------------------------------------------------------------
insert into auth.users(id, email, created_at, updated_at)
values ('17800000-0000-4000-8000-000000000001', 'rewards-178-owner@example.test', now(), now());
insert into public.admin_users(id, auth_user_id, display_name, role, is_active)
values ('17800000-0000-4000-8000-000000000002', '17800000-0000-4000-8000-000000000001', 'Rewards 178 Owner', 'OWNER', true);
insert into public.employees(id, name) values ('17800000-0000-4000-8000-000000000003', 'Rewards 178 staff');
insert into public.categories(id, name, slug) values ('17800000-0000-4000-8000-000000000004', 'Rewards 178', 'rewards-178');
insert into public.services(
  id, category_id, name, slug, base_duration_minutes, base_price, buffer_before_minutes, buffer_after_minutes,
  minimum_people, maximum_people, minimum_booking_notice_minutes, maximum_booking_horizon_days, requires_terms,
  duration_mode, operation_scope, booking_product_type, service_type_id
) values
  ('17800000-0000-4000-8000-000000000010', '17800000-0000-4000-8000-000000000004', 'R178 rental', 'r178-rental', 60, 100, 0, 0, 1, 10, 0, 365, false,
   'FIXED', 'BLACKSHEEP', 'STANDARD', (select id from public.service_type where key = 'LOCACAO')),
  ('17800000-0000-4000-8000-000000000011', '17800000-0000-4000-8000-000000000004', 'R178 visit', 'r178-visit', 30, 0, 0, 0, 1, 10, 0, 365, false,
   'FIXED', 'BLACKSHEEP', 'FREE_VISIT', (select id from public.service_type where key = 'LOCACAO'));
insert into public.service_employees(id, service_id, employee_id) values
  ('17800000-0000-4000-8000-000000000020', '17800000-0000-4000-8000-000000000010', '17800000-0000-4000-8000-000000000003'),
  ('17800000-0000-4000-8000-000000000021', '17800000-0000-4000-8000-000000000011', '17800000-0000-4000-8000-000000000003');
insert into public.service_change_policies(service_id, notice_hours, reschedule_first_early_percent, reschedule_first_late_percent, reschedule_repeat_percent, cancellation_late_percent)
values ('17800000-0000-4000-8000-000000000010', 48, 0, 20, 30, 30), ('17800000-0000-4000-8000-000000000011', 48, 0, 20, 30, 30);

-- A: rented 120 days ago (legacy, unsnapshotted). B: rented 10 days ago. C: only in the Amelia history.
-- D: visited, never rented. E: visited but had rented before. F: old rental with a booking ahead. G: anonymized.
insert into public.customers(id, name, email, phone, anonymized_at) values
  ('17800000-0000-4000-8000-0000000000a1', 'R178 A', 'r178-a@example.test', '+5548999780001', null),
  ('17800000-0000-4000-8000-0000000000b1', 'R178 B', 'r178-b@example.test', '+5548999780002', null),
  ('17800000-0000-4000-8000-0000000000c1', 'R178 C', 'r178-c@example.test', '+5548999780003', null),
  ('17800000-0000-4000-8000-0000000000d1', 'R178 D', 'r178-d@example.test', '+5548999780004', null),
  ('17800000-0000-4000-8000-0000000000e1', 'R178 E', 'r178-e@example.test', '+5548999780005', null),
  ('17800000-0000-4000-8000-0000000000f1', 'R178 F', 'r178-f@example.test', '+5548999780006', null),
  ('17800000-0000-4000-8000-000000000071', 'R178 G', null, null, now() - interval '1 day');

insert into public.appointments(
  id, public_code, service_id, service_employee_id, primary_customer_id, status, financial_status,
  start_at, end_at, duration_minutes, people_count, service_name_snapshot, commercial_value, confirmed_at
) values
  ('17800000-0000-4000-8000-0000000000a2', 'R178-A-OLD', '17800000-0000-4000-8000-000000000010', '17800000-0000-4000-8000-000000000020', '17800000-0000-4000-8000-0000000000a1',
   'CONFIRMED', 'PAID', now() - interval '120 days', now() - interval '120 days' + interval '1 hour', 60, 1, 'R178 rental', 100, now() - interval '130 days'),
  ('17800000-0000-4000-8000-0000000000b2', 'R178-B-RECENT', '17800000-0000-4000-8000-000000000010', '17800000-0000-4000-8000-000000000020', '17800000-0000-4000-8000-0000000000b1',
   'CONFIRMED', 'PAID', now() - interval '10 days', now() - interval '10 days' + interval '1 hour', 60, 1, 'R178 rental', 100, now() - interval '20 days'),
  ('17800000-0000-4000-8000-0000000000d2', 'R178-D-VISIT', '17800000-0000-4000-8000-000000000011', '17800000-0000-4000-8000-000000000021', '17800000-0000-4000-8000-0000000000d1',
   'CONFIRMED', 'PAID', now() - interval '3 days', now() - interval '3 days' + interval '30 minutes', 30, 1, 'R178 visit', 0, now() - interval '5 days'),
  ('17800000-0000-4000-8000-0000000000d3', 'R178-D-VISIT-NEXT', '17800000-0000-4000-8000-000000000011', '17800000-0000-4000-8000-000000000021', '17800000-0000-4000-8000-0000000000d1',
   'CONFIRMED', 'PAID', now() + interval '3 days', now() + interval '3 days' + interval '30 minutes', 30, 1, 'R178 visit', 0, now() - interval '1 day'),
  ('17800000-0000-4000-8000-0000000000e2', 'R178-E-RENT', '17800000-0000-4000-8000-000000000010', '17800000-0000-4000-8000-000000000020', '17800000-0000-4000-8000-0000000000e1',
   'CONFIRMED', 'PAID', now() - interval '60 days', now() - interval '60 days' + interval '1 hour', 60, 1, 'R178 rental', 100, now() - interval '70 days'),
  ('17800000-0000-4000-8000-0000000000e3', 'R178-E-VISIT', '17800000-0000-4000-8000-000000000011', '17800000-0000-4000-8000-000000000021', '17800000-0000-4000-8000-0000000000e1',
   'CONFIRMED', 'PAID', now() - interval '2 days', now() - interval '2 days' + interval '30 minutes', 30, 1, 'R178 visit', 0, now() - interval '4 days'),
  ('17800000-0000-4000-8000-0000000000f2', 'R178-F-OLD', '17800000-0000-4000-8000-000000000010', '17800000-0000-4000-8000-000000000020', '17800000-0000-4000-8000-0000000000f1',
   'CONFIRMED', 'PAID', now() - interval '150 days', now() - interval '150 days' + interval '1 hour', 60, 1, 'R178 rental', 100, now() - interval '160 days'),
  ('17800000-0000-4000-8000-0000000000f3', 'R178-F-NEXT', '17800000-0000-4000-8000-000000000010', '17800000-0000-4000-8000-000000000020', '17800000-0000-4000-8000-0000000000f1',
   'CONFIRMED', 'PAID', now() + interval '7 days', now() + interval '7 days' + interval '1 hour', 60, 1, 'R178 rental', 100, now() - interval '1 day'),
  ('17800000-0000-4000-8000-000000000072', 'R178-G-OLD', '17800000-0000-4000-8000-000000000010', '17800000-0000-4000-8000-000000000020', '17800000-0000-4000-8000-000000000071',
   'CONFIRMED', 'PAID', now() - interval '200 days', now() - interval '200 days' + interval '1 hour', 60, 1, 'R178 rental', 100, now() - interval '210 days');

-- A's rental predates the S3 snapshot: clear it the way legacy rows look in production.
set local session_replication_role = replica;
update public.appointments
set rewards_source_operation_scope_snapshot = null, rewards_source_service_type_key_snapshot = null
where id = '17800000-0000-4000-8000-0000000000a2';
set local session_replication_role = origin;

insert into public.legacy_amelia_bookings(amelia_booking_id, matched_customer_id, customer_name, service_name, employee_name, start_at, end_at, status_raw)
values ('r178-c-old', '17800000-0000-4000-8000-0000000000c1', 'R178 C', '2 Horas - Locação de Estúdio', 'BlackSheep Estudio Criativo',
        now() - interval '200 days', now() - interval '200 days' + interval '2 hours', 'Aprovado');

-- Campaigns: come back after 90 days, after the visit, and after each rental.
create temporary table r178_campaign(kind text primary key, campaign_id uuid, version_id uuid) on commit drop;
do $$
declare
  v_offer jsonb;
  v_created jsonb;
  v_kind text;
begin
  foreach v_kind in array array['INACTIVITY', 'FREE_VISIT_COMPLETED', 'RENTAL_COMPLETED_FINANCIALLY_CLEARED'] loop
    v_offer := jsonb_build_object(
      'trigger_kind', v_kind, 'discount_type', 'PERCENT', 'discount_value', 15, 'discount_scope', 'SERVICE_ONLY',
      'validity_basis', 'BOOKING_CONFIRMATION', 'validity_days', 30, 'max_uses', 1, 'max_uses_per_customer', 1,
      'applies_to_extras', false, 'applies_to_hour_packages', false, 'stacking_policy', 'EXCLUSIVE',
      'recurring_after_discounted_rental', true,
      'eligibility_rules', jsonb_build_object('service_ids', jsonb_build_array('17800000-0000-4000-8000-000000000010')),
      'trigger_rules', case when v_kind = 'INACTIVITY' then jsonb_build_object('inactivity_days', 90) else '{}'::jsonb end
    );
    v_created := public.service_admin_create_marketing_campaign(
      '8fba3c57-c0e6-4a37-b7d3-4cf41e5fb65f', 'r178-' || lower(replace(v_kind, '_', '-')), 'R178 ' || v_kind, null, null, v_offer,
      '17800000-0000-4000-8000-000000000002', gen_random_uuid()
    );
    perform public.service_admin_transition_marketing_campaign(
      (v_created->>'campaign_id')::uuid, 'ACTIVE', (v_created->>'version_id')::uuid, 'R178 fixture',
      '17800000-0000-4000-8000-000000000002', gen_random_uuid()
    );
    insert into r178_campaign values (v_kind, (v_created->>'campaign_id')::uuid, (v_created->>'version_id')::uuid);
  end loop;
end
$$;

create function pg_temp.r178(kind text) returns uuid language sql as $$ select campaign_id from r178_campaign where r178_campaign.kind = $1 $$;
create function pg_temp.visit(appointment uuid) returns text language sql as $$
  select public.service_evaluate_marketing_campaign_eligibility(pg_temp.r178('FREE_VISIT_COMPLETED'), $1)->>'reason_code' $$;
create function pg_temp.back(customer uuid) returns text language sql as $$
  select public.service_evaluate_marketing_campaign_customer_eligibility(pg_temp.r178('INACTIVITY'), $1)->>'reason_code' $$;

-- ACL -------------------------------------------------------------------------
select ok(
  (select bool_and(has_function_privilege('service_role', f, 'EXECUTE')
     and not has_function_privilege('anon', f, 'EXECUTE')
     and not has_function_privilege('authenticated', f, 'EXECUTE'))
   from unnest(array[
     'public.marketing_rewards_source_kind(uuid)', 'public.marketing_rewards_last_rental_at(uuid)',
     'public.service_evaluate_marketing_campaign_customer_eligibility(uuid,uuid)',
     'public.service_list_marketing_campaign_candidates(uuid,integer)',
     'public.service_issue_marketing_campaign_customer_coupon(uuid,uuid,text)'
   ]::regprocedure[]) f),
  'the new Rewards functions are service-only'
);
select is((select count(*)::integer from r178_campaign), 3, 'the visit trigger is accepted next to rental and inactivity');

-- Classification -------------------------------------------------------------
select is(public.marketing_rewards_source_kind('17800000-0000-4000-8000-0000000000a2'), 'RENTAL', 'an unsnapshotted rental is classified by its current service');
select is(public.marketing_rewards_source_kind('17800000-0000-4000-8000-0000000000d2'), 'VISIT', 'a free visit is a visit, never a rental');
select is(
  public.marketing_rewards_last_rental_at('17800000-0000-4000-8000-0000000000c1')::date,
  (now() - interval '200 days' + interval '2 hours')::date,
  'the last rental also comes from the linked Amelia history'
);
select is(public.marketing_rewards_last_rental_at('17800000-0000-4000-8000-0000000000d1'), null, 'a visit is not a rental');

-- Rental trigger: realized = confirmed with the time slot over ------------------
select is(
  public.service_evaluate_marketing_campaign_eligibility(pg_temp.r178('RENTAL_COMPLETED_FINANCIALLY_CLEARED'), '17800000-0000-4000-8000-0000000000a2')->>'decision',
  'ELIGIBLE',
  'a confirmed, ended, paid legacy rental is eligible for the rental coupon'
);
select is(
  public.service_evaluate_marketing_campaign_eligibility(pg_temp.r178('RENTAL_COMPLETED_FINANCIALLY_CLEARED'), '17800000-0000-4000-8000-0000000000d2')->>'reason_code',
  'MARKETING_CAMPAIGN_SOURCE_NOT_BLACKSHEEP_RENTAL',
  'a free visit never earns the rental coupon'
);
select is(
  public.service_evaluate_marketing_campaign_eligibility(pg_temp.r178('RENTAL_COMPLETED_FINANCIALLY_CLEARED'), '17800000-0000-4000-8000-0000000000f3')->>'reason_code',
  'MARKETING_CAMPAIGN_SOURCE_NOT_COMPLETED',
  'a future rental is not realized yet'
);

-- Visit trigger --------------------------------------------------------------
select is(pg_temp.visit('17800000-0000-4000-8000-0000000000d2'), 'MARKETING_CAMPAIGN_ELIGIBLE', 'a realized visit by someone who never rented earns the visit coupon');
select is(pg_temp.visit('17800000-0000-4000-8000-0000000000d3'), 'MARKETING_CAMPAIGN_SOURCE_NOT_COMPLETED', 'a visit still ahead does not');
select is(pg_temp.visit('17800000-0000-4000-8000-0000000000e3'), 'MARKETING_CAMPAIGN_CUSTOMER_ALREADY_RENTED', 'whoever already rented gets the rental coupon instead');
select is(pg_temp.visit('17800000-0000-4000-8000-0000000000a2'), 'MARKETING_CAMPAIGN_SOURCE_NOT_BLACKSHEEP_VISIT', 'a rental is not a visit');

-- 90 days without a rental ----------------------------------------------------
select is(pg_temp.back('17800000-0000-4000-8000-0000000000a1'), 'MARKETING_CAMPAIGN_ELIGIBLE', '120 days without renting: come-back coupon');
select is(pg_temp.back('17800000-0000-4000-8000-0000000000c1'), 'MARKETING_CAMPAIGN_ELIGIBLE', 'an Amelia-only customer is reached too');
select is(pg_temp.back('17800000-0000-4000-8000-0000000000b1'), 'MARKETING_CAMPAIGN_CUSTOMER_RECENTLY_ACTIVE', 'rented 10 days ago: not gone');
select is(pg_temp.back('17800000-0000-4000-8000-0000000000f1'), 'MARKETING_CAMPAIGN_CUSTOMER_HAS_UPCOMING_BOOKING', 'a booking ahead means they are coming back');
select is(pg_temp.back('17800000-0000-4000-8000-000000000071'), 'MARKETING_CAMPAIGN_CUSTOMER_ANONYMIZED', 'anonymized customers are never contacted');
select is(pg_temp.back('17800000-0000-4000-8000-0000000000d1'), 'MARKETING_CAMPAIGN_CUSTOMER_NEVER_RENTED', 'a visitor who never rented is not a come-back');
select is(
  public.service_evaluate_marketing_campaign_eligibility(pg_temp.r178('INACTIVITY'), '17800000-0000-4000-8000-0000000000a2')->>'reason_code',
  'MARKETING_CAMPAIGN_TRIGGER_CUSTOMER_BASED',
  'the come-back trigger is never issued from a reservation'
);

select ok(
  (select jsonb_agg(item->>'customer_id' order by item->>'customer_id') from jsonb_array_elements(
     public.service_list_marketing_campaign_candidates(pg_temp.r178('INACTIVITY'), 50)) item
   ) @> '["17800000-0000-4000-8000-0000000000a1", "17800000-0000-4000-8000-0000000000c1"]'::jsonb
  and not (public.service_list_marketing_campaign_candidates(pg_temp.r178('INACTIVITY'), 50)::text
       ~ '(0000000000b1|0000000000f1|000000000071|0000000000d1)'),
  'the come-back candidates are exactly the customers who went away'
);
select ok(
  public.service_list_marketing_campaign_candidates(pg_temp.r178('FREE_VISIT_COMPLETED'), 50)
    @> '[{"source_appointment_id": "17800000-0000-4000-8000-0000000000d2"}]'::jsonb
  and not (public.service_list_marketing_campaign_candidates(pg_temp.r178('FREE_VISIT_COMPLETED'), 50)::text ~ '0000000000e3'),
  'the visit candidates exclude visitors who already rented'
);

-- Customer-anchored issuance --------------------------------------------------
select set_config('agenda.r178.issued', public.service_issue_marketing_campaign_customer_coupon(
  pg_temp.r178('INACTIVITY'), '17800000-0000-4000-8000-0000000000a1', 'r178-come-back-a1')::text, true);
select is(
  (select row(c.customer_id, c.source_appointment_id, c.discount_type, c.discount_value::text, c.discount_scope)::text from public.coupons c
   where c.id = (current_setting('agenda.r178.issued')::jsonb->>'coupon_id')::uuid),
  row('17800000-0000-4000-8000-0000000000a1'::uuid, null::uuid, 'PERCENT', '15.00', 'SERVICE_ONLY')::text,
  'the come-back coupon belongs to the customer, with no source reservation'
);
select is(
  (public.service_issue_marketing_campaign_customer_coupon(pg_temp.r178('INACTIVITY'), '17800000-0000-4000-8000-0000000000a1', 'r178-come-back-a1')->>'replayed')::boolean,
  true,
  'the same idempotency key replays the same coupon'
);
select is(pg_temp.back('17800000-0000-4000-8000-0000000000a1'), 'MARKETING_CAMPAIGN_CUSTOMER_ALREADY_ISSUED', 'one come-back coupon per absence');
select throws_ok(
  $$select public.service_issue_marketing_campaign_customer_coupon(pg_temp.r178('INACTIVITY'), '17800000-0000-4000-8000-0000000000b1', 'r178-come-back-b1')$$,
  'P0001', 'MARKETING_CAMPAIGN_ISSUANCE_INELIGIBLE',
  'an active customer cannot be issued a come-back coupon'
);
select is(
  public.service_issue_marketing_campaign_coupon(pg_temp.r178('FREE_VISIT_COMPLETED'), '17800000-0000-4000-8000-0000000000d2', 'r178-visit-d1')->>'customer_id',
  '17800000-0000-4000-8000-0000000000d1',
  'the reservation issuance serves the visit trigger'
);

-- Rules ---------------------------------------------------------------------
-- Published versions are immutable; bypass the guard only to plant a bad rule.
set local session_replication_role = replica;
update public.marketing_campaign_versions set trigger_rules = '{"inactivity_days": 10}'::jsonb
where id = (select version_id from r178_campaign where kind = 'INACTIVITY');
set local session_replication_role = origin;
select is(pg_temp.back('17800000-0000-4000-8000-0000000000c1'), 'MARKETING_CAMPAIGN_TRIGGER_RULES_INVALID', 'the absence window must stay between 30 and 365 days');

select * from finish();
rollback;
