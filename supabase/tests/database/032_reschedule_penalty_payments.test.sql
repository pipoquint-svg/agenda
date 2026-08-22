begin;
create extension if not exists pgtap with schema extensions;
set local search_path=public,extensions;
select plan(10);

insert into public.customers(id,name) values ('97900000-0000-0000-0000-000000000001','Penalty Customer');
insert into public.employees(id,name) values ('97900000-0000-0000-0000-000000000002','Penalty Employee');
insert into public.categories(id,name,slug) values ('97900000-0000-0000-0000-000000000003','Penalty Test','penalty-test');
insert into public.resources(id,name,resource_type) values ('97900000-0000-0000-0000-000000000004','Penalty Studio','PHYSICAL');
insert into public.services(id,category_id,name,slug,base_duration_minutes,base_price,buffer_before_minutes,buffer_after_minutes,minimum_people,maximum_people,minimum_booking_notice_minutes,maximum_booking_horizon_days)
values ('97900000-0000-0000-0000-000000000005','97900000-0000-0000-0000-000000000003','Penalty Service','penalty-service',120,1000,0,30,1,10,0,365);
insert into public.service_employees(id,service_id,employee_id) values ('97900000-0000-0000-0000-000000000006','97900000-0000-0000-0000-000000000005','97900000-0000-0000-0000-000000000002');
insert into public.service_resources(service_id,resource_id,is_required) values ('97900000-0000-0000-0000-000000000005','97900000-0000-0000-0000-000000000004',true);
insert into public.availability_rules(service_employee_id,weekday,start_local_time,end_local_time,slot_interval_minutes,is_active)
select '97900000-0000-0000-0000-000000000006',d,time '08:00',time '18:00',30,true from generate_series(0,6)d;
insert into public.service_change_policies(service_id,notice_hours,reschedule_first_early_percent,reschedule_first_late_percent,reschedule_repeat_percent,cancellation_late_percent)
values ('97900000-0000-0000-0000-000000000005',48,0,20,30,30);

insert into public.appointments(id,public_code,service_id,service_employee_id,status,financial_status,start_at,end_at,core_start_at,core_end_at,duration_minutes,contracted_minutes,people_count,primary_customer_id,commercial_value,confirmed_at)
values ('97900000-0000-0000-0000-000000000010','PENALTY-1','97900000-0000-0000-0000-000000000005','97900000-0000-0000-0000-000000000006','CONFIRMED','PARTIALLY_PAID',((current_date+5)+time '10:00') at time zone 'America/Sao_Paulo',((current_date+5)+time '12:00') at time zone 'America/Sao_Paulo',((current_date+5)+time '10:00') at time zone 'America/Sao_Paulo',((current_date+5)+time '12:00') at time zone 'America/Sao_Paulo',120,120,1,'97900000-0000-0000-0000-000000000001',1000,now());
insert into public.payment_transactions(appointment_id,transaction_type,method,provider,provider_payment_id,status,contract_amount_settled,cash_amount,paid_at,payment_purpose)
values ('97900000-0000-0000-0000-000000000010','CHARGE','PIX','MERCADO_PAGO','retained-policy-pay','APPROVED',500,500,now(),'CONTRACT');
insert into public.resource_allocations(resource_id,appointment_id,allocation_type,status,occupied_range)
values ('97900000-0000-0000-0000-000000000004','97900000-0000-0000-0000-000000000010','APPOINTMENT','CONFIRMED',tstzrange(((current_date+5)+time '10:00') at time zone 'America/Sao_Paulo',((current_date+5)+time '12:30') at time zone 'America/Sao_Paulo','[)'));

select ok(not has_function('public','service_admin_register_reschedule_penalty_payment',array['uuid','text','text','uuid']),'separate reschedule penalty payment RPC no longer exists');

-- Request less than 48h before current appointment, but move to a later free slot.
create temporary table h as
select public.service_admin_create_reschedule_hold(
  '97900000-0000-0000-0000-000000000010',
  ((current_date+10)+time '10:00') at time zone 'America/Sao_Paulo',
  (((current_date+4)+time '10:01') at time zone 'America/Sao_Paulo'),
  'CLIENT',null
) data;

select is((select (data->>'penalty_retained')::numeric from h),200.00::numeric,'first late reschedule retains 20 percent of R$1000');
select is((select (data->>'applicable_amount')::numeric from h),300.00::numeric,'R$500 paid minus R$200 retained leaves R$300 applicable');
select is((select (data->>'difference_due')::numeric from h),700.00::numeric,'new R$1000 contract exposes R$700 difference instead of penalty debt');
select is((select data->>'policy_action_status' from h),'AWAITING_DIFFERENCE_PAYMENT','reschedule waits only for contract difference');
select is((select count(*)::integer from public.payment_transactions where appointment_id='97900000-0000-0000-0000-000000000010' and payment_purpose='RESCHEDULE_PENALTY'),0,'no separate penalty charge is created');
select is((select penalty_retained from public.appointment_change_settlements where policy_action_id=(select (data->>'policy_action_id')::uuid from h)),200.00::numeric,'retention is recorded in immutable change settlement ledger');
select throws_ok(
  $$select public.service_admin_apply_reschedule((select (data->>'policy_action_id')::uuid from h),null)$$,
  'P0001','RESCHEDULE_DIFFERENCE_PAYMENT_REQUIRED',
  'reschedule cannot apply until the R$700 contract difference is covered'
);

-- Simulate the contractual difference being paid, not a penalty payment.
insert into public.payment_transactions(appointment_id,transaction_type,method,provider,provider_payment_id,status,contract_amount_settled,cash_amount,paid_at,payment_purpose)
values ('97900000-0000-0000-0000-000000000010','CHARGE','PIX','MERCADO_PAGO','reschedule-contract-difference','APPROVED',700,700,now(),'CONTRACT');
select is((public.service_admin_apply_reschedule((select (data->>'policy_action_id')::uuid from h),null)->>'status'),'APPLIED','reschedule applies after contract difference is satisfied');
select is(public.appointment_client_reschedule_count('97900000-0000-0000-0000-000000000010'),1,'applied CLIENT reschedule increments lifetime counter exactly once');

select * from finish();
rollback;