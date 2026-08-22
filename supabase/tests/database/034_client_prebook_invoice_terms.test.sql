begin;

select plan(12);

select has_table('public', 'customer_commercial_terms', 'customer commercial terms table exists');
select has_table('public', 'pre_reservations', 'pre reservations table exists');
select has_table('public', 'customer_prebook_authorized_services', 'authorized services table exists');
select has_column('public', 'appointments', 'billing_mode_snapshot', 'appointment billing mode snapshot exists');
select has_column('public', 'appointments', 'invoice_due_at', 'appointment invoice due date exists');
select has_column('public', 'appointments', 'source_pre_reservation_id', 'appointment links source pre reservation');
select has_function('public', 'service_get_customer_commercial_terms', array['uuid'], 'commercial terms service exists');
select has_function('public', 'service_expire_pre_reservations', array[]::text[], 'pre reservation expiration service exists');
select has_function('public', 'service_admin_authorize_invoiced_appointment', array['uuid','uuid'], 'invoice authorization service exists');

insert into public.customers (id, customer_type, name)
values ('11111111-1111-1111-1111-111111111111', 'BUSINESS', 'Corporate Test');

insert into public.customer_commercial_terms (
  customer_id, can_prebook, prebook_hold_minutes, max_active_prebooks,
  requires_manual_confirmation, billing_mode, invoice_due_days
) values (
  '11111111-1111-1111-1111-111111111111', true, 720, 2, true, 'INVOICE', 15
);

select is(
  (select invoice_due_days from public.customer_commercial_terms where customer_id = '11111111-1111-1111-1111-111111111111'),
  15,
  'invoice due days are configurable per customer'
);

select is(
  (select can_prebook from public.customer_commercial_terms where customer_id = '11111111-1111-1111-1111-111111111111'),
  true,
  'pre booking can be enabled per customer'
);

select is(
  (select max_active_prebooks from public.customer_commercial_terms where customer_id = '11111111-1111-1111-1111-111111111111'),
  2,
  'pre booking concurrency limit is configurable per customer'
);

select * from finish();
rollback;
