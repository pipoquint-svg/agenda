begin;

create extension if not exists pgtap with schema extensions;
set local search_path=public,extensions;

select plan(8);

insert into auth.users(
  id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,
  created_at,updated_at,raw_app_meta_data,raw_user_meta_data
)
values (
  'b1000000-0000-4000-8000-000000000001',
  '00000000-0000-0000-0000-000000000000',
  'authenticated','authenticated','item-b-owner@example.test','',now(),
  now(),now(),'{}'::jsonb,'{}'::jsonb
);

insert into public.admin_users(id,auth_user_id,display_name,role,is_active)
values (
  'b1000000-0000-4000-8000-000000000002',
  'b1000000-0000-4000-8000-000000000001',
  'Item B Finance Owner','OWNER',true
);

insert into public.customers(id,name,email,cpf_cnpj)
values (
  'b1000000-0000-4000-8000-000000000010',
  'Item B NFSe Customer','item-b-customer@example.test','12345678901'
);

insert into public.employees(id,name)
values ('b1000000-0000-4000-8000-000000000020','Item B Employee');

insert into public.categories(id,name,slug)
values ('b1000000-0000-4000-8000-000000000021','Item B NFSe','item-b-nfse');

insert into public.services(
  id,category_id,name,slug,base_duration_minutes,base_price,
  minimum_people,maximum_people,operation_scope
)
values (
  'b1000000-0000-4000-8000-000000000022',
  'b1000000-0000-4000-8000-000000000021',
  'Item B NFSe Service','item-b-nfse-service',60,100,1,10,'BLACKSHEEP'
);

insert into public.service_employees(id,service_id,employee_id)
values (
  'b1000000-0000-4000-8000-000000000023',
  'b1000000-0000-4000-8000-000000000022',
  'b1000000-0000-4000-8000-000000000020'
);

insert into public.service_change_policies(
  service_id,notice_hours,reschedule_first_early_percent,
  reschedule_first_late_percent,reschedule_repeat_percent,cancellation_late_percent
)
values ('b1000000-0000-4000-8000-000000000022',48,0,20,20,20);

insert into public.appointments(
  id,public_code,service_id,service_employee_id,status,financial_status,
  start_at,end_at,duration_minutes,people_count,primary_customer_id,
  commercial_value,confirmed_at
)
values
  ('b1000000-0000-4000-8000-000000000041','ITEM-B-PIX',
   'b1000000-0000-4000-8000-000000000022','b1000000-0000-4000-8000-000000000023',
   'COMPLETED','PAID','2036-01-05 10:00:00-03','2036-01-05 11:00:00-03',60,1,
   'b1000000-0000-4000-8000-000000000010',100,now()),
  ('b1000000-0000-4000-8000-000000000042','ITEM-B-CARD',
   'b1000000-0000-4000-8000-000000000022','b1000000-0000-4000-8000-000000000023',
   'COMPLETED','PAID','2036-01-06 10:00:00-03','2036-01-06 11:00:00-03',60,1,
   'b1000000-0000-4000-8000-000000000010',100,now()),
  ('b1000000-0000-4000-8000-000000000043','ITEM-B-CASH',
   'b1000000-0000-4000-8000-000000000022','b1000000-0000-4000-8000-000000000023',
   'COMPLETED','PAID','2036-01-07 10:00:00-03','2036-01-07 11:00:00-03',60,1,
   'b1000000-0000-4000-8000-000000000010',100,now()),
  ('b1000000-0000-4000-8000-000000000044','ITEM-B-TRANSFER',
   'b1000000-0000-4000-8000-000000000022','b1000000-0000-4000-8000-000000000023',
   'COMPLETED','PAID','2036-01-08 10:00:00-03','2036-01-08 11:00:00-03',60,1,
   'b1000000-0000-4000-8000-000000000010',100,now()),
  ('b1000000-0000-4000-8000-000000000045','ITEM-B-CREDIT',
   'b1000000-0000-4000-8000-000000000022','b1000000-0000-4000-8000-000000000023',
   'COMPLETED','PAID','2036-01-09 10:00:00-03','2036-01-09 11:00:00-03',60,1,
   'b1000000-0000-4000-8000-000000000010',100,now()),
  ('b1000000-0000-4000-8000-000000000046','ITEM-B-COURTESY',
   'b1000000-0000-4000-8000-000000000022','b1000000-0000-4000-8000-000000000023',
   'COMPLETED','PAID','2036-01-10 10:00:00-03','2036-01-10 11:00:00-03',60,1,
   'b1000000-0000-4000-8000-000000000010',100,now()),
  ('b1000000-0000-4000-8000-000000000047','ITEM-B-OTHER',
   'b1000000-0000-4000-8000-000000000022','b1000000-0000-4000-8000-000000000023',
   'COMPLETED','PAID','2036-01-11 10:00:00-03','2036-01-11 11:00:00-03',60,1,
   'b1000000-0000-4000-8000-000000000010',100,now());

insert into public.payment_transactions(
  id,appointment_id,transaction_type,method,provider,status,
  contract_amount_settled,cash_amount,paid_at,payment_purpose
)
values
  ('b1000000-0000-4000-8000-000000000051','b1000000-0000-4000-8000-000000000041',
   'CHARGE','PIX','MANUAL','APPROVED',100,100,'2036-01-05 09:00:00-03','CONTRACT'),
  ('b1000000-0000-4000-8000-000000000052','b1000000-0000-4000-8000-000000000042',
   'CHARGE','CARD','MANUAL','APPROVED',100,100,'2036-01-06 09:00:00-03','CONTRACT'),
  ('b1000000-0000-4000-8000-000000000053','b1000000-0000-4000-8000-000000000043',
   'CHARGE','CASH','MANUAL','APPROVED',100,100,'2036-01-07 09:00:00-03','CONTRACT'),
  ('b1000000-0000-4000-8000-000000000054','b1000000-0000-4000-8000-000000000044',
   'CHARGE','TRANSFER','MANUAL','APPROVED',100,100,'2036-01-08 09:00:00-03','CONTRACT'),
  ('b1000000-0000-4000-8000-000000000055','b1000000-0000-4000-8000-000000000045',
   'CHARGE','CREDIT','MANUAL','APPROVED',100,100,'2036-01-09 09:00:00-03','CONTRACT'),
  ('b1000000-0000-4000-8000-000000000056','b1000000-0000-4000-8000-000000000046',
   'CHARGE','COURTESY','MANUAL','APPROVED',100,0,'2036-01-10 09:00:00-03','CONTRACT'),
  ('b1000000-0000-4000-8000-000000000057','b1000000-0000-4000-8000-000000000047',
   'CHARGE','OTHER','MANUAL','APPROVED',100,100,'2036-01-11 09:00:00-03','CONTRACT');

create temporary table item_b_nfse_rows as
select row_data
from jsonb_array_elements(
  public.service_admin_finance_nfse_export(
    '2036-01-01','BLACKSHEEP','b1000000-0000-4000-8000-000000000002'
  )->'rows'
) as exported(row_data);

select is((select count(*)::integer from item_b_nfse_rows),7,'NFS-e export returns one fixture for every valid payment method');
select is((select row_data->>'payment_method' from item_b_nfse_rows where row_data->>'public_code'='ITEM-B-PIX'),'Pix','PIX exports as Pix');
select is((select row_data->>'payment_method' from item_b_nfse_rows where row_data->>'public_code'='ITEM-B-CARD'),'Cartão','CARD exports as Cartão');
select is((select row_data->>'payment_method' from item_b_nfse_rows where row_data->>'public_code'='ITEM-B-CASH'),'Dinheiro','CASH exports as Dinheiro');
select is((select row_data->>'payment_method' from item_b_nfse_rows where row_data->>'public_code'='ITEM-B-TRANSFER'),'Transferência','TRANSFER exports as Transferência');
select is((select row_data->>'payment_method' from item_b_nfse_rows where row_data->>'public_code'='ITEM-B-CREDIT'),'Crédito','CREDIT exports as Crédito');
select is((select row_data->>'payment_method' from item_b_nfse_rows where row_data->>'public_code'='ITEM-B-COURTESY'),'Cortesia','COURTESY exports as Cortesia');
select is((select row_data->>'payment_method' from item_b_nfse_rows where row_data->>'public_code'='ITEM-B-OTHER'),'Outro','OTHER explicitly exports as Outro');

select * from finish();
rollback;
