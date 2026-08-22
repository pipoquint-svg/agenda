begin;
create extension if not exists pgtap with schema extensions;
set local search_path=public,extensions;
select plan(17);

insert into public.customers(id,name,email) values
('60000000-0000-0000-0000-000000000001','Balance One','balance1@example.com'),
('60000000-0000-0000-0000-000000000002','Balance Two','balance2@example.com'),
('60000000-0000-0000-0000-000000000003','Balance Three','balance3@example.com');
insert into public.employees(id,name) values ('60000000-0000-0000-0000-000000000010','Balance Employee');
insert into public.categories(id,name,slug) values ('60000000-0000-0000-0000-000000000011','Balance','balance');
insert into public.services(id,category_id,name,slug,base_duration_minutes,base_price,minimum_people,maximum_people)
values ('60000000-0000-0000-0000-000000000012','60000000-0000-0000-0000-000000000011','Balance Service','balance-service',60,700,1,10);
insert into public.service_employees(id,service_id,employee_id)
values ('60000000-0000-0000-0000-000000000013','60000000-0000-0000-0000-000000000012','60000000-0000-0000-0000-000000000010');
insert into public.service_change_policies(service_id,notice_hours,reschedule_first_early_percent,reschedule_first_late_percent,reschedule_repeat_percent,cancellation_late_percent)
values ('60000000-0000-0000-0000-000000000012',48,0,20,30,30);

-- Mandatory excess cancellation example: R$800 customer funds on R$700 contract.
insert into public.appointments(id,public_code,service_id,service_employee_id,status,financial_status,start_at,end_at,duration_minutes,people_count,primary_customer_id,commercial_value,confirmed_at)
values ('60000000-0000-0000-0000-000000000020','BAL-CANCEL-EXCESS','60000000-0000-0000-0000-000000000012','60000000-0000-0000-0000-000000000013','CONFIRMED','PAID','2035-05-10 10:00:00-03','2035-05-10 11:00:00-03',60,1,'60000000-0000-0000-0000-000000000001',700,now());
insert into public.payment_transactions(appointment_id,transaction_type,method,provider,provider_payment_id,status,contract_amount_settled,cash_amount,paid_at,payment_purpose)
values ('60000000-0000-0000-0000-000000000020','CHARGE','PIX','MERCADO_PAGO','bal-pay-800','APPROVED',800,800,now(),'CONTRACT');

select is((public.calculate_reservation_change('60000000-0000-0000-0000-000000000020','CANCEL','2035-05-09 10:01:00-03','CLIENT',null)->>'penalty_retained')::numeric,210::numeric,'late cancellation retains 30 percent of R$700');
select is((public.calculate_reservation_change('60000000-0000-0000-0000-000000000020','CANCEL','2035-05-09 10:01:00-03','CLIENT',null)->>'excess_before')::numeric,100::numeric,'R$100 excess is customer-owned before cancellation');
select is((public.calculate_reservation_change('60000000-0000-0000-0000-000000000020','CANCEL','2035-05-09 10:01:00-03','CLIENT',null)->>'refund_due')::numeric,590::numeric,'mandatory example refunds R$490 contract plus R$100 excess = R$590');

select is((public.service_admin_cancel_appointment('60000000-0000-0000-0000-000000000020',null,'TEST','2035-05-09 10:01:00-03','CLIENT',null)->>'refund_amount')::numeric,590::numeric,'cancellation workflow defaults the R$590 return to refund');
select is((select settlement_choice from public.appointment_policy_actions where appointment_id='60000000-0000-0000-0000-000000000020' and action_type='CANCEL'),'REFUND','refund is preselected/default settlement');

select lives_ok($$select public.service_credit_customer_balance_from_return(
  '60000000-0000-0000-0000-000000000020',
  (select id from public.appointment_policy_actions where appointment_id='60000000-0000-0000-0000-000000000020' and action_type='CANCEL'),
  'CLIENT_TOKEN',null,'127.0.0.1'::inet,'pgTAP','req-balance-one',null
)$$,'explicit client choice can move refundable cancellation amount to customer balance');
select is(public.customer_balance_available('60000000-0000-0000-0000-000000000001'),590::numeric,'customer balance is R$590 and has no expiry deduction');
select ok(not has_column('public','customer_balance_movements','valid_until'),'customer balance has no validity/expiry field');

-- Integral application: all R$590 moves, even though only R$250 is due; R$340 becomes excess.
insert into public.appointments(id,public_code,service_id,service_employee_id,status,financial_status,start_at,end_at,duration_minutes,people_count,primary_customer_id,commercial_value,confirmed_at)
values ('60000000-0000-0000-0000-000000000021','BAL-APPLY-INTEGRAL','60000000-0000-0000-0000-000000000012','60000000-0000-0000-0000-000000000013','CONFIRMED','PARTIALLY_PAID','2035-06-10 10:00:00-03','2035-06-10 11:00:00-03',60,1,'60000000-0000-0000-0000-000000000001',500,now());
insert into public.payment_transactions(appointment_id,transaction_type,method,provider,provider_payment_id,status,contract_amount_settled,cash_amount,paid_at,payment_purpose)
values ('60000000-0000-0000-0000-000000000021','CHARGE','PIX','MERCADO_PAGO','bal-pay-250','APPROVED',250,250,now(),'CONTRACT');
select is((public.service_apply_customer_balance_to_appointment('60000000-0000-0000-0000-000000000021',null,'CLIENT_TOKEN',null,'127.0.0.1'::inet,'pgTAP','req-apply-integral',null)->>'amount_applied')::numeric,590::numeric,'balance application consumes the full available balance');
select is(public.customer_balance_available('60000000-0000-0000-0000-000000000001'),0::numeric,'no partial balance remains after integral application');
select is(public.appointment_returnable_excess('60000000-0000-0000-0000-000000000021'),340::numeric,'integral application creates R$340 customer-owned excess');
update public.appointments set status='COMPLETED' where id='60000000-0000-0000-0000-000000000021';
select is((public.service_finalize_appointment_excess('60000000-0000-0000-0000-000000000021',null,null,null,null,null,null,null)->>'settlement_choice'),'REFUND','final excess defaults to refund when customer does not choose balance');

-- Authorship is mandatory for choosing balance instead of refund.
insert into public.appointments(id,public_code,service_id,service_employee_id,status,financial_status,start_at,end_at,duration_minutes,people_count,primary_customer_id,commercial_value,confirmed_at)
values ('60000000-0000-0000-0000-000000000022','BAL-AUTHORSHIP','60000000-0000-0000-0000-000000000012','60000000-0000-0000-0000-000000000013','CONFIRMED','PARTIALLY_PAID','2035-07-10 10:00:00-03','2035-07-10 11:00:00-03',60,1,'60000000-0000-0000-0000-000000000002',700,now());
insert into public.payment_transactions(appointment_id,transaction_type,method,provider,provider_payment_id,status,contract_amount_settled,cash_amount,paid_at,payment_purpose)
values ('60000000-0000-0000-0000-000000000022','CHARGE','PIX','MERCADO_PAGO','bal-pay-350','APPROVED',350,350,now(),'CONTRACT');
perform public.service_admin_cancel_appointment('60000000-0000-0000-0000-000000000022',null,'TEST','2035-07-07 10:00:00-03','CLIENT',null);
select throws_ok($$select public.service_credit_customer_balance_from_return(
  '60000000-0000-0000-0000-000000000022',
  (select id from public.appointment_policy_actions where appointment_id='60000000-0000-0000-0000-000000000022' and action_type='CANCEL'),
  'CLIENT_TOKEN',null,null,'pgTAP','req-missing-ip',null
)$$,'P0001','BALANCE_AUTHORSHIP_EVIDENCE_REQUIRED','balance choice without authorship evidence is rejected');
perform public.service_credit_customer_balance_from_return('60000000-0000-0000-0000-000000000022',(select id from public.appointment_policy_actions where appointment_id='60000000-0000-0000-0000-000000000022' and action_type='CANCEL'),'CLIENT_TOKEN',null,'127.0.0.1'::inet,'pgTAP','req-balance-two',null);
select is((public.service_request_customer_balance_refund('60000000-0000-0000-0000-000000000002','CLIENT_TOKEN',null,'127.0.0.1'::inet,'pgTAP','req-refund-balance',null)->>'amount')::numeric,350::numeric,'customer may convert entire balance to refund at any time');
select is(public.customer_balance_available('60000000-0000-0000-0000-000000000002'),0::numeric,'pending balance refund reserves the entire liability');

-- Three client reschedules are lifetime-limited; OPERATION does not count.
insert into public.appointments(id,public_code,service_id,service_employee_id,status,financial_status,start_at,end_at,duration_minutes,people_count,primary_customer_id,commercial_value,confirmed_at)
values ('60000000-0000-0000-0000-000000000023','BAL-LIMIT','60000000-0000-0000-0000-000000000012','60000000-0000-0000-0000-000000000013','CONFIRMED','PARTIALLY_PAID','2035-08-10 10:00:00-03','2035-08-10 11:00:00-03',60,1,'60000000-0000-0000-0000-000000000003',700,now());
insert into public.appointment_policy_actions(appointment_id,action_type,status,original_start_at,hours_before_start,notice_hours_snapshot,is_inside_notice_window,contract_value_snapshot,net_paid_snapshot,penalty_type,penalty_value,penalty_amount,refundable_amount,change_origin)
select '60000000-0000-0000-0000-000000000023','RESCHEDULE','APPLIED','2035-08-10 10:00:00-03',100,48,false,700,350,'NONE',0,0,0,'CLIENT' from generate_series(1,3);
select throws_ok($$select public.enforce_appointment_reschedule_limit('60000000-0000-0000-0000-000000000023','CLIENT')$$,'P0001','CLIENT_RESCHEDULE_LIMIT_REACHED','fourth client reschedule is refused');
select lives_ok($$select public.enforce_appointment_reschedule_limit('60000000-0000-0000-0000-000000000023','OPERATION')$$,'operation-origin reschedule bypasses client lifetime limit');

select * from finish();
rollback;
