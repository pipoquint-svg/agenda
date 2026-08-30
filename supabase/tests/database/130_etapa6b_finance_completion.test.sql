begin;
create extension if not exists pgtap with schema extensions;
set local search_path=public,extensions;
select plan(19);

insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,raw_app_meta_data,raw_user_meta_data)
values ('6b000000-0000-4000-8000-000000000001','00000000-0000-0000-0000-000000000000','authenticated','authenticated','finance6b@example.test','',now(),now(),now(),'{}'::jsonb,'{}'::jsonb);
insert into public.admin_users(id,auth_user_id,display_name,role,is_active)
values ('6b000000-0000-4000-8000-000000000002','6b000000-0000-4000-8000-000000000001','Finance 6B Owner','OWNER',true);

insert into public.customers(id,name,email,cpf_cnpj) values
('6b000000-0000-4000-8000-000000000010','Cliente Saldo 6B','saldo6b@example.test','11122233344'),
('6b000000-0000-4000-8000-000000000011','Cliente Refund 6B','refund6b@example.test','55566677788'),
('6b000000-0000-4000-8000-000000000012','Cliente No Show 6B','noshow6b@example.test','99988877766');
insert into public.employees(id,name) values ('6b000000-0000-4000-8000-000000000020','Finance 6B Employee');
insert into public.categories(id,name,slug) values ('6b000000-0000-4000-8000-000000000021','Finance 6B','finance-6b');
insert into public.services(id,category_id,name,slug,base_duration_minutes,base_price,minimum_people,maximum_people,operation_scope)
values ('6b000000-0000-4000-8000-000000000022','6b000000-0000-4000-8000-000000000021','Finance 6B Service','finance-6b-service',60,500,1,10,'BLACKSHEEP');
insert into public.service_employees(id,service_id,employee_id)
values ('6b000000-0000-4000-8000-000000000023','6b000000-0000-4000-8000-000000000022','6b000000-0000-4000-8000-000000000020');
insert into public.service_change_policies(service_id,notice_hours,reschedule_first_early_percent,reschedule_first_late_percent,reschedule_repeat_percent,cancellation_late_percent)
values ('6b000000-0000-4000-8000-000000000022',48,0,20,20,20);

select has_column('public','customer_balance_movements','expires_at','balance lots expose expires_at');
select has_column('public','customer_balance_movements','source_credit_movement_id','balance debits identify their source credit lot');

insert into public.customer_balance_movements(id,customer_id,movement_type,direction,amount,choice_origin,ip_address,user_agent,request_id,idempotency_key,created_at,expires_at) values
('6b000000-0000-4000-8000-000000000030','6b000000-0000-4000-8000-000000000010','CREDIT_FROM_RETURN','CREDIT',50,'CLIENT_TOKEN','127.0.0.1','pgTAP','expired-credit','6b-expired',now()-interval '13 months',now()-interval '1 month'),
('6b000000-0000-4000-8000-000000000031','6b000000-0000-4000-8000-000000000010','CREDIT_FROM_RETURN','CREDIT',100,'CLIENT_TOKEN','127.0.0.1','pgTAP','early-credit','6b-early',now(),now()+interval '6 months'),
('6b000000-0000-4000-8000-000000000032','6b000000-0000-4000-8000-000000000010','CREDIT_FROM_RETURN','CREDIT',150,'CLIENT_TOKEN','127.0.0.1','pgTAP','late-credit','6b-late',now(),now()+interval '12 months');
select is(public.customer_balance_available('6b000000-0000-4000-8000-000000000010'),250::numeric,'expired R$50 lot is excluded from available balance');

insert into public.appointments(id,public_code,service_id,service_employee_id,status,financial_status,start_at,end_at,duration_minutes,people_count,primary_customer_id,commercial_value,confirmed_at)
values ('6b000000-0000-4000-8000-000000000040','6B-BALANCE-APPLY','6b000000-0000-4000-8000-000000000022','6b000000-0000-4000-8000-000000000023','CONFIRMED','NOT_STARTED','2035-08-10 10:00:00-03','2035-08-10 11:00:00-03',60,1,'6b000000-0000-4000-8000-000000000010',100,now());
select is((public.service_apply_customer_balance_to_appointment('6b000000-0000-4000-8000-000000000040',null,'CLIENT_TOKEN',null,'127.0.0.1','pgTAP','6b-apply',null)->>'amount_applied')::numeric,100::numeric,'balance applies only the R$100 amount due');
select is(public.customer_balance_available('6b000000-0000-4000-8000-000000000010'),150::numeric,'R$150 remains after partial balance application');
select is((select source_credit_movement_id from public.customer_balance_movements where appointment_id='6b000000-0000-4000-8000-000000000040' and direction='DEBIT' limit 1),'6b000000-0000-4000-8000-000000000031'::uuid,'earliest-expiry credit lot is consumed first');

insert into public.appointments(id,public_code,service_id,service_employee_id,status,financial_status,start_at,end_at,duration_minutes,people_count,primary_customer_id,commercial_value,confirmed_at)
values ('6b000000-0000-4000-8000-000000000041','6B-MANUAL-REFUND','6b000000-0000-4000-8000-000000000022','6b000000-0000-4000-8000-000000000023','CONFIRMED','PARTIALLY_PAID','2035-10-10 10:00:00-03','2035-10-10 11:00:00-03',60,1,'6b000000-0000-4000-8000-000000000011',500,now());
insert into public.payment_transactions(id,appointment_id,transaction_type,method,provider,status,contract_amount_settled,cash_amount,paid_at,payment_purpose)
values ('6b000000-0000-4000-8000-000000000050','6b000000-0000-4000-8000-000000000041','CHARGE','PIX','MANUAL','APPROVED',300,300,'2035-09-01 12:00:00-03','CONTRACT');
select public.service_admin_cancel_appointment('6b000000-0000-4000-8000-000000000041',null,'6B test','2035-10-01 10:00:00-03','CLIENT',null);
select is(((public.service_admin_finance_pending_refunds('BLACKSHEEP','6b000000-0000-4000-8000-000000000002')->'refunds'->0->>'manual_refund_amount')::numeric),300::numeric,'pending finance list exposes the R$300 off-gateway refund');
select throws_ok($$select public.service_admin_record_cancellation_manual_refund((select id from public.appointment_policy_actions where appointment_id='6b000000-0000-4000-8000-000000000041' and action_type='CANCEL'),'PIX',300,null,now(),'6b000000-0000-4000-8000-000000000002','127.0.0.1','pgTAP','6b-refund-no-ref')$$,'P0001','MANUAL_REFUND_EVIDENCE_REQUIRED','manual refund requires a written reference');
select lives_ok($$select public.service_admin_record_cancellation_manual_refund((select id from public.appointment_policy_actions where appointment_id='6b000000-0000-4000-8000-000000000041' and action_type='CANCEL'),'PIX',300,'Comprovante PIX 6B','2035-10-01 11:00:00-03','6b000000-0000-4000-8000-000000000002','127.0.0.1','pgTAP','6b-refund-ok')$$,'off-gateway refund can be recorded by FINANCE_MANAGE');
select is((select provider from public.payment_transactions where parent_transaction_id='6b000000-0000-4000-8000-000000000050' and transaction_type='REFUND'),'MANUAL','manual return is an auditable child REFUND transaction');
select is((select status from public.appointment_policy_actions where appointment_id='6b000000-0000-4000-8000-000000000041' and action_type='CANCEL'),'REFUNDED','policy action closes after full manual refund is recorded');
select is((public.service_admin_record_cancellation_manual_refund((select id from public.appointment_policy_actions where appointment_id='6b000000-0000-4000-8000-000000000041' and action_type='CANCEL'),'PIX',300,'Comprovante PIX 6B','2035-10-01 11:00:00-03','6b000000-0000-4000-8000-000000000002','127.0.0.1','pgTAP','6b-refund-ok')->>'idempotent_replay')::boolean,true,'same manual refund request replays idempotently after the action is already refunded');

insert into public.appointments(id,public_code,service_id,service_employee_id,status,financial_status,start_at,end_at,duration_minutes,people_count,primary_customer_id,commercial_value,confirmed_at,no_show_at)
values ('6b000000-0000-4000-8000-000000000042','6B-NO-SHOW','6b000000-0000-4000-8000-000000000022','6b000000-0000-4000-8000-000000000023','NO_SHOW','PARTIALLY_PAID','2035-09-15 10:00:00-03','2035-09-15 11:00:00-03',60,1,'6b000000-0000-4000-8000-000000000012',500,now(),'2035-09-15 11:01:00-03');
insert into public.payment_transactions(appointment_id,transaction_type,method,provider,status,contract_amount_settled,cash_amount,paid_at,payment_purpose)
values ('6b000000-0000-4000-8000-000000000042','CHARGE','PIX','MANUAL','APPROVED',200,200,'2035-09-10 10:00:00-03','CONTRACT');
select is((public.service_admin_finance_month_close('2035-09-01','BLACKSHEEP','6b000000-0000-4000-8000-000000000002')->'services'->>'service_count')::integer,1,'month close counts NO_SHOW as a performed service');
select is((public.service_admin_finance_month_close('2035-09-01','BLACKSHEEP','6b000000-0000-4000-8000-000000000002')->'contract'->>'outstanding')::numeric,300::numeric,'no-show keeps R$300 outstanding instead of refunding or crediting it');
select is((public.service_admin_finance_month_close('2035-09-01','BLACKSHEEP','6b000000-0000-4000-8000-000000000002')->'cash'->>'received')::numeric,500::numeric,'September cash includes R$300 received for a future service plus R$200 from the no-show service');
select is((public.service_admin_finance_month_close('2035-09-01','BLACKSHEEP','6b000000-0000-4000-8000-000000000002')->'customer_balance'->>'accounting_classification'),'LIABILITY_NOT_REVENUE','customer balance remains a liability, not revenue');
select is((public.service_admin_finance_nfse_export('2035-09-01','BLACKSHEEP','6b000000-0000-4000-8000-000000000002')->'rows'->0->>'appointment_status'),'NO_SHOW','NFS-e export includes no-show services');

select ok(not has_function_privilege('anon','public.service_admin_record_cancellation_manual_refund(uuid,text,numeric,text,timestamptz,uuid,inet,text,text)','EXECUTE') and not has_function_privilege('authenticated','public.service_admin_record_cancellation_manual_refund(uuid,text,numeric,text,timestamptz,uuid,inet,text,text)','EXECUTE'),'manual refund RPC is not exposed to browser database roles');
select ok(not exists(select 1 from pg_trigger t join pg_proc p on p.oid=t.tgfoid where not t.tgisinternal and p.proname='enqueue_no_show_balance_cancellation'),'legacy no-show balance cancellation remains unattached');

select * from finish();
rollback;
