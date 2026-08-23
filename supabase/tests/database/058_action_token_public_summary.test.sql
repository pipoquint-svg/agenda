begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(8);

insert into public.categories(id,name,slug)
values ('95800000-0000-0000-0000-000000000001','Public Summary','public-summary-test');
insert into public.employees(id,name)
values ('95800000-0000-0000-0000-000000000002','Summary Employee');
insert into public.services(
  id,category_id,name,slug,base_duration_minutes,base_price,minimum_people,maximum_people,
  maximum_booking_horizon_days,confirmation_percentage,operation_scope
)
values (
  '95800000-0000-0000-0000-000000000010','95800000-0000-0000-0000-000000000001',
  'Locação BlackSheep','public-summary-service',60,1000,1,2,5000,50,'BLACKSHEEP'
);
insert into public.service_employees(id,service_id,employee_id)
values ('95800000-0000-0000-0000-000000000011','95800000-0000-0000-0000-000000000010','95800000-0000-0000-0000-000000000002');
insert into public.customers(id,name,email,phone)
values ('95800000-0000-0000-0000-000000000020','Nome Secreto','segredo@example.com','48999990000');
insert into public.appointments(
  id,public_code,service_id,service_employee_id,service_name_snapshot,primary_customer_id,
  status,financial_status,start_at,end_at,duration_minutes,people_count,commercial_value,confirmed_at
)
values (
  '95800000-0000-0000-0000-000000000030','BS-SAFE-1',
  '95800000-0000-0000-0000-000000000010','95800000-0000-0000-0000-000000000011',
  'Locação BlackSheep','95800000-0000-0000-0000-000000000020',
  'CONFIRMED','PARTIALLY_PAID','2035-05-10 10:00:00-03','2035-05-10 11:00:00-03',60,1,1000,now()
);

create temporary table issued_summary as
select public.service_issue_appointment_action_token(
  '95800000-0000-0000-0000-000000000030','CANCEL','EMAIL','s***@example.com','summary-issue'
) payload;

create temporary table public_summary as
select public.service_appointment_action_public_summary(((select payload->>'token_id' from issued_summary))::uuid) data;

select has_function('public','service_appointment_action_public_summary',array['uuid'],'safe action summary function exists');
select is((select data->>'public_code' from public_summary),'BS-SAFE-1','public code is exposed');
select is((select data->>'service_name' from public_summary),'Locação BlackSheep','service name is exposed');
select is((select data->>'resource_name' from public_summary),'BlackSheep Estúdio Criativo','BlackSheep physical resource label is exposed');
select is((select data->>'status_label' from public_summary),'Confirmada','safe status label is exposed');
select ok(not ((select data from public_summary) ? 'email'),'email is never present');
select ok(not ((select data from public_summary) ? 'phone') and not ((select data from public_summary) ? 'customer_display_name'),'customer PII is never present');
select ok(position('segredo@example.com' in (select data::text from public_summary)) = 0 and position('Nome Secreto' in (select data::text from public_summary)) = 0,'summary payload contains no hidden customer PII');

select * from finish();
rollback;
