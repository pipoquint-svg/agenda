begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(12);

insert into public.customers(id,name) values ('97600000-0000-0000-0000-000000000001','Reschedule Customer');
insert into public.employees(id,name) values ('97600000-0000-0000-0000-000000000002','Reschedule Employee');
insert into public.categories(id,name,slug) values ('97600000-0000-0000-0000-000000000003','Reschedule Test','reschedule-test');
insert into public.resources(id,name,resource_type) values ('97600000-0000-0000-0000-000000000004','Reschedule Studio','PHYSICAL');
insert into public.services(id,category_id,name,slug,base_duration_minutes,base_price,buffer_before_minutes,buffer_after_minutes,minimum_people,maximum_people,minimum_booking_notice_minutes,maximum_booking_horizon_days)
values ('97600000-0000-0000-0000-000000000005','97600000-0000-0000-0000-000000000003','Reschedule Service','reschedule-service',120,500,0,30,1,10,0,365);
insert into public.service_employees(id,service_id,employee_id) values ('97600000-0000-0000-0000-000000000006','97600000-0000-0000-0000-000000000005','97600000-0000-0000-0000-000000000002');
insert into public.service_resources(service_id,resource_id,is_required) values ('97600000-0000-0000-0000-000000000005','97600000-0000-0000-0000-000000000004',true);
insert into public.availability_rules(service_employee_id,weekday,start_local_time,end_local_time,slot_interval_minutes,is_active)
select '97600000-0000-0000-0000-000000000006',d,time '08:00',time '18:00',30,true from generate_series(0,6) d;
insert into public.resource_availability_rules(resource_id,weekday,start_local_time,end_local_time,is_active)
select '97600000-0000-0000-0000-000000000004',d,time '08:00',time '18:00',true from generate_series(0,6) d;
insert into public.service_change_policies(service_id,notice_hours,reschedule_first_early_percent,reschedule_first_late_percent,reschedule_repeat_percent,cancellation_late_percent)
values ('97600000-0000-0000-0000-000000000005',48,0,20,30,30);

insert into public.appointments(id,public_code,service_id,service_employee_id,status,financial_status,start_at,end_at,core_start_at,core_end_at,duration_minutes,contracted_minutes,people_count,primary_customer_id,commercial_value,confirmed_at)
values ('97600000-0000-0000-0000-000000000010','RESCHEDULE-1','97600000-0000-0000-0000-000000000005','97600000-0000-0000-0000-000000000006','CONFIRMED','PARTIALLY_PAID',((current_date+5)+time '10:00') at time zone 'America/Sao_Paulo',((current_date+5)+time '12:00') at time zone 'America/Sao_Paulo',((current_date+5)+time '10:00') at time zone 'America/Sao_Paulo',((current_date+5)+time '12:00') at time zone 'America/Sao_Paulo',120,120,1,'97600000-0000-0000-0000-000000000001',500,now());
insert into public.payment_transactions(appointment_id,transaction_type,method,provider,provider_payment_id,status,contract_amount_settled,cash_amount,paid_at,payment_purpose)
values ('97600000-0000-0000-0000-000000000010','CHARGE','CARD','MERCADO_PAGO','reschedule-half-paid','APPROVED',250,250,now(),'CONTRACT');
insert into public.resource_allocations(id,resource_id,appointment_id,allocation_type,status,occupied_range)
values ('97600000-0000-0000-0000-000000000011','97600000-0000-0000-0000-000000000004','97600000-0000-0000-0000-000000000010','APPOINTMENT','CONFIRMED',tstzrange(((current_date+5)+time '10:00') at time zone 'America/Sao_Paulo',((current_date+5)+time '12:30') at time zone 'America/Sao_Paulo','[)'));

select has_function('public','service_admin_create_reschedule_hold',array['uuid','timestamp with time zone','timestamp with time zone','text','uuid'],'explicit-origin reschedule hold function exists');
select has_function('public','service_admin_apply_reschedule',array['uuid','uuid'],'reschedule apply function exists');

create temporary table original_blocks as
select duration_blocks from public.appointments where id='97600000-0000-0000-0000-000000000010';

create temporary table r as select public.service_admin_create_reschedule_hold('97600000-0000-0000-0000-000000000010',((current_date+10)+time '10:00') at time zone 'America/Sao_Paulo',now(),'CLIENT',null) data;
select is((select data->>'policy_action_status' from r),'PREVIEW','free first client reschedule creates preview');
select is((select (data->>'difference_due')::numeric from r),0::numeric,'same-price reschedule preserves the already-satisfied 50 percent commitment');
select is((select (data->>'applicable_amount')::numeric from r),250::numeric,'the R$250 customer payment remains applied to the new reservation');
select is((select status::text from public.resource_allocations where id='97600000-0000-0000-0000-000000000011'),'CONFIRMED','old slot remains occupied before apply');
select is(
  (select ch.duration_blocks from public.checkout_holds ch where ch.id=(select reschedule_checkout_hold_id from public.appointment_policy_actions where id=(select (data->>'policy_action_id')::uuid from r))),
  (select duration_blocks from original_blocks),
  'reschedule hold preserves the original block count and cannot silently reduce it'
);

create temporary table a as select public.service_admin_apply_reschedule((select (data->>'policy_action_id')::uuid from r),null) data;
select is((select data->>'status' from a),'APPLIED','protected reschedule applies');
select is((select status::text from public.resource_allocations where id='97600000-0000-0000-0000-000000000011'),'RELEASED','old allocation is released after swap');
select ok(exists(select 1 from public.resource_allocations where appointment_id='97600000-0000-0000-0000-000000000010' and status='CONFIRMED' and lower(occupied_range)=((current_date+10)+time '10:00') at time zone 'America/Sao_Paulo' and upper(occupied_range)=((current_date+10)+time '12:30') at time zone 'America/Sao_Paulo'),'new allocation keeps final 30 minute buffer');
select is(
  (select duration_blocks from public.appointments where id='97600000-0000-0000-0000-000000000010'),
  (select duration_blocks from original_blocks),
  'applied reschedule preserves the original block count'
);
select ok((public.service_admin_apply_reschedule((select (data->>'policy_action_id')::uuid from r),null)->>'already_applied')::boolean,'replay is idempotent');

select * from finish();
rollback;
