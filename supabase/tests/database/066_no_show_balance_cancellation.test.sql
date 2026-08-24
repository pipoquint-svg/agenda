begin;
create extension if not exists pgtap with schema extensions;
set local search_path=public,extensions;
select plan(6);
select set_config('agenda.test_now','2026-08-24 15:00:00-03',true);

insert into public.categories(id,name,slug)
values('96700000-0000-0000-0000-000000000001','No Show Balance','no-show-balance');
insert into public.employees(id,name)
values('96700000-0000-0000-0000-000000000002','No Show Employee');
insert into public.services(
 id,category_id,name,slug,base_duration_minutes,base_price,minimum_people,maximum_people,maximum_booking_horizon_days,
 duration_mode,booking_block_minutes,minimum_booking_blocks,maximum_booking_blocks,price_per_block,confirmation_percentage,max_reschedules,operation_scope
) values(
 '96700000-0000-0000-0000-000000000003','96700000-0000-0000-0000-000000000001','Locação BlackSheep','no-show-balance-rental',120,1000,1,10,365,
 'BLOCKS',30,2,8,250,50,2,'BLACKSHEEP'
);
insert into public.service_change_policies(service_id,notice_hours,reschedule_first_early_percent,reschedule_first_late_percent,reschedule_repeat_percent,cancellation_late_percent)
values('96700000-0000-0000-0000-000000000003',12,0,20,20,20);
insert into public.service_employees(id,service_id,employee_id)
values('96700000-0000-0000-0000-000000000004','96700000-0000-0000-0000-000000000003','96700000-0000-0000-0000-000000000002');
insert into public.customers(id,name,email,phone)
values('96700000-0000-0000-0000-000000000005','Cliente No Show','noshow@example.com','48999990003');
insert into public.appointments(
 id,public_code,service_id,service_employee_id,service_name_snapshot,primary_customer_id,status,financial_status,
 start_at,end_at,core_start_at,core_end_at,duration_minutes,contracted_minutes,pre_service_minutes,post_service_minutes,people_count,
 commercial_value,billing_mode_snapshot,confirmation_percentage_snapshot
) values(
 '96700000-0000-0000-0000-000000000006','BAL-NS-COLLECT','96700000-0000-0000-0000-000000000003','96700000-0000-0000-0000-000000000004','Locação BlackSheep','96700000-0000-0000-0000-000000000005','CONFIRMED','PARTIALLY_PAID',
 '2026-08-24 15:00:00-03','2026-08-24 17:30:00-03','2026-08-24 15:00:00-03','2026-08-24 17:00:00-03',150,120,0,30,1,1000,'CHECKOUT',50
);
insert into public.payment_transactions(appointment_id,transaction_type,method,provider,status,contract_amount_settled,cash_amount,payment_purpose)
values('96700000-0000-0000-0000-000000000006','CHARGE','CARD','MERCADO_PAGO','APPROVED',500,500,'CONTRACT');

select is(public.enqueue_due_rental_balance_collections(),1,'confirmed rental receives balance collection at start');
update public.appointments set status='NO_SHOW',no_show_at=public.balance_collection_clock(),updated_at=now()
where id='96700000-0000-0000-0000-000000000006';
select is((select status from public.appointment_balance_collections where appointment_id='96700000-0000-0000-0000-000000000006'),'PENDING','NO_SHOW does not cancel an already-issued balance collection');
select is((select count(*)::integer from public.integration_jobs where job_type='RENTAL_BALANCE_CANCEL_NO_SHOW' and payload_json->>'appointment_id'='96700000-0000-0000-0000-000000000006'),0,'NO_SHOW does not queue provider cancellation');
select throws_ok($$select public.service_mark_balance_collection_cancelled((select id from public.appointment_balance_collections where appointment_id='96700000-0000-0000-0000-000000000006'),'NO_SHOW',null,null,null,null)$$,'22023','BALANCE_COLLECTION_CANCEL_REASON_INVALID','NO_SHOW cannot be used as a cancellation reason for a balance collection');
select set_config('agenda.test_now','2026-08-26 15:01:00-03',true);
select is(public.expire_due_balance_collections(),1,'NO_SHOW balance collection expires after the 48h payment window');
select is((select count(*)::integer from public.appointment_overdue_balances where appointment_id='96700000-0000-0000-0000-000000000006'),1,'NO_SHOW enters delinquency after its balance collection expires');

select * from finish();
rollback;
