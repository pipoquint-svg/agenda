begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(11);

insert into public.categories(id,name,slug)
values ('96300000-0000-0000-0000-000000000001','Config Authority','config-authority');

insert into public.employees(id,name)
values ('96300000-0000-0000-0000-000000000002','Config Authority Employee');

insert into public.services(
  id,category_id,name,slug,base_duration_minutes,base_price,
  minimum_people,maximum_people,maximum_booking_horizon_days,
  confirmation_percentage,max_reschedules
) values (
  '96300000-0000-0000-0000-000000000003',
  '96300000-0000-0000-0000-000000000001',
  'Config Authority Service','config-authority-service',60,1000,1,2,365,30,0
);

insert into public.service_employees(id,service_id,employee_id)
values (
  '96300000-0000-0000-0000-000000000004',
  '96300000-0000-0000-0000-000000000003',
  '96300000-0000-0000-0000-000000000002'
);

insert into public.service_change_policies(
  service_id,notice_hours,reschedule_first_early_percent,
  reschedule_first_late_percent,reschedule_repeat_percent,cancellation_late_percent
) values ('96300000-0000-0000-0000-000000000003',48,0,20,20,20);

insert into public.customers(id,name,email,phone)
values ('96300000-0000-0000-0000-000000000005','Config Customer','config@example.com','48999990000');

insert into public.appointments(
  id,public_code,service_id,service_employee_id,service_name_snapshot,primary_customer_id,
  status,financial_status,start_at,end_at,duration_minutes,people_count,
  hold_expires_at,commercial_value,billing_mode_snapshot
) values (
  '96300000-0000-0000-0000-000000000006','CFG-AUTH',
  '96300000-0000-0000-0000-000000000003','96300000-0000-0000-0000-000000000004',
  'Config Authority Service','96300000-0000-0000-0000-000000000005',
  'AWAITING_PAYMENT','PENDING',now()+interval '10 days',now()+interval '10 days 1 hour',60,1,
  now()+interval '30 minutes',1000,'CHECKOUT'
);

insert into public.appointment_access_tokens(appointment_id,token_hash,scope,expires_at)
values (
  '96300000-0000-0000-0000-000000000006',
  encode(digest('config-authority-pay-token-abcdefghijklmnopqrstuvwxyz','sha256'),'hex'),
  'PAY',now()+interval '1 day'
);

select is(
  (select confirmation_percentage_snapshot from public.appointments where id='96300000-0000-0000-0000-000000000006'),
  30.00::numeric,
  'appointment snapshots non-default 30 percent confirmation configuration'
);

select is(
  (select max_customer_reschedules from public.appointment_change_policy_snapshots where appointment_id='96300000-0000-0000-0000-000000000006'),
  0::smallint,
  'policy snapshot uses service max_reschedules instead of literal three'
);

select is(
  (select (policy_json->>'max_customer_reschedules')::integer from public.appointment_change_policy_snapshots where appointment_id='96300000-0000-0000-0000-000000000006'),
  0,
  'policy JSON and typed snapshot agree on configured reschedule limit'
);

select is(
  (public.service_get_public_payment_context('config-authority-pay-token-abcdefghijklmnopqrstuvwxyz')->>'confirmation_percentage')::numeric,
  30.00::numeric,
  'public payment context reads reservation snapshot'
);

select is(
  (public.service_get_public_payment_context('config-authority-pay-token-abcdefghijklmnopqrstuvwxyz')->>'confirmation_target_amount')::numeric,
  300.00::numeric,
  '30 percent snapshot produces 300 confirmation target on 1000 contract'
);

update public.services
set confirmation_percentage=80,max_reschedules=5
where id='96300000-0000-0000-0000-000000000003';

select is(
  (public.service_get_public_payment_context('config-authority-pay-token-abcdefghijklmnopqrstuvwxyz')->>'confirmation_percentage')::numeric,
  30.00::numeric,
  'later service configuration change cannot alter existing reservation commitment'
);

create temporary table config_intent as
select public.service_create_payment_intent_by_token(
  'config-authority-pay-token-abcdefghijklmnopqrstuvwxyz','MINIMUM','CARD','config_auth_req_001'
) payload;

select is(
  (select (payload->>'contract_amount_settled')::numeric from config_intent),
  300.00::numeric,
  'minimum payment intent settles configured 30 percent target'
);

select is(
  (public.calculate_reservation_change(
    '96300000-0000-0000-0000-000000000006','RESCHEDULE',now(),'CLIENT',1200
  )->>'payment_commitment_percent')::numeric,
  30.00::numeric,
  'reschedule engine preserves reservation confirmation snapshot instead of literal 50'
);

select is(
  (public.calculate_reservation_change(
    '96300000-0000-0000-0000-000000000006','RESCHEDULE',now(),'CLIENT',1200
  )->>'confirmation_target_amount')::numeric,
  360.00::numeric,
  'reschedule target follows 30 percent configuration on new contract value'
);

select ok(
  (public.calculate_reservation_change(
    '96300000-0000-0000-0000-000000000006','RESCHEDULE',now(),'CLIENT',1200
  )->>'customer_reschedule_limit_reached')::boolean,
  'configured max_reschedules zero immediately governs client reschedule limit'
);

select throws_ok(
  $$ update public.appointments set confirmation_percentage_snapshot=50 where id='96300000-0000-0000-0000-000000000006' $$,
  '42501','APPOINTMENT_CONFIRMATION_SNAPSHOT_IMMUTABLE',
  'reservation confirmation snapshot cannot drift after capture'
);

select * from finish();
rollback;
