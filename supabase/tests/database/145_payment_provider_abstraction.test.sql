begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(12);

insert into public.resources (id, name, resource_type)
values ('94500000-0000-0000-0000-000000000001', 'Provider Test Studio', 'PHYSICAL');

insert into public.employees (id, name)
values ('94500000-0000-0000-0000-000000000002', 'Provider Test Employee');

insert into public.categories (id, name, slug)
values ('94500000-0000-0000-0000-000000000003', 'Provider Test', 'provider-test');

insert into public.services (
  id, category_id, name, slug, base_duration_minutes, base_price,
  minimum_people, maximum_people, maximum_booking_horizon_days
) values (
  '94500000-0000-0000-0000-000000000010',
  '94500000-0000-0000-0000-000000000003',
  'Provider Test Service', 'provider-test-service', 60, 1000, 1, 10, 5000
);

insert into public.service_employees (id, service_id, employee_id)
values (
  '94500000-0000-0000-0000-000000000011',
  '94500000-0000-0000-0000-000000000010',
  '94500000-0000-0000-0000-000000000002'
);

insert into public.customers (id, name, email, phone)
values ('94500000-0000-0000-0000-000000000020', 'Provider Customer', 'provider@example.com', '+5548999999450');

insert into public.booking_pages (id, slug, display_name, title, brand_key, payment_provider)
values (
  '94500000-0000-0000-0000-000000000030',
  'provider-infinitepay',
  'Provider InfinitePay',
  'Provider InfinitePay',
  'SABRINA',
  'INFINITEPAY'
);

insert into public.booking_pages (id, slug, display_name, title, brand_key)
values (
  '94500000-0000-0000-0000-000000000031',
  'provider-default',
  'Provider Default',
  'Provider Default',
  'BLACKSHEEP'
);

select is(
  (select payment_provider from public.booking_pages where id='94500000-0000-0000-0000-000000000031'),
  'MERCADO_PAGO',
  'booking pages remain Mercado Pago by default'
);

-- Mirrors public_create_checkout_hold: the hold is created first and the page is
-- attached in a second statement.
insert into public.checkout_holds (
  id, public_token_hash, service_id, service_employee_id, selection_hash,
  people_count, requested_start_at, requested_end_at, expires_at, commercial_value
) values (
  '94500000-0000-0000-0000-000000000040',
  'provider-hold-token-945',
  '94500000-0000-0000-0000-000000000010',
  '94500000-0000-0000-0000-000000000011',
  'provider-selection-945',
  1,
  '2035-03-01 09:00:00-03',
  '2035-03-01 10:00:00-03',
  now() + interval '30 minutes',
  1000
);

select is(
  (select payment_provider_snapshot from public.checkout_holds where id='94500000-0000-0000-0000-000000000040'),
  'MERCADO_PAGO',
  'unscoped checkout hold starts on the safe Mercado Pago default'
);

update public.checkout_holds
set booking_page_id='94500000-0000-0000-0000-000000000030'
where id='94500000-0000-0000-0000-000000000040';

select is(
  (select payment_provider_snapshot from public.checkout_holds where id='94500000-0000-0000-0000-000000000040'),
  'INFINITEPAY',
  'first booking page assignment snapshots InfinitePay on the hold'
);

insert into public.appointments (
  id, public_code, service_id, service_employee_id, primary_customer_id,
  status, financial_status, start_at, end_at, duration_minutes, people_count,
  hold_expires_at, commercial_value
) values (
  '94500000-0000-0000-0000-000000000050',
  'PROVIDER-IP',
  '94500000-0000-0000-0000-000000000010',
  '94500000-0000-0000-0000-000000000011',
  '94500000-0000-0000-0000-000000000020',
  'AWAITING_PAYMENT',
  'PENDING',
  '2035-03-01 09:00:00-03',
  '2035-03-01 10:00:00-03',
  60,
  1,
  now() + interval '30 minutes',
  1000
);

select is(
  (select payment_provider_snapshot from public.appointments where id='94500000-0000-0000-0000-000000000050'),
  'MERCADO_PAGO',
  'appointment is safe-defaulted before a public hold is promoted'
);

update public.checkout_holds
set promoted_appointment_id='94500000-0000-0000-0000-000000000050', status='PROMOTED'
where id='94500000-0000-0000-0000-000000000040';

select is(
  (select payment_provider_snapshot from public.appointments where id='94500000-0000-0000-0000-000000000050'),
  'INFINITEPAY',
  'promoting the hold copies its provider snapshot to the appointment'
);

update public.booking_pages
set payment_provider='MERCADO_PAGO'
where id='94500000-0000-0000-0000-000000000030';

select is(
  (select payment_provider_snapshot from public.checkout_holds where id='94500000-0000-0000-0000-000000000040'),
  'INFINITEPAY',
  'changing booking page configuration does not rewrite an existing hold snapshot'
);

select is(
  (select payment_provider_snapshot from public.appointments where id='94500000-0000-0000-0000-000000000050'),
  'INFINITEPAY',
  'changing booking page configuration does not rewrite an existing appointment snapshot'
);

select is(
  public.service_resolve_appointment_payment_provider('94500000-0000-0000-0000-000000000050'),
  'INFINITEPAY',
  'provider resolver returns the frozen appointment provider'
);

insert into public.payment_transactions (
  id, appointment_id, transaction_type, method, provider, status,
  contract_amount_settled, payment_discount_amount, cash_amount, idempotency_key
) values (
  '94500000-0000-0000-0000-000000000060',
  '94500000-0000-0000-0000-000000000050',
  'CHARGE',
  'CARD',
  'INFINITEPAY',
  'PENDING',
  1000,
  0,
  1000,
  'provider-ip-945'
);

select is(
  (select provider from public.payment_transactions where id='94500000-0000-0000-0000-000000000060'),
  'INFINITEPAY',
  'payment transactions accept InfinitePay without removing existing providers'
);

insert into public.payment_provider_events (
  id, provider, event_key, transaction_id, provider_payment_id, normalized_status, payload_json
) values (
  '94500000-0000-0000-0000-000000000070',
  'INFINITEPAY',
  'provider-event-ip-945',
  '94500000-0000-0000-0000-000000000060',
  'ip-payment-945',
  'PENDING',
  '{}'::jsonb
);

select is(
  (select provider from public.payment_provider_events where id='94500000-0000-0000-0000-000000000070'),
  'INFINITEPAY',
  'provider event ledger accepts InfinitePay'
);

select ok(
  (select pg_get_constraintdef(oid) like '%MERCADO_PAGO%' and pg_get_constraintdef(oid) like '%MANUAL%' and pg_get_constraintdef(oid) like '%INFINITEPAY%'
   from pg_constraint
   where conrelid='public.payment_transactions'::regclass
     and conname='payment_transactions_provider_check'),
  'transaction provider constraint keeps Mercado Pago and Manual while adding InfinitePay'
);

select ok(
  (select pg_get_constraintdef(oid) like '%MERCADO_PAGO%' and pg_get_constraintdef(oid) like '%INFINITEPAY%'
   from pg_constraint
   where conrelid='public.payment_provider_events'::regclass
     and conname='payment_provider_events_provider_check'),
  'provider event constraint keeps Mercado Pago while adding InfinitePay'
);

select * from finish();
rollback;
