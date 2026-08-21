begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(11);

insert into public.categories (id, name, slug)
values ('98000000-0000-0000-0000-000000000001', 'MP Access', 'mp-access-test');

insert into public.employees (id, name)
values ('98000000-0000-0000-0000-000000000002', 'MP Employee');

insert into public.services (
  id, category_id, name, slug, base_duration_minutes, base_price,
  minimum_people, maximum_people, maximum_booking_horizon_days, confirmation_percentage
) values (
  '98000000-0000-0000-0000-000000000010',
  '98000000-0000-0000-0000-000000000001',
  'MP Service', 'mp-service', 60, 1000, 1, 1, 5000, 40
);

insert into public.service_employees (id, service_id, employee_id)
values ('98000000-0000-0000-0000-000000000011','98000000-0000-0000-0000-000000000010','98000000-0000-0000-0000-000000000002');

insert into public.customers (id, name, email, phone, cpf_cnpj)
values ('98000000-0000-0000-0000-000000000020','MP Customer','mp.customer@example.com','48999991111','52998224725');

insert into public.appointments (
  id, public_code, service_id, service_employee_id, service_name_snapshot,
  primary_customer_id, status, financial_status, start_at, end_at,
  duration_minutes, people_count, hold_expires_at, commercial_value
) values (
  '98000000-0000-0000-0000-000000000030','MP-PUBLIC-1',
  '98000000-0000-0000-0000-000000000010','98000000-0000-0000-0000-000000000011','MP Service',
  '98000000-0000-0000-0000-000000000020','AWAITING_PAYMENT','PENDING',
  '2035-06-01 09:00:00-03','2035-06-01 10:00:00-03',60,1,now()+interval '30 minutes',1000
);

insert into public.appointment_access_tokens (appointment_id, token_hash, scope)
values
  ('98000000-0000-0000-0000-000000000030', encode(digest('manage-token-abcdefghijklmnopqrstuvwxyz-123456','sha256'),'hex'), 'MANAGE'),
  ('98000000-0000-0000-0000-000000000030', encode(digest('view-token-abcdefghijklmnopqrstuvwxyz-12345678','sha256'),'hex'), 'VIEW');

select is(
  public.resolve_appointment_access_token('manage-token-abcdefghijklmnopqrstuvwxyz-123456','PAY'),
  '98000000-0000-0000-0000-000000000030'::uuid,
  'MANAGE appointment token is allowed to pay its own appointment'
);

select throws_ok(
  $$ select public.resolve_appointment_access_token('view-token-abcdefghijklmnopqrstuvwxyz-12345678','PAY') $$,
  'P0001','TOKEN_SCOPE_DENIED',
  'VIEW token cannot initiate payment'
);

select is(
  (public.service_get_public_payment_context('manage-token-abcdefghijklmnopqrstuvwxyz-123456')->>'confirmation_percentage')::numeric,
  40::numeric,
  'payment context exposes the service confirmation percentage'
);

select is(
  (public.service_get_public_payment_context('manage-token-abcdefghijklmnopqrstuvwxyz-123456')->>'minimum_due_contract_amount')::numeric,
  400::numeric,
  'payment context calculates minimum amount from the contract target'
);

create temporary table mp_intent as
select public.service_create_payment_intent_by_token(
  'manage-token-abcdefghijklmnopqrstuvwxyz-123456',
  'MINIMUM',
  'PIX',
  'request_key_123456789'
) as payload;

select is((select (payload->>'contract_amount_settled')::numeric from mp_intent),400::numeric,'token-scoped MINIMUM intent settles the configured 40 percent target');
select is((select (payload->>'cash_amount')::numeric from mp_intent),380::numeric,'token-scoped PIX applies 5 percent only to this transaction');

select ok(
  not has_function_privilege('anon','public.service_create_payment_intent_by_token(text,text,text,text)','EXECUTE'),
  'anonymous SQL client cannot call payment intent service function directly'
);

select ok(
  not has_function_privilege('anon','public.create_payment_intent(uuid,numeric,text,text)','EXECUTE'),
  'anonymous SQL client cannot bypass token scope using core payment intent'
);

select lives_ok(
  $$ select public.service_store_provider_payment_snapshot(
    ((select payload->>'transaction_id' from mp_intent))::uuid,
    'mp-provider-123',
    '{"id":"mp-provider-123","status":"pending"}'::jsonb
  ) $$,
  'backend can associate a provider payment id with a pending transaction'
);

select is(
  (select provider_payment_id from public.payment_transactions where id=((select payload->>'transaction_id' from mp_intent))::uuid),
  'mp-provider-123',
  'provider payment association is persisted'
);

select lives_ok(
  $$ select public.service_fail_payment_intent(
    ((select payload->>'transaction_id' from mp_intent))::uuid,
    'MERCADO_PAGO_CREATE_REJECTED',
    '{"http_status":400}'::jsonb
  ) $$,
  'backend can explicitly close a locally-created intent rejected before provider id approval'
);

select * from finish();
rollback;
