begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(14);

insert into public.customers (id, name, email)
values ('50000000-0000-0000-0000-000000000001', 'Policy Customer', 'policy@example.com');

insert into public.employees (id, name)
values ('50000000-0000-0000-0000-000000000002', 'Policy Employee');

insert into public.categories (id, name, slug)
values ('50000000-0000-0000-0000-000000000003', 'Policy', 'policy-test');

-- BlackSheep-style service: free first reschedule, 20% repeat/late,
-- early cancellation free, late cancellation 20%, refund or credit allowed.
insert into public.services (
  id, category_id, name, slug, base_duration_minutes, base_price,
  minimum_people, maximum_people
) values (
  '50000000-0000-0000-0000-000000000004',
  '50000000-0000-0000-0000-000000000003',
  'BlackSheep Policy Service', 'blacksheep-policy-service', 120, 1000, 1, 10
);

insert into public.service_employees (id, service_id, employee_id)
values (
  '50000000-0000-0000-0000-000000000005',
  '50000000-0000-0000-0000-000000000004',
  '50000000-0000-0000-0000-000000000002'
);

insert into public.service_change_policies (
  service_id,
  notice_hours,
  reschedule_first_penalty_type, reschedule_first_penalty_value,
  reschedule_repeat_penalty_type, reschedule_repeat_penalty_value,
  reschedule_late_penalty_type, reschedule_late_penalty_value,
  cancellation_early_penalty_type, cancellation_early_penalty_value,
  cancellation_late_penalty_type, cancellation_late_penalty_value,
  cancellation_early_refund_allowed, cancellation_early_credit_allowed,
  cancellation_late_refund_allowed, cancellation_late_credit_allowed,
  cancellation_credit_validity_days
) values (
  '50000000-0000-0000-0000-000000000004',
  48,
  'NONE', 0,
  'PERCENT', 20,
  'PERCENT', 20,
  'NONE', 0,
  'PERCENT', 20,
  true, true,
  true, true,
  90
);

insert into public.appointments (
  id, public_code, service_id, service_employee_id, status, financial_status,
  start_at, end_at, duration_minutes, people_count, primary_customer_id,
  commercial_value
) values (
  '50000000-0000-0000-0000-000000000006',
  'POLICY-BLACKSHEEP-1',
  '50000000-0000-0000-0000-000000000004',
  '50000000-0000-0000-0000-000000000005',
  'CONFIRMED', 'PARTIALLY_PAID',
  '2035-01-10 10:00:00-03', '2035-01-10 12:00:00-03',
  120, 1,
  '50000000-0000-0000-0000-000000000001',
  1000
);

insert into public.payment_transactions (
  appointment_id, transaction_type, method, provider, provider_payment_id,
  status, contract_amount_settled, cash_amount, paid_at
) values (
  '50000000-0000-0000-0000-000000000006',
  'CHARGE', 'PIX', 'MERCADO_PAGO', 'policy-pay-blacksheep',
  'APPROVED', 500, 500, '2035-01-01 10:00:00-03'
);

select is(
  (public.calculate_appointment_change_policy(
    '50000000-0000-0000-0000-000000000006',
    'RESCHEDULE',
    '2035-01-07 10:00:00-03'
  )->>'penalty_amount')::numeric,
  0.00::numeric,
  'BlackSheep first reschedule at least 48h before has no penalty'
);

insert into public.appointment_policy_actions (
  appointment_id, action_type, status, requested_at, original_start_at,
  requested_new_start_at, hours_before_start, notice_hours_snapshot,
  is_inside_notice_window, prior_customer_reschedules,
  contract_value_snapshot, net_paid_snapshot,
  penalty_type, penalty_value, penalty_amount, penalty_due_now,
  refund_allowed, credit_allowed
) values (
  '50000000-0000-0000-0000-000000000006',
  'RESCHEDULE', 'APPLIED',
  '2035-01-06 10:00:00-03',
  '2035-01-10 10:00:00-03',
  '2035-01-15 10:00:00-03',
  96, 48, false, 0, 1000, 500,
  'NONE', 0, 0, 0, false, false
);

select is(
  (public.calculate_appointment_change_policy(
    '50000000-0000-0000-0000-000000000006',
    'RESCHEDULE',
    '2035-01-07 10:00:00-03'
  )->>'penalty_due_now')::numeric,
  200.00::numeric,
  'BlackSheep repeat reschedule charges 20 percent immediately'
);

select is(
  (public.calculate_appointment_change_policy(
    '50000000-0000-0000-0000-000000000006',
    'RESCHEDULE',
    '2035-01-09 10:01:00-03'
  )->>'penalty_due_now')::numeric,
  200.00::numeric,
  'BlackSheep reschedule inside 48h charges 20 percent immediately'
);

select is(
  (public.calculate_appointment_change_policy(
    '50000000-0000-0000-0000-000000000006',
    'CANCEL',
    '2035-01-07 10:00:00-03'
  )->>'refundable_amount')::numeric,
  500.00::numeric,
  'BlackSheep early cancellation exposes full paid amount'
);

select ok(
  (public.calculate_appointment_change_policy(
    '50000000-0000-0000-0000-000000000006',
    'CANCEL',
    '2035-01-07 10:00:00-03'
  )->>'refund_allowed')::boolean,
  'BlackSheep early cancellation allows refund'
);

select is(
  (public.calculate_appointment_change_policy(
    '50000000-0000-0000-0000-000000000006',
    'CANCEL',
    '2035-01-09 10:01:00-03'
  )->>'penalty_amount')::numeric,
  200.00::numeric,
  'BlackSheep late cancellation retains 20 percent of contract value'
);

select is(
  (public.calculate_appointment_change_policy(
    '50000000-0000-0000-0000-000000000006',
    'CANCEL',
    '2035-01-09 10:01:00-03'
  )->>'refundable_amount')::numeric,
  300.00::numeric,
  'BlackSheep late cancellation leaves paid amount minus penalty'
);

insert into public.appointment_policy_actions (
  id, appointment_id, action_type, status, settlement_choice,
  requested_at, original_start_at, hours_before_start, notice_hours_snapshot,
  is_inside_notice_window, prior_customer_reschedules,
  contract_value_snapshot, net_paid_snapshot,
  penalty_type, penalty_value, penalty_amount, penalty_due_now,
  refund_allowed, credit_allowed, credit_validity_days_snapshot,
  refundable_amount, credit_amount, cancellation_penalty_outstanding
) values (
  '50000000-0000-0000-0000-000000000007',
  '50000000-0000-0000-0000-000000000006',
  'CANCEL', 'APPLIED', 'CREDIT',
  '2035-01-09 10:01:00-03', '2035-01-10 10:00:00-03',
  23.98, 48, true, 1, 1000, 500,
  'PERCENT', 20, 200, 0,
  true, true, 90, 300, 300, 0
);

select is(
  (select c.amount from public.issue_cancellation_credit_coupon('50000000-0000-0000-0000-000000000007') c),
  300.00::numeric,
  'BlackSheep cancellation credit equals paid amount minus penalty'
);

select ok(
  exists (
    select 1 from public.coupons c
    where c.source_appointment_id = '50000000-0000-0000-0000-000000000006'
      and c.source = 'CANCELLATION_CREDIT'
      and c.max_uses = 1
      and c.customer_id = '50000000-0000-0000-0000-000000000001'
      and c.valid_until > c.valid_from + interval '89 days'
      and c.valid_until <= c.valid_from + interval '91 days'
  ),
  'BlackSheep credit coupon is customer-bound, one-time, and about 90 days'
);

-- Sabrina-style service: rescheduling is always free; cancellation always
-- retains a fixed R$100; cash refund is disabled. Credit remains independently configurable.
insert into public.services (
  id, category_id, name, slug, base_duration_minutes, base_price,
  minimum_people, maximum_people
) values (
  '50000000-0000-0000-0000-000000000104',
  '50000000-0000-0000-0000-000000000003',
  'Sabrina Policy Service', 'sabrina-policy-service', 120, 1000, 1, 10
);

insert into public.service_employees (id, service_id, employee_id)
values (
  '50000000-0000-0000-0000-000000000105',
  '50000000-0000-0000-0000-000000000104',
  '50000000-0000-0000-0000-000000000002'
);

insert into public.service_change_policies (
  service_id,
  notice_hours,
  reschedule_first_penalty_type, reschedule_first_penalty_value,
  reschedule_repeat_penalty_type, reschedule_repeat_penalty_value,
  reschedule_late_penalty_type, reschedule_late_penalty_value,
  cancellation_early_penalty_type, cancellation_early_penalty_value,
  cancellation_late_penalty_type, cancellation_late_penalty_value,
  cancellation_early_refund_allowed, cancellation_early_credit_allowed,
  cancellation_late_refund_allowed, cancellation_late_credit_allowed,
  cancellation_credit_validity_days
) values (
  '50000000-0000-0000-0000-000000000104',
  48,
  'NONE', 0,
  'NONE', 0,
  'NONE', 0,
  'FIXED', 100,
  'FIXED', 100,
  false, true,
  false, true,
  90
);

insert into public.appointments (
  id, public_code, service_id, service_employee_id, status, financial_status,
  start_at, end_at, duration_minutes, people_count, primary_customer_id,
  commercial_value
) values (
  '50000000-0000-0000-0000-000000000106',
  'POLICY-SABRINA-1',
  '50000000-0000-0000-0000-000000000104',
  '50000000-0000-0000-0000-000000000105',
  'CONFIRMED', 'PARTIALLY_PAID',
  '2035-02-10 10:00:00-03', '2035-02-10 12:00:00-03',
  120, 1,
  '50000000-0000-0000-0000-000000000001',
  1000
);

insert into public.payment_transactions (
  appointment_id, transaction_type, method, provider, provider_payment_id,
  status, contract_amount_settled, cash_amount, paid_at
) values (
  '50000000-0000-0000-0000-000000000106',
  'CHARGE', 'PIX', 'MERCADO_PAGO', 'policy-pay-sabrina',
  'APPROVED', 500, 500, '2035-02-01 10:00:00-03'
);

select is(
  (public.calculate_appointment_change_policy(
    '50000000-0000-0000-0000-000000000106',
    'RESCHEDULE',
    '2035-02-09 10:01:00-03'
  )->>'penalty_amount')::numeric,
  0.00::numeric,
  'Sabrina late reschedule remains free'
);

insert into public.appointment_policy_actions (
  appointment_id, action_type, status, requested_at, original_start_at,
  requested_new_start_at, hours_before_start, notice_hours_snapshot,
  is_inside_notice_window, prior_customer_reschedules,
  contract_value_snapshot, net_paid_snapshot,
  penalty_type, penalty_value, penalty_amount, penalty_due_now,
  refund_allowed, credit_allowed
) values (
  '50000000-0000-0000-0000-000000000106',
  'RESCHEDULE', 'APPLIED',
  '2035-02-06 10:00:00-03',
  '2035-02-10 10:00:00-03',
  '2035-02-15 10:00:00-03',
  96, 48, false, 0, 1000, 500,
  'NONE', 0, 0, 0, false, false
);

select is(
  (public.calculate_appointment_change_policy(
    '50000000-0000-0000-0000-000000000106',
    'RESCHEDULE',
    '2035-02-07 10:00:00-03'
  )->>'penalty_amount')::numeric,
  0.00::numeric,
  'Sabrina repeat reschedule remains free'
);

select is(
  (public.calculate_appointment_change_policy(
    '50000000-0000-0000-0000-000000000106',
    'CANCEL',
    '2035-02-07 10:00:00-03'
  )->>'penalty_amount')::numeric,
  100.00::numeric,
  'Sabrina early cancellation retains fixed R$100'
);

select is(
  (public.calculate_appointment_change_policy(
    '50000000-0000-0000-0000-000000000106',
    'CANCEL',
    '2035-02-09 10:01:00-03'
  )->>'penalty_amount')::numeric,
  100.00::numeric,
  'Sabrina late cancellation also retains fixed R$100'
);

select ok(
  not (public.calculate_appointment_change_policy(
    '50000000-0000-0000-0000-000000000106',
    'CANCEL',
    '2035-02-07 10:00:00-03'
  )->>'refund_allowed')::boolean,
  'Sabrina cancellation does not offer cash refund'
);

select ok(
  (public.calculate_appointment_change_policy(
    '50000000-0000-0000-0000-000000000106',
    'CANCEL',
    '2035-02-07 10:00:00-03'
  )->>'credit_allowed')::boolean,
  'Sabrina cancellation can independently allow credit'
);

select * from finish();
rollback;
