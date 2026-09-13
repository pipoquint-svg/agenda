-- Disposable benchmark fixture. Loaded inside the benchmark transaction only.
insert into public.categories(id,name,slug) values ('15900000-0000-0000-0000-000000000001','Benchmark','benchmark-159');
insert into public.resources(id,name,resource_type) values
 ('15900000-0000-0000-0000-000000000002','Benchmark person','PERSON'),
 ('15900000-0000-0000-0000-000000000003','Benchmark studio','PHYSICAL');
insert into public.employees(id,name,resource_id) values ('15900000-0000-0000-0000-000000000004','Benchmark employee','15900000-0000-0000-0000-000000000002');
insert into public.services(id,category_id,name,slug,base_duration_minutes,base_price,buffer_before_minutes,buffer_after_minutes,minimum_people,maximum_people,maximum_booking_horizon_days,duration_mode,booking_block_minutes,minimum_booking_blocks,maximum_booking_blocks,price_per_block) values
 ('15900000-0000-0000-0000-000000000010','15900000-0000-0000-0000-000000000001','Benchmark blocks','benchmark-blocks-159',60,100,15,15,1,4,5000,'BLOCKS',30,2,4,50);
insert into public.service_employees(id,service_id,employee_id) values ('15900000-0000-0000-0000-000000000020','15900000-0000-0000-0000-000000000010','15900000-0000-0000-0000-000000000004');
insert into public.service_change_policies(service_id,notice_hours,reschedule_first_early_percent,reschedule_first_late_percent,reschedule_repeat_percent,cancellation_late_percent) values ('15900000-0000-0000-0000-000000000010',0,0,0,0,0);
insert into public.service_resources(service_id,resource_id) values ('15900000-0000-0000-0000-000000000010','15900000-0000-0000-0000-000000000003');
insert into public.booking_page_services(booking_page_id,service_id,sort_order) select id,'15900000-0000-0000-0000-000000000010',159 from public.booking_pages where slug='blacksheep';
insert into public.availability_rules(service_employee_id,weekday,start_local_time,end_local_time) select '15900000-0000-0000-0000-000000000020',d,'08:00','18:00' from generate_series(0,6) d;
insert into public.resource_availability_rules(resource_id,weekday,start_local_time,end_local_time) select r,d,'07:00','19:00' from (values ('15900000-0000-0000-0000-000000000002'::uuid),('15900000-0000-0000-0000-000000000003'::uuid)) x(r) cross join generate_series(0,6) d;
insert into public.extras(id,name,price,duration_delta_minutes) values ('15900000-0000-0000-0000-000000000030','Benchmark prepend',0,30),('15900000-0000-0000-0000-000000000031','Benchmark append',0,30);
insert into public.service_extras(service_id,extra_id,schedule_placement,default_schedule_minutes) values ('15900000-0000-0000-0000-000000000010','15900000-0000-0000-0000-000000000030','PREPEND',30),('15900000-0000-0000-0000-000000000010','15900000-0000-0000-0000-000000000031','APPEND',30);
insert into public.extra_resources(extra_id,resource_id) values ('15900000-0000-0000-0000-000000000030','15900000-0000-0000-0000-000000000003'),('15900000-0000-0000-0000-000000000031','15900000-0000-0000-0000-000000000003');
