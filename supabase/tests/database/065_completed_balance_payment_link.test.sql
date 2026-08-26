begin;
create extension if not exists pgtap with schema extensions;
set local search_path=public,extensions;
select plan(4);

insert into public.categories(id,name,slug)
values('96600000-0000-0000-0000-000000000001','Completed Balance','completed-balance');
insert into public.employees(id,name)
values('96600000-0000-0000-0000-000000000002','Completed Balance Employee');
insert into public.services(
 id,category_id,name,slug,base_duration_minutes,base_price,minimum_people,maximum_people,maximum_booking_horizon_days,
 duration_mode,booking_block_minutes,minimum_booking_blocks,maximum_booking_blocks,price_per_block,confirmation_percentage,max_reschedules,operation_scope
) values(
 '96600000-0000-0000-0000-000000000003','96600000-0000-0000-0000-000000000001','Locação BlackSheep','completed-balance-rental',120,1000,1,10,365,
 'BLOCKS',30,2,8,250,50,2,'BLACKSHEEP'
);
insert into public.service_change_policies(service_id,notice_hours,reschedule_first_early_percent,reschedule_first_late_percent,reschedule_repeat_percent,cancellation_late_percent)
values('96600000-0000-0000-0000-000000000003',12,0,20,20,20);
insert into public.service_employees(id,service_id,employee_id)
values('96600000-0000-0000-0000-000000000004','96600000-0000-0000-0000-000000000003','96600000-0000-0000-0000-000000000002');
insert into public.customers(id,name,email,phone)
values('96600000-0000-0000-0000-000000000005','Cliente Completed','completed@example.com','48999990002');

insert into public.appointments(
 id,public_code,service_id,service_employee_id,service_name_snapshot,primary_customer_id,status,financial_status,
 start_at,end_at,core_start_at,core_end_at,duration_minutes,contracted_minutes,pre_service_minutes,post_service_minutes,people_count,
 commercial_value,billing_mode_snapshot,confirmation_percentage_snapshot
) values(
 '96600000-0000-0000-0000-000000000006','BAL-COMP','96600000-0000-0000-0000-000000000003','96600000-0000-0000-0000-000000000004','Locação BlackSheep','96600000-0000-0000-0000-000000000005','COMPLETED','PARTIALLY_PAID',
 current_timestamp - interval '3 hours',current_timestamp - interval '30 minutes',current_timestamp - interval '3 hours',current_timestamp - interval '1 hour',150,120,0,30,1,1000,'CHECKOUT',50
);
insert into public.payment_transactions(appointment_id,transaction_type,method,provider,status,contract_amount_settled,cash_amount,payment_purpose)
values('96600000-0000-0000-0000-000000000006','CHARGE','CARD','MERCADO_PAGO','APPROVED',500,500,'CONTRACT');

insert into public.appointment_balance_collections(
 id,appointment_id,sequence,source,status,amount_snapshot,issued_at,expires_at
) values(
 '96600000-0000-0000-0000-000000000007','96600000-0000-0000-0000-000000000006',1,'AUTO_START','PENDING',500,
 current_timestamp - interval '1 hour',current_timestamp + interval '47 hours'
);

create temporary table test_completed_balance_token as
select public.service_verify_balance_collection_email(
  '96600000-0000-0000-0000-000000000007',
  'completed@example.com'
) as payload;

select lives_ok(
  $$select public.service_create_payment_intent_by_token(
    (select payload->>'access_token' from test_completed_balance_token),
    'FULL','CARD','completedBalance001'
  )$$,
  'valid 48h balance link remains payable after appointment becomes COMPLETED'
);
select is(
  (select contract_amount_settled from public.payment_transactions where balance_collection_id='96600000-0000-0000-0000-000000000007' order by created_at desc limit 1),
  500::numeric,
  'completed appointment intent uses current open balance'
);
select is(
  (select payment_discount_amount from public.payment_transactions where balance_collection_id='96600000-0000-0000-0000-000000000007' order by created_at desc limit 1),
  0::numeric,
  'card balance payment has no PIX discount'
);
select is(
  (select status from public.appointment_balance_collections where id='96600000-0000-0000-0000-000000000007'),
  'PENDING',
  'creating the provider intent does not prematurely mark collection paid'
);

select * from finish();
rollback;
