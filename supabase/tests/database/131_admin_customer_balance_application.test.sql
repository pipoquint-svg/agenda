begin;
create extension if not exists pgtap with schema extensions;
set local search_path=public,extensions;
select plan(13);

insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,raw_app_meta_data,raw_user_meta_data)
values ('7b000000-0000-4000-8000-000000000001','00000000-0000-0000-0000-000000000000','authenticated','authenticated','finance-balance-admin@example.test','',now(),now(),now(),'{}'::jsonb,'{}'::jsonb);
insert into public.admin_users(id,auth_user_id,display_name,role,is_active)
values ('7b000000-0000-4000-8000-000000000002','7b000000-0000-4000-8000-000000000001','Balance Admin Owner','OWNER',true);

insert into public.customers(id,name,email)
values ('7b000000-0000-4000-8000-000000000010','Cliente Saldo Admin','saldo-admin@example.test');
insert into public.employees(id,name) values ('7b000000-0000-4000-8000-000000000020','Balance Admin Employee');
insert into public.categories(id,name,slug) values ('7b000000-0000-4000-8000-000000000021','Balance Admin','balance-admin');
insert into public.services(id,category_id,name,slug,base_duration_minutes,base_price,minimum_people,maximum_people,operation_scope)
values ('7b000000-0000-4000-8000-000000000022','7b000000-0000-4000-8000-000000000021','Balance Admin Service','balance-admin-service',60,250,1,10,'BLACKSHEEP');
insert into public.service_employees(id,service_id,employee_id)
values ('7b000000-0000-4000-8000-000000000023','7b000000-0000-4000-8000-000000000022','7b000000-0000-4000-8000-000000000020');
insert into public.service_change_policies(service_id,notice_hours,reschedule_first_early_percent,reschedule_first_late_percent,reschedule_repeat_percent,cancellation_late_percent)
values ('7b000000-0000-4000-8000-000000000022',48,0,20,20,20);

insert into public.customer_balance_movements(id,customer_id,movement_type,direction,amount,choice_origin,ip_address,user_agent,request_id,idempotency_key,created_at,expires_at) values
('7b000000-0000-4000-8000-000000000030','7b000000-0000-4000-8000-000000000010','CREDIT_FROM_RETURN','CREDIT',100,'CLIENT_TOKEN','127.0.0.1','pgTAP','balance-admin-early','balance-admin-early',now(),now()+interval '6 months'),
('7b000000-0000-4000-8000-000000000031','7b000000-0000-4000-8000-000000000010','CREDIT_FROM_RETURN','CREDIT',200,'CLIENT_TOKEN','127.0.0.1','pgTAP','balance-admin-late','balance-admin-late',now(),now()+interval '12 months');

insert into public.appointments(id,public_code,service_id,service_employee_id,status,financial_status,start_at,end_at,duration_minutes,people_count,primary_customer_id,commercial_value,confirmed_at)
values ('7b000000-0000-4000-8000-000000000040','BALANCE-ADMIN-QA','7b000000-0000-4000-8000-000000000022','7b000000-0000-4000-8000-000000000023','CONFIRMED','NOT_STARTED','2035-11-20 10:00:00-03','2035-11-20 11:00:00-03',60,1,'7b000000-0000-4000-8000-000000000010',250,now());

select is(public.customer_balance_available('7b000000-0000-4000-8000-000000000010'),300::numeric,'fixture starts with R$300 available');
select is((public.service_admin_customer_balance_application_preview('7b000000-0000-4000-8000-000000000040','7b000000-0000-4000-8000-000000000002')->>'balance_available')::numeric,300::numeric,'preview exposes authoritative available balance');
select is((public.service_admin_customer_balance_application_preview('7b000000-0000-4000-8000-000000000040','7b000000-0000-4000-8000-000000000002')->>'amount_due')::numeric,250::numeric,'preview exposes authoritative amount due');
select is((public.service_admin_customer_balance_application_preview('7b000000-0000-4000-8000-000000000040','7b000000-0000-4000-8000-000000000002')->>'amount_applicable')::numeric,250::numeric,'preview limits application to amount due');
select is((public.service_admin_customer_balance_application_preview('7b000000-0000-4000-8000-000000000040','7b000000-0000-4000-8000-000000000002')->>'balance_after')::numeric,50::numeric,'preview exposes remaining customer balance');
select ok((public.service_admin_customer_balance_application_preview('7b000000-0000-4000-8000-000000000040','7b000000-0000-4000-8000-000000000002')->>'nearest_expiry')::timestamptz < now()+interval '7 months','preview exposes the nearest usable expiry');
select is(public.customer_balance_available('7b000000-0000-4000-8000-000000000010'),300::numeric,'preview is read-only');
select is((public.service_apply_customer_balance_to_appointment('7b000000-0000-4000-8000-000000000040',null,'ADMIN_UI','7b000000-0000-4000-8000-000000000002','127.0.0.1','pgTAP','balance-admin-apply','Gestão QA')->>'amount_applied')::numeric,250::numeric,'admin application consumes the backend-authoritative amount');
select is(public.customer_balance_available('7b000000-0000-4000-8000-000000000010'),50::numeric,'R$50 remains after application');
select is((public.service_apply_customer_balance_to_appointment('7b000000-0000-4000-8000-000000000040',null,'ADMIN_UI','7b000000-0000-4000-8000-000000000002','127.0.0.1','pgTAP','balance-admin-replay','Gestão QA')->>'idempotent_replay')::boolean,true,'second application is an idempotent replay');
select is((select count(*) from public.customer_balance_movements where appointment_id='7b000000-0000-4000-8000-000000000040' and direction='DEBIT'),2::bigint,'idempotent replay creates no additional debit lots');
select ok(exists(select 1 from public.audit_logs where admin_user_id='7b000000-0000-4000-8000-000000000002' and entity_id='7b000000-0000-4000-8000-000000000040' and action='CUSTOMER_BALANCE_APPLIED'),'admin application records authorship in audit log');
select ok(not has_function_privilege('anon','public.service_admin_customer_balance_application_preview(uuid,uuid)','EXECUTE') and not has_function_privilege('authenticated','public.service_admin_customer_balance_application_preview(uuid,uuid)','EXECUTE') and has_function_privilege('service_role','public.service_admin_customer_balance_application_preview(uuid,uuid)','EXECUTE'),'preview RPC is service-role-only');

select * from finish();
rollback;
