begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(18);

insert into public.resources (id, name, resource_type)
values ('90000000-0000-0000-0000-000000000001', 'PAYMENT TEST STUDIO', 'PHYSICAL');

insert into public.employees (id, name)
values ('90000000-0000-0000-0000-000000000002', 'Payment Employee');

insert into public.categories (id, name, slug)
values ('90000000-0000-0000-0000-000000000003', 'Payment', 'payment-test');

insert into public.services (
  id, category_id, name, slug, base_duration_minutes, base_price,
  minimum_people, maximum_people, maximum_booking_horizon_days
) values (
  '90000000-0000-0000-0000-000000000010',
  '90000000-0000-0000-0000-000000000003',
  'Payment Service', 'payment-service', 60, 1000, 1, 10, 5000
);

insert into public.service_employees (id, service_id, employee_id)
values (
  '90000000-0000-0000-0000-000000000011',
  '90000000-0000-0000-0000-000000000010',
  '90000000-0000-0000-0000-000000000002'
);

insert into public.service_resources (service_id, resource_id)
values (
  '90000000-0000-0000-0000-000000000010',
  '90000000-0000-0000-0000-000000000001'
);

insert into public.customers (id, name, email, phone)
values ('90000000-0000-0000-0000-000000000020', 'Payment Customer', 'payment@example.com', '+5548999999200');

insert into public.appointments (
  id, public_code, service_id, service_employee_id, primary_customer_id,
  status, financial_status, start_at, end_at, duration_minutes, people_count,
  hold_expires_at, commercial_value
) values
  ('90000000-0000-0000-0000-000000000030','PAY-PIX','90000000-0000-0000-0000-000000000010','90000000-0000-0000-0000-000000000011','90000000-0000-0000-0000-000000000020','AWAITING_PAYMENT','PENDING','2035-02-01 09:00:00-03','2035-02-01 10:00:00-03',60,1,now()+interval '30 minutes',1000),
  ('90000000-0000-0000-0000-000000000031','PAY-MANUAL','90000000-0000-0000-0000-000000000010','90000000-0000-0000-0000-000000000011','90000000-0000-0000-0000-000000000020','AWAITING_PAYMENT','PENDING','2035-02-01 11:00:00-03','2035-02-01 12:00:00-03',60,1,now()+interval '30 minutes',600),
  ('90000000-0000-0000-0000-000000000032','PAY-AUTH','90000000-0000-0000-0000-000000000010','90000000-0000-0000-0000-000000000011','90000000-0000-0000-0000-000000000020','AWAITING_PAYMENT','PENDING','2035-02-01 13:00:00-03','2035-02-01 14:00:00-03',60,1,now()+interval '30 minutes',500),
  ('90000000-0000-0000-0000-000000000033','PAY-LATE','90000000-0000-0000-0000-000000000010','90000000-0000-0000-0000-000000000011','90000000-0000-0000-0000-000000000020','AWAITING_PAYMENT','PENDING','2035-02-01 15:00:00-03','2035-02-01 16:00:00-03',60,1,now()+interval '30 minutes',800),
  ('90000000-0000-0000-0000-000000000034','PAY-REJECT','90000000-0000-0000-0000-000000000010','90000000-0000-0000-0000-000000000011','90000000-0000-0000-0000-000000000020','AWAITING_PAYMENT','PENDING','2035-02-01 17:00:00-03','2035-02-01 18:00:00-03',60,1,now()+interval '30 minutes',400);

insert into public.resource_allocations (
  resource_id, appointment_id, allocation_type, status, occupied_range
)
select
  '90000000-0000-0000-0000-000000000001'::uuid,
  a.id,
  'APPOINTMENT',
  'AWAITING_PAYMENT',
  tstzrange(a.start_at, a.end_at, '[)')
from public.appointments a
where a.id in (
  '90000000-0000-0000-0000-000000000030'::uuid,
  '90000000-0000-0000-0000-000000000031'::uuid,
  '90000000-0000-0000-0000-000000000032'::uuid,
  '90000000-0000-0000-0000-000000000033'::uuid,
  '90000000-0000-0000-0000-000000000034'::uuid
);

create temporary table payment_test_ids (name text primary key, id uuid not null);

insert into payment_test_ids
select 'pix1', (public.create_payment_intent(
  '90000000-0000-0000-0000-000000000030', 50, 'PIX', 'idem-pay-pix-1'
)->>'transaction_id')::uuid;

select is(
  (select contract_amount_settled from public.payment_transactions where id=(select id from payment_test_ids where name='pix1')),
  500.00::numeric,
  '50 percent intent settles half of current contract balance'
);

select is(
  (select payment_discount_amount from public.payment_transactions where id=(select id from payment_test_ids where name='pix1')),
  25.00::numeric,
  'PIX gives 5 percent discount only on settled contract portion'
);

select is(
  (select cash_amount from public.payment_transactions where id=(select id from payment_test_ids where name='pix1')),
  475.00::numeric,
  'PIX cash due reflects payment discount'
);

select is(
  (public.create_payment_intent('90000000-0000-0000-0000-000000000030',50,'PIX','idem-pay-pix-1')->>'idempotent_replay')::boolean,
  true,
  'payment intent is idempotent'
);

select is(
  (select count(*)::integer from public.payment_transactions where idempotency_key='idem-pay-pix-1'),
  1,
  'idempotent retry does not create duplicate transaction'
);

select public.apply_provider_payment_status(
  (select id from payment_test_ids where name='pix1'),
  'mp-payment-1','APPROVED','event-payment-1','{}'::jsonb,now()
);

select is((select status::text from public.appointments where id='90000000-0000-0000-0000-000000000030'),'CONFIRMED','approved provider payment confirms active booking');
select is((select financial_status::text from public.appointments where id='90000000-0000-0000-0000-000000000030'),'PARTIALLY_PAID','50 percent approval leaves contract partially paid');
select is((select status::text from public.resource_allocations where appointment_id='90000000-0000-0000-0000-000000000030'),'CONFIRMED','approved payment promotes allocation to confirmed');
select is((select count(*)::integer from public.integration_jobs where entity_id='90000000-0000-0000-0000-000000000030'),2,'confirmation emits Google and message outbox jobs once');

select is(
  (public.apply_provider_payment_status((select id from payment_test_ids where name='pix1'),'mp-payment-1','APPROVED','event-payment-1','{}'::jsonb,now())->>'idempotent_replay')::boolean,
  true,
  'duplicate provider event is idempotent'
);

insert into payment_test_ids
select 'card2', (public.create_payment_intent(
  '90000000-0000-0000-0000-000000000030', 100, 'CARD', 'idem-pay-card-2'
)->>'transaction_id')::uuid;

select is(
  (select contract_amount_settled from public.payment_transactions where id=(select id from payment_test_ids where name='card2')),
  500.00::numeric,
  '100 percent second intent settles remaining contract balance only'
);

select public.apply_provider_payment_status(
  (select id from payment_test_ids where name='card2'),
  'mp-payment-2','APPROVED','event-payment-2','{}'::jsonb,now()
);

select is((select financial_status::text from public.appointments where id='90000000-0000-0000-0000-000000000030'),'PAID','second payment closes contract balance');
select is((public.get_appointment_financial_summary('90000000-0000-0000-0000-000000000030')->>'cash_received')::numeric,975.00::numeric,'financial summary separates contract settlement from cash received');

select public.register_manual_payment(
  '90000000-0000-0000-0000-000000000031','PIX',300,'manual deposit',null,true
);
select is((select status::text from public.appointments where id='90000000-0000-0000-0000-000000000031'),'CONFIRMED','manual payment can explicitly confirm pending booking');
select is((select cash_amount from public.payment_transactions where appointment_id='90000000-0000-0000-0000-000000000031'),285.00::numeric,'manual PIX uses same 5 percent transaction discount rule');

select public.confirm_without_payment(
  '90000000-0000-0000-0000-000000000032','Parceiro paga presencialmente',null
);
select is((select financial_status::text from public.appointments where id='90000000-0000-0000-0000-000000000032'),'UNPAID_AUTHORIZED','admin can confirm without payment while preserving financial state');

insert into payment_test_ids
select 'late', (public.create_payment_intent(
  '90000000-0000-0000-0000-000000000033', 50, 'CARD', 'idem-pay-late'
)->>'transaction_id')::uuid;

update public.appointments
set hold_expires_at = now() - interval '1 minute'
where id='90000000-0000-0000-0000-000000000033';

select public.apply_provider_payment_status(
  (select id from payment_test_ids where name='late'),
  'mp-payment-late','APPROVED','event-payment-late','{}'::jsonb,now()
);

select ok(
  (select status='EXPIRED' from public.appointments where id='90000000-0000-0000-0000-000000000033')
  and (select status='EXPIRED' from public.resource_allocations where appointment_id='90000000-0000-0000-0000-000000000033')
  and exists (select 1 from public.payment_incidents where appointment_id='90000000-0000-0000-0000-000000000033' and incident_type='PAYMENT_AFTER_EXPIRATION' and status='OPEN')
  and not exists (select 1 from public.integration_jobs where entity_id='90000000-0000-0000-0000-000000000033'),
  'late approved payment is recorded but never reoccupies or confirms expired slot'
);

insert into payment_test_ids
select 'reject', (public.create_payment_intent(
  '90000000-0000-0000-0000-000000000034', 50, 'CARD', 'idem-pay-reject'
)->>'transaction_id')::uuid;
select public.apply_provider_payment_status(
  (select id from payment_test_ids where name='reject'),
  'mp-payment-reject','REJECTED','event-payment-reject','{}'::jsonb,now()
);
select ok(
  (select status='AWAITING_PAYMENT' from public.appointments where id='90000000-0000-0000-0000-000000000034')
  and (select financial_status='REJECTED' from public.appointments where id='90000000-0000-0000-0000-000000000034'),
  'rejected provider payment does not release booking before hold expires'
);

select * from finish();
rollback;
