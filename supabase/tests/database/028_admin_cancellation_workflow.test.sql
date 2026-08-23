begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(15);

insert into public.customers(id,name,email)
values ('97500000-0000-0000-0000-000000000001','Cancellation Customer','cancel@example.com');
insert into public.employees(id,name)
values ('97500000-0000-0000-0000-000000000002','Cancellation Employee');
insert into public.categories(id,name,slug)
values ('97500000-0000-0000-0000-000000000003','Cancellation Test','cancellation-workflow-test');
insert into public.resources(id,name,resource_type)
values ('97500000-0000-0000-0000-000000000004','Cancellation Studio','PHYSICAL');
insert into public.services(id,category_id,name,slug,base_duration_minutes,base_price,minimum_people,maximum_people)
values ('97500000-0000-0000-0000-000000000005','97500000-0000-0000-0000-000000000003','Cancellation Service','cancellation-service',120,1000,1,10);
insert into public.service_employees(id,service_id,employee_id)
values ('97500000-0000-0000-0000-000000000006','97500000-0000-0000-0000-000000000005','97500000-0000-0000-0000-000000000002');
insert into public.service_change_policies(service_id,notice_hours,reschedule_first_early_percent,reschedule_first_late_percent,reschedule_repeat_percent,cancellation_late_percent)
values ('97500000-0000-0000-0000-000000000005',48,0,20,30,30);

insert into public.appointments(id,public_code,service_id,service_employee_id,status,financial_status,start_at,end_at,duration_minutes,people_count,primary_customer_id,commercial_value,confirmed_at)
values
('97500000-0000-0000-0000-000000000010','CANCEL-BALANCE-1','97500000-0000-0000-0000-000000000005','97500000-0000-0000-0000-000000000006','CONFIRMED','PARTIALLY_PAID','2035-02-10 10:00:00-03','2035-02-10 12:00:00-03',120,1,'97500000-0000-0000-0000-000000000001',1000,now()),
('97500000-0000-0000-0000-000000000020','CANCEL-REFUND-1','97500000-0000-0000-0000-000000000005','97500000-0000-0000-0000-000000000006','CONFIRMED','PARTIALLY_PAID','2035-02-11 10:00:00-03','2035-02-11 12:00:00-03',120,1,'97500000-0000-0000-0000-000000000001',1000,now());

insert into public.resource_allocations(id,resource_id,appointment_id,allocation_type,status,occupied_range)
values
('97500000-0000-0000-0000-000000000011','97500000-0000-0000-0000-000000000004','97500000-0000-0000-0000-000000000010','APPOINTMENT','CONFIRMED',tstzrange('2035-02-10 10:00:00-03','2035-02-10 12:30:00-03','[)')),
('97500000-0000-0000-0000-000000000021','97500000-0000-0000-0000-000000000004','97500000-0000-0000-0000-000000000020','APPOINTMENT','CONFIRMED',tstzrange('2035-02-11 10:00:00-03','2035-02-11 12:30:00-03','[)'));

insert into public.payment_transactions(appointment_id,transaction_type,method,provider,provider_payment_id,status,contract_amount_settled,cash_amount,paid_at,payment_purpose)
values
('97500000-0000-0000-0000-000000000010','CHARGE','PIX','MERCADO_PAGO','cancel-approved-balance','APPROVED',500,500,'2035-02-01 10:00:00-03','CONTRACT'),
('97500000-0000-0000-0000-000000000010','CHARGE','CARD','MERCADO_PAGO','cancel-pending-balance','PENDING',100,100,null,'CONTRACT'),
('97500000-0000-0000-0000-000000000020','CHARGE','PIX','MERCADO_PAGO','cancel-approved-refund','APPROVED',500,500,'2035-02-01 10:00:00-03','CONTRACT');

select has_function('public','service_admin_cancel_appointment',array['uuid','text','text','timestamp with time zone','text','uuid'],'explicit-origin transactional cancellation function exists');
select throws_ok(
  $$select public.service_admin_cancel_appointment('97500000-0000-0000-0000-000000000010','CREDIT','CLIENT_REQUEST','2035-02-07 10:00:00-03','CLIENT',null)$$,
  'P0001','LEGACY_CANCELLATION_CREDIT_REMOVED','legacy automatic cancellation credit is rejected');
select is((select status::text from public.appointments where id='97500000-0000-0000-0000-000000000010'),'CONFIRMED','rejected legacy settlement leaves appointment untouched');

create temporary table c as
select public.service_admin_cancel_appointment('97500000-0000-0000-0000-000000000010',null,'CLIENT_REQUEST','2035-02-07 10:00:00-03','CLIENT',null) data;
select is((select data->>'status' from c),'CANCELLED','valid client cancellation applies operational cancellation');
select is((select data->>'settlement_choice' from c),'REFUND','refund is the safe default');
select is((select status::text from public.resource_allocations where id='97500000-0000-0000-0000-000000000011'),'CANCELLED','cancellation releases appointment allocation');
select is((select status from public.payment_transactions where provider_payment_id='cancel-pending-balance'),'EXPIRED','pending charge expires when appointment is cancelled');
select is((select status from public.appointment_policy_actions where appointment_id='97500000-0000-0000-0000-000000000010' and action_type='CANCEL'),'PENDING_REFUND','default cancellation remains pending refund until real settlement');
select is((select count(*)::integer from public.coupons where source_appointment_id='97500000-0000-0000-0000-000000000010'),0,'cancellation no longer creates a coupon');
select ok(exists(select 1 from public.integration_jobs where job_type='GOOGLE_APPOINTMENT_SYNC' and entity_id='97500000-0000-0000-0000-000000000010' and payload_json->>'reason'='APPOINTMENT_CANCELLED'),'cancellation enqueues Google desired-state sync');
select ok((public.service_admin_cancel_appointment('97500000-0000-0000-0000-000000000010',null,'REPLAY','2035-02-07 10:01:00-03','CLIENT',null)->>'already_cancelled')::boolean,'repeated cancellation is idempotent');

select lives_ok($$select public.service_credit_customer_balance_from_return(
  '97500000-0000-0000-0000-000000000010',
  (select id from public.appointment_policy_actions where appointment_id='97500000-0000-0000-0000-000000000010' and action_type='CANCEL'),
  'CLIENT_TOKEN',null,'127.0.0.1'::inet,'pgTAP','cancel-balance-choice',null
)$$,'explicit evidenced client choice converts return into indefinite customer balance');
select is(public.customer_balance_available('97500000-0000-0000-0000-000000000001'),500.00::numeric,'early cancellation balance equals the R$500 customer return');

select is(
  (public.service_admin_cancel_appointment('97500000-0000-0000-0000-000000000020',null,'CLIENT_REQUEST','2035-02-08 10:00:00-03','CLIENT',null)->>'policy_action_status'),
  'PENDING_REFUND','second cancellation also defaults to real refund settlement');
select is((select count(*)::integer from public.payment_transactions where appointment_id='97500000-0000-0000-0000-000000000020' and transaction_type='REFUND'),0,'workflow never fabricates refund before provider/manual confirmation');

select * from finish();
rollback;
