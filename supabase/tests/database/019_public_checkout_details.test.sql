begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(18);

select ok(public.is_valid_cpf('529.982.247-25'), 'valid CPF is accepted');
select ok(not public.is_valid_cpf('111.111.111-11'), 'repeated CPF is rejected');

insert into public.categories (id, name, slug)
values ('96000000-0000-0000-0000-000000000001', 'Checkout Test', 'checkout-test');

insert into public.resources (id, name, resource_type)
values
  ('96000000-0000-0000-0000-000000000002', 'CHECKOUT TEST STUDIO', 'PHYSICAL'),
  ('96000000-0000-0000-0000-000000000003', 'CHECKOUT TEST PERSON', 'PERSON');

insert into public.employees (id, name, resource_id)
values ('96000000-0000-0000-0000-000000000004', 'Checkout Person', '96000000-0000-0000-0000-000000000003');

insert into public.services (
  id, category_id, name, slug, base_duration_minutes, base_price,
  minimum_people, maximum_people, maximum_booking_horizon_days,
  checkout_hold_minutes, payment_hold_minutes, requires_terms
) values (
  '96000000-0000-0000-0000-000000000005',
  '96000000-0000-0000-0000-000000000001',
  'Checkout Service', 'checkout-service', 60, 500.00,
  1, 1, 5000, 10, 30, true
);

insert into public.service_employees (id, service_id, employee_id)
values ('96000000-0000-0000-0000-000000000006', '96000000-0000-0000-0000-000000000005', '96000000-0000-0000-0000-000000000004');

insert into public.service_resources (service_id, resource_id, is_required)
values
  ('96000000-0000-0000-0000-000000000005', '96000000-0000-0000-0000-000000000002', true),
  ('96000000-0000-0000-0000-000000000005', '96000000-0000-0000-0000-000000000003', true);

insert into public.service_fields (
  id, service_id, field_key, label, field_type, is_required, sort_order
) values (
  '96000000-0000-0000-0000-000000000007',
  '96000000-0000-0000-0000-000000000005',
  'dpp', 'Data prevista', 'DATE', true, 10
);

insert into public.terms_versions (
  id, service_id, name, version, content, is_active, published_at
) values (
  '96000000-0000-0000-0000-000000000008',
  '96000000-0000-0000-0000-000000000005',
  'Termos do serviço', '1.0', 'Conteúdo contratual de teste.', true, now() - interval '1 day'
);

-- 2030-01-01 is Tuesday (DOW 2).
insert into public.availability_rules (
  service_employee_id, weekday, start_local_time, end_local_time, slot_interval_minutes
) values ('96000000-0000-0000-0000-000000000006', 2, '09:00', '11:00', 30);

insert into public.resource_availability_rules (resource_id, weekday, start_local_time, end_local_time)
values
  ('96000000-0000-0000-0000-000000000002', 2, '09:00', '11:00'),
  ('96000000-0000-0000-0000-000000000003', 2, '09:00', '11:00');

insert into public.booking_page_services (booking_page_id, service_id, sort_order)
select id, '96000000-0000-0000-0000-000000000005', 10
from public.booking_pages where slug = 'sabrina';

create temporary table checkout_hold as
select public.public_create_checkout_hold(
  'sabrina',
  '96000000-0000-0000-0000-000000000005',
  '96000000-0000-0000-0000-000000000006',
  '[]'::jsonb,
  1,
  '2030-01-01 09:00:00-03'::timestamptz
) as payload;

create temporary table checkout_context as
select public.public_get_checkout_context((select payload->>'checkout_hold_token' from checkout_hold)) as payload;

select is(jsonb_array_length((select payload->'fields' from checkout_context)), 1, 'checkout context exposes service-specific fields');
select is(jsonb_array_length((select payload->'terms' from checkout_context)), 1, 'checkout context exposes the current service terms');

create temporary table customer_bind as
select public.public_bind_checkout_customer(
  (select payload->>'checkout_hold_token' from checkout_hold),
  'Cliente Checkout',
  'cliente.checkout@example.com',
  '(48) 99999-1234',
  '529.982.247-25',
  true
) as payload;

select ok((select (payload->>'customer_bound')::boolean from customer_bind), 'customer is bound to the active hold');

select is(
  (select recovery_phone from public.checkout_holds where id = ((select payload->>'checkout_hold_id' from checkout_hold))::uuid),
  '48999991234',
  'validated phone is immediately available for minimal hold recovery'
);

select is(
  (select regexp_replace(c.cpf_cnpj, '\D', '', 'g')
   from public.customers c
   join public.checkout_holds ch on ch.primary_customer_id = c.id
   where ch.id = ((select payload->>'checkout_hold_id' from checkout_hold))::uuid),
  '52998224725',
  'native booking stores the validated CPF instead of leaving it blank'
);

select throws_ok(
  $$ select public.validate_checkout_answers(
    '96000000-0000-0000-0000-000000000005',
    '[{"service_field_id":"96000000-0000-0000-0000-000000000007","value":123}]'::jsonb
  ) $$,
  'P0001', 'INVALID_SERVICE_ANSWER_VALUE',
  'service-field type validation rejects a number for a DATE field'
);

select ok(
  not has_function_privilege('anon', 'public.service_submit_public_checkout(text,text,uuid[],jsonb,inet,text)', 'EXECUTE'),
  'anonymous clients cannot call the server-only submit primitive'
);

select ok(
  not has_function_privilege('anon', 'public.public_promote_checkout_hold(text,text,uuid[],jsonb,text)', 'EXECUTE'),
  'anonymous clients cannot bypass server-side terms evidence capture'
);

create temporary table submit_result as
select public.service_submit_public_checkout(
  (select payload->>'checkout_hold_token' from checkout_hold),
  null,
  array['96000000-0000-0000-0000-000000000008'::uuid],
  '[{"service_field_id":"96000000-0000-0000-0000-000000000007","value":"2030-03-01"}]'::jsonb,
  '203.0.113.10'::inet,
  'BlackSheep Checkout Test UA'
) as payload;

select is((select payload->>'status' from submit_result), 'AWAITING_PAYMENT', 'cash checkout promotes the hold into an awaiting-payment appointment');
select is((select status::text from public.checkout_holds where id = ((select payload->>'checkout_hold_id' from checkout_hold))::uuid), 'PROMOTED', 'checkout hold is atomically marked promoted');
select is((select count(*)::integer from public.appointments where id = ((select payload->>'appointment_id' from submit_result))::uuid), 1, 'exactly one appointment is created');

select is(
  (select host(ip_address) from public.appointment_term_acceptances where appointment_id = ((select payload->>'appointment_id' from submit_result))::uuid),
  '203.0.113.10',
  'terms acceptance stores server-observed IP evidence'
);

select is(
  (select user_agent from public.appointment_term_acceptances where appointment_id = ((select payload->>'appointment_id' from submit_result))::uuid),
  'BlackSheep Checkout Test UA',
  'terms acceptance stores server-observed User-Agent evidence'
);

select is(
  (select value_json #>> '{}' from public.appointment_answers where appointment_id = ((select payload->>'appointment_id' from submit_result))::uuid),
  '2030-03-01',
  'validated service answers are snapshotted on the appointment'
);

select is(
  (select count(*)::integer from public.resource_allocations where appointment_id = ((select payload->>'appointment_id' from submit_result))::uuid and status = 'AWAITING_PAYMENT'),
  2,
  'all protected resources transfer to the awaiting-payment appointment without a release gap'
);

select is(
  (select cpf_cnpj_snapshot from public.appointment_participants where appointment_id = ((select payload->>'appointment_id' from submit_result))::uuid and role = 'BOOKER'),
  '52998224725',
  'booker identity snapshot includes the CPF for the new native reservation'
);

select * from finish();
rollback;
