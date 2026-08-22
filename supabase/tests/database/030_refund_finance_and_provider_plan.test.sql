begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(19);

insert into public.customers(id, name, email)
values ('97700000-0000-0000-0000-000000000001', 'Refund Customer', 'refund@example.com');

insert into public.employees(id, name)
values ('97700000-0000-0000-0000-000000000002', 'Refund Employee');

insert into public.categories(id, name, slug)
values ('97700000-0000-0000-0000-000000000003', 'Refund Test', 'refund-test');

insert into public.services(
  id, category_id, name, slug, base_duration_minutes, base_price,
  minimum_people, maximum_people
) values (
  '97700000-0000-0000-0000-000000000004',
  '97700000-0000-0000-0000-000000000003',
  'Refund Service', 'refund-service', 120, 1000, 1, 10
);

insert into public.service_employees(id, service_id, employee_id)
values (
  '97700000-0000-0000-0000-000000000005',
  '97700000-0000-0000-0000-000000000004',
  '97700000-0000-0000-0000-000000000002'
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
  '97700000-0000-0000-0000-000000000004', 48,
  'NONE',0,'NONE',0,'NONE',0,
  'NONE',0,'NONE',0,
  true,true,true,true,90
);

insert into public.appointments(
  id, public_code, service_id, service_employee_id, status, financial_status,
  start_at, end_at, duration_minutes, people_count, primary_customer_id, commercial_value
) values (
  '97700000-0000-0000-0000-000000000010', 'REFUND-MIXED-1',
  '97700000-0000-0000-0000-000000000004', '97700000-0000-0000-0000-000000000005',
  'CONFIRMED', 'PARTIALLY_PAID',
  '2035-03-10 10:00:00-03', '2035-03-10 12:00:00-03', 120, 1,
  '97700000-0000-0000-0000-000000000001', 1000
), (
  '97700000-0000-0000-0000-000000000020', 'REFUND-MP-ONLY-1',
  '97700000-0000-0000-0000-000000000004', '97700000-0000-0000-0000-000000000005',
  'CONFIRMED', 'PARTIALLY_PAID',
  '2035-03-11 10:00:00-03', '2035-03-11 12:00:00-03', 120, 1,
  '97700000-0000-0000-0000-000000000001', 1000
);

insert into public.payment_transactions(
  id, appointment_id, transaction_type, method, provider, provider_payment_id,
  status, contract_amount_settled, payment_discount_amount, cash_amount, paid_at
) values
  (
    '97700000-0000-0000-0000-000000000011',
    '97700000-0000-0000-0000-000000000010',
    'CHARGE','PIX','MERCADO_PAGO','mp-mixed-charge','APPROVED',500,25,475,'2035-03-01 10:00:00-03'
  ),
  (
    '97700000-0000-0000-0000-000000000012',
    '97700000-0000-0000-0000-000000000010',
    'CHARGE','TRANSFER','MANUAL',null,'APPROVED',100,0,100,'2035-03-01 11:00:00-03'
  ),
  (
    '97700000-0000-0000-0000-000000000021',
    '97700000-0000-0000-0000-000000000020',
    'CHARGE','PIX','MERCADO_PAGO','mp-only-charge','APPROVED',500,25,475,'2035-03-01 10:00:00-03'
  );

select has_function(
  'public', 'service_get_cancellation_refund_plan', array['uuid'],
  'provider refund plan function exists'
);

select has_function(
  'public', 'service_record_cancellation_provider_refund',
  array['uuid','uuid','text','numeric','jsonb'],
  'provider refund recorder exists'
);

select ok(
  not has_function_privilege('anon', 'public.service_get_cancellation_refund_plan(uuid)', 'EXECUTE'),
  'anonymous clients cannot inspect provider refund plans'
);

select is(
  (public.service_admin_cancel_appointment(
    '97700000-0000-0000-0000-000000000010', 'REFUND', 'MIXED_REFUND',
    '2035-03-07 10:00:00-03', null
  )->>'policy_action_status'),
  'PENDING_REFUND',
  'mixed-payment cancellation enters pending refund'
);

select is(
  (select refundable_amount from public.appointment_policy_actions
   where appointment_id = '97700000-0000-0000-0000-000000000010' and action_type = 'CANCEL'),
  575.00::numeric(12,2),
  'refund target is cash actually received, not contract value settled'
);

select is(
  (
    select (public.service_get_cancellation_refund_plan(id)->>'mercado_pago_available_cash')::numeric(12,2)
    from public.appointment_policy_actions
    where appointment_id = '97700000-0000-0000-0000-000000000010' and action_type = 'CANCEL'
  ),
  475.00::numeric(12,2),
  'refund plan identifies Mercado Pago cash available'
);

select is(
  (
    select (public.service_get_cancellation_refund_plan(id)->>'manual_refund_cash')::numeric(12,2)
    from public.appointment_policy_actions
    where appointment_id = '97700000-0000-0000-0000-000000000010' and action_type = 'CANCEL'
  ),
  100.00::numeric(12,2),
  'manual payment portion remains explicitly manual'
);

select lives_ok(
  $$ select public.service_record_cancellation_provider_refund(
    (select id from public.appointment_policy_actions
     where appointment_id = '97700000-0000-0000-0000-000000000010' and action_type = 'CANCEL'),
    '97700000-0000-0000-0000-000000000011',
    'mp-refund-mixed-475',
    475,
    '{"id":"mp-refund-mixed-475","amount":475}'::jsonb
  ) $$,
  'Mercado Pago portion can be recorded after provider success'
);

select is(
  (select contract_amount_settled from public.payment_transactions
   where provider_payment_id = 'mp-refund-mixed-475' and transaction_type = 'REFUND'),
  500.00::numeric(12,2),
  'PIX cash refund restores the proportional contract amount including discount'
);

select is(
  (select status from public.payment_transactions where id = '97700000-0000-0000-0000-000000000011'),
  'REFUNDED',
  'fully refunded provider charge is marked REFUNDED'
);

select is(
  (select status from public.appointment_policy_actions
   where appointment_id = '97700000-0000-0000-0000-000000000010' and action_type = 'CANCEL'),
  'PENDING_REFUND',
  'mixed cancellation remains pending while manual cash is outstanding'
);

select is(
  (public.get_appointment_financial_summary('97700000-0000-0000-0000-000000000010')->>'cash_received')::numeric(12,2),
  100.00::numeric(12,2),
  'financial summary reports net cash after refund'
);

select is(
  (select financial_status::text from public.appointments where id = '97700000-0000-0000-0000-000000000010'),
  'PARTIALLY_REFUNDED',
  'mixed refund produces partially-refunded financial state'
);

select is(
  (public.service_admin_cancel_appointment(
    '97700000-0000-0000-0000-000000000020', 'REFUND', 'MP_ONLY_REFUND',
    '2035-03-08 10:00:00-03', null
  )->>'policy_action_status'),
  'PENDING_REFUND',
  'provider-only cancellation starts pending'
);

select lives_ok(
  $$ select public.service_record_cancellation_provider_refund(
    (select id from public.appointment_policy_actions
     where appointment_id = '97700000-0000-0000-0000-000000000020' and action_type = 'CANCEL'),
    '97700000-0000-0000-0000-000000000021',
    'mp-refund-only-475',
    475,
    '{"id":"mp-refund-only-475","amount":475}'::jsonb
  ) $$,
  'provider-only refund can be recorded'
);

select is(
  (select status from public.appointment_policy_actions
   where appointment_id = '97700000-0000-0000-0000-000000000020' and action_type = 'CANCEL'),
  'REFUNDED',
  'policy action completes only when full eligible cash was refunded'
);

select is(
  (select financial_status::text from public.appointments where id = '97700000-0000-0000-0000-000000000020'),
  'REFUNDED',
  'fully refunded appointment has REFUNDED financial status'
);

select ok(
  (public.service_record_cancellation_provider_refund(
    (select id from public.appointment_policy_actions
     where appointment_id = '97700000-0000-0000-0000-000000000020' and action_type = 'CANCEL'),
    '97700000-0000-0000-0000-000000000021',
    'mp-refund-only-475',
    475,
    '{}'::jsonb
  )->>'idempotent_replay')::boolean,
  'replaying the same provider refund is idempotent'
);

select is(
  (select count(*)::integer from public.payment_transactions
   where appointment_id = '97700000-0000-0000-0000-000000000020' and transaction_type = 'REFUND'),
  1,
  'idempotent replay does not duplicate refund transaction'
);

select * from finish();
rollback;
