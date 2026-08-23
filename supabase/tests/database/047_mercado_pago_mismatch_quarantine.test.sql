begin;
create extension if not exists pgtap with schema extensions;
set local search_path=public,extensions;
select plan(9);

insert into public.customers(id,name,email,cpf_cnpj)
values ('61000000-0000-0000-0000-000000000001','MP Quarantine Customer','mp-quarantine@example.com','52998224725');
insert into public.employees(id,name)
values ('61000000-0000-0000-0000-000000000002','MP Quarantine Employee');
insert into public.categories(id,name,slug)
values ('61000000-0000-0000-0000-000000000003','MP Quarantine','mp-quarantine');
insert into public.services(id,category_id,name,slug,base_duration_minutes,base_price,minimum_people,maximum_people)
values ('61000000-0000-0000-0000-000000000004','61000000-0000-0000-0000-000000000003','MP Quarantine Service','mp-quarantine-service',60,500,1,10);
insert into public.service_employees(id,service_id,employee_id)
values ('61000000-0000-0000-0000-000000000005','61000000-0000-0000-0000-000000000004','61000000-0000-0000-0000-000000000002');

insert into public.appointments(
  id,public_code,service_id,service_employee_id,status,financial_status,start_at,end_at,duration_minutes,people_count,
  primary_customer_id,commercial_value,hold_expires_at
) values (
  '61000000-0000-0000-0000-000000000010','MP-QUARANTINE-1','61000000-0000-0000-0000-000000000004','61000000-0000-0000-0000-000000000005',
  'AWAITING_PAYMENT','PENDING','2035-09-10 10:00:00-03','2035-09-10 11:00:00-03',60,1,
  '61000000-0000-0000-0000-000000000001',500,'2035-09-10 09:00:00-03'
);

insert into public.payment_transactions(
  id,appointment_id,transaction_type,method,provider,status,contract_amount_settled,payment_discount_amount,cash_amount,
  idempotency_key,requested_percentage
) values (
  '61000000-0000-0000-0000-000000000020','61000000-0000-0000-0000-000000000010','CHARGE','PIX','MERCADO_PAGO','PENDING',
  500,25,475,'mp-quarantine-request',100
);

select has_function(
  'public','service_quarantine_provider_payment_mismatch',array['uuid','text','text','jsonb'],
  'Mercado Pago mismatch quarantine RPC exists'
);

select lives_ok($$
  select public.service_quarantine_provider_payment_mismatch(
    '61000000-0000-0000-0000-000000000020',
    'mp-provider-accepted-1',
    'MERCADO_PAGO_PAYMENT_AMOUNT_MISMATCH',
    '{"id":"mp-provider-accepted-1","status":"approved","transaction_amount":474.99,"external_reference":"61000000-0000-0000-0000-000000000020"}'::jsonb
  )
$$,'provider-accepted mismatch is quarantined instead of applied/rejected');

select is(
  (select status from public.payment_transactions where id='61000000-0000-0000-0000-000000000020'),
  'PENDING','quarantined internal charge remains PENDING and settles no contract value'
);
select is(
  (select provider_payment_id from public.payment_transactions where id='61000000-0000-0000-0000-000000000020'),
  'mp-provider-accepted-1','observed provider payment id remains traceable'
);
select is(
  (select status::text from public.appointments where id='61000000-0000-0000-0000-000000000010'),
  'AWAITING_PAYMENT','provider mismatch never confirms the appointment'
);
select is(
  (select status from public.payment_incidents where payment_transaction_id='61000000-0000-0000-0000-000000000020' and incident_type='PROVIDER_INTENT_MISMATCH'),
  'OPEN','mismatch creates an open payment incident'
);
select is(
  (select details_json->>'reason' from public.payment_incidents where payment_transaction_id='61000000-0000-0000-0000-000000000020' and incident_type='PROVIDER_INTENT_MISMATCH'),
  'MERCADO_PAGO_PAYMENT_AMOUNT_MISMATCH','incident records the validation reason'
);

select lives_ok($$
  select public.service_quarantine_provider_payment_mismatch(
    '61000000-0000-0000-0000-000000000020',
    'mp-provider-accepted-1',
    'MERCADO_PAGO_PAYMENT_AMOUNT_MISMATCH',
    '{"id":"mp-provider-accepted-1","status":"approved","transaction_amount":474.99}'::jsonb
  )
$$,'duplicate mismatch signal is idempotent at incident level');
select is(
  (select count(*)::integer from public.payment_incidents where payment_transaction_id='61000000-0000-0000-0000-000000000020' and incident_type='PROVIDER_INTENT_MISMATCH'),
  1,'duplicate mismatch does not create duplicate incidents'
);

select * from finish();
rollback;
