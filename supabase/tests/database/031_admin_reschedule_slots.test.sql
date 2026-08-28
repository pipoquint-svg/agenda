begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(6);

insert into public.customers(id,name) values ('97800000-0000-0000-0000-000000000001','Slot Customer');
insert into public.employees(id,name) values ('97800000-0000-0000-0000-000000000002','Slot Employee');
insert into public.categories(id,name,slug) values ('97800000-0000-0000-0000-000000000003','Slot Test','slot-test');
insert into public.resources(id,name,resource_type) values ('97800000-0000-0000-0000-000000000004','Slot Studio','PHYSICAL');
insert into public.services(id,category_id,name,slug,base_duration_minutes,base_price,buffer_before_minutes,buffer_after_minutes,minimum_people,maximum_people,minimum_booking_notice_minutes,maximum_booking_horizon_days)
values ('97800000-0000-0000-0000-000000000005','97800000-0000-0000-0000-000000000003','Slot Service','slot-service',120,500,0,30,1,10,0,365);
insert into public.service_employees(id,service_id,employee_id) values ('97800000-0000-0000-0000-000000000006','97800000-0000-0000-0000-000000000005','97800000-0000-0000-0000-000000000002');
insert into public.service_resources(service_id,resource_id,is_required) values ('97800000-0000-0000-0000-000000000005','97800000-0000-0000-0000-000000000004',true);
insert into public.availability_rules(service_employee_id,weekday,start_local_time,end_local_time,slot_interval_minutes,is_active)
select '97800000-0000-0000-0000-000000000006',d,time '08:00',time '18:00',30,true from generate_series(0,6) d;
insert into public.resource_availability_rules(resource_id,weekday,start_local_time,end_local_time,is_active)
select '97800000-0000-0000-0000-000000000004',d,time '08:00',time '18:00',true from generate_series(0,6) d;

insert into public.appointments(id,public_code,service_id,service_employee_id,status,financial_status,start_at,end_at,core_start_at,core_end_at,duration_minutes,contracted_minutes,people_count,primary_customer_id,commercial_value)
values ('97800000-0000-0000-0000-000000000010','SLOTS-1','97800000-0000-0000-0000-000000000005','97800000-0000-0000-0000-000000000006','CONFIRMED','NOT_STARTED',((current_date+10)+time '10:00') at time zone 'America/Sao_Paulo',((current_date+10)+time '12:00') at time zone 'America/Sao_Paulo',((current_date+10)+time '10:00') at time zone 'America/Sao_Paulo',((current_date+10)+time '12:00') at time zone 'America/Sao_Paulo',120,120,1,'97800000-0000-0000-0000-000000000001',500);
insert into public.resource_allocations(resource_id,appointment_id,allocation_type,status,occupied_range)
values ('97800000-0000-0000-0000-000000000004','97800000-0000-0000-0000-000000000010','APPOINTMENT','CONFIRMED',tstzrange(((current_date+10)+time '10:00') at time zone 'America/Sao_Paulo',((current_date+10)+time '12:30') at time zone 'America/Sao_Paulo','[)'));

select has_function('public','service_admin_list_reschedule_slots',array['uuid','date'],'admin reschedule slot discovery exists');
select ok(not has_function_privilege('anon','public.service_admin_list_reschedule_slots(uuid,date)','EXECUTE'),'anonymous users cannot query admin reschedule slots');

create temporary table slots as
select public.service_admin_list_reschedule_slots('97800000-0000-0000-0000-000000000010',current_date+10) data;

select ok(jsonb_array_length((select data from slots)) > 0,'available replacement slots are returned');
select ok(not exists(
  select 1 from jsonb_array_elements((select data from slots)) x
  where (x->>'slot_start_at')::timestamptz = ((current_date+10)+time '10:00') at time zone 'America/Sao_Paulo'
),'currently occupied appointment slot is not offered');
select ok(exists(
  select 1 from jsonb_array_elements((select data from slots)) x
  where (x->>'slot_start_at')::timestamptz = ((current_date+10)+time '13:00') at time zone 'America/Sao_Paulo'
),'later non-conflicting slot is offered');
select is((
  select extract(epoch from ((x->>'slot_end_at')::timestamptz - (x->>'slot_start_at')::timestamptz))::integer/60
  from jsonb_array_elements((select data from slots)) x
  where (x->>'slot_start_at')::timestamptz = ((current_date+10)+time '13:00') at time zone 'America/Sao_Paulo'
),120,'customer-facing replacement slot preserves contracted two-hour duration');

select * from finish();
rollback;