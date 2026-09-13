\set ON_ERROR_STOP on
begin;
\i scripts/benchmarks/month-availability-v2-fixture.sql
create temp table benchmark_samples(scenario text, engine text, iteration int, elapsed_ms numeric);
create or replace function pg_temp.month_dates(p_engine text, p_extras jsonb default '[]'::jsonb) returns jsonb language plpgsql as $$
declare v jsonb;
begin
 if p_engine='V1' then
  select coalesce(jsonb_agg(to_char(local_date,'YYYY-MM-DD') order by local_date),'[]'::jsonb) into v from public.public_list_available_dates_month('blacksheep','15900000-0000-0000-0000-000000000010','15900000-0000-0000-0000-000000000020',60,p_extras,1,date '2035-01-01');
 else
  select coalesce(jsonb_agg(to_char(local_date,'YYYY-MM-DD') order by local_date),'[]'::jsonb) into v from agenda_internal.list_available_dates_month_v2('blacksheep','15900000-0000-0000-0000-000000000010','15900000-0000-0000-0000-000000000020',60,p_extras,1,date '2035-01-01');
 end if; return v;
end $$;
do $$ declare s text; e text; i int; a jsonb; b jsonb; t timestamptz; x jsonb; extras jsonb;
begin
 foreach s in array array['frequent','low','zero','resource_heavy','extras','occupancy'] loop
  extras := case when s='extras' then '[{"extra_id":"15900000-0000-0000-0000-000000000030","quantity":1},{"extra_id":"15900000-0000-0000-0000-000000000031","quantity":1}]'::jsonb else '[]'::jsonb end;
  if s='low' then delete from public.availability_rules where service_employee_id='15900000-0000-0000-0000-000000000020' and weekday<>1; end if;
  if s='zero' then delete from public.availability_rules where service_employee_id='15900000-0000-0000-0000-000000000020'; end if;
  if s='occupancy' then
    insert into public.customers(id,name,email,phone) values ('15900000-0000-0000-0000-000000000040','Benchmark occupancy','benchmark-occupancy@example.invalid','+55489999159');
    insert into public.appointments(id,public_code,service_id,service_employee_id,primary_customer_id,status,financial_status,start_at,end_at,core_start_at,core_end_at,duration_minutes,contracted_minutes,people_count,commercial_value,confirmed_at)
    values ('15900000-0000-0000-0000-000000000041','BENCHMARK-OCCUPANCY','15900000-0000-0000-0000-000000000010','15900000-0000-0000-0000-000000000020','15900000-0000-0000-0000-000000000040','CONFIRMED','PAID','2035-01-01 07:00 America/Sao_Paulo','2035-02-01 19:00 America/Sao_Paulo','2035-01-01 08:00 America/Sao_Paulo','2035-02-01 18:00 America/Sao_Paulo',44640,60,1,100,'2035-01-01 00:00 America/Sao_Paulo');
    insert into public.resource_allocations(resource_id,appointment_id,allocation_type,status,occupied_range) values ('15900000-0000-0000-0000-000000000003','15900000-0000-0000-0000-000000000041','APPOINTMENT','CONFIRMED',tstzrange('2035-01-01 07:00 America/Sao_Paulo','2035-02-01 19:00 America/Sao_Paulo','[)'));
  end if;
  a:=pg_temp.month_dates('V1',extras); b:=pg_temp.month_dates('V2',extras); if a<>b then raise exception 'PARITY:% V1=% V2=%',s,a,b; end if;
  for i in 1..2 loop perform pg_temp.month_dates('V1',extras); perform pg_temp.month_dates('V2',extras); end loop;
  for i in 1..7 loop foreach e in array case when i%2=1 then array['V1','V2'] else array['V2','V1'] end loop t:=clock_timestamp(); x:=pg_temp.month_dates(e,extras); insert into benchmark_samples values(s,e,i,extract(epoch from clock_timestamp()-t)*1000); end loop; end loop;
  if s='low' then insert into public.availability_rules(service_employee_id,weekday,start_local_time,end_local_time) select '15900000-0000-0000-0000-000000000020',d,'08:00','18:00' from generate_series(0,6)d where d<>1; end if;
  if s='zero' then insert into public.availability_rules(service_employee_id,weekday,start_local_time,end_local_time) select '15900000-0000-0000-0000-000000000020',d,'08:00','18:00' from generate_series(0,6)d; end if;
  if s='occupancy' then
    delete from public.resource_allocations where appointment_id='15900000-0000-0000-0000-000000000041';
    delete from public.appointment_change_policy_snapshots where appointment_id='15900000-0000-0000-0000-000000000041';
    delete from public.appointments where id='15900000-0000-0000-0000-000000000041';
    delete from public.customers where id='15900000-0000-0000-0000-000000000040';
  end if;
 end loop;
end $$;
\copy (select scenario, min(elapsed_ms) filter(where engine='V1') as v1_min, percentile_cont(.5) within group(order by elapsed_ms) filter(where engine='V1') as v1_median, max(elapsed_ms) filter(where engine='V1') as v1_max, min(elapsed_ms) filter(where engine='V2') as v2_min, percentile_cont(.5) within group(order by elapsed_ms) filter(where engine='V2') as v2_median, max(elapsed_ms) filter(where engine='V2') as v2_max, percentile_cont(.5) within group(order by elapsed_ms) filter(where engine='V1')/nullif(percentile_cont(.5) within group(order by elapsed_ms) filter(where engine='V2'),0) speedup, count(*) filter(where engine='V1') iterations from benchmark_samples group by scenario order by scenario) to 'benchmark-results.csv' csv header;
\o benchmark-explain.txt
\echo frequent availability V2
explain (analyze,buffers) select * from agenda_internal.list_available_dates_month_v2('blacksheep','15900000-0000-0000-0000-000000000010','15900000-0000-0000-0000-000000000020',60,'[]',1,date '2035-01-01');
\echo zero availability V2
delete from public.availability_rules where service_employee_id='15900000-0000-0000-0000-000000000020';
explain (analyze,buffers) select * from agenda_internal.list_available_dates_month_v2('blacksheep','15900000-0000-0000-0000-000000000010','15900000-0000-0000-0000-000000000020',60,'[]',1,date '2035-01-01');
insert into public.availability_rules(service_employee_id,weekday,start_local_time,end_local_time) select '15900000-0000-0000-0000-000000000020',d,'08:00','18:00' from generate_series(0,6)d;
\echo resource-heavy V2
explain (analyze,buffers) select * from agenda_internal.list_available_dates_month_v2('blacksheep','15900000-0000-0000-0000-000000000010','15900000-0000-0000-0000-000000000020',60,'[{"extra_id":"15900000-0000-0000-0000-000000000030","quantity":1},{"extra_id":"15900000-0000-0000-0000-000000000031","quantity":1}]',1,date '2035-01-01');
\o
rollback;
