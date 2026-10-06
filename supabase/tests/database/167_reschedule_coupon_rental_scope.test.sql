begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(32);

insert into public.customers(id,name,email)
values ('16700000-0000-4000-8000-000000000001','Reschedule Coupon Customer','reschedule-coupon@example.test');
insert into public.employees(id,name)
values ('16700000-0000-4000-8000-000000000002','Reschedule Coupon Employee');
insert into public.categories(id,name,slug)
values ('16700000-0000-4000-8000-000000000003','Reschedule Coupon','reschedule-coupon-scope');
insert into public.resources(id,name,resource_type)
values ('16700000-0000-4000-8000-000000000004','Reschedule Coupon Studio','PHYSICAL');
insert into public.services(
  id,category_id,name,slug,base_duration_minutes,base_price,
  buffer_before_minutes,buffer_after_minutes,minimum_people,maximum_people,
  included_people,price_per_extra_person,minimum_booking_notice_minutes,
  maximum_booking_horizon_days,requires_terms
) values (
  '16700000-0000-4000-8000-000000000005','16700000-0000-4000-8000-000000000003',
  'Coupon Scope Rental','coupon-scope-rental',60,340,0,0,1,10,1,25,0,365,false
);
insert into public.service_employees(id,service_id,employee_id)
values ('16700000-0000-4000-8000-000000000006','16700000-0000-4000-8000-000000000005','16700000-0000-4000-8000-000000000002');
insert into public.service_resources(service_id,resource_id,is_required)
values ('16700000-0000-4000-8000-000000000005','16700000-0000-4000-8000-000000000004',true);
insert into public.availability_rules(service_employee_id,weekday,start_local_time,end_local_time,slot_interval_minutes,is_active)
select '16700000-0000-4000-8000-000000000006',d,time '08:00',time '18:00',30,true
from generate_series(0,6) d;
insert into public.resource_availability_rules(resource_id,weekday,start_local_time,end_local_time,is_active)
select '16700000-0000-4000-8000-000000000004',d,time '08:00',time '18:00',true
from generate_series(0,6) d;
insert into public.service_change_policies(
  service_id,notice_hours,reschedule_first_early_percent,reschedule_first_late_percent,
  reschedule_repeat_percent,cancellation_late_percent
) values ('16700000-0000-4000-8000-000000000005',0,0,0,0,0);

insert into public.extras(id,name,price,duration_delta_minutes)
values ('16700000-0000-4000-8000-000000000007','Assistance',75,0);
insert into public.service_extras(service_id,extra_id,max_quantity)
values ('16700000-0000-4000-8000-000000000005','16700000-0000-4000-8000-000000000007',1);
insert into public.coupons(id,code,discount_type,discount_value,is_active,max_uses,valid_from,valid_until)
values
  ('16700000-0000-4000-8000-000000000008','RESCHEDULE-SCOPE-50','PERCENT',50,true,2,now()-interval '2 days',now()+interval '1 day'),
  ('16700000-0000-4000-8000-000000000009','RESCHEDULE-SCOPE-1000','FIXED',1000,true,1,now()-interval '2 days',now()+interval '1 day');

-- Rental R$340 + assistance R$75 + additional people R$50 = R$465.
-- The new 50% contract owes R$295; its legacy counterpart keeps R$232.50.
create temporary table reschedule_coupon_cases(
  label text primary key, appointment_id uuid, local_time time,
  coupon_id uuid, coupon_code text, discount_type text,
  nominal_value numeric, discount_amount numeric, original_total numeric
);
insert into reschedule_coupon_cases values
  ('new_percent','16700000-0000-4000-8000-000000000010','09:00','16700000-0000-4000-8000-000000000008','RESCHEDULE-SCOPE-50','PERCENT',50,170,295),
  ('legacy_percent','16700000-0000-4000-8000-000000000020','11:00','16700000-0000-4000-8000-000000000008','RESCHEDULE-SCOPE-50','PERCENT',50,232.50,232.50),
  ('new_fixed','16700000-0000-4000-8000-000000000030','13:00','16700000-0000-4000-8000-000000000009','RESCHEDULE-SCOPE-1000','FIXED',1000,340,125);

insert into public.appointments(
  id,public_code,service_id,service_employee_id,status,financial_status,
  start_at,end_at,core_start_at,core_end_at,duration_minutes,contracted_minutes,
  people_count,primary_customer_id,base_price_snapshot,variable_price_adjustment,
  extras_total,coupon_discount,commercial_value,confirmed_at
)
select appointment_id,'RESCHEDULE-SCOPE-'||label,
  '16700000-0000-4000-8000-000000000005','16700000-0000-4000-8000-000000000006',
  'CONFIRMED','PAID',
  ((current_date+6)+local_time) at time zone 'America/Sao_Paulo',
  ((current_date+6)+local_time+interval '1 hour') at time zone 'America/Sao_Paulo',
  ((current_date+6)+local_time) at time zone 'America/Sao_Paulo',
  ((current_date+6)+local_time+interval '1 hour') at time zone 'America/Sao_Paulo',
  60,60,3,'16700000-0000-4000-8000-000000000001',340,50,75,
  discount_amount,original_total,now()
from reschedule_coupon_cases;

insert into public.appointment_extras(appointment_id,extra_id,name_snapshot,unit_price_snapshot,quantity,total_price)
select appointment_id,'16700000-0000-4000-8000-000000000007','Assistance',75,1,75
from reschedule_coupon_cases;
insert into public.appointment_discounts(
  appointment_id,coupon_id,code_snapshot,discount_type_snapshot,
  discount_value_snapshot,calculated_discount_amount
)
select appointment_id,coupon_id,coupon_code,discount_type,nominal_value,discount_amount
from reschedule_coupon_cases;
insert into public.payment_transactions(
  appointment_id,transaction_type,method,provider,provider_payment_id,status,
  contract_amount_settled,cash_amount,paid_at,payment_purpose
)
select appointment_id,'CHARGE','CARD','MERCADO_PAGO','reschedule-scope-fixture-'||label,
  'APPROVED',original_total,original_total,now(),'CONTRACT'
from reschedule_coupon_cases;
insert into public.resource_allocations(resource_id,appointment_id,allocation_type,status,occupied_range)
select '16700000-0000-4000-8000-000000000004',appointment_id,'APPOINTMENT','CONFIRMED',
  tstzrange(((current_date+6)+local_time) at time zone 'America/Sao_Paulo',
    ((current_date+6)+local_time+interval '1 hour') at time zone 'America/Sao_Paulo','[)')
from reschedule_coupon_cases;

-- Scope must remain available even if an original checkout hold is no longer
-- retained: the creation audit is the durable first source.
insert into public.audit_logs(entity_type,entity_id,action,after_json,origin)
values
  ('APPOINTMENT','16700000-0000-4000-8000-000000000010','CHECKOUT_HOLD_PROMOTED',
    '{"coupon_scope":"RENTAL_ONLY","coupon_eligible_amount":340,"coupon_applied":true}'::jsonb,'PUBLIC'),
  ('APPOINTMENT','16700000-0000-4000-8000-000000000020','CHECKOUT_HOLD_PROMOTED',
    '{"coupon_applied":true}'::jsonb,'PUBLIC');

-- The original promoted checkout is a compatible scope source as well.
insert into public.checkout_holds(
  id,public_token_hash,service_id,service_employee_id,selection_hash,status,
  people_count,requested_start_at,requested_end_at,core_start_at,core_end_at,expires_at,created_at,
  extra_selections,commercial_value,pricing_version,duration_minutes,contracted_minutes,
  resource_ids,primary_customer_id,quote_snapshot,promoted_appointment_id
)
select '16700000-0000-4000-8000-000000000031','reschedule-fixed-original-hold',
  service_id,service_employee_id,'reschedule-fixed-original','PROMOTED',people_count,
  start_at,end_at,core_start_at,core_end_at,now()-interval '1 minute',now()-interval '2 minutes',
  '[{"extra_id":"16700000-0000-4000-8000-000000000007","quantity":1}]'::jsonb,
  commercial_value,'reschedule-fixed-snapshot',duration_minutes,contracted_minutes,
  array['16700000-0000-4000-8000-000000000004'::uuid],primary_customer_id,
  jsonb_build_object('base_price',340,'day_time_adjustment',0,'people_adjustment',50,
    'extras_total',75,'coupon_discount',340,'commercial_value',125,
    'coupon_scope','RENTAL_ONLY','coupon_eligible_amount',340),id
from public.appointments where id='16700000-0000-4000-8000-000000000030';

-- Both original coupons are now expired, inactive and exhausted. A reschedule
-- must continue their saved contracts without requiring a new coupon redemption.
update public.coupons c set is_active=false,valid_until=now()-interval '1 day',
  used_count=(select count(*) from public.appointment_discounts ad where ad.coupon_id=c.id)
where c.id in ('16700000-0000-4000-8000-000000000008','16700000-0000-4000-8000-000000000009');

select ok(not has_function_privilege('anon','public.appointment_original_coupon_scope(uuid)','EXECUTE'),'original scope helper is private to the backend');
select ok(not has_function_privilege('authenticated','public.appointment_original_coupon_scope(uuid)','EXECUTE'),'authenticated browser cannot inspect contract scope directly');
select ok(has_function_privilege('service_role','public.appointment_original_coupon_scope(uuid)','EXECUTE'),'service role can resolve original contract scope');
select is(public.appointment_original_coupon_scope('16700000-0000-4000-8000-000000000010'),'RENTAL_ONLY','original audit preserves rental-only scope without a retained hold');
select is(public.appointment_original_coupon_scope('16700000-0000-4000-8000-000000000020'),'LEGACY_TOTAL','missing legacy marker preserves the original total-based agreement');
select is(public.appointment_original_coupon_scope('16700000-0000-4000-8000-000000000030'),'RENTAL_ONLY','original promoted hold is a compatible scope source');

create temporary table reschedule_coupon_quotes as
select label,public.calculate_reschedule_quote_for_appointment(
  appointment_id,((current_date+13)+local_time) at time zone 'America/Sao_Paulo'
) data from reschedule_coupon_cases;

select is((select (data->>'coupon_discount')::numeric from reschedule_coupon_quotes where label='new_percent'),170::numeric,'new percentage reschedule discounts only R$340 rental');
select is((select (data->>'commercial_value')::numeric from reschedule_coupon_quotes where label='new_percent'),295::numeric,'new percentage reschedule retains all R$125 extras');
select is((select (data->>'coupon_eligible_amount')::numeric from reschedule_coupon_quotes where label='new_percent'),340::numeric,'rental-only quote records the eligible amount');
select is((select data->>'coupon_scope' from reschedule_coupon_quotes where label='new_percent'),'RENTAL_ONLY','new scope survives quote recalculation');
select is((select (data->>'commercial_value')::numeric from reschedule_coupon_quotes where label='legacy_percent'),232.50::numeric,'legacy same-weekday reschedule does not increase the agreed total');
select is((select (data->>'coupon_discount')::numeric from reschedule_coupon_quotes where label='legacy_percent'),232.50::numeric,'legacy discount preserves its original total-based scope');
select is((select data->>'coupon_scope' from reschedule_coupon_quotes where label='legacy_percent'),'LEGACY_TOTAL','legacy marker overrides the fresh engine rental-only marker');
select is((select (data->>'commercial_value')::numeric from reschedule_coupon_quotes where label='new_fixed'),125::numeric,'oversized fixed coupon leaves all extras payable on reschedule');
select is((select (data->>'coupon_discount')::numeric from reschedule_coupon_quotes where label='new_fixed'),340::numeric,'oversized fixed coupon is capped at the rental amount');
select is((select (data->>'extras_total')::numeric from reschedule_coupon_quotes where label='new_percent'),75::numeric,'catalog extras retain their full amount');
select is((select (data->>'people_adjustment')::numeric from reschedule_coupon_quotes where label='new_percent'),50::numeric,'extra people retain their full amount');

create temporary table reschedule_coupon_holds as
select label,public.create_checkout_hold_for_reschedule(
  appointment_id,((current_date+13)+local_time) at time zone 'America/Sao_Paulo'
) data from reschedule_coupon_cases;

select is((select (data->>'commercial_value')::numeric from reschedule_coupon_holds where label='new_percent'),295::numeric,'client hold uses the same rental-only amount as the quote');
select is((select ch.quote_snapshot->>'coupon_scope' from public.checkout_holds ch
  join reschedule_coupon_holds h on ch.id=(h.data->>'checkout_hold_id')::uuid where h.label='new_percent'),'RENTAL_ONLY','client hold persists the new contract scope');
select is((select ch.coupon_discount from public.checkout_holds ch
  join reschedule_coupon_holds h on ch.id=(h.data->>'checkout_hold_id')::uuid where h.label='new_percent'),170::numeric,'client hold persists the same single discount');
select is((select (data->>'commercial_value')::numeric from reschedule_coupon_holds where label='legacy_percent'),232.50::numeric,'client hold preserves the legacy agreed total');
select is((select ch.quote_snapshot->>'coupon_scope' from public.checkout_holds ch
  join reschedule_coupon_holds h on ch.id=(h.data->>'checkout_hold_id')::uuid where h.label='legacy_percent'),'LEGACY_TOTAL','legacy client hold does not acquire the new scope accidentally');
select is((select (data->>'commercial_value')::numeric from reschedule_coupon_holds where label='new_fixed'),125::numeric,'client hold cannot spend a fixed coupon on extras');

create temporary table reschedule_coupon_policy as
select public.service_admin_create_reschedule_hold(
  '16700000-0000-4000-8000-000000000010',
  ((current_date+20)+time '09:00') at time zone 'America/Sao_Paulo',now(),'CLIENT',null
) data;
select is((select (data->>'difference_due')::numeric from reschedule_coupon_policy),0::numeric,'same-weekday new-scope contract has no additional payment difference');
create temporary table reschedule_coupon_apply as
select public.service_admin_apply_reschedule((select (data->>'policy_action_id')::uuid from reschedule_coupon_policy),null) data;
select is((select data->>'status' from reschedule_coupon_apply),'APPLIED','expired and inactive coupon does not block continuation of its original contract');
select is((select commercial_value from public.appointments where id='16700000-0000-4000-8000-000000000010'),295::numeric,'applied reschedule preserves the rental-only total');
select is((select coupon_discount from public.appointments where id='16700000-0000-4000-8000-000000000010'),170::numeric,'applied reschedule keeps a single rental-only discount');
select is((public.calculate_reschedule_quote_for_appointment(
  '16700000-0000-4000-8000-000000000010',((current_date+27)+time '09:00') at time zone 'America/Sao_Paulo'
)->>'commercial_value')::numeric,295::numeric,'a later reschedule still preserves the original rental-only scope');

create temporary table reschedule_legacy_policy as
select public.service_admin_create_reschedule_hold(
  '16700000-0000-4000-8000-000000000020',
  ((current_date+20)+time '11:00') at time zone 'America/Sao_Paulo',now(),'CLIENT',null
) data;
select is((select (data->>'difference_due')::numeric from reschedule_legacy_policy),0::numeric,'same-weekday legacy reschedule creates no retroactive coupon difference');
select is((select sum(used_count) from public.coupons where id in (
  '16700000-0000-4000-8000-000000000008','16700000-0000-4000-8000-000000000009'
)),3::bigint,'quotes, holds and applied reschedules do not consume the original coupons again');
select is((select count(*) from public.appointment_discounts where appointment_id in (
  select appointment_id from reschedule_coupon_cases
)),3::bigint,'rescheduling does not insert another coupon redemption');
select is((select ch.quote_snapshot->>'discount_source' from public.checkout_holds ch
  join reschedule_coupon_holds h on ch.id=(h.data->>'checkout_hold_id')::uuid where h.label='new_percent'),'APPOINTMENT_SNAPSHOT','hold remains an original appointment discount, not a new coupon application');

select * from finish();
rollback;
