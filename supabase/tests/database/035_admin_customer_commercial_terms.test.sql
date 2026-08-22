begin;

select plan(10);

select has_function('public', 'service_admin_list_customers', array['text','integer'], 'admin customer list exists');
select has_function('public', 'service_admin_get_customer_commercial_profile', array['uuid'], 'admin customer profile exists');
select has_function('public', 'service_admin_set_customer_commercial_terms', array['uuid','boolean','integer','integer','boolean','text','integer','boolean','uuid[]','uuid'], 'admin customer terms mutation exists');

insert into public.customers (id, customer_type, name, email)
values ('22222222-2222-4222-8222-222222222222', 'BUSINESS', 'Volt Test', 'financeiro@volt.example');

select lives_ok(
  $$select public.service_admin_set_customer_commercial_terms(
    '22222222-2222-4222-8222-222222222222'::uuid,
    true,
    1440,
    2,
    true,
    'INVOICE',
    15,
    true,
    '{}'::uuid[],
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'::uuid
  )$$,
  'corporate customer terms can be configured'
);

select is(
  (select billing_mode from public.customer_commercial_terms where customer_id = '22222222-2222-4222-8222-222222222222'),
  'INVOICE',
  'billing mode is invoice'
);

select is(
  (select invoice_due_days from public.customer_commercial_terms where customer_id = '22222222-2222-4222-8222-222222222222'),
  15,
  'invoice due days are 15'
);

select is(
  (select max_active_prebooks from public.customer_commercial_terms where customer_id = '22222222-2222-4222-8222-222222222222'),
  2,
  'pre reservation limit is persisted'
);

select is(
  (select (public.service_admin_get_customer_commercial_profile('22222222-2222-4222-8222-222222222222'::uuid)->'terms'->>'can_prebook')::boolean),
  true,
  'profile exposes pre booking authorization'
);

select is(
  (select count(*)::integer from public.audit_logs where entity_type = 'CUSTOMER' and entity_id = '22222222-2222-4222-8222-222222222222' and action = 'COMMERCIAL_TERMS_CHANGED'),
  1,
  'commercial terms change is audited'
);

select is(
  (select jsonb_array_length(public.service_admin_list_customers('Volt', 50)->'customers')),
  1,
  'customer search returns configured customer'
);

select * from finish();
rollback;
