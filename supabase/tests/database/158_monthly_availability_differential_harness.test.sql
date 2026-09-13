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

select plan(51);

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

-- Bound fixtures use the engine's deterministic test clock where the legacy
-- duration path does, then restore it before exercising public notice, which
-- deliberately remains relative to PostgreSQL now().
select set_config('agenda.test_now', '2035-01-01 08:00 America/Sao_Paulo', true);
update public.services
set minimum_booking_notice_minutes = 181,
    maximum_booking_horizon_days = 5000,
    public_minimum_booking_notice_hours = 0
where id = '15800000-0000-0000-0000-000000000010';
insert into monthly_legacy values
 ('minimum_notice',pg_temp.monthly_availability_capture_legacy('blacksheep','15800000-0000-0000-0000-000000000010','15800000-0000-0000-0000-000000000020',60,'[]',1,'2035-01-01'));
insert into monthly_v2 values
 ('minimum_notice',pg_temp.monthly_availability_capture_v2('blacksheep','15800000-0000-0000-0000-000000000010','15800000-0000-0000-0000-000000000020',60,'[]',1,'2035-01-01'));

update public.services
set minimum_booking_notice_minutes = 0,
    maximum_booking_horizon_days = 1
where id = '15800000-0000-0000-0000-000000000010';
insert into monthly_legacy values
 ('maximum_horizon',pg_temp.monthly_availability_capture_legacy('blacksheep','15800000-0000-0000-0000-000000000010','15800000-0000-0000-0000-000000000020',60,'[]',1,'2035-01-01'));
insert into monthly_v2 values
 ('maximum_horizon',pg_temp.monthly_availability_capture_v2('blacksheep','15800000-0000-0000-0000-000000000010','15800000-0000-0000-0000-000000000020',60,'[]',1,'2035-01-01'));

select set_config('agenda.test_now', '', true);
update public.services
set maximum_booking_horizon_days = 5000,
    public_minimum_booking_notice_hours = 4
where id = '15800000-0000-0000-0000-000000000010';
delete from public.availability_rules
where service_employee_id = '15800000-0000-0000-0000-000000000020';
delete from public.resource_availability_rules
where resource_id in ('15800000-0000-0000-0000-000000000002','15800000-0000-0000-0000-000000000003');
create temp table public_notice_clock as
select date_trunc('hour', now()) + interval '1 hour' as pre_start_at,
       date_trunc('hour', now()) + interval '6 hours' as post_start_at;
insert into public.availability_exceptions(service_employee_id,exception_type,start_at,end_at,reason)
select '15800000-0000-0000-0000-000000000020'::uuid, 'OPEN', c.pre_start_at, c.pre_start_at + interval '1 hour', 'monthly-public-notice-pre'
from public_notice_clock c
union all
select '15800000-0000-0000-0000-000000000020'::uuid, 'OPEN', c.post_start_at, c.post_start_at + interval '1 hour', 'monthly-public-notice-post'
from public_notice_clock c;
insert into public.availability_exceptions(resource_id,exception_type,start_at,end_at,reason)
select r.resource_id, 'OPEN', c.pre_start_at - interval '15 minutes', c.pre_start_at + interval '75 minutes', 'monthly-public-notice-pre'
from public_notice_clock c cross join (values ('15800000-0000-0000-0000-000000000002'::uuid),('15800000-0000-0000-0000-000000000003'::uuid)) r(resource_id)
union all
select r.resource_id, 'OPEN', c.post_start_at - interval '15 minutes', c.post_start_at + interval '75 minutes', 'monthly-public-notice-post'
from public_notice_clock c cross join (values ('15800000-0000-0000-0000-000000000002'::uuid),('15800000-0000-0000-0000-000000000003'::uuid)) r(resource_id);
insert into monthly_legacy
select 'public_notice_pre', pg_temp.monthly_availability_capture_legacy('blacksheep','15800000-0000-0000-0000-000000000010','15800000-0000-0000-0000-000000000020',60,'[]',1,(c.pre_start_at at time zone 'America/Sao_Paulo')::date)
from public_notice_clock c
union all
select 'public_notice_post', pg_temp.monthly_availability_capture_legacy('blacksheep','15800000-0000-0000-0000-000000000010','15800000-0000-0000-0000-000000000020',60,'[]',1,(c.post_start_at at time zone 'America/Sao_Paulo')::date)
from public_notice_clock c;
insert into monthly_v2
select 'public_notice_pre', pg_temp.monthly_availability_capture_v2('blacksheep','15800000-0000-0000-0000-000000000010','15800000-0000-0000-0000-000000000020',60,'[]',1,(c.pre_start_at at time zone 'America/Sao_Paulo')::date)
from public_notice_clock c
union all
select 'public_notice_post', pg_temp.monthly_availability_capture_v2('blacksheep','15800000-0000-0000-0000-000000000010','15800000-0000-0000-0000-000000000020',60,'[]',1,(c.post_start_at at time zone 'America/Sao_Paulo')::date)
from public_notice_clock c;

-- Restore the baseline before the original deterministic replays below.
update public.services
set minimum_booking_notice_minutes = 0,
    maximum_booking_horizon_days = 5000,
    public_minimum_booking_notice_hours = 0
where id = '15800000-0000-0000-0000-000000000010';
delete from public.availability_exceptions
where reason in ('monthly-public-notice-pre','monthly-public-notice-post');
insert into public.availability_rules(service_employee_id,weekday,start_local_time,end_local_time)
values ('15800000-0000-0000-0000-000000000020',1,'09:00','12:00');
insert into public.resource_availability_rules(resource_id,weekday,start_local_time,end_local_time)
values
 ('15800000-0000-0000-0000-000000000002',1,'08:00','13:00'),
 ('15800000-0000-0000-0000-000000000003',1,'08:00','13:00');

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
select ok(not (select result->'dates' ? '2035-01-01' from monthly_legacy where case_key='minimum_notice') and (select result->'dates' ? '2035-01-02' from monthly_legacy where case_key='minimum_notice'),'minimum_booking_notice_minutes excludes only candidates before the deterministic cutoff in V1');
select is((select result->'dates' from monthly_legacy where case_key='minimum_notice'),(select result->'dates' from monthly_v2 where case_key='minimum_notice'),'V1/V2 parity: minimum_booking_notice_minutes');
select ok((select result->'dates' ? '2035-01-01' from monthly_legacy where case_key='maximum_horizon') and not (select result->'dates' ? '2035-01-02' from monthly_legacy where case_key='maximum_horizon'),'maximum_booking_horizon_days preserves an in-horizon date and excludes an out-of-horizon date in V1');
select is((select result->'dates' from monthly_legacy where case_key='maximum_horizon'),(select result->'dates' from monthly_v2 where case_key='maximum_horizon'),'V1/V2 parity: maximum_booking_horizon_days');
select ok(not (select result->'dates' ? to_char(c.pre_start_at at time zone 'America/Sao_Paulo','YYYY-MM-DD') from monthly_legacy l cross join public_notice_clock c where l.case_key='public_notice_pre'),'public_minimum_booking_notice_hours excludes the pre-cutoff date in V1');
select is((select result->'dates' from monthly_legacy where case_key='public_notice_pre'),(select result->'dates' from monthly_v2 where case_key='public_notice_pre'),'V1/V2 parity: public notice pre-cutoff date');
select ok((select result->'dates' ? to_char(c.post_start_at at time zone 'America/Sao_Paulo','YYYY-MM-DD') from monthly_legacy l cross join public_notice_clock c where l.case_key='public_notice_post'),'public_minimum_booking_notice_hours retains the post-cutoff date in V1');
select is((select result->'dates' from monthly_legacy where case_key='public_notice_post'),(select result->'dates' from monthly_v2 where case_key='public_notice_post'),'V1/V2 parity: public notice post-cutoff date');
select ok((select (result->>'elapsed_ms')::numeric >= 0 from monthly_legacy where case_key='feb_28'),'monthly elapsed time is recorded outside comparison');
select ok(to_regprocedure('agenda_internal.list_available_dates_month_v2(text,uuid,uuid,integer,jsonb,integer,date)') is not null,'private V2 month engine exists');
select ok(not has_function_privilege('anon','agenda_internal.list_available_dates_month_v2(text,uuid,uuid,integer,jsonb,integer,date)','EXECUTE') and not has_function_privilege('authenticated','agenda_internal.list_available_dates_month_v2(text,uuid,uuid,integer,jsonb,integer,date)','EXECUTE'),'V2 engine is not callable by app roles');
select ok(position('list_available_slots_for_duration' in pg_get_functiondef('agenda_public_bridge.list_available_dates_month_impl(text,uuid,uuid,integer,jsonb,integer,date)'::regprocedure)) > 0 and position('list_available_dates_month_v2' in pg_get_functiondef('agenda_public_bridge.list_available_dates_month_impl(text,uuid,uuid,integer,jsonb,integer,date)'::regprocedure)) = 0,'public monthly bridge remains on V1 before V2 exists');

-- Google fixtures deliberately run after the baseline assertions above so their
-- mappings cannot change the original deterministic captures.
insert into public.google_connections(id,account_email,refresh_token_ciphertext,token_encryption_version,scopes,status) values
 ('15800000-0000-0000-0000-000000000050','monthly-person@example.invalid','fixture',1,array['calendar.events'],'ACTIVE'),
 ('15800000-0000-0000-0000-000000000051','monthly-studio@example.invalid','fixture',1,array['calendar.events'],'ACTIVE');
insert into public.google_calendars(id,google_connection_id,google_calendar_id,name,timezone,is_active) values
 ('15800000-0000-0000-0000-000000000052','15800000-0000-0000-0000-000000000050','monthly-person-calendar','Monthly person','America/Sao_Paulo',true),
 ('15800000-0000-0000-0000-000000000053','15800000-0000-0000-0000-000000000051','monthly-studio-calendar','Monthly studio','America/Sao_Paulo',true);
insert into public.google_calendar_resources(google_calendar_id,resource_id) values
 ('15800000-0000-0000-0000-000000000052','15800000-0000-0000-0000-000000000002'),
 ('15800000-0000-0000-0000-000000000053','15800000-0000-0000-0000-000000000003');
insert into public.google_sync_state(google_calendar_id,sync_token,health_status,last_attempt_at,last_success_at,consecutive_failures) values
 ('15800000-0000-0000-0000-000000000052','monthly-person-sync','HEALTHY',now(),now(),0),
 ('15800000-0000-0000-0000-000000000053','monthly-studio-sync','HEALTHY',now(),now(),0);
insert into monthly_legacy values
 ('google_healthy',pg_temp.monthly_availability_capture_legacy('blacksheep','15800000-0000-0000-0000-000000000010','15800000-0000-0000-0000-000000000020',60,'[]',1,'2035-03-01'));
insert into monthly_v2 values
 ('google_healthy',pg_temp.monthly_availability_capture_v2('blacksheep','15800000-0000-0000-0000-000000000010','15800000-0000-0000-0000-000000000020',60,'[]',1,'2035-03-01'));
update public.google_sync_state set last_success_at = now() - interval '11 minutes' where google_calendar_id = '15800000-0000-0000-0000-000000000053';
insert into monthly_legacy values
 ('google_material_stale',pg_temp.monthly_availability_capture_legacy('blacksheep','15800000-0000-0000-0000-000000000010','15800000-0000-0000-0000-000000000020',60,'[]',1,'2035-03-01'));
insert into monthly_v2 values
 ('google_material_stale',pg_temp.monthly_availability_capture_v2('blacksheep','15800000-0000-0000-0000-000000000010','15800000-0000-0000-0000-000000000020',60,'[]',1,'2035-03-01'));
update public.google_sync_state set last_success_at = now() where google_calendar_id = '15800000-0000-0000-0000-000000000053';
update public.google_sync_state set last_success_at = now() - interval '11 minutes' where google_calendar_id = '15800000-0000-0000-0000-000000000052';
insert into monthly_legacy values
 ('google_person_stale',pg_temp.monthly_availability_capture_legacy('blacksheep','15800000-0000-0000-0000-000000000010','15800000-0000-0000-0000-000000000020',60,'[]',1,'2035-03-01'));
insert into monthly_v2 values
 ('google_person_stale',pg_temp.monthly_availability_capture_v2('blacksheep','15800000-0000-0000-0000-000000000010','15800000-0000-0000-0000-000000000020',60,'[]',1,'2035-03-01'));
update public.google_sync_state set last_success_at = now() where google_calendar_id = '15800000-0000-0000-0000-000000000052';
insert into public.google_calendar_events(id,google_calendar_id,google_event_id,status,start_at,end_at,qualification,normalized_payload) values
 ('15800000-0000-0000-0000-000000000054','15800000-0000-0000-0000-000000000053','monthly-material-conflict','confirmed','2035-03-05 08:00 America/Sao_Paulo','2035-03-05 13:00 America/Sao_Paulo','BLOCKING','{}'),
 ('15800000-0000-0000-0000-000000000055','15800000-0000-0000-0000-000000000052','monthly-person-conflict','confirmed','2035-03-12 08:00 America/Sao_Paulo','2035-03-12 13:00 America/Sao_Paulo','BLOCKING','{}');
insert into public.schedule_divergences(id,resource_id,google_calendar_event_id,desired_range,reason) values
 ('15800000-0000-0000-0000-000000000056','15800000-0000-0000-0000-000000000003','15800000-0000-0000-0000-000000000054',tstzrange('2035-03-05 08:00 America/Sao_Paulo','2035-03-05 13:00 America/Sao_Paulo','[)'),'GOOGLE_EVENT_CONFLICT');
insert into monthly_legacy values
 ('google_material_divergence',pg_temp.monthly_availability_capture_legacy('blacksheep','15800000-0000-0000-0000-000000000010','15800000-0000-0000-0000-000000000020',60,'[]',1,'2035-03-01'));
insert into monthly_v2 values
 ('google_material_divergence',pg_temp.monthly_availability_capture_v2('blacksheep','15800000-0000-0000-0000-000000000010','15800000-0000-0000-0000-000000000020',60,'[]',1,'2035-03-01'));
update public.schedule_divergences set status = 'RESOLVED', resolved_at = now(), resolution_notes = 'fixture transition' where id = '15800000-0000-0000-0000-000000000056';
insert into public.schedule_divergences(id,resource_id,google_calendar_event_id,desired_range,reason) values
 ('15800000-0000-0000-0000-000000000057','15800000-0000-0000-0000-000000000002','15800000-0000-0000-0000-000000000055',tstzrange('2035-03-12 08:00 America/Sao_Paulo','2035-03-12 13:00 America/Sao_Paulo','[)'),'GOOGLE_EVENT_CONFLICT');
insert into monthly_legacy values
 ('google_person_divergence',pg_temp.monthly_availability_capture_legacy('blacksheep','15800000-0000-0000-0000-000000000010','15800000-0000-0000-0000-000000000020',60,'[]',1,'2035-03-01'));
insert into monthly_v2 values
 ('google_person_divergence',pg_temp.monthly_availability_capture_v2('blacksheep','15800000-0000-0000-0000-000000000010','15800000-0000-0000-0000-000000000020',60,'[]',1,'2035-03-01'));
select ok((select result->'dates' ? '2035-03-19' from monthly_legacy where case_key='google_healthy'),'healthy Google resources retain an unrelated available Monday in V1');
select is((select result->'dates' from monthly_legacy where case_key='google_healthy'),(select result->'dates' from monthly_v2 where case_key='google_healthy'),'V1/V2 parity: Google healthy');
select ok((select result->'dates' = '[]'::jsonb from monthly_legacy where case_key='google_material_stale'),'stale material Google resource fails closed in V1');
select is((select result->'dates' from monthly_legacy where case_key='google_material_stale'),(select result->'dates' from monthly_v2 where case_key='google_material_stale'),'V1/V2 parity: stale material Google resource');
select ok((select result->'dates' = '[]'::jsonb from monthly_legacy where case_key='google_person_stale'),'stale PERSON Google resource fails closed in V1');
select is((select result->'dates' from monthly_legacy where case_key='google_person_stale'),(select result->'dates' from monthly_v2 where case_key='google_person_stale'),'V1/V2 parity: stale PERSON Google resource');
select ok(not (select result->'dates' ? '2035-03-05' from monthly_legacy where case_key='google_material_divergence'),'material GOOGLE_EVENT_CONFLICT removes its Monday in V1');
select is((select result->'dates' from monthly_legacy where case_key='google_material_divergence'),(select result->'dates' from monthly_v2 where case_key='google_material_divergence'),'V1/V2 parity: material GOOGLE_EVENT_CONFLICT');
select ok(not (select result->'dates' ? '2035-03-12' from monthly_legacy where case_key='google_person_divergence'),'PERSON GOOGLE_EVENT_CONFLICT removes its Monday in V1');
select is((select result->'dates' from monthly_legacy where case_key='google_person_divergence'),(select result->'dates' from monthly_v2 where case_key='google_person_divergence'),'V1/V2 parity: PERSON GOOGLE_EVENT_CONFLICT');

select * from finish();
rollback;
