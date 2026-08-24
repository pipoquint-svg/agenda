begin;
create extension if not exists pgtap with schema extensions;
set local search_path=public,extensions;
select plan(29);

select set_config('agenda.test_now','2026-08-24 15:00:00-03',true);

insert into auth.users(id,email,created_at,updated_at)
values('96500000-0000-0000-0000-000000000001','finance-test@example.com',now(),now());
insert into public.admin_users(id,auth_user_id,display_name,role)
values('96500000-0000-0000-0000-000000000002','96500000-0000-0000-0000-000000000001','Finance Test','FINANCE');

insert into public.categories(id,name,slug) values('96500000-0000-0000-0000-000000000003','Balance Test','balance-test');
insert into public.employees(id,name) values('96500000-0000-0000-0000-000000000004','Balance Employee');
insert into public.services(
 id,category_id,name,slug,base_duration_minutes,base_price,minimum_people,maximum_people,maximum_booking_horizon_days,
 duration_mode,booking_block_minutes,minimum_booking_blocks,maximum_booking_blocks,price_per_block,confirmation_percentage,max_reschedules,operation_scope
) values(
 '96500000-0000-0000-0000-000000000005','96500000-0000-0000-0000-000000000003','Locação BlackSheep','balance-rental',120,1000,1,10,365,
 'BLOCKS',30,2,8,250,50,2,'BLACKSHEEP'
);
insert into public.service_change_policies(service_id,notice_hours,reschedule_first_early_percent,reschedule_first_late_percent,reschedule_repeat_percent,cancellation_late_percent)
values('96500000-0000-0000-0000-000000000005',12,0,20,20,20);
insert into public.service_employees(id,service_id,employee_id)
values('96500000-0000-0000-0000-000000000006','96500000-0000-0000-0000-000000000005','96500000-0000-0000-0000-000000000004');
insert into public.customers(id,name,email,phone)
values('96500000-0000-0000-0000-000000000007','Cliente Saldo','saldo@example.com','48999990001');

insert into public.appointments(
 id,public_code,service_id,service_employee_id,service_name_snapshot,primary_customer_id,status,financial_status,
 start_at,end_at,core_start_at,core_end_at,duration_minutes,contracted_minutes,pre_service_minutes,post_service_minutes,people_count,
 commercial_value,billing_mode_snapshot,confirmation_percentage_snapshot
) values(
 '96500000-0000-0000-0000-000000000008','BAL-001','96500000-0000-0000-0000-000000000005','96500000-0000-0000-0000-000000000006','Locação BlackSheep','96500000-0000-0000-0000-000000000007','CONFIRMED','PARTIAL',
 '2026-08-24 15:00:00-03','2026-08-24 17:30:00-03','2026-08-24 15:00:00-03','2026-08-24 17:00:00-03',150,120,0,30,1,1000,'CHECKOUT',50
);
insert into public.payment_transactions(appointment_id,transaction_type,method,provider,status,contract_amount_settled,cash_amount,payment_purpose)
values('96500000-0000-0000-0000-000000000008','CHARGE','CARD','MERCADO_PAGO','APPROVED',500,500,'CONTRACT');

select is(public.enqueue_due_rental_balance_collections(),1,'start-time worker creates one balance collection');
select is((select status from public.appointment_balance_collections where appointment_id='96500000-0000-0000-0000-000000000008'),'PENDING','new collection is pending');
select is((select amount_snapshot from public.appointment_balance_collections where appointment_id='96500000-0000-0000-0000-000000000008'),500.00::numeric,'collection snapshots actual open balance');
select is((select extract(epoch from (expires_at-issued_at))::integer from public.appointment_balance_collections where appointment_id='96500000-0000-0000-0000-000000000008'),172800,'collection link is exactly 48 hours');
select is(public.enqueue_due_rental_balance_collections(),0,'worker is idempotent for an existing collection');
select throws_ok($$select public.service_admin_reissue_balance_collection('96500000-0000-0000-0000-000000000008','96500000-0000-0000-0000-000000000002')$$,'P0001','BALANCE_COLLECTION_STILL_ACTIVE','server refuses reissue while prior collection is live');

select set_config('agenda.test_now','2026-08-26 16:01:00-03',true);
select is(public.expire_due_balance_collections(),1,'collection expires after 48 hours');
select is((select status from public.appointment_balance_collections where appointment_id='96500000-0000-0000-0000-000000000008' and sequence=1),'EXPIRED','expired collection has terminal state');
select is((select count(*)::integer from public.appointment_overdue_balances where appointment_id='96500000-0000-0000-0000-000000000008'),1,'expired serviced checkout reservation enters overdue filter');
select is((public.service_admin_reissue_balance_collection('96500000-0000-0000-0000-000000000008','96500000-0000-0000-0000-000000000002')->>'sequence')::integer,2,'terminal collection can be reissued');
select is((select status from public.appointment_balance_collections where appointment_id='96500000-0000-0000-0000-000000000008' and sequence=2),'PENDING','reissue creates a fresh pending collection');

select is((public.service_record_manual_contract_payment('96500000-0000-0000-0000-000000000008','96500000-0000-0000-0000-000000000002',500,'CASH','127.0.0.1','pgTAP','request-1')->>'settled')::boolean,true,'cash payment can settle remaining contract balance');
select is((select payment_discount_amount from public.payment_transactions where appointment_id='96500000-0000-0000-0000-000000000008' and provider='MANUAL' order by created_at desc limit 1),0::numeric,'manual payment never receives PIX discount');

-- NO_SHOW is financially treated as a performed BlackSheep rental.
insert into public.appointments(
 id,public_code,service_id,service_employee_id,service_name_snapshot,primary_customer_id,status,financial_status,
 start_at,end_at,core_start_at,core_end_at,duration_minutes,contracted_minutes,pre_service_minutes,post_service_minutes,people_count,
 commercial_value,billing_mode_snapshot,confirmation_percentage_snapshot
) values(
 '96500000-0000-0000-0000-000000000009','BAL-NS','96500000-0000-0000-0000-000000000005','96500000-0000-0000-0000-000000000006','Locação BlackSheep','96500000-0000-0000-0000-000000000007','NO_SHOW','PARTIAL',
 '2026-08-26 15:00:00-03','2026-08-26 17:30:00-03','2026-08-26 15:00:00-03','2026-08-26 17:00:00-03',150,120,0,30,1,1000,'CHECKOUT',50
);
select is(public.enqueue_due_rental_balance_collections(),1,'NO_SHOW creates automatic balance collection because rental is considered performed');
select is((select status from public.appointment_balance_collections where appointment_id='96500000-0000-0000-0000-000000000009'),'PENDING','NO_SHOW collection remains payable');

select set_config('agenda.test_now','2026-08-28 16:02:00-03',true);
select is(public.expire_due_balance_collections(),2,'due collections expire, including NO_SHOW balance collection');
select is((select count(*)::integer from public.appointment_overdue_balances where appointment_id='96500000-0000-0000-0000-000000000009'),1,'NO_SHOW with expired balance collection enters overdue filter');

-- INVOICE has its own billing lifecycle and is excluded.
insert into public.appointments(
 id,public_code,service_id,service_employee_id,service_name_snapshot,primary_customer_id,status,financial_status,
 start_at,end_at,core_start_at,core_end_at,duration_minutes,contracted_minutes,pre_service_minutes,post_service_minutes,people_count,
 commercial_value,billing_mode_snapshot,confirmation_percentage_snapshot
) values(
 '96500000-0000-0000-0000-000000000010','BAL-INV','96500000-0000-0000-0000-000000000005','96500000-0000-0000-0000-000000000006','Locação BlackSheep','96500000-0000-0000-0000-000000000007','CONFIRMED','PENDING',
 '2026-08-28 15:00:00-03','2026-08-28 17:30:00-03','2026-08-28 15:00:00-03','2026-08-28 17:00:00-03',150,120,0,30,1,1000,'INVOICE',50
);
select is(public.enqueue_due_rental_balance_collections(),0,'INVOICE reservation does not create automatic balance collection');
select is((select count(*)::integer from public.appointment_overdue_balances where appointment_id='96500000-0000-0000-0000-000000000010'),0,'INVOICE reservation is excluded from overdue filter');

-- A provider payment arriving after another payment settled the contract is quarantined as excess, not applied again.
insert into public.payment_transactions(id,appointment_id,transaction_type,method,provider,provider_payment_id,status,contract_amount_settled,cash_amount,payment_purpose,balance_collection_id)
values('96500000-0000-0000-0000-000000000011','96500000-0000-0000-0000-000000000008','CHARGE','PIX','MERCADO_PAGO','late-order','PENDING',500,500,'CONTRACT',(select id from public.appointment_balance_collections where appointment_id='96500000-0000-0000-0000-000000000008' and sequence=2));
update public.payment_transactions set status='APPROVED' where id='96500000-0000-0000-0000-000000000011';
select is((select contract_amount_settled from public.payment_transactions where id='96500000-0000-0000-0000-000000000011'),0::numeric,'second balance payment is not applied to contract');
select is((select count(*)::integer from public.balance_collection_divergences where payment_transaction_id='96500000-0000-0000-0000-000000000011' and divergence_type='DUPLICATE_BALANCE_PAYMENT'),1,'second balance payment creates administrative divergence');

-- Partial in-person payment cancels the old collection state and permits a reissue for the reduced balance.
select set_config('agenda.test_now','2026-08-30 10:00:00-03',true);
insert into public.appointments(
 id,public_code,service_id,service_employee_id,service_name_snapshot,primary_customer_id,status,financial_status,
 start_at,end_at,core_start_at,core_end_at,duration_minutes,contracted_minutes,pre_service_minutes,post_service_minutes,people_count,
 commercial_value,billing_mode_snapshot,confirmation_percentage_snapshot
) values(
 '96500000-0000-0000-0000-000000000012','BAL-PART','96500000-0000-0000-0000-000000000005','96500000-0000-0000-0000-000000000006','Locação BlackSheep','96500000-0000-0000-0000-000000000007','CONFIRMED','PARTIAL',
 '2026-08-30 10:00:00-03','2026-08-30 12:30:00-03','2026-08-30 10:00:00-03','2026-08-30 12:00:00-03',150,120,0,30,1,1000,'CHECKOUT',50
);
insert into public.payment_transactions(appointment_id,transaction_type,method,provider,status,contract_amount_settled,cash_amount,payment_purpose)
values('96500000-0000-0000-0000-000000000012','CHARGE','CARD','MERCADO_PAGO','APPROVED',500,500,'CONTRACT');
select is(public.enqueue_due_rental_balance_collections(),1,'partial-payment scenario starts with one live collection');
select is((public.service_record_manual_contract_payment('96500000-0000-0000-0000-000000000012','96500000-0000-0000-0000-000000000002',100,'CASH','127.0.0.1','pgTAP','request-partial')->>'balance_after')::numeric,400::numeric,'partial in-person payment immediately reduces contract balance');
select is((public.service_mark_balance_collection_cancelled((select id from public.appointment_balance_collections where appointment_id='96500000-0000-0000-0000-000000000012' and sequence=1),'PARTIAL','96500000-0000-0000-0000-000000000002','127.0.0.1','pgTAP','request-partial-cancel')->>'status'),'CANCELLED_PARTIAL_PAYMENT','partial payment gives old collection an explicit terminal state');
select is((public.service_admin_reissue_balance_collection('96500000-0000-0000-0000-000000000012','96500000-0000-0000-0000-000000000002')->>'amount')::numeric,400::numeric,'partial payment reissue snapshots the new reduced balance');

select set_config('agenda.test_now','2026-09-01 10:01:00-03',true);
select is(public.expire_due_balance_collections(),1,'first administrative reissue can expire');
select is((public.service_admin_reissue_balance_collection('96500000-0000-0000-0000-000000000012','96500000-0000-0000-0000-000000000002')->>'sequence')::integer,3,'second administrative reissue is allowed');
select set_config('agenda.test_now','2026-09-03 10:02:00-03',true);
select is(public.expire_due_balance_collections(),1,'second administrative reissue can expire');
select throws_ok($$select public.service_admin_reissue_balance_collection('96500000-0000-0000-0000-000000000012','96500000-0000-0000-0000-000000000002')$$,'P0001','BALANCE_COLLECTION_REISSUE_LIMIT_REACHED','third administrative reissue is refused by the server');

select * from finish();
rollback;
