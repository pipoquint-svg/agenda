begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

-- Test-only canonicalizer.  V2 tests will call this unchanged and compare its
-- JSON result with availability_parity_capture_slots('V2', ...).
create function pg_temp.availability_parity_capture_slots(
  p_engine text, p_service_id uuid, p_service_employee_id uuid,
  p_duration_blocks integer, p_contracted_minutes integer,
  p_extras jsonb, p_people_count integer, p_local_date date
) returns jsonb language plpgsql as $$
declare v_started timestamptz := clock_timestamp(); v_slots jsonb;
begin
  if p_engine = 'LEGACY_FIXED' then
    select coalesce(jsonb_agg(jsonb_build_object(
      'slot_start_at', to_char(slot_start_at at time zone 'America/Sao_Paulo','YYYY-MM-DD"T"HH24:MI:SS'),
      'slot_end_at', to_char(slot_end_at at time zone 'America/Sao_Paulo','YYYY-MM-DD"T"HH24:MI:SS'),
      'core_start_at', to_char(core_start_at at time zone 'America/Sao_Paulo','YYYY-MM-DD"T"HH24:MI:SS'),
      'core_end_at', to_char(core_end_at at time zone 'America/Sao_Paulo','YYYY-MM-DD"T"HH24:MI:SS'),
      'duration_minutes', duration_minutes, 'pre_service_minutes', pre_service_minutes,
      'post_service_minutes', post_service_minutes, 'commercial_value', commercial_value
    ) order by slot_start_at), '[]'::jsonb) into v_slots
    from public.list_available_slots(p_service_id,p_service_employee_id,p_extras,p_people_count,p_local_date,null);
  elsif p_engine in ('LEGACY_BLOCKS','LEGACY_MINUTES') then
    select coalesce(jsonb_agg(jsonb_build_object(
      'slot_start_at', to_char(slot_start_at at time zone 'America/Sao_Paulo','YYYY-MM-DD"T"HH24:MI:SS'),
      'slot_end_at', to_char(slot_end_at at time zone 'America/Sao_Paulo','YYYY-MM-DD"T"HH24:MI:SS'),
      'core_start_at', to_char(core_start_at at time zone 'America/Sao_Paulo','YYYY-MM-DD"T"HH24:MI:SS'),
      'core_end_at', to_char(core_end_at at time zone 'America/Sao_Paulo','YYYY-MM-DD"T"HH24:MI:SS'),
      'duration_minutes', duration_minutes, 'pre_service_minutes', pre_service_minutes,
      'post_service_minutes', post_service_minutes, 'commercial_value', commercial_value
    ) order by slot_start_at), '[]'::jsonb) into v_slots
    from public.list_available_slots_for_duration(p_service_id,p_service_employee_id,
      case when p_engine='LEGACY_MINUTES' then public.resolve_service_duration_blocks_from_minutes(p_service_id,p_contracted_minutes) else p_duration_blocks end,
      p_extras,p_people_count,p_local_date,null);
  else raise exception 'PARITY_ENGINE_UNKNOWN'; end if;
  return jsonb_build_object('engine',p_engine,'input',jsonb_build_object('service_id',p_service_id,'service_employee_id',p_service_employee_id,'duration_blocks',p_duration_blocks,'contracted_minutes',p_contracted_minutes,'extras',p_extras,'people_count',p_people_count,'local_date',p_local_date),'slots',v_slots,'slot_count',jsonb_array_length(v_slots),'elapsed_ms',round(extract(epoch from clock_timestamp()-v_started)*1000,3));
end $$;

select plan(7);

insert into public.categories(id,name,slug) values ('15700000-0000-0000-0000-000000000001','Parity','parity-harness');
insert into public.resources(id,name,resource_type) values
 ('15700000-0000-0000-0000-000000000002','PARITY PERSON','PERSON'),
 ('15700000-0000-0000-0000-000000000003','PARITY STUDIO','PHYSICAL');
insert into public.employees(id,name,resource_id) values ('15700000-0000-0000-0000-000000000004','Parity Employee','15700000-0000-0000-0000-000000000002');
insert into public.services(id,category_id,name,slug,base_duration_minutes,base_price,buffer_before_minutes,buffer_after_minutes,minimum_people,maximum_people,maximum_booking_horizon_days,duration_mode,booking_block_minutes,minimum_booking_blocks,maximum_booking_blocks,price_per_block) values
 ('15700000-0000-0000-0000-000000000010','15700000-0000-0000-0000-000000000001','Parity Fixed','parity-fixed',60,100,15,15,1,4,5000,'FIXED',null,null,null,null),
 ('15700000-0000-0000-0000-000000000011','15700000-0000-0000-0000-000000000001','Parity Blocks','parity-blocks',60,100,15,15,1,4,5000,'BLOCKS',30,2,4,50);
insert into public.service_employees(id,service_id,employee_id) values
 ('15700000-0000-0000-0000-000000000020','15700000-0000-0000-0000-000000000010','15700000-0000-0000-0000-000000000004'),
 ('15700000-0000-0000-0000-000000000021','15700000-0000-0000-0000-000000000011','15700000-0000-0000-0000-000000000004');
insert into public.service_resources(service_id,resource_id) values
 ('15700000-0000-0000-0000-000000000010','15700000-0000-0000-0000-000000000003'),
 ('15700000-0000-0000-0000-000000000011','15700000-0000-0000-0000-000000000003');
insert into public.availability_rules(service_employee_id,weekday,start_local_time,end_local_time) values
 ('15700000-0000-0000-0000-000000000020',1,'09:00','12:00'),('15700000-0000-0000-0000-000000000021',1,'09:00','12:00');
insert into public.resource_availability_rules(resource_id,weekday,start_local_time,end_local_time) values
 ('15700000-0000-0000-0000-000000000002',1,'08:00','13:00'),('15700000-0000-0000-0000-000000000003',1,'08:00','13:00');

create temp table parity_golden(case_key text primary key, result jsonb not null);
insert into parity_golden values
 ('fixed',pg_temp.availability_parity_capture_slots('LEGACY_FIXED','15700000-0000-0000-0000-000000000010','15700000-0000-0000-0000-000000000020',null,null,'[]',1,'2035-01-15')),
 ('blocks',pg_temp.availability_parity_capture_slots('LEGACY_BLOCKS','15700000-0000-0000-0000-000000000011','15700000-0000-0000-0000-000000000021',2,null,'[]',1,'2035-01-15')),
 ('minutes',pg_temp.availability_parity_capture_slots('LEGACY_MINUTES','15700000-0000-0000-0000-000000000011','15700000-0000-0000-0000-000000000021',null,60,'[]',1,'2035-01-15'));

select is((select result->>'slot_count' from parity_golden where case_key='fixed'),'4','FIXED golden captures buffered legacy slots');
select is((select result->>'slot_count' from parity_golden where case_key='blocks'),'3','BLOCKS golden captures legacy slots');
select is((select result->'slots' from parity_golden where case_key='blocks'),(select result->'slots' from parity_golden where case_key='minutes'),'MINUTES normalizes to identical BLOCKS availability');
select is((select result - 'elapsed_ms' from parity_golden where case_key='fixed'),(pg_temp.availability_parity_capture_slots('LEGACY_FIXED','15700000-0000-0000-0000-000000000010','15700000-0000-0000-0000-000000000020',null,null,'[]',1,'2035-01-15') - 'elapsed_ms'),'normalization is deterministic and excludes volatile timing');
select ok((select (result->>'elapsed_ms')::numeric >= 0 from parity_golden where case_key='fixed'),'benchmark capture records elapsed query time');
select ok((select result ? 'input' and result ? 'slots' and result ? 'slot_count' from parity_golden where case_key='minutes'),'capture serializes input, slots and count for future V2 comparison');
select throws_ok($$select pg_temp.availability_parity_capture_slots('UNKNOWN',null,null,null,null,'[]',1,'2035-01-15')$$,'P0001','PARITY_ENGINE_UNKNOWN','unknown engine cannot silently produce a false comparison');

select * from finish();
rollback;
