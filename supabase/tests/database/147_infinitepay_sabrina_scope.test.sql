begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(6);

insert into public.booking_pages(id,slug,display_name,title,brand_key,payment_provider)
values
  ('94700000-0000-0000-0000-000000000001','sabrina','Sabrina Gate 4','Sabrina Gate 4','SABRINA','MERCADO_PAGO'),
  ('94700000-0000-0000-0000-000000000002','natal-2026','Natal Gate 4','Natal Gate 4','SABRINA','MERCADO_PAGO'),
  ('94700000-0000-0000-0000-000000000003','blacksheep','BlackSheep Gate 4','BlackSheep Gate 4','BLACKSHEEP','MERCADO_PAGO')
on conflict (slug) do nothing;

select is(
  (select payment_provider from public.booking_pages where slug='blacksheep'),
  'MERCADO_PAGO',
  'BlackSheep remains Mercado Pago by default'
);

select throws_ok(
  $$ update public.booking_pages set payment_provider='INFINITEPAY' where slug='blacksheep' $$,
  '23514',
  null,
  'BlackSheep cannot be switched to InfinitePay'
);

select lives_ok(
  $$ update public.booking_pages set payment_provider='INFINITEPAY' where slug='sabrina' $$,
  'Sabrina booking page may be configured for InfinitePay'
);

select lives_ok(
  $$ update public.booking_pages set payment_provider='INFINITEPAY' where slug='natal-2026' $$,
  'Natal 2026 booking page may be configured for InfinitePay'
);

insert into public.booking_pages(id,slug,display_name,title,brand_key,payment_provider)
values ('94700000-0000-0000-0000-000000000004','sabrina-future-page','Future Sabrina','Future Sabrina','SABRINA','MERCADO_PAGO');
select throws_ok(
  $$ update public.booking_pages set payment_provider='INFINITEPAY' where slug='sabrina-future-page' $$,
  '23514',
  null,
  'InfinitePay scope does not silently expand to future Sabrina pages'
);

insert into public.resources(id,name,resource_type)
values ('94700000-0000-0000-0000-000000000010','Gate 4 Studio','PHYSICAL');
insert into public.employees(id,name)
values ('94700000-0000-0000-0000-000000000011','Gate 4 Employee');
insert into public.categories(id,name,slug)
values ('94700000-0000-0000-0000-000000000012','Gate 4','gate-4-provider');
insert into public.services(
  id,category_id,name,slug,base_duration_minutes,base_price,minimum_people,maximum_people,
  maximum_booking_horizon_days,confirmation_percentage,pix_discount_percent,payment_mode
) values (
  '94700000-0000-0000-0000-000000000013','94700000-0000-0000-0000-000000000012',
  'Gate 4 Service','gate-4-service',60,1000,1,10,5000,50,0,'MINIMUM_OR_FULL'
);
insert into public.service_change_policies(
  service_id,notice_hours,reschedule_first_early_percent,reschedule_first_late_percent,
  reschedule_repeat_percent,cancellation_late_percent,reschedule_first_early_penalty_type,
  reschedule_first_early_penalty_value,reschedule_first_late_penalty_type,
  reschedule_first_late_penalty_value,reschedule_repeat_penalty_type,reschedule_repeat_penalty_value,
  cancellation_late_penalty_type,cancellation_late_penalty_value
) values (
  '94700000-0000-0000-0000-000000000013',48,0,20,20,20,
  'PERCENT',0,'PERCENT',20,'PERCENT',20,'PERCENT',20
);
insert into public.service_employees(id,service_id,employee_id)
values ('94700000-0000-0000-0000-000000000014','94700000-0000-0000-0000-000000000013','94700000-0000-0000-0000-000000000011');
insert into public.service_resources(service_id,resource_id)
values ('94700000-0000-0000-0000-000000000013','94700000-0000-0000-0000-000000000010');
insert into public.customers(id,name,email,phone,cpf_cnpj)
values ('94700000-0000-0000-0000-000000000015','Gate 4 Customer','gate4@example.com','48999999470','52998224725');
insert into public.appointments(
  id,public_code,service_id,service_employee_id,service_name_snapshot,primary_customer_id,
  status,financial_status,start_at,end_at,duration_minutes,people_count,hold_expires_at,
  commercial_value,payment_provider_snapshot
) values (
  '94700000-0000-0000-0000-000000000016','IP-MP-GUARD','94700000-0000-0000-0000-000000000013',
  '94700000-0000-0000-0000-000000000014','Gate 4 Service','94700000-0000-0000-0000-000000000015',
  'AWAITING_PAYMENT','PENDING','2035-05-01 09:00:00-03','2035-05-01 10:00:00-03',60,1,
  now()+interval '30 minutes',1000,'INFINITEPAY'
);
insert into public.appointment_access_tokens(appointment_id,token_hash,scope)
values (
  '94700000-0000-0000-0000-000000000016',
  encode(digest('gate4-provider-token-abcdefghijklmnopqrstuvwxyz-123456','sha256'),'hex'),
  'MANAGE'
);

select throws_ok(
  $$ select public.service_create_payment_intent_by_token(
    'gate4-provider-token-abcdefghijklmnopqrstuvwxyz-123456',
    'FULL','PIX','gate4_mp_guard_request_12345'
  ) $$,
  'P0001',
  'PAYMENT_PROVIDER_MISMATCH',
  'InfinitePay appointment cannot create a Mercado Pago payment intent'
);

select * from finish();
rollback;
