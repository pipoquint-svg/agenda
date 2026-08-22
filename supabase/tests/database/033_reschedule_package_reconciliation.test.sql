begin;
create extension if not exists pgtap with schema extensions;
set local search_path=public,extensions;
select plan(13);

insert into public.customers(id,name) values ('98000000-0000-0000-0000-000000000001','Package Reschedule Customer');
insert into public.employees(id,name) values ('98000000-0000-0000-0000-000000000002','Package Reschedule Employee');
insert into public.categories(id,name,slug) values ('98000000-0000-0000-0000-000000000003','Package Reschedule','package-reschedule');
insert into public.resources(id,name,resource_type) values ('98000000-0000-0000-0000-000000000004','Package Studio','PHYSICAL');
insert into public.services(id,category_id,name,slug,base_duration_minutes,base_price,buffer_before_minutes,buffer_after_minutes,minimum_people,maximum_people,minimum_booking_notice_minutes,maximum_booking_horizon_days)
values ('98000000-0000-0000-0000-000000000005','98000000-0000-0000-0000-000000000003','Package Service','package-reschedule-service',120,500,0,30,1,10,0,5000);
insert into public.service_employees(id,service_id,employee_id) values ('98000000-0000-0000-0000-000000000006','98000000-0000-0000-0000-000000000005','98000000-0000-0000-0000-000000000002');
insert into public.service_resources(service_id,resource_id,is_required) values ('98000000-0000-0000-0000-000000000005','98000000-0000-0000-0000-000000000004',true);
insert into public.availability_rules(service_employee_id,weekday,start_local_time,end_local_time,slot_interval_minutes,is_active)
select '98000000-0000-0000-0000-000000000006',d,time '08:00',time '18:00',30,true from generate_series(0,6)d;
insert into public.service_change_policies(service_id,notice_hours,reschedule_first_early_percent,reschedule_first_late_percent,reschedule_repeat_percent,cancellation_late_percent)
values ('98000000-0000-0000-0000-000000000005',48,0,20,30,30);

insert into public.hour_packages(id,customer_id,name,total_minutes,purchased_value,valid_from,valid_until,status,special_surcharge_percent,standard_start_local_time,standard_end_local_time)
values ('98000000-0000-0000-0000-000000000007','98000000-0000-0000-0000-000000000001','40h Test',600,3000,'2035-01-01 00:00:00-03','2036-01-01 00:00:00-03','ACTIVE',15,time '08:00',time '18:00');
insert into public.hour_package_services(hour_package_id,service_id) values ('98000000-0000-0000-0000-000000000007','98000000-0000-0000-0000-000000000005');

insert into public.appointments(id,public_code,service_id,service_employee_id,status,financial_status,start_at,end_at,core_start_at,core_end_at,duration_minutes,contracted_minutes,people_count,primary_customer_id,commercial_value,confirmed_at)
values ('98000000-0000-0000-0000-000000000010','PKG-RS-1','98000000-0000-0000-0000-000000000005','98000000-0000-0000-0000-000000000006','CONFIRMED','NOT_STARTED','2035-03-05 10:00:00-03','2035-03-05 12:00:00-03','2035-03-05 10:00:00-03','2035-03-05 12:00:00-03',120,120,1,'98000000-0000-0000-0000-000000000001',500,now());
insert into public.resource_allocations(resource_id,appointment_id,allocation_type,status,occupied_range)
values ('98000000-0000-0000-0000-000000000004','98000000-0000-0000-0000-000000000010','APPOINTMENT','CONFIRMED',tstzrange('2035-03-05 10:00:00-03','2035-03-05 12:30:00-03','[)'));

insert into public.hour_package_movements(hour_package_id,appointment_id,movement_type,minutes_delta,seconds_delta,reason)
values ('98000000-0000-0000-0000-000000000007','98000000-0000-0000-0000-000000000010','RESERVATION_DEBIT',-120,-7200,'TEST_ORIGINAL_BOOKING');

insert into public.appointment_package_usage(appointment_id,hour_package_id,covered_minutes,uncovered_minutes,required_seconds,surcharge_seconds,charged_seconds,package_reference_minute_value,covered_reference_value,is_special_period,special_surcharge_percent,special_surcharge_amount,uncovered_time_amount,extras_cash_amount,cash_due,debit_movement_id)
select '98000000-0000-0000-0000-000000000010','98000000-0000-0000-0000-000000000007',120,0,7200,0,7200,
  (select reference_minute_value from public.hour_packages where id='98000000-0000-0000-0000-000000000007'),600,false,0,0,0,0,0,id
from public.hour_package_movements
where appointment_id='98000000-0000-0000-0000-000000000010' and movement_type='RESERVATION_DEBIT';

select has_function('public','service_reconcile_reschedule_package',array['uuid','uuid','uuid'],'package reschedule reconciliation exists');

create temporary table h as
select public.service_admin_create_reschedule_hold('98000000-0000-0000-0000-000000000010','2035-03-10 10:00:00-03','2035-03-01 10:00:00-03','CLIENT',null) data;

select is((select data->'package_reconciliation'->>'uses_package' from h),'true','package-backed appointment can create a reschedule hold');
select is((select (data->'package_reconciliation'->>'new_surcharge_seconds')::bigint from h),1080::bigint,'weekend target adds fifteen-percent seconds surcharge');
select is((select (data->'package_reconciliation'->>'delta_seconds')::bigint from h),1080::bigint,'hold exposes only incremental package debit');
select is((select status from public.appointments where id='98000000-0000-0000-0000-000000000010'),'CONFIRMED','old appointment remains confirmed before apply');

create temporary table a as
select public.service_admin_apply_reschedule((select (data->>'policy_action_id')::uuid from h),null) data;
select is((select data->>'status' from a),'APPLIED','package-backed reschedule applies');
select is((select surcharge_seconds from public.appointment_package_usage where appointment_id='98000000-0000-0000-0000-000000000010'),1080::bigint,'usage snapshot stores new surcharge');
select is((select charged_seconds from public.appointment_package_usage where appointment_id='98000000-0000-0000-0000-000000000010'),8280::bigint,'usage snapshot stores new total package charge');
select is((select seconds_delta from public.hour_package_movements where appointment_id='98000000-0000-0000-0000-000000000010' and movement_type='DURATION_ADJUSTMENT'),-1080::bigint,'ledger debits only package delta');
select is((select start_at from public.appointments where id='98000000-0000-0000-0000-000000000010'),'2035-03-10 10:00:00-03'::timestamptz,'appointment moves to protected weekend slot');
select is((select available_seconds from public.hour_package_balances where hour_package_id='98000000-0000-0000-0000-000000000007'),27720::bigint,'package balance includes original debit plus weekend delta');

select lives_ok($$select public.reverse_hour_package_usage('98000000-0000-0000-0000-000000000010','TEST_CANCEL_AFTER_RESCHEDULE',null)$$,'rescheduled package usage can still be reversed');
select is((select available_seconds from public.hour_package_balances where hour_package_id='98000000-0000-0000-0000-000000000007'),36000::bigint,'cancellation reversal restores complete package balance after adjustment');

select * from finish();
rollback;