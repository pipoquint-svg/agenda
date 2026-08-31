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
  minimum_people, maximum_people, maximum_booking_horizon_days, confirmation_percentage,
  checkout_minimum_payment_type, checkout_minimum_payment_value, pix_discount_percent
) values
  ('97000000-0000-0000-0000-000000000010','97000000-0000-0000-0000-000000000001','Default Confirmation Service','default-confirmation-target',60,1000,1,1,5000,null,'PERCENT',50,5),
  ('97000000-0000-0000-0000-000000000011','97000000-0000-0000-0000-000000000001','Full Confirmation Service','full-confirmation-target',60,1000,1,1,5000,100,'PERCENT',100,5);

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
  ('97000000-0000-0000-0000-000000000042','TGT-FULL','97000000-0000-0000-0000-000000000011','97000000-0000-0000-0000-000000000021','97000000-0000-0000-0000-000000000030','AWAITING_PAYMENT','PENDING','2035-05-01 13:00:00-03','2035-05-01 14:00:00-03',60,1,now()+interval '30 minutes',1000),
  ('97000000-0000-0000-0000-000000000043','TGT-SATISFIED','97000000-0000-0000-0000-000000000010','97000000-0000-0000-0000-000000000020','97000000-0000-0000-0000-000000000030','CONFIRMED','PARTIALLY_PAID','2035-05-01 15:00:00-03','2035-05-01 16:00:00-03',60,1,null,1000);

insert into public.payment_transactions (
  appointment_id, transaction_type, method, provider, status,
  contract_amount_settled, payment_discount_amount, cash_amount, paid_at, notes
) values
  ('97000000-0000-0000-0000-000000000041','CHARGE','TRANSFER','MANUAL','APPROVED',200,0,200,now(),'previous partial payment'),
  ('97000000-0000-0000-0000-000000000043','CHARGE','TRANSFER','MANUAL','APPROVED',500,0,500,now(),'confirmation already reached');

create temporary table target_results (name text primary key, payload jsonb not null);

insert into target_results values (
  'default',
  public.create_payment_intent_v2('97000000-0000-0000-0000-000000000040','MINIMUM','PIX','target-default')
);

select is((select (payload->>'payment_percentage')::numeric from target_results where name='default'),50::numeric,'default minimum percentage comes from the appointment snapshot');
select is((select (payload->>'confirmation_target_amount')::numeric from target_results where name='default'),500::numeric,'default confirmation target is 50 percent of contract value');
select is((select (payload->>'contract_amount_settled')::numeric from target_results where name='default'),500::numeric,'first minimum payment settles exactly the confirmation target');
select is((select (payload->>'cash_amount')::numeric from target_results where name='default'),475::numeric,'PIX snapshot discount applies only to the minimum transaction cash portion');

insert into target_results values (
  'partial',
  public.create_payment_intent_v2('97000000-0000-0000-0000-000000000041','MINIMUM','PIX','target-partial')
);

select is((select (payload->>'contract_settled_before')::numeric from target_results where name='partial'),200::numeric,'payment intent sees contract settlement already received');
select is((select (payload->>'contract_amount_settled')::numeric from target_results where name='partial'),300::numeric,'minimum payment charges only the R$300 gap to the R$500 threshold');
select is((select (payload->>'cash_amount')::numeric from target_results where name='partial'),285::numeric,'PIX snapshot discount is R$15 on the R$300 confirmation gap');

insert into target_results values (
  'full-minimum',
  public.create_payment_intent_v2('97000000-0000-0000-0000-000000000042','MINIMUM','CARD','target-full-minimum')
);

select is((select (payload->>'payment_percentage')::numeric from target_results where name='full-minimum'),100::numeric,'service can explicitly require a 100 percent minimum');
select is((select (payload->>'contract_amount_settled')::numeric from target_results where name='full-minimum'),1000::numeric,'100 percent minimum settles the full outstanding contract');

select throws_ok(
  $$ select public.create_payment_intent_v2('97000000-0000-0000-0000-000000000042','PERCENT_50','CARD','target-invalid-kind') $$,
  'P0001','INVALID_PAYMENT_KIND',
  'client cannot bypass the payment-kind contract with an arbitrary percentage'
);

select throws_ok(
  $$ select public.create_payment_intent_v2('97000000-0000-0000-0000-000000000043','MINIMUM','CARD','target-satisfied') $$,
  'P0001','CONFIRMATION_PAYMENT_ALREADY_SATISFIED',
  'minimum payment cannot be recreated after the confirmation threshold is already satisfied'
);

select is(
  (public.create_payment_intent_v2('97000000-0000-0000-0000-000000000041','FULL','CARD','target-full-after-partial')->>'contract_amount_settled')::numeric,
  800::numeric,
  'full option settles the exact outstanding contract balance'
);

select * from finish();
rollback;
