begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(18);

select has_function(
  'public',
  'service_admin_list_customers_page_scoped',
  array['text','integer','integer','text'],
  'scoped customer read model exists'
);
select has_function(
  'public',
  'service_admin_list_customers_page',
  array['text','integer','integer','text'],
  'admin customer list accepts operation_scope'
);
select ok(
  (select p.prosecdef from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'service_admin_list_customers_page_scoped'),
  'scoped read model is SECURITY DEFINER'
);
select ok(
  not (select p.prosecdef from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'service_admin_list_customers_page'
         and pg_get_function_identity_arguments(p.oid) = 'p_search text, p_limit integer, p_offset integer, p_operation_scope text'),
  'four-argument compatibility boundary stays SECURITY INVOKER'
);
select ok(
  not has_function_privilege('anon','public.service_admin_list_customers_page(text,integer,integer,text)','EXECUTE')
  and not has_function_privilege('authenticated','public.service_admin_list_customers_page(text,integer,integer,text)','EXECUTE')
  and not has_function_privilege('anon','public.service_admin_list_customers_page_scoped(text,integer,integer,text)','EXECUTE')
  and not has_function_privilege('authenticated','public.service_admin_list_customers_page_scoped(text,integer,integer,text)','EXECUTE'),
  'browser roles cannot execute scoped customer reads directly'
);
select ok(
  has_function_privilege('service_role','public.service_admin_list_customers_page(text,integer,integer,text)','EXECUTE')
  and has_function_privilege('service_role','public.service_admin_list_customers_page_scoped(text,integer,integer,text)','EXECUTE'),
  'service role can execute scoped customer reads for the admin Edge Function'
);

insert into public.employees (id, name, is_active)
values (
  '99000000-0000-0000-0000-000000000002',
  'QA Sabrina Operation Filter',
  false
);

insert into public.services (
  id, name, slug, base_duration_minutes, is_active, operation_scope
) values (
  '99100000-0000-0000-0000-000000000010',
  'QA Sabrina Operation Filter',
  'qa-sabrina-operation-filter',
  60,
  false,
  'SABRINA'
);

insert into public.service_employees (id, service_id, employee_id, is_active)
values (
  '99100000-0000-0000-0000-000000000020',
  '99100000-0000-0000-0000-000000000010',
  '99000000-0000-0000-0000-000000000002',
  false
);

insert into public.customers (id, name, email)
values
  ('99100000-0000-0000-0000-000000000101', 'Filtro Operação BlackSheep', 'filtro-bs@example.test'),
  ('99100000-0000-0000-0000-000000000102', 'Filtro Operação Sabrina', 'filtro-sabrina@example.test'),
  ('99100000-0000-0000-0000-000000000103', 'Filtro Operação Participante', 'filtro-participante@example.test'),
  ('99100000-0000-0000-0000-000000000104', 'Filtro Operação Ambas', 'filtro-ambas@example.test'),
  ('99100000-0000-0000-0000-000000000105', 'Filtro Operação Sem Reserva', 'filtro-sem-reserva@example.test'),
  ('99100000-0000-0000-0000-000000000106', 'Filtro Operação Draft', 'filtro-draft@example.test'),
  ('99100000-0000-0000-0000-000000000107', 'Filtro Operação Excluída', 'filtro-excluida@example.test');

insert into public.appointments (
  id, public_code, service_id, service_employee_id, status,
  start_at, end_at, duration_minutes, people_count, primary_customer_id,
  origin, is_test, deleted_at,
  checkout_minimum_payment_type_snapshot,
  checkout_minimum_payment_value_snapshot,
  payment_mode_snapshot,
  pix_discount_percent_snapshot,
  card_max_installments_snapshot,
  confirmation_percentage_snapshot
)
values
  (
    '99100000-0000-0000-0000-000000000201','OPFILTER-BS-1',
    '99000000-0000-0000-0000-000000000010','99000000-0000-0000-0000-000000000020','HELD',
    '2035-01-02T12:00:00Z','2035-01-02T13:00:00Z',60,1,'99100000-0000-0000-0000-000000000101',
    'ADMIN',true,null,'PERCENT',50,'MINIMUM_OR_FULL',0,6,50
  ),
  (
    '99100000-0000-0000-0000-000000000202','OPFILTER-SA-1',
    '99100000-0000-0000-0000-000000000010','99100000-0000-0000-0000-000000000020','HELD',
    '2035-01-03T12:00:00Z','2035-01-03T13:00:00Z',60,1,'99100000-0000-0000-0000-000000000102',
    'ADMIN',true,null,'PERCENT',50,'MINIMUM_OR_FULL',0,6,50
  ),
  (
    '99100000-0000-0000-0000-000000000203','OPFILTER-BOTH-BS',
    '99000000-0000-0000-0000-000000000010','99000000-0000-0000-0000-000000000020','HELD',
    '2035-01-04T12:00:00Z','2035-01-04T13:00:00Z',60,1,'99100000-0000-0000-0000-000000000104',
    'ADMIN',true,null,'PERCENT',50,'MINIMUM_OR_FULL',0,6,50
  ),
  (
    '99100000-0000-0000-0000-000000000204','OPFILTER-BOTH-SA',
    '99100000-0000-0000-0000-000000000010','99100000-0000-0000-0000-000000000020','HELD',
    '2035-01-05T12:00:00Z','2035-01-05T13:00:00Z',60,1,'99100000-0000-0000-0000-000000000104',
    'ADMIN',true,null,'PERCENT',50,'MINIMUM_OR_FULL',0,6,50
  ),
  (
    '99100000-0000-0000-0000-000000000205','OPFILTER-DRAFT-SA',
    '99100000-0000-0000-0000-000000000010','99100000-0000-0000-0000-000000000020','DRAFT',
    '2035-01-06T12:00:00Z','2035-01-06T13:00:00Z',60,1,'99100000-0000-0000-0000-000000000106',
    'ADMIN',true,null,'PERCENT',50,'MINIMUM_OR_FULL',0,6,50
  ),
  (
    '99100000-0000-0000-0000-000000000206','OPFILTER-DELETED-BS',
    '99000000-0000-0000-0000-000000000010','99000000-0000-0000-0000-000000000020','HELD',
    '2035-01-07T12:00:00Z','2035-01-07T13:00:00Z',60,1,'99100000-0000-0000-0000-000000000107',
    'ADMIN',true,now(),'PERCENT',50,'MINIMUM_OR_FULL',0,6,50
  );

insert into public.appointment_participants (
  appointment_id, customer_id, role, name_snapshot
) values (
  '99100000-0000-0000-0000-000000000202',
  '99100000-0000-0000-0000-000000000103',
  'END_CUSTOMER',
  'Filtro Operação Participante'
);

select is(
  (public.service_admin_list_customers_page('Filtro Operação',50,0)->>'total')::integer,
  7,
  'legacy three-argument list keeps ALL behavior unchanged'
);
select is(
  (public.service_admin_list_customers_page('Filtro Operação',50,0,'ALL')->>'total')::integer,
  7,
  'explicit ALL keeps every matching customer'
);
select is(
  (public.service_admin_list_customers_page('Filtro Operação',50,0,'BLACKSHEEP')->>'total')::integer,
  2,
  'BlackSheep scope derives customers from real non-deleted reservations'
);
select is(
  (public.service_admin_list_customers_page('Filtro Operação',50,0,'SABRINA')->>'total')::integer,
  3,
  'Sabrina scope includes primary customers and appointment participants'
);
select is(
  (public.service_admin_list_customers_page('Participante',50,0,'SABRINA')->>'total')::integer,
  1,
  'search and operation scope compose server-side'
);
select is(
  (public.service_admin_list_customers_page('Filtro Operação',2,0,'SABRINA')->>'total')::integer,
  3,
  'filtered pagination reports the scoped total'
);
select is(
  jsonb_array_length(public.service_admin_list_customers_page('Filtro Operação',2,0,'SABRINA')->'customers'),
  2,
  'first scoped page respects page size'
);
select is(
  (public.service_admin_list_customers_page('Filtro Operação',2,0,'SABRINA')->>'has_more')::boolean,
  true,
  'first scoped page reports remaining rows'
);
select is(
  jsonb_array_length(public.service_admin_list_customers_page('Filtro Operação',2,2,'SABRINA')->'customers'),
  1,
  'last scoped page returns the remaining customer'
);
select is(
  (public.service_admin_list_customers_page('Filtro Operação',2,2,'SABRINA')->>'has_more')::boolean,
  false,
  'last scoped page reports no hidden rows'
);
select is(
  (public.service_admin_list_customers_page('Filtro Operação',50,0,'sabrina')->>'total')::integer,
  3,
  'operation scope normalization is case-insensitive'
);
select throws_ok(
  $$select public.service_admin_list_customers_page('Filtro Operação',50,0,'OUTRA')$$,
  'P0001',
  'CUSTOMER_OPERATION_SCOPE_INVALID',
  'invalid operation scope is rejected at the database boundary'
);

select * from finish();
rollback;
