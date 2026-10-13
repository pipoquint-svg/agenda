begin;
create extension if not exists pgtap with schema extensions;
set local search_path=public,extensions;
select plan(36);
-- The fixture lives in the future (2037-10-05, also a Monday): collections use the
-- agenda.test_now clock, but token resolution checks the real now(). A past fixture
-- date turns into APPOINTMENT_TOKEN_EXPIRED as soon as the calendar passes it.
select set_config('agenda.test_now','2037-10-05 16:00:00-03',true);

insert into auth.users(id,email,created_at,updated_at)
values('16500000-0000-4000-8000-000000000001','extras-admin@example.test',now(),now());
insert into public.admin_users(id,auth_user_id,display_name,role)
values('16500000-0000-4000-8000-000000000002','16500000-0000-4000-8000-000000000001','Extras Admin','OWNER');
insert into public.categories(id,name,slug)
values('16500000-0000-4000-8000-000000000003','Extras Rental','extras-rental');
insert into public.employees(id,name)
values('16500000-0000-4000-8000-000000000004','Extras Employee');
insert into public.resources(id,name,resource_type)
values('16500000-0000-4000-8000-000000000014','Extras Studio','PHYSICAL');
insert into public.services(id,category_id,name,slug,base_duration_minutes,base_price,
  minimum_people,maximum_people,maximum_booking_horizon_days,duration_mode,
  booking_block_minutes,minimum_booking_blocks,maximum_booking_blocks,price_per_block,
  confirmation_percentage,max_reschedules,operation_scope)
values('16500000-0000-4000-8000-000000000005','16500000-0000-4000-8000-000000000003',
  'Locação Extras','extras-rental',60,190,1,10,365,'BLOCKS',30,2,8,95,50,2,'BLACKSHEEP');
insert into public.service_change_policies(service_id,notice_hours,reschedule_first_early_percent,
  reschedule_first_late_percent,reschedule_repeat_percent,cancellation_late_percent)
values('16500000-0000-4000-8000-000000000005',12,0,20,20,20);
insert into public.service_employees(id,service_id,employee_id)
values('16500000-0000-4000-8000-000000000006','16500000-0000-4000-8000-000000000005','16500000-0000-4000-8000-000000000004');
insert into public.service_resources(service_id,resource_id,is_required)
values('16500000-0000-4000-8000-000000000005','16500000-0000-4000-8000-000000000014',true);
insert into public.customers(id,name,email,phone)
values('16500000-0000-4000-8000-000000000007','Cliente Extras','extras@example.test','48999990001');
insert into public.extras(id,name,price,post_booking_kind)
values('16500000-0000-4000-8000-000000000011','Assistência',75,'ASSISTANCE'),
  ('16500000-0000-4000-8000-000000000012','Cobertura de redes sociais',100,'SOCIAL_COVERAGE');
insert into public.service_extras(service_id,extra_id,max_quantity)
values('16500000-0000-4000-8000-000000000005','16500000-0000-4000-8000-000000000011',99),
  ('16500000-0000-4000-8000-000000000005','16500000-0000-4000-8000-000000000012',99);

insert into public.appointments(id,public_code,service_id,service_employee_id,service_name_snapshot,
  primary_customer_id,status,financial_status,start_at,end_at,core_start_at,core_end_at,
  duration_minutes,contracted_minutes,people_count,base_price_snapshot,coupon_discount,
  commercial_value,billing_mode_snapshot,confirmation_percentage_snapshot,confirmed_at)
values
('16500000-0000-4000-8000-000000000008','EXTRA-4H','16500000-0000-4000-8000-000000000005',
 '16500000-0000-4000-8000-000000000006','Locação Extras','16500000-0000-4000-8000-000000000007',
 'CONFIRMED','PARTIALLY_PAID','2037-10-05 10:00:00-03','2037-10-05 14:00:00-03',
 '2037-10-05 10:00:00-03','2037-10-05 14:00:00-03',240,240,1,600,150,450,'CHECKOUT',50,now()),
('16500000-0000-4000-8000-000000000009','EXTRA-1H','16500000-0000-4000-8000-000000000005',
 '16500000-0000-4000-8000-000000000006','Locação Extras','16500000-0000-4000-8000-000000000007',
 'CONFIRMED','PAID','2037-10-05 11:00:00-03','2037-10-05 12:00:00-03',
 '2037-10-05 11:00:00-03','2037-10-05 12:00:00-03',60,60,1,190,0,190,'CHECKOUT',50,now());
insert into public.payment_transactions(appointment_id,transaction_type,method,provider,status,
  contract_amount_settled,cash_amount,payment_purpose)
values('16500000-0000-4000-8000-000000000008','CHARGE','CARD','MERCADO_PAGO','APPROVED',300,300,'CONTRACT'),
 ('16500000-0000-4000-8000-000000000009','CHARGE','CARD','MERCADO_PAGO','APPROVED',190,190,'CONTRACT');
insert into public.resource_allocations(resource_id,appointment_id,allocation_type,status,occupied_range)
values('16500000-0000-4000-8000-000000000014','16500000-0000-4000-8000-000000000008',
  'APPOINTMENT','CONFIRMED',tstzrange('2037-10-05 10:00:00-03','2037-10-05 14:00:00-03','[)')),
 ('16500000-0000-4000-8000-000000000014',null,
  'MANUAL_BLOCK','BLOCKED',tstzrange('2037-10-05 14:00:00-03','2037-10-05 16:00:00-03','[)'));

select is((public.appointment_original_time_quote('16500000-0000-4000-8000-000000000008')->>'unit_price')::numeric,75::numeric,'four-hour block uses original undiscounted 600 / 8');
select is((public.appointment_original_time_quote('16500000-0000-4000-8000-000000000009')->>'unit_price')::numeric,95::numeric,'one-hour block is more expensive');
select ok((public.appointment_original_time_quote('16500000-0000-4000-8000-000000000008')->>'unit_price')::numeric
  <(public.appointment_original_time_quote('16500000-0000-4000-8000-000000000009')->>'unit_price')::numeric,
  'four-hour tier is cheaper than one-hour tier');
select is((public.service_admin_post_booking_extra_options('16500000-0000-4000-8000-000000000008',
  '16500000-0000-4000-8000-000000000002')->>'balance')::numeric,150::numeric,'preview shows existing balance');

select set_config('agenda.extra_collection',public.create_balance_collection(
  '16500000-0000-4000-8000-000000000008','AUTO_START',null)->>'collection_id',true);
select set_config('agenda.extra_token',public.service_issue_balance_collection_payment_token(
  current_setting('agenda.extra_collection')::uuid)->>'access_token',true);
select set_config('agenda.extra_result',public.service_admin_add_post_booking_extra(
  '16500000-0000-4000-8000-000000000008','EXTRA_TIME',null,2,
  '16500000-0000-4000-8000-000000000002','16500000-0000-4000-8000-000000000101')::text,true);
select is((current_setting('agenda.extra_result')::jsonb->>'total')::numeric,150::numeric,'two blocks cost 150 despite the resource conflict after the original end');
select is((current_setting('agenda.extra_result')::jsonb->>'balance_after')::numeric,300::numeric,'existing balance grows dynamically');
select is(current_setting('agenda.extra_result')::jsonb->>'collection_id',current_setting('agenda.extra_collection'),'existing link stays attached to same collection');
select is(current_setting('agenda.extra_result')::jsonb->>'notification','LINK_UPDATED','no new email queued for active link');
select is((select count(*)::integer from public.appointment_balance_collections where appointment_id='16500000-0000-4000-8000-000000000008'),1,'active collection is not duplicated');
select is((public.service_verify_balance_collection_payment_token(current_setting('agenda.extra_token'))->>'amount')::numeric,300::numeric,'same PAY token reads current balance');
select ok((public.service_admin_add_post_booking_extra('16500000-0000-4000-8000-000000000008','EXTRA_TIME',null,2,
  '16500000-0000-4000-8000-000000000002','16500000-0000-4000-8000-000000000101')->>'idempotent_replay')::boolean,
  'retry returns the original launch');
select is((select count(*)::integer from public.appointment_post_booking_extras where appointment_id='16500000-0000-4000-8000-000000000008'),1,'retry does not duplicate a launch');
select is((select commercial_value from public.appointments where id='16500000-0000-4000-8000-000000000008'),450::numeric,'original contract remains unchanged');
select is((select total_value from public.appointment_open_balances where appointment_id='16500000-0000-4000-8000-000000000008'),600::numeric,'management total includes separate launches');
select is((select unit_price_snapshot from public.appointment_post_booking_extras where appointment_id='16500000-0000-4000-8000-000000000008'),75::numeric,'unit price snapshot is persisted');

insert into public.payment_transactions(id,appointment_id,transaction_type,method,provider,provider_payment_id,
  status,contract_amount_settled,cash_amount,payment_purpose,balance_collection_id)
values('16500000-0000-4000-8000-000000000013','16500000-0000-4000-8000-000000000008',
  'CHARGE','PIX','MERCADO_PAGO','old-pix-order','PENDING',300,300,'CONTRACT',current_setting('agenda.extra_collection')::uuid);
select set_config('agenda.extra_result_2',public.service_admin_add_post_booking_extra(
  '16500000-0000-4000-8000-000000000008','EXTRA_TIME',null,1,
  '16500000-0000-4000-8000-000000000002','16500000-0000-4000-8000-000000000102')::text,true);
select ok((select provider_refresh_pending from public.appointment_balance_collections where id=current_setting('agenda.extra_collection')::uuid),'old PIX must be cancelled before new payment intent');
select throws_ok($$select public.service_create_payment_intent_by_token(current_setting('agenda.extra_token'),'FULL','PIX','changedamountkey123')$$,
  'P0001','BALANCE_PROVIDER_REFRESH_PENDING','old provider order blocks checkout');
select is((current_setting('agenda.extra_result_2')::jsonb->>'balance_after')::numeric,375::numeric,'same link now represents increased balance');
-- The provider adapter cancels the old order, then expires its local intent.
update public.payment_transactions set status='EXPIRED' where id='16500000-0000-4000-8000-000000000013';
update public.appointment_balance_collections set provider_refresh_pending=false
  where id=current_setting('agenda.extra_collection')::uuid;
select set_config('agenda.new_intent',public.service_create_payment_intent_by_token(
  current_setting('agenda.extra_token'),'FULL','PIX','freshamountkey123')::text,true);
select is((current_setting('agenda.new_intent')::jsonb->>'contract_amount_settled')::numeric,375::numeric,
  'same PAY link creates a new FULL intent for the current balance after provider cancellation');
select is((current_setting('agenda.new_intent')::jsonb->>'balance_collection_id')::uuid,
  current_setting('agenda.extra_collection')::uuid,'new provider order stays on the original collection');
select is((select status from public.payment_transactions where id='16500000-0000-4000-8000-000000000013'),
  'EXPIRED','old PIX intent remains expired');

select set_config('agenda.zero_result',public.service_admin_add_post_booking_extra(
  '16500000-0000-4000-8000-000000000009','EXTRA_TIME',null,1,
  '16500000-0000-4000-8000-000000000002','16500000-0000-4000-8000-000000000103')::text,true);
select is((current_setting('agenda.zero_result')::jsonb->>'total')::numeric,95::numeric,'one-hour reservation uses its own 95 block');
select is(current_setting('agenda.zero_result')::jsonb->>'notification','EMAIL_QUEUED','zero to positive creates a payment email');
select is((select count(*)::integer from public.integration_jobs where entity_id=(current_setting('agenda.zero_result')::jsonb->>'collection_id')::uuid and job_type='RENTAL_BALANCE_DUE_EMAIL'),1,'new collection queues one email');
select is((select count(*)::integer from public.appointment_balance_collections where appointment_id='16500000-0000-4000-8000-000000000009'),1,'legacy paid reservation is backfilled on demand');
select is((public.service_verify_balance_collection_email((current_setting('agenda.zero_result')::jsonb->>'collection_id')::uuid,'extras@example.test')->>'amount')::numeric,95::numeric,'legacy collection validation obtains current balance');
select throws_ok($$select public.service_verify_balance_collection_email(
  (current_setting('agenda.zero_result')::jsonb->>'collection_id')::uuid,'wrong@example.test')$$,
  'P0001','BALANCE_COLLECTION_VERIFICATION_FAILED','legacy collection UUID alone is insufficient');
select set_config('agenda.catalog_assistance',public.service_admin_add_post_booking_extra(
  '16500000-0000-4000-8000-000000000009','ASSISTANCE','16500000-0000-4000-8000-000000000011',1,
  '16500000-0000-4000-8000-000000000002','16500000-0000-4000-8000-000000000104')::text,true);
select is((current_setting('agenda.catalog_assistance')::jsonb->>'unit_price')::numeric,75::numeric,'assistance snapshots current catalog price');
select is((select unit from public.appointment_post_booking_extras where id=(current_setting('agenda.catalog_assistance')::jsonb->>'id')::uuid),'HOUR','assistance catalog price is per hour');
select set_config('agenda.catalog_social',public.service_admin_add_post_booking_extra(
  '16500000-0000-4000-8000-000000000009','SOCIAL_COVERAGE','16500000-0000-4000-8000-000000000012',1,
  '16500000-0000-4000-8000-000000000002','16500000-0000-4000-8000-000000000105')::text,true);
select is((current_setting('agenda.catalog_social')::jsonb->>'unit_price')::numeric,100::numeric,'social coverage snapshots current catalog price');
select is((select unit from public.appointment_post_booking_extras where id=(current_setting('agenda.catalog_social')::jsonb->>'id')::uuid),'HOUR','social coverage catalog price is per hour');
select is(current_setting('agenda.catalog_social')::jsonb->>'collection_id',
  current_setting('agenda.zero_result')::jsonb->>'collection_id','later catalog extras keep the same collection');
select is((select count(*)::integer from public.integration_jobs where entity_id=(current_setting('agenda.zero_result')::jsonb->>'collection_id')::uuid and job_type='RENTAL_BALANCE_DUE_EMAIL'),1,'later extras do not queue another email');
select set_config('agenda.zero_token',public.service_issue_balance_collection_payment_token(
  (current_setting('agenda.zero_result')::jsonb->>'collection_id')::uuid)->>'access_token',true);
select throws_ok($$select public.service_create_payment_intent_by_token(current_setting('agenda.zero_token'),'MINIMUM','PIX','minimumdeniedkey123')$$,
  'P0001','BALANCE_COLLECTION_FULL_PAYMENT_REQUIRED','balance payments require FULL');
select throws_ok($$select public.resolve_appointment_access_token(current_setting('agenda.extra_token'),'MANAGE')$$,
  'P0001','TOKEN_SCOPE_DENIED','PAY token cannot manage appointment');
insert into public.payment_transactions(appointment_id,transaction_type,method,provider,status,
  contract_amount_settled,cash_amount,payment_purpose)
values('16500000-0000-4000-8000-000000000009','CHARGE','CARD','MERCADO_PAGO','APPROVED',270,270,'CONTRACT');
select is(public.appointment_returnable_excess('16500000-0000-4000-8000-000000000009'),0::numeric,
  'paid extras are not misclassified as customer excess');

select * from finish();
rollback;
