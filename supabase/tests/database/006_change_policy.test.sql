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

insert into public.services(
  id,category_id,name,slug,base_duration_minutes,base_price,minimum_people,maximum_people
) values (
  '50000000-0000-0000-0000-000000000004',
  '50000000-0000-0000-0000-000000000003',
  'Consolidated Policy Service','consolidated-policy-service',120,1000,1,10
);

insert into public.service_employees(id,service_id,employee_id)
values (
  '50000000-0000-0000-0000-000000000005',
  '50000000-0000-0000-0000-000000000004',
  '50000000-0000-0000-0000-000000000002'
);

-- Complete V2 contract, explicitly configured. No DB default supplies policy values.
insert into public.service_change_policies(
  service_id,notice_hours,
  cancellation_early_refund_allowed,cancellation_early_credit_allowed,
  cancellation_late_refund_allowed,cancellation_late_credit_allowed,
  cancellation_credit_validity_days,
  reschedule_first_early_percent,reschedule_first_late_percent,
  reschedule_repeat_percent,cancellation_late_percent
) values (
  '50000000-0000-0000-0000-000000000004',48,
  true,false,true,false,null,
  0,20,30,30
);

insert into public.appointments(
  id,public_code,service_id,service_employee_id,status,financial_status,
  start_at,end_at,duration_minutes,people_count,primary_customer_id,
  commercial_value,confirmed_at
) values (
  '50000000-0000-0000-0000-000000000006','POLICY-CONSOLIDATED-1',
  '50000000-0000-0000-0000-000000000004',
  '50000000-0000-0000-0000-000000000005',
  'CONFIRMED','PARTIALLY_PAID',
  '2035-01-10 10:00:00-03','2035-01-10 12:00:00-03',120,1,
  '50000000-0000-0000-0000-000000000001',1000,now()
);

insert into public.payment_transactions(
  appointment_id,transaction_type,method,provider,provider_payment_id,
  status,contract_amount_settled,cash_amount,paid_at,payment_purpose
) values (
  '50000000-0000-0000-0000-000000000006',
  'CHARGE','PIX','MERCADO_PAGO','policy-consolidated-pay-1',
  'APPROVED',500,500,now(),'CONTRACT'
);

select is(
  (select policy_json->>'snapshot_schema_version'
   from public.appointment_change_policy_snapshots
   where appointment_id='50000000-0000-0000-0000-000000000006'),
  'CONSOLIDATED_POLICY_V2',
  'new reservation freezes the consolidated policy schema'
);

select is(
  (public.calculate_appointment_change_policy(
    '50000000-0000-0000-0000-000000000006','RESCHEDULE','2035-01-07 10:00:00-03'
  )->>'penalty_amount')::numeric,
  0.00::numeric,
  'first client reschedule above 48h has zero penalty'
);

select is(
  (public.calculate_appointment_change_policy(
    '50000000-0000-0000-0000-000000000006','RESCHEDULE','2035-01-08 10:00:00-03'
  )->>'penalty_amount')::numeric,
  0.00::numeric,
  'exactly 48h before remains outside the penalty window'
);

select is(
  (public.calculate_appointment_change_policy(
    '50000000-0000-0000-0000-000000000006','RESCHEDULE','2035-01-09 10:01:00-03'
  )->>'penalty_amount')::numeric,
  200.00::numeric,
  'first client reschedule below 48h retains 20 percent of total contract'
);

select is(
  (public.calculate_appointment_change_policy(
    '50000000-0000-0000-0000-000000000006','RESCHEDULE','2035-01-09 10:01:00-03'
  )->>'penalty_calculated_on_total')::numeric,
  200.00::numeric,
  'penalty base is the full R$1000 reservation value, not the R$500 paid'
);

select is(
  (public.calculate_appointment_change_policy(
    '50000000-0000-0000-0000-000000000006','RESCHEDULE','2035-01-09 10:01:00-03'
  )->>'retained_amount')::numeric,
  200.00::numeric,
  'the 20 percent penalty is retained from the amount already paid'
);

select is(
  (public.calculate_appointment_change_policy(
    '50000000-0000-0000-0000-000000000006','RESCHEDULE','2035-01-09 10:01:00-03'
  )->>'penalty_due_now')::numeric,
  0.00::numeric,
  'consolidated reschedule never creates a separate penalty debt'
);

select is(
  (public.calculate_appointment_change_policy(
    '50000000-0000-0000-0000-000000000006','RESCHEDULE','2035-01-09 10:01:00-03'
  )->>'applicable_amount')::numeric,
  300.00::numeric,
  'R$500 paid minus R$200 retained leaves R$300 applicable to the new contract'
);

-- First applied client reschedule. Stage 5 will make CLIENT/OPERATION origin explicit;
-- this stage verifies recurrence precedence in the calculation engine.
insert into public.appointment_policy_actions(
  appointment_id,action_type,status,requested_at,original_start_at,
  requested_new_start_at,hours_before_start,notice_hours_snapshot,
  is_inside_notice_window,prior_customer_reschedules,
  contract_value_snapshot,net_paid_snapshot,
  penalty_type,penalty_value,penalty_amount,penalty_due_now,
  refund_allowed,credit_allowed
) values (
  '50000000-0000-0000-0000-000000000006','RESCHEDULE','APPLIED',
  '2035-01-01 10:00:00-03','2035-01-10 10:00:00-03','2035-01-20 10:00:00-03',
  216,48,false,0,1000,500,'NONE',0,0,0,false,false
);

select is(
  (public.calculate_appointment_change_policy(
    '50000000-0000-0000-0000-000000000006','RESCHEDULE','2034-12-31 10:00:00-03'
  )->>'penalty_amount')::numeric,
  300.00::numeric,
  'second client reschedule costs 30 percent even with ten days notice'
);

insert into public.appointment_policy_actions(
  appointment_id,action_type,status,requested_at,original_start_at,
  requested_new_start_at,hours_before_start,notice_hours_snapshot,
  is_inside_notice_window,prior_customer_reschedules,
  contract_value_snapshot,net_paid_snapshot,
  penalty_type,penalty_value,penalty_amount,penalty_due_now,
  refund_allowed,credit_allowed
) values (
  '50000000-0000-0000-0000-000000000006','RESCHEDULE','APPLIED',
  '2035-01-02 10:00:00-03','2035-01-20 10:00:00-03','2035-01-30 10:00:00-03',
  432,48,false,1,1000,500,'PERCENT',30,300,0,false,false
);

select is(
  (public.calculate_appointment_change_policy(
    '50000000-0000-0000-0000-000000000006','RESCHEDULE','2035-01-09 10:01:00-03'
  )->>'penalty_amount')::numeric,
  300.00::numeric,
  'third client reschedule also costs 30 percent'
);

select is(
  (public.calculate_appointment_change_policy(
    '50000000-0000-0000-0000-000000000006','CANCEL','2035-01-07 10:00:00-03'
  )->>'penalty_amount')::numeric,
  0.00::numeric,
  'cancellation above 48h ignores recurrence and has zero penalty'
);

select is(
  (public.calculate_appointment_change_policy(
    '50000000-0000-0000-0000-000000000006','CANCEL','2035-01-07 10:00:00-03'
  )->>'refundable_amount')::numeric,
  500.00::numeric,
  'early cancellation returns the full amount applied to the current contract'
);

select is(
  (public.calculate_appointment_change_policy(
    '50000000-0000-0000-0000-000000000006','CANCEL','2035-01-09 10:01:00-03'
  )->>'penalty_amount')::numeric,
  300.00::numeric,
  'late cancellation retains 30 percent of the R$1000 total'
);

select is(
  (public.calculate_appointment_change_policy(
    '50000000-0000-0000-0000-000000000006','CANCEL','2035-01-09 10:01:00-03'
  )->>'refundable_amount')::numeric,
  200.00::numeric,
  'mandatory R$1000/R$500 late-cancellation example refunds exactly R$200'
);

select is(
  (public.calculate_appointment_change_policy(
    '50000000-0000-0000-0000-000000000006','CANCEL','2035-01-09 10:01:00-03'
  )->>'cancellation_penalty_outstanding')::numeric,
  0.00::numeric,
  'penalty never creates residual debt'
);

select ok(
  (public.calculate_appointment_change_policy(
    '50000000-0000-0000-0000-000000000006','CANCEL','2035-01-09 10:01:00-03'
  )->>'penalty_amount')::numeric
  <=
  (public.calculate_appointment_change_policy(
    '50000000-0000-0000-0000-000000000006','CANCEL','2035-01-09 10:01:00-03'
  )->>'net_paid')::numeric,
  'retained penalty never exceeds money already paid'
);

select ok(
  not (public.calculate_appointment_change_policy(
    '50000000-0000-0000-0000-000000000006','CANCEL','2035-01-09 10:01:00-03'
  )->>'credit_allowed')::boolean,
  'V2 does not automatically offer the legacy expiring cancellation credit'
);

-- Mandatory hand-checkable R$100 example.
insert into public.services(
  id,category_id,name,slug,base_duration_minutes,base_price,minimum_people,maximum_people
) values (
  '50000000-0000-0000-0000-000000000104',
  '50000000-0000-0000-0000-000000000003',
  'R100 Policy Service','r100-policy-service',60,100,1,10
);
insert into public.service_employees(id,service_id,employee_id)
values (
  '50000000-0000-0000-0000-000000000105',
  '50000000-0000-0000-0000-000000000104',
  '50000000-0000-0000-0000-000000000002'
);
insert into public.service_change_policies(
  service_id,notice_hours,
  cancellation_early_refund_allowed,cancellation_early_credit_allowed,
  cancellation_late_refund_allowed,cancellation_late_credit_allowed,
  cancellation_credit_validity_days,
  reschedule_first_early_percent,reschedule_first_late_percent,
  reschedule_repeat_percent,cancellation_late_percent
) values (
  '50000000-0000-0000-0000-000000000104',48,
  true,false,true,false,null,0,20,30,30
);
insert into public.appointments(
  id,public_code,service_id,service_employee_id,status,financial_status,
  start_at,end_at,duration_minutes,people_count,primary_customer_id,
  commercial_value,confirmed_at
) values (
  '50000000-0000-0000-0000-000000000106','POLICY-R100-1',
  '50000000-0000-0000-0000-000000000104',
  '50000000-0000-0000-0000-000000000105',
  'CONFIRMED','PAID','2035-03-10 10:00:00-03','2035-03-10 11:00:00-03',60,1,
  '50000000-0000-0000-0000-000000000001',100,now()
);
insert into public.payment_transactions(
  appointment_id,transaction_type,method,provider,provider_payment_id,
  status,contract_amount_settled,cash_amount,paid_at,payment_purpose
) values (
  '50000000-0000-0000-0000-000000000106','CHARGE','PIX','MERCADO_PAGO',
  'policy-r100-pay','APPROVED',100,100,now(),'CONTRACT'
);

select is(
  (public.calculate_appointment_change_policy(
    '50000000-0000-0000-0000-000000000106','RESCHEDULE','2035-03-09 10:01:00-03',100
  )->>'penalty_amount')::numeric,
  20.00::numeric,
  'R$100 paid in full, first late reschedule: penalty is exactly R$20'
);

select is(
  (public.calculate_appointment_change_policy(
    '50000000-0000-0000-0000-000000000106','RESCHEDULE','2035-03-09 10:01:00-03',100
  )->>'difference_to_pay')::numeric,
  20.00::numeric,
  'R$80 remains applicable to a new R$100 booking, so difference is exactly R$20'
);

select is(
  (public.calculate_appointment_change_policy(
    '50000000-0000-0000-0000-000000000106','RESCHEDULE','2035-03-09 10:01:00-03',60
  )->>'retained_excess')::numeric,
  20.00::numeric,
  'if the new booking costs R$60, the R$20 excess is tracked for later settlement'
);

select * from finish();
rollback;
