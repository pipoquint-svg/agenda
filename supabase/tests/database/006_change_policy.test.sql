begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(8);

insert into public.customers (id, name, email)
values ('50000000-0000-0000-0000-000000000001', 'Policy Customer', 'policy@example.com');

insert into public.employees (id, name)
values ('50000000-0000-0000-0000-000000000002', 'Policy Employee');

insert into public.categories (id, name, slug)
values ('50000000-0000-0000-0000-000000000003', 'Policy', 'policy-test');

insert into public.services (
  id, category_id, name, slug, base_duration_minutes, base_price,
  minimum_people, maximum_people
) values (
  '50000000-0000-0000-0000-000000000004',
  '50000000-0000-0000-0000-000000000003',
  'Policy Service', 'policy-service', 120, 1000, 1, 10
);

insert into public.service_employees (id, service_id, employee_id)
values (
  '50000000-0000-0000-0000-000000000005',
  '50000000-0000-0000-0000-000000000004',
  '50000000-0000-0000-0000-000000000002'
);

insert into public.appointments (
  id, public_code, service_id, service_employee_id, status, financial_status,
  start_at, end_at, duration_minutes, people_count, primary_customer_id,
  commercial_value
) values (
  '50000000-0000-0000-0000-000000000006',
  'POLICY-TEST-1',
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
  'CHARGE', 'PIX', 'MERCADO_PAGO', 'policy-pay-1',
  'APPROVED', 500, 500, '2035-01-01 10:00:00-03'
);

select is(
  (public.calculate_appointment_change_policy(
    '50000000-0000-0000-0000-000000000006',
    'RESCHEDULE',
    '2035-01-07 10:00:00-03'
  )->>'penalty_amount')::numeric,
  0.00::numeric,
  'first reschedule at least 48h before has no penalty'
);

insert into public.appointment_policy_actions (
  appointment_id, action_type, status, requested_at, original_start_at,
  requested_new_start_at, hours_before_start, is_inside_notice_window,
  prior_customer_reschedules, contract_value_snapshot, net_paid_snapshot,
  penalty_percent, penalty_amount, penalty_due_now
) values (
  '50000000-0000-0000-0000-000000000006',
  'RESCHEDULE', 'APPLIED',
  '2035-01-06 10:00:00-03',
  '2035-01-10 10:00:00-03',
  '2035-01-15 10:00:00-03',
  96, false, 0, 1000, 500, 0, 0, 0
);

select is(
  (public.calculate_appointment_change_policy(
    '50000000-0000-0000-0000-000000000006',
    'RESCHEDULE',
    '2035-01-07 10:00:00-03'
  )->>'penalty_due_now')::numeric,
  200.00::numeric,
  'repeat reschedule charges 20 percent immediately'
);

select is(
  (public.calculate_appointment_change_policy(
    '50000000-0000-0000-0000-000000000006',
    'RESCHEDULE',
    '2035-01-09 10:01:00-03'
  )->>'penalty_due_now')::numeric,
  200.00::numeric,
  'reschedule inside 48h charges 20 percent immediately'
);

select is(
  (public.calculate_appointment_change_policy(
    '50000000-0000-0000-0000-000000000006',
    'CANCEL',
    '2035-01-07 10:00:00-03'
  )->>'refundable_amount')::numeric,
  500.00::numeric,
  'cancellation at least 48h before refunds all net paid'
);

select is(
  (public.calculate_appointment_change_policy(
    '50000000-0000-0000-0000-000000000006',
    'CANCEL',
    '2035-01-09 10:01:00-03'
  )->>'penalty_amount')::numeric,
  200.00::numeric,
  'late cancellation retains 20 percent of contract value'
);

select is(
  (public.calculate_appointment_change_policy(
    '50000000-0000-0000-0000-000000000006',
    'CANCEL',
    '2035-01-09 10:01:00-03'
  )->>'refundable_amount')::numeric,
  300.00::numeric,
  'late cancellation refunds paid amount minus 20 percent penalty'
);

insert into public.appointment_policy_actions (
  id, appointment_id, action_type, status, settlement_choice,
  requested_at, original_start_at, hours_before_start, is_inside_notice_window,
  prior_customer_reschedules, contract_value_snapshot, net_paid_snapshot,
  penalty_percent, penalty_amount, penalty_due_now,
  refundable_amount, credit_amount, cancellation_penalty_outstanding
) values (
  '50000000-0000-0000-0000-000000000007',
  '50000000-0000-0000-0000-000000000006',
  'CANCEL', 'APPLIED', 'CREDIT',
  '2035-01-09 10:01:00-03', '2035-01-10 10:00:00-03',
  23.98, true, 1, 1000, 500, 20, 200, 0, 300, 300, 0
);

select is(
  (select c.amount from public.issue_cancellation_credit_coupon('50000000-0000-0000-0000-000000000007') c),
  300.00::numeric,
  'late cancellation credit coupon equals paid amount minus penalty'
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
  'credit coupon is customer-bound, one-time, and valid for about 90 days'
);

select * from finish();
rollback;
