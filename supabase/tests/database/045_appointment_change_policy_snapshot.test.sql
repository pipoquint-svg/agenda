begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(18);

insert into public.customers(id,name,email)
values ('45000000-0000-0000-0000-000000000001','Snapshot Customer','snapshot@example.com');
insert into public.employees(id,name)
values ('45000000-0000-0000-0000-000000000002','Snapshot Employee');
insert into public.categories(id,name,slug)
values ('45000000-0000-0000-0000-000000000003','Snapshot','snapshot-policy');
insert into public.services(id,category_id,name,slug,base_duration_minutes,base_price,minimum_people,maximum_people,requires_terms)
values ('45000000-0000-0000-0000-000000000004','45000000-0000-0000-0000-000000000003','Snapshot Service','snapshot-service',120,1000,1,10,true);
insert into public.service_employees(id,service_id,employee_id)
values ('45000000-0000-0000-0000-000000000005','45000000-0000-0000-0000-000000000004','45000000-0000-0000-0000-000000000002');
insert into public.service_change_policies(service_id,notice_hours,reschedule_first_early_percent,reschedule_first_late_percent,reschedule_repeat_percent,cancellation_late_percent)
values ('45000000-0000-0000-0000-000000000004',48,0,20,30,30);

insert into public.terms_versions(id,service_id,name,version,content,is_active,published_at)
values ('45000000-0000-0000-0000-000000000006','45000000-0000-0000-0000-000000000004','Política comercial','v1','Termos v1',true,now()-interval '1 day');

insert into public.appointments(id,public_code,service_id,service_employee_id,primary_customer_id,status,financial_status,start_at,end_at,duration_minutes,people_count,commercial_value,confirmed_at)
values ('45000000-0000-0000-0000-000000000007','SNAPSHOT-OLD','45000000-0000-0000-0000-000000000004','45000000-0000-0000-0000-000000000005','45000000-0000-0000-0000-000000000001','CONFIRMED','PARTIALLY_PAID','2035-01-10 15:00:00-03','2035-01-10 17:00:00-03',120,1,1000,now());
insert into public.appointment_term_acceptances(appointment_id,terms_version_id,content_snapshot,accepted_at)
values ('45000000-0000-0000-0000-000000000007','45000000-0000-0000-0000-000000000006','Termos v1',now());
insert into public.payment_transactions(appointment_id,transaction_type,method,provider,provider_payment_id,status,contract_amount_settled,cash_amount,paid_at,payment_purpose)
values ('45000000-0000-0000-0000-000000000007','CHARGE','PIX','MERCADO_PAGO','snapshot-payment-old','APPROVED',500,500,now(),'CONTRACT');

select ok(exists(select 1 from public.appointment_change_policy_snapshots s where s.appointment_id='45000000-0000-0000-0000-000000000007'),'confirmed appointment receives a policy snapshot');
select is((select (s.policy_json->>'reschedule_first_late_percent')::numeric from public.appointment_change_policy_snapshots s where s.appointment_id='45000000-0000-0000-0000-000000000007'),20.00::numeric,'snapshot freezes the late-first-reschedule percent in force');
select is((select s.max_customer_reschedules::integer from public.appointment_change_policy_snapshots s where s.appointment_id='45000000-0000-0000-0000-000000000007'),3,'snapshot records three-client-reschedule limit');
select is((select s.notice_boundary_semantics from public.appointment_change_policy_snapshots s where s.appointment_id='45000000-0000-0000-0000-000000000007'),'EXACT_LIMIT_IS_OUTSIDE_WINDOW','exact notice boundary semantics are explicit');
select ok(exists(select 1 from public.appointment_change_policy_snapshot_terms st where st.appointment_id='45000000-0000-0000-0000-000000000007' and st.terms_version_id='45000000-0000-0000-0000-000000000006' and st.version_snapshot='v1'),'snapshot records corresponding terms version');

-- Change live policy after reservation. Prior reservation must keep 20%, new one gets 35%.
update public.service_change_policies
set reschedule_first_late_percent=35,cancellation_late_percent=35,updated_at=now()+interval '1 second'
where service_id='45000000-0000-0000-0000-000000000004';
update public.terms_versions set is_active=false where id='45000000-0000-0000-0000-000000000006';
insert into public.terms_versions(id,service_id,name,version,content,is_active,published_at)
values ('45000000-0000-0000-0000-000000000008','45000000-0000-0000-0000-000000000004','Política comercial','v2','Termos v2',true,now());

select is((public.calculate_reservation_change('45000000-0000-0000-0000-000000000007','RESCHEDULE','2035-01-08 14:59:59-03','CLIENT',1000)->>'penalty_retained')::numeric,0.00::numeric,'one second before 48h boundary has no reschedule penalty');
select is((public.calculate_reservation_change('45000000-0000-0000-0000-000000000007','RESCHEDULE','2035-01-08 15:00:00-03','CLIENT',1000)->>'penalty_retained')::numeric,0.00::numeric,'exactly 48h has no reschedule penalty');
select is((public.calculate_reservation_change('45000000-0000-0000-0000-000000000007','RESCHEDULE','2035-01-08 15:00:01-03','CLIENT',1000)->>'penalty_retained')::numeric,200.00::numeric,'one second after boundary uses old reservation 20 percent snapshot');
select is((public.calculate_reservation_change('45000000-0000-0000-0000-000000000007','CANCEL','2035-01-08 14:59:59-03','CLIENT',null)->>'penalty_retained')::numeric,0.00::numeric,'one second before 48h has no cancellation penalty');
select is((public.calculate_reservation_change('45000000-0000-0000-0000-000000000007','CANCEL','2035-01-08 15:00:00-03','CLIENT',null)->>'penalty_retained')::numeric,0.00::numeric,'exactly 48h has no cancellation penalty');
select is((public.calculate_reservation_change('45000000-0000-0000-0000-000000000007','CANCEL','2035-01-08 15:00:01-03','CLIENT',null)->>'penalty_retained')::numeric,300.00::numeric,'old reservation retains its original 30 percent late-cancellation snapshot');
select is((select (s.policy_json->>'reschedule_first_late_percent')::numeric from public.appointment_change_policy_snapshots s where s.appointment_id='45000000-0000-0000-0000-000000000007'),20.00::numeric,'live policy change does not mutate prior snapshot');
select ok(not exists(select 1 from public.appointment_change_policy_snapshot_terms st where st.appointment_id='45000000-0000-0000-0000-000000000007' and st.terms_version_id='45000000-0000-0000-0000-000000000008'),'later terms publication does not alter prior reservation terms snapshot');

insert into public.appointments(id,public_code,service_id,service_employee_id,primary_customer_id,status,financial_status,start_at,end_at,duration_minutes,people_count,commercial_value,confirmed_at)
values ('45000000-0000-0000-0000-000000000009','SNAPSHOT-NEW','45000000-0000-0000-0000-000000000004','45000000-0000-0000-0000-000000000005','45000000-0000-0000-0000-000000000001','CONFIRMED','PARTIALLY_PAID','2035-02-10 15:00:00-03','2035-02-10 17:00:00-03',120,1,1000,now()+interval '2 seconds');
insert into public.payment_transactions(appointment_id,transaction_type,method,provider,provider_payment_id,status,contract_amount_settled,cash_amount,paid_at,payment_purpose)
values ('45000000-0000-0000-0000-000000000009','CHARGE','PIX','MERCADO_PAGO','snapshot-payment-new','APPROVED',500,500,now(),'CONTRACT');

select is((select (s.policy_json->>'reschedule_first_late_percent')::numeric from public.appointment_change_policy_snapshots s where s.appointment_id='45000000-0000-0000-0000-000000000009'),35.00::numeric,'later reservation freezes later live policy');
select ok(exists(select 1 from public.appointment_change_policy_snapshot_terms st where st.appointment_id='45000000-0000-0000-0000-000000000009' and st.terms_version_id='45000000-0000-0000-0000-000000000008' and st.version_snapshot='v2'),'later reservation receives later terms version');
select is((public.calculate_reservation_change('45000000-0000-0000-0000-000000000009','RESCHEDULE','2035-02-08 15:00:01-03','CLIENT',1000)->>'penalty_retained')::numeric,350.00::numeric,'later reservation calculation uses its own 35 percent snapshot');
select throws_ok($$update public.appointment_change_policy_snapshots set max_customer_reschedules=3 where appointment_id='45000000-0000-0000-0000-000000000007'$$,'42501','APPOINTMENT_CHANGE_POLICY_SNAPSHOT_IMMUTABLE','reservation policy snapshot rejects mutation');
select ok(not has_table_privilege('service_role','public.appointment_change_policy_snapshots','UPDATE') and not has_table_privilege('service_role','public.appointment_change_policy_snapshots','DELETE') and not has_table_privilege('service_role','public.appointment_change_policy_snapshots','TRUNCATE'),'service_role has no destructive snapshot privileges');

select * from finish();
rollback;