begin;
create extension if not exists pgtap with schema extensions;
set local search_path=public,extensions;
select plan(11);

insert into public.customers(id,name) values ('97900000-0000-0000-0000-000000000001','Penalty Customer');
insert into public.employees(id,name) values ('97900000-0000-0000-0000-000000000002','Penalty Employee');
insert into public.categories(id,name,slug) values ('97900000-0000-0000-0000-000000000003','Penalty Test','penalty-test');
insert into public.resources(id,name,resource_type) values ('97900000-0000-0000-0000-000000000004','Penalty Studio','PHYSICAL');
insert into public.services(id,category_id,name,slug,base_duration_minutes,base_price,buffer_before_minutes,buffer_after_minutes,minimum_people,maximum_people,minimum_booking_notice_minutes,maximum_booking_horizon_days)
values ('97900000-0000-0000-0000-000000000005','97900000-0000-0000-0000-000000000003','Penalty Service','penalty-service',120,1000,0,30,1,10,0,365);
insert into public.service_employees(id,service_id,employee_id) values ('97900000-0000-0000-0000-000000000006','97900000-0000-0000-0000-000000000005','97900000-0000-0000-0000-000000000002');
insert into public.service_resources(service_id,resource_id,is_required) values ('97900000-0000-0000-0000-000000000005','97900000-0000-0000-0000-000000000004',true);
insert into public.availability_rules(service_employee_id,weekday,start_local_time,end_local_time,slot_interval_minutes,is_active)
select '97900000-0000-0000-0000-000000000006',d,time '08:00',time '18:00',30,true from generate_series(0,6)d;
insert into public.service_change_policies(service_id,notice_hours,reschedule_first_penalty_type,reschedule_first_penalty_value,reschedule_repeat_penalty_type,reschedule_repeat_penalty_value,reschedule_late_penalty_type,reschedule_late_penalty_value,cancellation_early_penalty_type,cancellation_early_penalty_value,cancellation_late_penalty_type,cancellation_late_penalty_value,cancellation_early_refund_allowed,cancellation_early_credit_allowed,cancellation_late_refund_allowed,cancellation_late_credit_allowed,cancellation_credit_validity_days)
values ('97900000-0000-0000-0000-000000000005',48,'FIXED',100,'PERCENT',20,'PERCENT',20,'NONE',0,'PERCENT',20,true,true,true,true,90);

insert into public.appointments(id,public_code,service_id,service_employee_id,status,financial_status,start_at,end_at,core_start_at,core_end_at,duration_minutes,contracted_minutes,people_count,primary_customer_id,commercial_value)
values ('97900000-0000-0000-0000-000000000010','PENALTY-1','97900000-0000-0000-0000-000000000005','97900000-0000-0000-0000-000000000006','CONFIRMED','NOT_STARTED',((current_date+5)+time '10:00') at time zone 'America/Sao_Paulo',((current_date+5)+time '12:00') at time zone 'America/Sao_Paulo',((current_date+5)+time '10:00') at time zone 'America/Sao_Paulo',((current_date+5)+time '12:00') at time zone 'America/Sao_Paulo',120,120,1,'97900000-0000-0000-0000-000000000001',1000);
insert into public.resource_allocations(resource_id,appointment_id,allocation_type,status,occupied_range)
values ('97900000-0000-0000-0000-000000000004','97900000-0000-0000-0000-000000000010','APPOINTMENT','CONFIRMED',tstzrange(((current_date+5)+time '10:00') at time zone 'America/Sao_Paulo',((current_date+5)+time '12:30') at time zone 'America/Sao_Paulo','[)'));

select has_function('public','service_admin_register_reschedule_penalty_payment',array['uuid','text','text','uuid'],'admin penalty payment function exists');

create temporary table h as select public.service_admin_create_reschedule_hold('97900000-0000-0000-0000-000000000010',((current_date+10)+time '10:00') at time zone 'America/Sao_Paulo',now(),null) data;
select is((select data->>'policy_action_status' from h),'AWAITING_PENALTY_PAYMENT','penalty-bearing reschedule waits for payment');
select is((select (data->>'penalty_due_now')::numeric from h),100.00::numeric,'configured fixed penalty is due');

create temporary table p as select public.service_admin_register_reschedule_penalty_payment((select (data->>'policy_action_id')::uuid from h),'PIX','received by admin',null) data;
select is((select data->>'status' from p),'PAID','admin can register collected reschedule penalty');
select is((select payment_purpose from public.payment_transactions where id=(select (data->>'payment_transaction_id')::uuid from p)),'RESCHEDULE_PENALTY','penalty transaction is isolated by purpose');
select is((public.get_appointment_financial_summary('97900000-0000-0000-0000-000000000010')->>'contract_settled')::numeric,0.00::numeric,'penalty does not settle contract balance');
select is((public.get_appointment_financial_summary('97900000-0000-0000-0000-000000000010')->>'operational_penalties_cash_received')::numeric,100.00::numeric,'penalty cash remains visible operationally');
select is((select status from public.appointment_policy_actions where id=(select (data->>'policy_action_id')::uuid from h)),'PREVIEW','paid penalty unlocks reschedule apply state');
select throws_ok(
  $$select public.service_admin_create_reschedule_hold('97900000-0000-0000-0000-000000000010',((current_date+11)+time '10:00') at time zone 'America/Sao_Paulo',now(),null)$$,
  'P0001',
  'RESCHEDULE_PAID_PROPOSAL_MUST_BE_APPLIED_OR_REVERSED',
  'paid reschedule proposal cannot be replaced and orphan its penalty payment'
);
select is((public.service_admin_apply_reschedule((select (data->>'policy_action_id')::uuid from h),null)->>'status'),'APPLIED','reschedule applies after penalty payment');
select ok((public.service_admin_register_reschedule_penalty_payment((select (data->>'policy_action_id')::uuid from h),'PIX',null,null)->>'idempotent_replay')::boolean,'penalty payment replay is idempotent');

select * from finish();
rollback;