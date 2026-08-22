begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(8);

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
insert into public.service_change_policies(service_id,notice_hours,reschedule_first_penalty_type,reschedule_first_penalty_value,reschedule_repeat_penalty_type,reschedule_repeat_penalty_value,reschedule_late_penalty_type,reschedule_late_penalty_value,cancellation_early_penalty_type,cancellation_early_penalty_value,cancellation_late_penalty_type,cancellation_late_penalty_value,cancellation_early_refund_allowed,cancellation_early_credit_allowed,cancellation_late_refund_allowed,cancellation_late_credit_allowed,cancellation_credit_validity_days)
values ('97600000-0000-0000-0000-000000000005',48,'NONE',0,'PERCENT',20,'PERCENT',20,'NONE',0,'PERCENT',20,true,true,true,true,90);

insert into public.appointments(id,public_code,service_id,service_employee_id,status,financial_status,start_at,end_at,core_start_at,core_end_at,duration_minutes,contracted_minutes,people_count,primary_customer_id,commercial_value)
values ('97600000-0000-0000-0000-000000000010','RESCHEDULE-1','97600000-0000-0000-0000-000000000005','97600000-0000-0000-0000-000000000006','CONFIRMED','NOT_STARTED',((current_date+5)+time '10:00') at time zone 'America/Sao_Paulo',((current_date+5)+time '12:00') at time zone 'America/Sao_Paulo',((current_date+5)+time '10:00') at time zone 'America/Sao_Paulo',((current_date+5)+time '12:00') at time zone 'America/Sao_Paulo',120,120,1,'97600000-0000-0000-0000-000000000001',500);
insert into public.resource_allocations(id,resource_id,appointment_id,allocation_type,status,occupied_range)
values ('97600000-0000-0000-0000-000000000011','97600000-0000-0000-0000-000000000004','97600000-0000-0000-0000-000000000010','APPOINTMENT','CONFIRMED',tstzrange(((current_date+5)+time '10:00') at time zone 'America/Sao_Paulo',((current_date+5)+time '12:30') at time zone 'America/Sao_Paulo','[)'));

select has_function('public','service_admin_create_reschedule_hold',array['uuid','timestamp with time zone','timestamp with time zone','uuid'],'reschedule hold function exists');
select has_function('public','service_admin_apply_reschedule',array['uuid','uuid'],'reschedule apply function exists');

create temporary table r as select public.service_admin_create_reschedule_hold('97600000-0000-0000-0000-000000000010',((current_date+10)+time '10:00') at time zone 'America/Sao_Paulo',now(),null) data;
select is((select data->>'policy_action_status' from r),'PREVIEW','free reschedule creates preview');
select is((select status::text from public.resource_allocations where id='97600000-0000-0000-0000-000000000011'),'CONFIRMED','old slot remains occupied before apply');

create temporary table a as select public.service_admin_apply_reschedule((select (data->>'policy_action_id')::uuid from r),null) data;
select is((select data->>'status' from a),'APPLIED','protected reschedule applies');
select is((select status::text from public.resource_allocations where id='97600000-0000-0000-0000-000000000011'),'RELEASED','old allocation is released after swap');
select ok(exists(select 1 from public.resource_allocations where appointment_id='97600000-0000-0000-0000-000000000010' and status='CONFIRMED' and lower(occupied_range)=((current_date+10)+time '10:00') at time zone 'America/Sao_Paulo' and upper(occupied_range)=((current_date+10)+time '12:30') at time zone 'America/Sao_Paulo'),'new allocation keeps final 30 minute buffer');
select ok((public.service_admin_apply_reschedule((select (data->>'policy_action_id')::uuid from r),null)->>'already_applied')::boolean,'replay is idempotent');

select * from finish();
rollback;
