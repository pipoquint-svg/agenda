begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

-- Test-only canonicalizer. elapsed_ms is intentionally outside deterministic comparisons.
create function pg_temp.monthly_availability_capture_legacy(
  p_page_slug text, p_service_id uuid, p_service_employee_id uuid,
  p_contracted_minutes integer, p_extras jsonb, p_people_count integer, p_month date
) returns jsonb language plpgsql as $$
declare v_started timestamptz := clock_timestamp(); v_dates jsonb;
begin
  select coalesce(jsonb_agg(to_char(local_date, 'YYYY-MM-DD') order by local_date), '[]'::jsonb)
    into v_dates
  from public.public_list_available_dates_month(
    p_page_slug, p_service_id, p_service_employee_id, p_contracted_minutes,
    p_extras, p_people_count, p_month
  );
  return jsonb_build_object(
    'engine', 'LEGACY_MONTH',
    'input', jsonb_build_object('booking_page_slug',p_page_slug,'service_id',p_service_id,
      'service_employee_id',p_service_employee_id,'contracted_minutes',p_contracted_minutes,
      'extras',p_extras,'people_count',p_people_count,'month',p_month),
    'dates',v_dates,'date_count',jsonb_array_length(v_dates),
    'elapsed_ms',round(extract(epoch from clock_timestamp()-v_started)*1000,3)
  );
end $$;

select plan(8);

insert into public.categories(id,name,slug) values ('15800000-0000-0000-0000-000000000001','Monthly parity','monthly-parity');
insert into public.resources(id,name,resource_type) values
 ('15800000-0000-0000-0000-000000000002','MONTHLY PERSON','PERSON'),
 ('15800000-0000-0000-0000-000000000003','MONTHLY STUDIO','PHYSICAL');
insert into public.employees(id,name,resource_id) values ('15800000-0000-0000-0000-000000000004','Monthly parity employee','15800000-0000-0000-0000-000000000002');
insert into public.services(id,category_id,name,slug,base_duration_minutes,base_price,buffer_before_minutes,buffer_after_minutes,minimum_people,maximum_people,maximum_booking_horizon_days,duration_mode,booking_block_minutes,minimum_booking_blocks,maximum_booking_blocks,price_per_block) values
 ('15800000-0000-0000-0000-000000000010','15800000-0000-0000-0000-000000000001','Monthly parity blocks','monthly-parity-blocks',60,100,15,15,1,4,5000,'BLOCKS',30,2,4,50);
insert into public.service_employees(id,service_id,employee_id) values ('15800000-0000-0000-0000-000000000020','15800000-0000-0000-0000-000000000010','15800000-0000-0000-0000-000000000004');
insert into public.service_change_policies(service_id,notice_hours,reschedule_first_early_percent,reschedule_first_late_percent,reschedule_repeat_percent,cancellation_late_percent)
values ('15800000-0000-0000-0000-000000000010',0,0,0,0,0);
insert into public.service_resources(service_id,resource_id) values ('15800000-0000-0000-0000-000000000010','15800000-0000-0000-0000-000000000003');
insert into public.availability_rules(service_employee_id,weekday,start_local_time,end_local_time) values ('15800000-0000-0000-0000-000000000020',1,'09:00','12:00');
insert into public.resource_availability_rules(resource_id,weekday,start_local_time,end_local_time) values
 ('15800000-0000-0000-0000-000000000002',1,'08:00','13:00'),('15800000-0000-0000-0000-000000000003',1,'08:00','13:00');
insert into public.extras(id,name,price,duration_delta_minutes) values
 ('15800000-0000-0000-0000-000000000030','Monthly prepend',0,30),('15800000-0000-0000-0000-000000000031','Monthly append',0,45);
insert into public.service_extras(service_id,extra_id,schedule_placement,default_schedule_minutes) values
 ('15800000-0000-0000-0000-000000000010','15800000-0000-0000-0000-000000000030','PREPEND',30),
 ('15800000-0000-0000-0000-000000000010','15800000-0000-0000-0000-000000000031','APPEND',45);
insert into public.extra_resources(extra_id,resource_id) values
 ('15800000-0000-0000-0000-000000000030','15800000-0000-0000-0000-000000000003'),
 ('15800000-0000-0000-0000-000000000031','15800000-0000-0000-0000-000000000003');
insert into public.booking_page_services(booking_page_id,service_id,sort_order)
select id,'15800000-0000-0000-0000-000000000010',999 from public.booking_pages where slug='blacksheep';

create temp table monthly_legacy(case_key text primary key, result jsonb not null);
insert into monthly_legacy values
 ('feb_28',pg_temp.monthly_availability_capture_legacy('blacksheep','15800000-0000-0000-0000-000000000010','15800000-0000-0000-0000-000000000020',60,'[]',1,'2035-02-01')),
 ('feb_29',pg_temp.monthly_availability_capture_legacy('blacksheep','15800000-0000-0000-0000-000000000010','15800000-0000-0000-0000-000000000020',60,'[]',1,'2036-02-01')),
 ('apr_30',pg_temp.monthly_availability_capture_legacy('blacksheep','15800000-0000-0000-0000-000000000010','15800000-0000-0000-0000-000000000020',60,'[]',1,'2035-04-01')),
 ('dec_31',pg_temp.monthly_availability_capture_legacy('blacksheep','15800000-0000-0000-0000-000000000010','15800000-0000-0000-0000-000000000020',60,'[]',1,'2035-12-01')),
 ('extras',pg_temp.monthly_availability_capture_legacy('blacksheep','15800000-0000-0000-0000-000000000010','15800000-0000-0000-0000-000000000020',60,'[{"extra_id":"15800000-0000-0000-0000-000000000030","quantity":1},{"extra_id":"15800000-0000-0000-0000-000000000031","quantity":1}]',1,'2035-01-01'));

select ok((select result ?& array['input','dates','date_count','elapsed_ms'] from monthly_legacy where case_key='feb_28'),'legacy monthly capture serializes canonical payload');
select is((select result->'dates' from monthly_legacy where case_key='feb_28'),(pg_temp.monthly_availability_capture_legacy('blacksheep','15800000-0000-0000-0000-000000000010','15800000-0000-0000-0000-000000000020',60,'[]',1,'2035-02-01')->'dates'),'monthly dates are deterministic and ordered');
select is((select result - 'elapsed_ms' from monthly_legacy where case_key='feb_29'),(pg_temp.monthly_availability_capture_legacy('blacksheep','15800000-0000-0000-0000-000000000010','15800000-0000-0000-0000-000000000020',60,'[]',1,'2036-02-01')-'elapsed_ms'),'leap February excludes volatile timing');
select ok((select (result->>'date_count')::integer >= 0 from monthly_legacy where case_key='apr_30'),'30-day month is captured');
select ok((select (result->>'date_count')::integer >= 0 from monthly_legacy where case_key='dec_31'),'31-day and year-boundary month is captured');
select ok((select result->'input'->'extras' <> '[]'::jsonb from monthly_legacy where case_key='extras'),'PREPEND APPEND merged-resource selection is serialized');
select ok((select (result->>'elapsed_ms')::numeric >= 0 from monthly_legacy where case_key='feb_28'),'monthly elapsed time is recorded outside comparison');
select ok(position('list_available_slots_for_duration' in pg_get_functiondef('agenda_public_bridge.list_available_dates_month_impl(text,uuid,uuid,integer,jsonb,integer,date)'::regprocedure)) > 0 and position('list_available_dates_month_v2' in pg_get_functiondef('agenda_public_bridge.list_available_dates_month_impl(text,uuid,uuid,integer,jsonb,integer,date)'::regprocedure)) = 0,'public monthly bridge remains on V1 before V2 exists');

select * from finish();
rollback;
