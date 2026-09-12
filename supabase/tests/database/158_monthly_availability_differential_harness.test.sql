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

create function pg_temp.monthly_availability_capture_v2(
  p_page_slug text, p_service_id uuid, p_service_employee_id uuid,
  p_contracted_minutes integer, p_extras jsonb, p_people_count integer, p_month date
) returns jsonb language plpgsql as $$
declare v_started timestamptz := clock_timestamp(); v_dates jsonb;
begin
  select coalesce(jsonb_agg(to_char(local_date, 'YYYY-MM-DD') order by local_date), '[]'::jsonb)
    into v_dates
  from agenda_internal.list_available_dates_month_v2(
    p_page_slug, p_service_id, p_service_employee_id, p_contracted_minutes,
    p_extras, p_people_count, p_month
  );
  return jsonb_build_object(
    'engine', 'V2_MONTH',
    'input', jsonb_build_object('booking_page_slug',p_page_slug,'service_id',p_service_id,
      'service_employee_id',p_service_employee_id,'contracted_minutes',p_contracted_minutes,
      'extras',p_extras,'people_count',p_people_count,'month',p_month),
    'dates',v_dates,'date_count',jsonb_array_length(v_dates),
    'elapsed_ms',round(extract(epoch from clock_timestamp()-v_started)*1000,3)
  );
end $$;

select plan(31);

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

insert into public.customers(id,name,email,phone) values
 ('15800000-0000-0000-0000-000000000040','Monthly confirmed customer','monthly-confirmed@example.com','+554899990158');
insert into public.appointments(id,public_code,service_id,service_employee_id,primary_customer_id,status,financial_status,start_at,end_at,core_start_at,core_end_at,duration_minutes,contracted_minutes,people_count,commercial_value,confirmed_at) values
 ('15800000-0000-0000-0000-000000000041','MONTHLY-CONFIRMED','15800000-0000-0000-0000-000000000010','15800000-0000-0000-0000-000000000020','15800000-0000-0000-0000-000000000040','CONFIRMED','PAID','2035-01-22 08:00 America/Sao_Paulo','2035-01-22 13:00 America/Sao_Paulo','2035-01-22 08:15 America/Sao_Paulo','2035-01-22 12:45 America/Sao_Paulo',270,60,1,100,'2035-01-01 00:00 America/Sao_Paulo');
insert into public.resource_allocations(resource_id,appointment_id,allocation_type,status,occupied_range) values
 ('15800000-0000-0000-0000-000000000003','15800000-0000-0000-0000-000000000041','APPOINTMENT','CONFIRMED',tstzrange('2035-01-22 08:00 America/Sao_Paulo','2035-01-22 13:00 America/Sao_Paulo','[)'));
insert into public.checkout_holds(id,public_token_hash,service_id,service_employee_id,selection_hash,people_count,requested_start_at,requested_end_at,core_start_at,core_end_at,pre_service_minutes,duration_blocks,contracted_minutes,duration_minutes,commercial_value,pricing_version,extra_selections,resource_ids,status,expires_at) values
 ('15800000-0000-0000-0000-000000000042',repeat('a',64),'15800000-0000-0000-0000-000000000010','15800000-0000-0000-0000-000000000020','monthly-active-hold',1,'2035-01-29 08:00 America/Sao_Paulo','2035-01-29 13:00 America/Sao_Paulo','2035-01-29 08:15 America/Sao_Paulo','2035-01-29 12:45 America/Sao_Paulo',15,2,60,270,100,'fixture','[]',array['15800000-0000-0000-0000-000000000003'::uuid],'ACTIVE',now()+interval '10 minutes');
insert into public.resource_allocations(resource_id,checkout_hold_id,allocation_type,status,occupied_range) values
 ('15800000-0000-0000-0000-000000000003','15800000-0000-0000-0000-000000000042','CHECKOUT_HOLD','HELD',tstzrange('2035-01-29 08:00 America/Sao_Paulo','2035-01-29 13:00 America/Sao_Paulo','[)'));
insert into public.checkout_holds(id,public_token_hash,service_id,service_employee_id,selection_hash,people_count,requested_start_at,requested_end_at,core_start_at,core_end_at,pre_service_minutes,duration_blocks,contracted_minutes,duration_minutes,commercial_value,pricing_version,extra_selections,resource_ids,status,created_at,expires_at) values
 ('15800000-0000-0000-0000-000000000043',repeat('b',64),'15800000-0000-0000-0000-000000000010','15800000-0000-0000-0000-000000000020','monthly-expired-person-hold',1,'2035-02-05 08:00 America/Sao_Paulo','2035-02-05 13:00 America/Sao_Paulo','2035-02-05 08:15 America/Sao_Paulo','2035-02-05 12:45 America/Sao_Paulo',15,2,60,270,100,'fixture','[]',array['15800000-0000-0000-0000-000000000002'::uuid],'ACTIVE',now()-interval '2 minutes',now()-interval '1 minute');
insert into public.resource_allocations(resource_id,checkout_hold_id,allocation_type,status,occupied_range) values
 ('15800000-0000-0000-0000-000000000002','15800000-0000-0000-0000-000000000043','CHECKOUT_HOLD','HELD',tstzrange('2035-02-05 08:00 America/Sao_Paulo','2035-02-05 13:00 America/Sao_Paulo','[)'));
insert into public.appointments(id,public_code,service_id,service_employee_id,primary_customer_id,status,financial_status,start_at,end_at,core_start_at,core_end_at,duration_minutes,contracted_minutes,people_count,hold_expires_at,commercial_value) values
 ('15800000-0000-0000-0000-000000000044','MONTHLY-EXPIRED-AWAITING','15800000-0000-0000-0000-000000000010','15800000-0000-0000-0000-000000000020','15800000-0000-0000-0000-000000000040','AWAITING_PAYMENT','PENDING','2035-02-12 08:00 America/Sao_Paulo','2035-02-12 13:00 America/Sao_Paulo','2035-02-12 08:15 America/Sao_Paulo','2035-02-12 12:45 America/Sao_Paulo',270,60,1,now()-interval '1 minute',100);
insert into public.resource_allocations(resource_id,appointment_id,allocation_type,status,occupied_range) values
 ('15800000-0000-0000-0000-000000000002','15800000-0000-0000-0000-000000000044','APPOINTMENT','AWAITING_PAYMENT',tstzrange('2035-02-12 08:00 America/Sao_Paulo','2035-02-12 13:00 America/Sao_Paulo','[)'));
insert into public.resource_allocations(resource_id,allocation_type,status,occupied_range,reason,external_source,external_calendar_id,external_event_id) values
 ('15800000-0000-0000-0000-000000000002','EXTERNAL_BLOCK','EXTERNAL_ACTIVE',tstzrange('2035-02-19 08:00 America/Sao_Paulo','2035-02-19 13:00 America/Sao_Paulo','[)'),'monthly-external-person','GOOGLE','monthly-parity-person','monthly-parity-external-person');

-- January exception matrix: Tuesday is otherwise closed; two Mondays are
-- otherwise viable and are removed respectively by employee and resource BLOCK.
insert into public.availability_exceptions(service_employee_id,exception_type,start_at,end_at,reason) values
 ('15800000-0000-0000-0000-000000000020','OPEN','2035-01-02 09:00 America/Sao_Paulo','2035-01-02 12:00 America/Sao_Paulo','monthly-open'),
 ('15800000-0000-0000-0000-000000000020','BLOCK','2035-01-08 00:00 America/Sao_Paulo','2035-01-09 00:00 America/Sao_Paulo','monthly-employee-block');
insert into public.availability_exceptions(resource_id,exception_type,start_at,end_at,reason) values
 ('15800000-0000-0000-0000-000000000002','OPEN','2035-01-02 08:00 America/Sao_Paulo','2035-01-02 13:00 America/Sao_Paulo','monthly-person-open'),
 ('15800000-0000-0000-0000-000000000003','OPEN','2035-01-02 08:00 America/Sao_Paulo','2035-01-02 13:00 America/Sao_Paulo','monthly-studio-open'),
 ('15800000-0000-0000-0000-000000000003','BLOCK','2035-01-15 08:00 America/Sao_Paulo','2035-01-15 13:00 America/Sao_Paulo','monthly-resource-block');

create temp table monthly_legacy(case_key text primary key, result jsonb not null);
insert into monthly_legacy values
 ('feb_28',pg_temp.monthly_availability_capture_legacy('blacksheep','15800000-0000-0000-0000-000000000010','15800000-0000-0000-0000-000000000020',60,'[]',1,'2035-02-01')),
 ('feb_29',pg_temp.monthly_availability_capture_legacy('blacksheep','15800000-0000-0000-0000-000000000010','15800000-0000-0000-0000-000000000020',60,'[]',1,'2036-02-01')),
 ('apr_30',pg_temp.monthly_availability_capture_legacy('blacksheep','15800000-0000-0000-0000-000000000010','15800000-0000-0000-0000-000000000020',60,'[]',1,'2035-04-01')),
 ('dec_31',pg_temp.monthly_availability_capture_legacy('blacksheep','15800000-0000-0000-0000-000000000010','15800000-0000-0000-0000-000000000020',60,'[]',1,'2035-12-01')),
 ('employee_open',pg_temp.monthly_availability_capture_legacy('blacksheep','15800000-0000-0000-0000-000000000010','15800000-0000-0000-0000-000000000020',60,'[]',1,'2035-01-01')),
 ('employee_block',pg_temp.monthly_availability_capture_legacy('blacksheep','15800000-0000-0000-0000-000000000010','15800000-0000-0000-0000-000000000020',60,'[]',1,'2035-01-01')),
 ('resource_block',pg_temp.monthly_availability_capture_legacy('blacksheep','15800000-0000-0000-0000-000000000010','15800000-0000-0000-0000-000000000020',60,'[]',1,'2035-01-01')),
 ('confirmed',pg_temp.monthly_availability_capture_legacy('blacksheep','15800000-0000-0000-0000-000000000010','15800000-0000-0000-0000-000000000020',60,'[]',1,'2035-01-01')),
 ('active_hold',pg_temp.monthly_availability_capture_legacy('blacksheep','15800000-0000-0000-0000-000000000010','15800000-0000-0000-0000-000000000020',60,'[]',1,'2035-01-01')),
 ('expired_person_hold',pg_temp.monthly_availability_capture_legacy('blacksheep','15800000-0000-0000-0000-000000000010','15800000-0000-0000-0000-000000000020',60,'[]',1,'2035-02-01')),
 ('expired_awaiting',pg_temp.monthly_availability_capture_legacy('blacksheep','15800000-0000-0000-0000-000000000010','15800000-0000-0000-0000-000000000020',60,'[]',1,'2035-02-01')),
 ('external_person',pg_temp.monthly_availability_capture_legacy('blacksheep','15800000-0000-0000-0000-000000000010','15800000-0000-0000-0000-000000000020',60,'[]',1,'2035-02-01')),
 ('extras',pg_temp.monthly_availability_capture_legacy('blacksheep','15800000-0000-0000-0000-000000000010','15800000-0000-0000-0000-000000000020',60,'[{"extra_id":"15800000-0000-0000-0000-000000000030","quantity":1},{"extra_id":"15800000-0000-0000-0000-000000000031","quantity":1}]',1,'2035-01-01'));

create temp table monthly_v2(case_key text primary key, result jsonb not null);
insert into monthly_v2 values
 ('feb_28',pg_temp.monthly_availability_capture_v2('blacksheep','15800000-0000-0000-0000-000000000010','15800000-0000-0000-0000-000000000020',60,'[]',1,'2035-02-01')),
 ('feb_29',pg_temp.monthly_availability_capture_v2('blacksheep','15800000-0000-0000-0000-000000000010','15800000-0000-0000-0000-000000000020',60,'[]',1,'2036-02-01')),
 ('apr_30',pg_temp.monthly_availability_capture_v2('blacksheep','15800000-0000-0000-0000-000000000010','15800000-0000-0000-0000-000000000020',60,'[]',1,'2035-04-01')),
 ('dec_31',pg_temp.monthly_availability_capture_v2('blacksheep','15800000-0000-0000-0000-000000000010','15800000-0000-0000-0000-000000000020',60,'[]',1,'2035-12-01')),
 ('employee_open',pg_temp.monthly_availability_capture_v2('blacksheep','15800000-0000-0000-0000-000000000010','15800000-0000-0000-0000-000000000020',60,'[]',1,'2035-01-01')),
 ('employee_block',pg_temp.monthly_availability_capture_v2('blacksheep','15800000-0000-0000-0000-000000000010','15800000-0000-0000-0000-000000000020',60,'[]',1,'2035-01-01')),
 ('resource_block',pg_temp.monthly_availability_capture_v2('blacksheep','15800000-0000-0000-0000-000000000010','15800000-0000-0000-0000-000000000020',60,'[]',1,'2035-01-01')),
 ('confirmed',pg_temp.monthly_availability_capture_v2('blacksheep','15800000-0000-0000-0000-000000000010','15800000-0000-0000-0000-000000000020',60,'[]',1,'2035-01-01')),
 ('active_hold',pg_temp.monthly_availability_capture_v2('blacksheep','15800000-0000-0000-0000-000000000010','15800000-0000-0000-0000-000000000020',60,'[]',1,'2035-01-01')),
 ('expired_person_hold',pg_temp.monthly_availability_capture_v2('blacksheep','15800000-0000-0000-0000-000000000010','15800000-0000-0000-0000-000000000020',60,'[]',1,'2035-02-01')),
 ('expired_awaiting',pg_temp.monthly_availability_capture_v2('blacksheep','15800000-0000-0000-0000-000000000010','15800000-0000-0000-0000-000000000020',60,'[]',1,'2035-02-01')),
 ('external_person',pg_temp.monthly_availability_capture_v2('blacksheep','15800000-0000-0000-0000-000000000010','15800000-0000-0000-0000-000000000020',60,'[]',1,'2035-02-01')),
 ('extras',pg_temp.monthly_availability_capture_v2('blacksheep','15800000-0000-0000-0000-000000000010','15800000-0000-0000-0000-000000000020',60,'[{"extra_id":"15800000-0000-0000-0000-000000000030","quantity":1},{"extra_id":"15800000-0000-0000-0000-000000000031","quantity":1}]',1,'2035-01-01'));

select ok((select result ?& array['input','dates','date_count','elapsed_ms'] from monthly_legacy where case_key='feb_28'),'legacy monthly capture serializes canonical payload');
select is((select result->'dates' from monthly_legacy where case_key='feb_28'),(pg_temp.monthly_availability_capture_legacy('blacksheep','15800000-0000-0000-0000-000000000010','15800000-0000-0000-0000-000000000020',60,'[]',1,'2035-02-01')->'dates'),'monthly dates are deterministic and ordered');
select is((select result->'dates' from monthly_legacy where case_key='feb_28'),(select result->'dates' from monthly_v2 where case_key='feb_28'),'V1/V2 parity: 28-day February date set');
select is((select result - 'elapsed_ms' from monthly_legacy where case_key='feb_29'),(pg_temp.monthly_availability_capture_legacy('blacksheep','15800000-0000-0000-0000-000000000010','15800000-0000-0000-0000-000000000020',60,'[]',1,'2036-02-01')-'elapsed_ms'),'leap February excludes volatile timing');
select is((select result->'dates' from monthly_legacy where case_key='feb_29'),(select result->'dates' from monthly_v2 where case_key='feb_29'),'V1/V2 parity: leap February date set');
select ok((select (result->>'date_count')::integer >= 0 from monthly_legacy where case_key='apr_30'),'30-day month is captured');
select is((select result->'dates' from monthly_legacy where case_key='apr_30'),(select result->'dates' from monthly_v2 where case_key='apr_30'),'V1/V2 parity: 30-day month date set');
select ok((select (result->>'date_count')::integer >= 0 from monthly_legacy where case_key='dec_31'),'31-day and year-boundary month is captured');
select is((select result->'dates' from monthly_legacy where case_key='dec_31'),(select result->'dates' from monthly_v2 where case_key='dec_31'),'V1/V2 parity: 31-day year-boundary date set');
select ok((select result->'input'->'extras' <> '[]'::jsonb from monthly_legacy where case_key='extras'),'PREPEND APPEND merged-resource selection is serialized');
select is((select result->'dates' from monthly_legacy where case_key='extras'),(select result->'dates' from monthly_v2 where case_key='extras'),'V1/V2 parity: PREPEND APPEND merged-resource date set');
select ok((select result->'dates' ? '2035-01-02' from monthly_legacy where case_key='employee_open'),'employee OPEN plus resource OPEN creates otherwise closed Tuesday in V1');
select is((select result->'dates' from monthly_legacy where case_key='employee_open'),(select result->'dates' from monthly_v2 where case_key='employee_open'),'V1/V2 parity: employee and resource OPEN');
select ok(not (select result->'dates' ? '2035-01-08' from monthly_legacy where case_key='employee_block'),'employee BLOCK removes otherwise weekly Monday in V1');
select is((select result->'dates' from monthly_legacy where case_key='employee_block'),(select result->'dates' from monthly_v2 where case_key='employee_block'),'V1/V2 parity: employee BLOCK');
select ok(not (select result->'dates' ? '2035-01-15' from monthly_legacy where case_key='resource_block'),'resource BLOCK removes occupied-range Monday in V1');
select is((select result->'dates' from monthly_legacy where case_key='resource_block'),(select result->'dates' from monthly_v2 where case_key='resource_block'),'V1/V2 parity: resource BLOCK');
select ok(not (select result->'dates' ? '2035-01-22' from monthly_legacy where case_key='confirmed'),'confirmed appointment allocation removes the occupied Monday in V1');
select is((select result->'dates' from monthly_legacy where case_key='confirmed'),(select result->'dates' from monthly_v2 where case_key='confirmed'),'V1/V2 parity: confirmed appointment allocation');
select ok(not (select result->'dates' ? '2035-01-29' from monthly_legacy where case_key='active_hold'),'active checkout hold removes the occupied Monday in V1');
select is((select result->'dates' from monthly_legacy where case_key='active_hold'),(select result->'dates' from monthly_v2 where case_key='active_hold'),'V1/V2 parity: active checkout hold');
select ok((select result->'dates' ? '2035-02-05' from monthly_legacy where case_key='expired_person_hold'),'expired checkout hold on PERSON resource does not block V1');
select is((select result->'dates' from monthly_legacy where case_key='expired_person_hold'),(select result->'dates' from monthly_v2 where case_key='expired_person_hold'),'V1/V2 parity: expired checkout hold on PERSON resource');
select ok((select result->'dates' ? '2035-02-12' from monthly_legacy where case_key='expired_awaiting'),'expired AWAITING_PAYMENT person allocation does not block V1');
select is((select result->'dates' from monthly_legacy where case_key='expired_awaiting'),(select result->'dates' from monthly_v2 where case_key='expired_awaiting'),'V1/V2 parity: expired AWAITING_PAYMENT person allocation');
select ok(not (select result->'dates' ? '2035-02-19' from monthly_legacy where case_key='external_person'),'EXTERNAL_ACTIVE PERSON allocation removes the occupied Monday in V1');
select is((select result->'dates' from monthly_legacy where case_key='external_person'),(select result->'dates' from monthly_v2 where case_key='external_person'),'V1/V2 parity: EXTERNAL_ACTIVE PERSON allocation');
select ok((select (result->>'elapsed_ms')::numeric >= 0 from monthly_legacy where case_key='feb_28'),'monthly elapsed time is recorded outside comparison');
select ok(to_regprocedure('agenda_internal.list_available_dates_month_v2(text,uuid,uuid,integer,jsonb,integer,date)') is not null,'private V2 month engine exists');
select ok(not has_function_privilege('anon','agenda_internal.list_available_dates_month_v2(text,uuid,uuid,integer,jsonb,integer,date)','EXECUTE') and not has_function_privilege('authenticated','agenda_internal.list_available_dates_month_v2(text,uuid,uuid,integer,jsonb,integer,date)','EXECUTE'),'V2 engine is not callable by app roles');
select ok(position('list_available_slots_for_duration' in pg_get_functiondef('agenda_public_bridge.list_available_dates_month_impl(text,uuid,uuid,integer,jsonb,integer,date)'::regprocedure)) > 0 and position('list_available_dates_month_v2' in pg_get_functiondef('agenda_public_bridge.list_available_dates_month_impl(text,uuid,uuid,integer,jsonb,integer,date)'::regprocedure)) = 0,'public monthly bridge remains on V1 before V2 exists');

select * from finish();
rollback;
