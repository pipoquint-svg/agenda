begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(20);

insert into public.customers(id,name,email)
values ('50000000-0000-0000-0000-000000000001','Policy Customer','policy@example.com');
insert into public.employees(id,name)
values ('50000000-0000-0000-0000-000000000002','Policy Employee');
insert into public.categories(id,name,slug)
values ('50000000-0000-0000-0000-000000000003','Policy','policy-test');

insert into public.services(id,category_id,name,slug,base_duration_minutes,base_price,minimum_people,maximum_people)
values ('50000000-0000-0000-0000-000000000004','50000000-0000-0000-0000-000000000003','Consolidated Policy Service','consolidated-policy-service',120,1000,1,10);
insert into public.service_employees(id,service_id,employee_id)
values ('50000000-0000-0000-0000-000000000005','50000000-0000-0000-0000-000000000004','50000000-0000-0000-0000-000000000002');
insert into public.service_change_policies(service_id,notice_hours,reschedule_first_early_percent,reschedule_first_late_percent,reschedule_repeat_percent,cancellation_late_percent)
values ('50000000-0000-0000-0000-000000000004',48,0,20,30,30);
insert into public.appointments(id,public_code,service_id,service_employee_id,status,financial_status,start_at,end_at,duration_minutes,people_count,primary_customer_id,commercial_value,confirmed_at)
values ('50000000-0000-0000-0000-000000000006','POLICY-CONSOLIDATED-1','50000000-0000-0000-0000-000000000004','50000000-0000-0000-0000-000000000005','CONFIRMED','PARTIALLY_PAID','2035-01-10 10:00:00-03','2035-01-10 12:00:00-03',120,1,'50000000-0000-0000-0000-000000000001',1000,now());
insert into public.payment_transactions(appointment_id,transaction_type,method,provider,provider_payment_id,status,contract_amount_settled,cash_amount,paid_at,payment_purpose)
values ('50000000-0000-0000-0000-000000000006','CHARGE','PIX','MERCADO_PAGO','policy-consolidated-pay-1','APPROVED',500,500,now(),'CONTRACT');

select is((select policy_json->>'snapshot_schema_version' from public.appointment_change_policy_snapshots where appointment_id='50000000-0000-0000-0000-000000000006'),'CONSOLIDATED_POLICY_V2','new reservation freezes consolidated policy');
select is((public.calculate_reservation_change('50000000-0000-0000-0000-000000000006','RESCHEDULE','2035-01-07 10:00:00-03','CLIENT',1000)->>'penalty_retained')::numeric,0::numeric,'first client reschedule above 48h has zero penalty');
select is((public.calculate_reservation_change('50000000-0000-0000-0000-000000000006','RESCHEDULE','2035-01-08 10:00:00-03','CLIENT',1000)->>'penalty_retained')::numeric,0::numeric,'exactly 48h is outside penalty window');
select is((public.calculate_reservation_change('50000000-0000-0000-0000-000000000006','RESCHEDULE','2035-01-09 10:01:00-03','CLIENT',1000)->>'theoretical_penalty')::numeric,200::numeric,'late first reschedule calculates 20 percent on R$1000 total');
select is((public.calculate_reservation_change('50000000-0000-0000-0000-000000000006','RESCHEDULE','2035-01-09 10:01:00-03','CLIENT',1000)->>'penalty_retained')::numeric,200::numeric,'R$200 penalty is retained from customer funds');
select is((public.calculate_reservation_change('50000000-0000-0000-0000-000000000006','RESCHEDULE','2035-01-09 10:01:00-03','CLIENT',1000)->>'applicable_amount')::numeric,300::numeric,'R$500 paid minus R$200 retained leaves R$300 applicable');
select is((public.calculate_reservation_change('50000000-0000-0000-0000-000000000006','RESCHEDULE','2035-01-09 10:01:00-03','CLIENT',1000)->>'difference_due')::numeric,700::numeric,'new R$1000 reservation requires R$700 difference');

insert into public.appointment_policy_actions(appointment_id,action_type,status,requested_at,original_start_at,requested_new_start_at,hours_before_start,notice_hours_snapshot,is_inside_notice_window,prior_customer_reschedules,contract_value_snapshot,net_paid_snapshot,penalty_type,penalty_value,penalty_amount,refundable_amount,change_origin)
values ('50000000-0000-0000-0000-000000000006','RESCHEDULE','APPLIED','2035-01-01 10:00:00-03','2035-01-10 10:00:00-03','2035-01-20 10:00:00-03',216,48,false,0,1000,500,'NONE',0,0,0,'CLIENT');
select is((public.calculate_reservation_change('50000000-0000-0000-0000-000000000006','RESCHEDULE','2034-12-31 10:00:00-03','CLIENT',1000)->>'penalty_retained')::numeric,300::numeric,'second client reschedule is 30 percent even early');

insert into public.appointment_policy_actions(appointment_id,action_type,status,requested_at,original_start_at,requested_new_start_at,hours_before_start,notice_hours_snapshot,is_inside_notice_window,prior_customer_reschedules,contract_value_snapshot,net_paid_snapshot,penalty_type,penalty_value,penalty_amount,refundable_amount,change_origin)
values ('50000000-0000-0000-0000-000000000006','RESCHEDULE','APPLIED','2035-01-02 10:00:00-03','2035-01-20 10:00:00-03','2035-01-30 10:00:00-03',432,48,false,1,1000,500,'PERCENT',30,300,0,'CLIENT');
select is((public.calculate_reservation_change('50000000-0000-0000-0000-000000000006','RESCHEDULE','2035-01-09 10:01:00-03','CLIENT',1000)->>'penalty_retained')::numeric,300::numeric,'third client reschedule remains 30 percent');
select is((public.calculate_reservation_change('50000000-0000-0000-0000-000000000006','CANCEL','2035-01-07 10:00:00-03','CLIENT',null)->>'penalty_retained')::numeric,0::numeric,'early cancellation ignores recurrence and has zero penalty');
select is((public.calculate_reservation_change('50000000-0000-0000-0000-000000000006','CANCEL','2035-01-07 10:00:00-03','CLIENT',null)->>'refund_due')::numeric,500::numeric,'early cancellation returns all customer funds');
select is((public.calculate_reservation_change('50000000-0000-0000-0000-000000000006','CANCEL','2035-01-09 10:01:00-03','CLIENT',null)->>'penalty_retained')::numeric,300::numeric,'late cancellation retains 30 percent of R$1000 total');
select is((public.calculate_reservation_change('50000000-0000-0000-0000-000000000006','CANCEL','2035-01-09 10:01:00-03','CLIENT',null)->>'refund_due')::numeric,200::numeric,'mandatory R$1000 paid R$500 cancellation refunds R$200');
select ok((public.calculate_reservation_change('50000000-0000-0000-0000-000000000006','CANCEL','2035-01-09 10:01:00-03','CLIENT',null)->>'penalty_retained')::numeric <= (public.calculate_reservation_change('50000000-0000-0000-0000-000000000006','CANCEL','2035-01-09 10:01:00-03','CLIENT',null)->>'contract_applied_before')::numeric,'penalty never exceeds applied customer funds');
select is((public.calculate_reservation_change('50000000-0000-0000-0000-000000000006','CANCEL','2035-01-09 10:01:00-03','OPERATION',null)->>'penalty_retained')::numeric,0::numeric,'operation-origin cancellation has no penalty');
select ok(not has_column('public','service_change_policies','cancellation_credit_validity_days'),'legacy expiring cancellation-credit policy field is absent');

insert into public.services(id,category_id,name,slug,base_duration_minutes,base_price,minimum_people,maximum_people)
values ('50000000-0000-0000-0000-000000000104','50000000-0000-0000-0000-000000000003','R100 Policy Service','r100-policy-service',60,100,1,10);
insert into public.service_employees(id,service_id,employee_id)
values ('50000000-0000-0000-0000-000000000105','50000000-0000-0000-0000-000000000104','50000000-0000-0000-0000-000000000002');
insert into public.service_change_policies(service_id,notice_hours,reschedule_first_early_percent,reschedule_first_late_percent,reschedule_repeat_percent,cancellation_late_percent)
values ('50000000-0000-0000-0000-000000000104',48,0,20,30,30);
insert into public.appointments(id,public_code,service_id,service_employee_id,status,financial_status,start_at,end_at,duration_minutes,people_count,primary_customer_id,commercial_value,confirmed_at)
values ('50000000-0000-0000-0000-000000000106','POLICY-R100-1','50000000-0000-0000-0000-000000000104','50000000-0000-0000-0000-000000000105','CONFIRMED','PAID','2035-03-10 10:00:00-03','2035-03-10 11:00:00-03',60,1,'50000000-0000-0000-0000-000000000001',100,now());
insert into public.payment_transactions(appointment_id,transaction_type,method,provider,provider_payment_id,status,contract_amount_settled,cash_amount,paid_at,payment_purpose)
values ('50000000-0000-0000-0000-000000000106','CHARGE','PIX','MERCADO_PAGO','policy-r100-pay','APPROVED',100,100,now(),'CONTRACT');
select is((public.calculate_reservation_change('50000000-0000-0000-0000-000000000106','RESCHEDULE','2035-03-09 10:01:00-03','CLIENT',100)->>'penalty_retained')::numeric,20::numeric,'R$100 late first reschedule retains R$20');
select is((public.calculate_reservation_change('50000000-0000-0000-0000-000000000106','RESCHEDULE','2035-03-09 10:01:00-03','CLIENT',100)->>'difference_due')::numeric,20::numeric,'R$80 applies to new R$100 booking and R$20 is due');
select is((public.calculate_reservation_change('50000000-0000-0000-0000-000000000106','RESCHEDULE','2035-03-09 10:01:00-03','CLIENT',60)->>'excess_amount')::numeric,20::numeric,'new R$60 booking keeps R$20 customer-owned excess for final settlement');

select * from finish();
rollback;
