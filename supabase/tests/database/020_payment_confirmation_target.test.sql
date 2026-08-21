begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(12);

insert into public.categories (id, name, slug)
values ('97000000-0000-0000-0000-000000000001', 'Payment Target', 'payment-target-test');

insert into public.employees (id, name)
values ('97000000-0000-0000-0000-000000000002', 'Payment Target Employee');

insert into public.services (
  id, category_id, name, slug, base_duration_minutes, base_price,
  minimum_people, maximum_people, maximum_booking_horizon_days, confirmation_percentage
) values
  ('97000000-0000-0000-0000-000000000010','97000000-0000-0000-0000-000000000001','Default Confirmation Service','default-confirmation-target',60,1000,1,1,5000,null),
  ('97000000-0000-0000-0000-000000000011','97000000-0000-0000-0000-000000000001','Override Confirmation Service','override-confirmation-target',60,1000,1,1,5000,30);

insert into public.service_employees (id, service_id, employee_id)
values
  ('97000000-0000-0000-0000-000000000020','97000000-0000-0000-0000-000000000010','97000000-0000-0000-0000-000000000002'),
  ('97000000-0000-0000-0000-000000000021','97000000-0000-0000-0000-000000000011','97000000-0000-0000-0000-000000000002');

insert into public.customers (id, name, email, phone)
values ('97000000-0000-0000-0000-000000000030', 'Payment Target Customer', 'target@example.com', '48999990000');

insert into public.appointments (
  id, public_code, service_id, service_employee_id, primary_customer_id,
  status, financial_status, start_at, end_at, duration_minutes, people_count,
  hold_expires_at, commercial_value
) values
  ('97000000-0000-0000-0000-000000000040','TGT-DEFAULT','97000000-0000-0000-0000-000000000010','97000000-0000-0000-0000-000000000020','97000000-0000-0000-0000-000000000030','AWAITING_PAYMENT','PENDING','2035-05-01 09:00:00-03','2035-05-01 10:00:00-03',60,1,now()+interval '30 minutes',1000),
  ('97000000-0000-0000-0000-000000000041','TGT-PARTIAL','97000000-0000-0000-0000-000000000010','97000000-0000-0000-0000-000000000020','97000000-0000-0000-0000-000000000030','AWAITING_PAYMENT','PARTIALLY_PAID','2035-05-01 11:00:00-03','2035-05-01 12:00:00-03',60,1,now()+interval '30 minutes',1000),
  ('97000000-0000-0000-0000-000000000042','TGT-OVERRIDE','97000000-0000-0000-0000-000000000011','97000000-0000-0000-0000-000000000021','97000000-0000-0000-0000-000000000030','AWAITING_PAYMENT','PENDING','2035-05-01 13:00:00-03','2035-05-01 14:00:00-03',60,1,now()+interval '30 minutes',1000),
  ('97000000-0000-0000-0000-000000000043','TGT-SATISFIED','97000000-0000-0000-0000-000000000010','97000000-0000-0000-0000-000000000020','97000000-0000-0000-0000-000000000030','CONFIRMED','PARTIALLY_PAID','2035-05-01 15:00:00-03','2035-05-01 16:00:00-03',60,1,null,1000);

-- Appointment 041 has already settled R$200; appointment 043 already reached the R$500 threshold.
insert into public.payment_transactions (
  appointment_id, transaction_type, method, provider, status,
  contract_amount_settled, payment_discount_amount, cash_amount, paid_at, notes
) values
  ('97000000-0000-0000-0000-000000000041','CHARGE','TRANSFER','MANUAL','APPROVED',200,0,200,now(),'previous partial payment'),
  ('97000000-0000-0000-0000-000000000043','CHARGE','TRANSFER','MANUAL','APPROVED',500,0,500,now(),'confirmation already reached');

create temporary table target_results (name text primary key, payload jsonb not null);

insert into target_results values (
  'default',
  public.create_payment_intent('97000000-0000-0000-0000-000000000040',50,'PIX','target-default')
);

select is((select (payload->>'confirmation_percentage')::numeric from target_results where name='default'),50::numeric,'default confirmation percentage comes from operation settings');
select is((select (payload->>'confirmation_target_amount')::numeric from target_results where name='default'),500::numeric,'default confirmation target is 50 percent of contract value');
select is((select (payload->>'contract_amount_settled')::numeric from target_results where name='default'),500::numeric,'first minimum payment settles exactly the confirmation target');
select is((select (payload->>'cash_amount')::numeric from target_results where name='default'),475::numeric,'PIX discount applies only to the minimum transaction cash portion');

insert into target_results values (
  'partial',
  public.create_payment_intent('97000000-0000-0000-0000-000000000041',50,'PIX','target-partial')
);

select is((select (payload->>'contract_settled_before')::numeric from target_results where name='partial'),200::numeric,'payment intent sees contract settlement already received');
select is((select (payload->>'contract_amount_settled')::numeric from target_results where name='partial'),300::numeric,'minimum payment charges only the R$300 gap to the R$500 threshold, not 50 percent of remaining balance');
select is((select (payload->>'cash_amount')::numeric from target_results where name='partial'),285::numeric,'PIX discount is R$15 on the R$300 confirmation gap');

insert into target_results values (
  'override',
  public.create_payment_intent('97000000-0000-0000-0000-000000000042',30,'CARD','target-override')
);

select is((select (payload->>'confirmation_percentage')::numeric from target_results where name='override'),30::numeric,'service confirmation percentage overrides the operation default');
select is((select (payload->>'contract_amount_settled')::numeric from target_results where name='override'),300::numeric,'service 30 percent minimum creates a R$300 contract settlement intent');

select throws_ok(
  $$ select public.create_payment_intent('97000000-0000-0000-0000-000000000042',50,'CARD','target-invalid-percent') $$,
  'P0001','INVALID_PAYMENT_PERCENTAGE',
  'client cannot choose a percentage other than the service minimum or 100 percent'
);

select throws_ok(
  $$ select public.create_payment_intent('97000000-0000-0000-0000-000000000043',50,'CARD','target-satisfied') $$,
  'P0001','CONFIRMATION_PAYMENT_ALREADY_SATISFIED',
  'minimum payment cannot be recreated after the confirmation threshold is already satisfied'
);

select is(
  (public.create_payment_intent('97000000-0000-0000-0000-000000000041',100,'CARD','target-full-after-partial')->>'contract_amount_settled')::numeric,
  800::numeric,
  '100 percent option settles the exact outstanding contract balance'
);

select * from finish();
rollback;
