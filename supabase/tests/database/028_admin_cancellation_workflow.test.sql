begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(14);

insert into public.customers(id, name, email)
values ('97500000-0000-0000-0000-000000000001', 'Cancellation Customer', 'cancel@example.com');

insert into public.employees(id, name)
values ('97500000-0000-0000-0000-000000000002', 'Cancellation Employee');

insert into public.categories(id, name, slug)
values ('97500000-0000-0000-0000-000000000003', 'Cancellation Test', 'cancellation-workflow-test');

insert into public.resources(id, name, resource_type)
values ('97500000-0000-0000-0000-000000000004', 'Cancellation Studio', 'PHYSICAL');

insert into public.services(
  id, category_id, name, slug, base_duration_minutes, base_price,
  minimum_people, maximum_people
) values (
  '97500000-0000-0000-0000-000000000005',
  '97500000-0000-0000-0000-000000000003',
  'Cancellation Service', 'cancellation-service', 120, 1000, 1, 10
);

insert into public.service_employees(id, service_id, employee_id)
values (
  '97500000-0000-0000-0000-000000000006',
  '97500000-0000-0000-0000-000000000005',
  '97500000-0000-0000-0000-000000000002'
);

insert into public.service_change_policies(
  service_id, notice_hours,
  reschedule_first_penalty_type, reschedule_first_penalty_value,
  reschedule_repeat_penalty_type, reschedule_repeat_penalty_value,
  reschedule_late_penalty_type, reschedule_late_penalty_value,
  cancellation_early_penalty_type, cancellation_early_penalty_value,
  cancellation_late_penalty_type, cancellation_late_penalty_value,
  cancellation_early_refund_allowed, cancellation_early_credit_allowed,
  cancellation_late_refund_allowed, cancellation_late_credit_allowed,
  cancellation_credit_validity_days
) values (
  '97500000-0000-0000-0000-000000000005', 48,
  'NONE',0,'PERCENT',20,'PERCENT',20,
  'NONE',0,'PERCENT',20,
  true,true,true,true,90
);

insert into public.appointments(
  id, public_code, service_id, service_employee_id, status, financial_status,
  start_at, end_at, duration_minutes, people_count, primary_customer_id, commercial_value
) values (
  '97500000-0000-0000-0000-000000000010', 'CANCEL-CREDIT-1',
  '97500000-0000-0000-0000-000000000005', '97500000-0000-0000-0000-000000000006',
  'CONFIRMED', 'PARTIALLY_PAID',
  '2035-02-10 10:00:00-03', '2035-02-10 12:00:00-03', 120, 1,
  '97500000-0000-0000-0000-000000000001', 1000
), (
  '97500000-0000-0000-0000-000000000020', 'CANCEL-REFUND-1',
  '97500000-0000-0000-0000-000000000005', '97500000-0000-0000-0000-000000000006',
  'CONFIRMED', 'PARTIALLY_PAID',
  '2035-02-11 10:00:00-03', '2035-02-11 12:00:00-03', 120, 1,
  '97500000-0000-0000-0000-000000000001', 1000
);

insert into public.resource_allocations(
  id, resource_id, appointment_id, allocation_type, status, occupied_range
) values (
  '97500000-0000-0000-0000-000000000011',
  '97500000-0000-0000-0000-000000000004',
  '97500000-0000-0000-0000-000000000010',
  'APPOINTMENT','CONFIRMED',
  tstzrange('2035-02-10 10:00:00-03','2035-02-10 12:30:00-03','[)')
), (
  '97500000-0000-0000-0000-000000000021',
  '97500000-0000-0000-0000-000000000004',
  '97500000-0000-0000-0000-000000000020',
  'APPOINTMENT','CONFIRMED',
  tstzrange('2035-02-11 10:00:00-03','2035-02-11 12:30:00-03','[)')
);

insert into public.payment_transactions(
  appointment_id, transaction_type, method, provider, provider_payment_id,
  status, contract_amount_settled, cash_amount, paid_at
) values
  ('97500000-0000-0000-0000-000000000010','CHARGE','PIX','MERCADO_PAGO','cancel-approved-credit','APPROVED',500,500,'2035-02-01 10:00:00-03'),
  ('97500000-0000-0000-0000-000000000010','CHARGE','CARD','MERCADO_PAGO','cancel-pending-credit','PENDING',100,100,null),
  ('97500000-0000-0000-0000-000000000020','CHARGE','PIX','MERCADO_PAGO','cancel-approved-refund','APPROVED',500,500,'2035-02-01 10:00:00-03');

select has_function(
  'public', 'service_admin_cancel_appointment',
  array['uuid','text','text','timestamp with time zone','uuid'],
  'transactional admin cancellation function exists'
);

select throws_ok(
  $$ select public.service_admin_cancel_appointment(
    '97500000-0000-0000-0000-000000000010', null, 'CLIENT_REQUEST',
    '2035-02-07 10:00:00-03', null
  ) $$,
  'P0001','CANCELLATION_SETTLEMENT_CHOICE_REQUIRED',
  'eligible paid cancellation requires explicit refund or credit choice'
);

select is(
  (select status::text from public.appointments where id = '97500000-0000-0000-0000-000000000010'),
  'CONFIRMED',
  'failed validation leaves appointment untouched'
);

select is(
  (public.service_admin_cancel_appointment(
    '97500000-0000-0000-0000-000000000010', 'CREDIT', 'CLIENT_REQUEST',
    '2035-02-07 10:00:00-03', null
  )->>'status'),
  'CANCELLED',
  'credit cancellation applies operational cancellation'
);

select is(
  (select status::text from public.resource_allocations where id = '97500000-0000-0000-0000-000000000011'),
  'CANCELLED',
  'cancellation immediately releases appointment resource allocation'
);

select is(
  (select status from public.payment_transactions where provider_payment_id = 'cancel-pending-credit'),
  'EXPIRED',
  'pending charge is expired when appointment is cancelled'
);

select is(
  (select status from public.appointment_policy_actions where appointment_id = '97500000-0000-0000-0000-000000000010' and action_type = 'CANCEL'),
  'CREDIT_ISSUED',
  'credit settlement action records issued-credit state'
);

select is(
  (select discount_value from public.coupons where source_appointment_id = '97500000-0000-0000-0000-000000000010'),
  500.00::numeric(12,2),
  'credit coupon equals eligible paid amount'
);

select ok(
  exists (
    select 1 from public.integration_jobs
    where job_type = 'GOOGLE_APPOINTMENT_SYNC'
      and entity_id = '97500000-0000-0000-0000-000000000010'
      and payload_json->>'reason' = 'APPOINTMENT_CANCELLED'
  ),
  'cancellation enqueues Google desired-state sync'
);

select ok(
  (public.service_admin_cancel_appointment(
    '97500000-0000-0000-0000-000000000010', 'CREDIT', 'REPLAY',
    '2035-02-07 10:01:00-03', null
  )->>'already_cancelled')::boolean,
  'repeated admin cancellation is idempotent'
);

select is(
  (select count(*)::integer from public.coupons where source_appointment_id = '97500000-0000-0000-0000-000000000010'),
  1,
  'idempotent replay does not issue a second credit coupon'
);

select is(
  (public.service_admin_cancel_appointment(
    '97500000-0000-0000-0000-000000000020', 'REFUND', 'CLIENT_REQUEST',
    '2035-02-08 10:00:00-03', null
  )->>'policy_action_status'),
  'PENDING_REFUND',
  'cash refund cancellation remains pending until provider/manual refund succeeds'
);

select is(
  (select count(*)::integer from public.payment_transactions where appointment_id = '97500000-0000-0000-0000-000000000020' and transaction_type = 'REFUND'),
  0,
  'workflow never fabricates a refund transaction before provider confirmation'
);

select ok(
  exists (
    select 1 from public.audit_logs
    where entity_type = 'APPOINTMENT'
      and entity_id = '97500000-0000-0000-0000-000000000020'
      and action = 'APPOINTMENT_CANCELLED'
  ),
  'administrative cancellation is written to audit log'
);

select * from finish();
rollback;
