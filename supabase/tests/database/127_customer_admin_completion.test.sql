begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(34);

select has_column('public','customers','address','customers stores the administrative address');
select has_column('public','customers','anonymized_at','customers records LGPD anonymization time');

select has_function('public','service_admin_list_customers_page',array['text','integer','integer'],'paginated customer read model exists');
select has_function('public','service_admin_create_customer',array['text','text','text','text','text','date','uuid'],'admin customer creation boundary exists');
select has_function('public','service_admin_update_customer_identity',array['uuid','text','text','text','text','date','uuid'],'admin customer identity update boundary exists');
select has_function('public','service_admin_anonymize_customer',array['uuid','uuid'],'LGPD anonymization boundary exists');

select is(
  (select count(*)::integer from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname in (
     'service_admin_list_customers_page','service_admin_create_customer',
     'service_admin_update_customer_identity','service_admin_anonymize_customer'
   ) and p.prosecdef),
  4,
  'all customer administration boundaries are SECURITY DEFINER'
);

select is(
  (select count(*)::integer from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname in (
     'service_admin_list_customers_page','service_admin_create_customer',
     'service_admin_update_customer_identity','service_admin_anonymize_customer'
   ) and p.proconfig::text='{"search_path=public, pg_temp"}'),
  4,
  'all customer administration boundaries pin search_path'
);

select ok(
  not has_function_privilege('anon','public.service_admin_create_customer(text,text,text,text,text,date,uuid)','EXECUTE')
  and not has_function_privilege('authenticated','public.service_admin_create_customer(text,text,text,text,text,date,uuid)','EXECUTE')
  and not has_function_privilege('anon','public.service_admin_update_customer_identity(uuid,text,text,text,text,date,uuid)','EXECUTE')
  and not has_function_privilege('authenticated','public.service_admin_update_customer_identity(uuid,text,text,text,text,date,uuid)','EXECUTE')
  and not has_function_privilege('anon','public.service_admin_anonymize_customer(uuid,uuid)','EXECUTE')
  and not has_function_privilege('authenticated','public.service_admin_anonymize_customer(uuid,uuid)','EXECUTE'),
  'anon/authenticated cannot mutate customers directly'
);

select ok(
  has_function_privilege('service_role','public.service_admin_list_customers_page(text,integer,integer)','EXECUTE')
  and has_function_privilege('service_role','public.service_admin_create_customer(text,text,text,text,text,date,uuid)','EXECUTE')
  and has_function_privilege('service_role','public.service_admin_update_customer_identity(uuid,text,text,text,text,date,uuid)','EXECUTE')
  and has_function_privilege('service_role','public.service_admin_anonymize_customer(uuid,uuid)','EXECUTE'),
  'service_role can execute customer administration boundaries'
);

insert into auth.users(id,instance_id,aud,role,email,encrypted_password,created_at,updated_at)
values('14000000-0000-4000-8000-000000000001','00000000-0000-0000-0000-000000000000','authenticated','authenticated','owner-customers@example.test','',now(),now());
insert into public.admin_users(id,auth_user_id,display_name,role)
values('24000000-0000-4000-8000-000000000001','14000000-0000-4000-8000-000000000001','Owner Customers','OWNER');

select lives_ok(
  $$select public.service_admin_create_customer(
    'PERSON','Cliente Etapa 4','CLIENTE.ETAPA4@EXAMPLE.TEST','(48) 99999-0000',
    'Rua do Estúdio, 100','1990-05-10'::date,
    '24000000-0000-4000-8000-000000000001'::uuid
  )$$,
  'owner can create a customer without a public write grant'
);

select is((select email from public.customers where name='Cliente Etapa 4'),'cliente.etapa4@example.test','creation normalizes email');
select is((select address from public.customers where name='Cliente Etapa 4'),'Rua do Estúdio, 100','creation persists address');
select is((select birth_date from public.customers where name='Cliente Etapa 4'),'1990-05-10'::date,'creation persists birth date');
select is((select count(*)::integer from public.audit_logs where entity_type='CUSTOMER' and action='CUSTOMER_CREATED' and entity_id=(select id from public.customers where name='Cliente Etapa 4')),1,'customer creation is audited');
select ok(
  exists(select 1 from public.customer_identity_keys k join public.customers c on c.id=k.customer_id where c.name='Cliente Etapa 4')
  and not exists(select 1 from public.customer_identity_keys k join public.customers c on c.id=k.customer_id where c.name='Cliente Etapa 4' and k.normalized_value !~ '^sha256:[0-9a-f]{64}$'),
  'new customer identity keys are irreversible fingerprints, not plaintext PII'
);

select throws_ok(
  $$select public.service_admin_create_customer(
    'PERSON','Duplicado','CLIENTE.ETAPA4@EXAMPLE.TEST',null,null,null,
    '24000000-0000-4000-8000-000000000001'::uuid
  )$$,
  'P0001','CUSTOMER_EMAIL_ALREADY_EXISTS',
  'normalized duplicate email is rejected'
);

select lives_ok(
  $$select public.service_admin_update_customer_identity(
    (select id from public.customers where name='Cliente Etapa 4'),
    'Cliente Etapa 4 Editado','editado@example.test','48999990001','Avenida Atualizada, 200','1991-06-11'::date,
    '24000000-0000-4000-8000-000000000001'::uuid
  )$$,
  'owner can edit the complete customer identity'
);

select ok(
  exists(select 1 from public.customers where name='Cliente Etapa 4 Editado' and email='editado@example.test' and phone='48999990001' and address='Avenida Atualizada, 200' and birth_date='1991-06-11'::date),
  'complete identity edit persists name, email, phone, address and birth date'
);
select is((select count(*)::integer from public.audit_logs where entity_type='CUSTOMER' and action='CUSTOMER_IDENTITY_UPDATED' and entity_id=(select id from public.customers where name='Cliente Etapa 4 Editado')),1,'identity update is audited without requiring a financial mutation');

insert into public.customers(customer_type,name,email)
select 'PERSON',format('Etapa4 Pagina %s',lpad(g::text,3,'0')),format('pagina%s@example.test',g)
from generate_series(1,55) g;

select is((public.service_admin_list_customers_page('Etapa4 Pagina',25,0)->>'total')::integer,55,'paginated read model reports the full filtered total');
select is(jsonb_array_length(public.service_admin_list_customers_page('Etapa4 Pagina',25,0)->'customers'),25,'first page has requested page size');
select is((public.service_admin_list_customers_page('Etapa4 Pagina',25,0)->>'has_more')::boolean,true,'first page reports more rows');
select is(jsonb_array_length(public.service_admin_list_customers_page('Etapa4 Pagina',25,50)->'customers'),5,'last page returns the remaining rows');
select is((public.service_admin_list_customers_page('Etapa4 Pagina',25,50)->>'has_more')::boolean,false,'last page reports no hidden rows');

insert into public.customer_balance_movements(
  customer_id,movement_type,direction,amount,appointment_id,policy_action_id,choice_origin,
  admin_user_id,admin_request_reference,ip_address,user_agent,request_id,idempotency_key
)
select id,'CREDIT_FROM_RETURN','CREDIT',321.45,null,null,'ADMIN_UI',
  '24000000-0000-4000-8000-000000000001','etapa4-lgpd-test','127.0.0.1','pgtap-etapa4','etapa4-finance-request','etapa4-finance-idempotency'
from public.customers where name='Cliente Etapa 4 Editado';

insert into public.legacy_import_batches(id,source,source_label,status)
values('34000000-0000-4000-8000-000000000001','ETAPA4_TEST','Etapa 4','IMPORTED');
insert into public.legacy_customer_sources(batch_id,source,source_key,customer_id,match_method,match_confidence,raw_snapshot)
select '34000000-0000-4000-8000-000000000001','ETAPA4_TEST','customer-row-1',id,'EMAIL','HIGH',
  jsonb_build_object('name',name,'email',email,'phone',phone,'birth_date',birth_date)
from public.customers where name='Cliente Etapa 4 Editado';

insert into public.notification_delivery_logs(
  event_key,channel,audience,customer_id,recipient_hash,recipient_masked,status,attempt_count,idempotency_key,payload_snapshot
)
select 'BIRTHDAY','EMAIL','CUSTOMER',id,repeat('a',64),'e***@example.test','SENT',1,'etapa4-lgpd-notification',jsonb_build_object('email',email,'name',name)
from public.customers where name='Cliente Etapa 4 Editado';

select lives_ok(
  $$select public.service_admin_anonymize_customer(
    (select id from public.customers where name='Cliente Etapa 4 Editado'),
    '24000000-0000-4000-8000-000000000001'::uuid
  )$$,
  'LGPD anonymization succeeds without bypassing append-only identity history'
);

select ok(
  exists(select 1 from public.customers where anonymized_at is not null and name like 'Cliente anonimizado %' and email is null and phone is null and address is null and birth_date is null and cpf_cnpj is null),
  'LGPD anonymization removes canonical PII and preserves the customer row'
);
select is((select amount from public.customer_balance_movements where idempotency_key='etapa4-finance-idempotency'),321.45::numeric,'LGPD anonymization preserves financial amount');
select ok(
  exists(select 1 from public.customer_balance_movements m join public.customers c on c.id=m.customer_id where m.idempotency_key='etapa4-finance-idempotency' and c.anonymized_at is not null),
  'LGPD anonymization preserves the financial customer_id relationship'
);
select ok(
  exists(select 1 from public.customer_identity_keys k join public.customers c on c.id=k.customer_id where c.anonymized_at is not null and c.name like 'Cliente anonimizado %')
  and not exists(select 1 from public.customer_identity_keys k join public.customers c on c.id=k.customer_id where c.anonymized_at is not null and c.name like 'Cliente anonimizado %' and k.normalized_value !~ '^sha256:[0-9a-f]{64}$'),
  'LGPD anonymization retains only irreversible append-only identity fingerprints for access-control history'
);
select is((select raw_snapshot from public.legacy_customer_sources where source='ETAPA4_TEST' and source_key='customer-row-1'),'{"lgpd_anonymized": true}'::jsonb,'LGPD anonymization scrubs linked legacy PII snapshot');
select ok(
  exists(select 1 from public.notification_delivery_logs where idempotency_key='etapa4-lgpd-notification' and recipient_masked='***' and payload_snapshot='{}'::jsonb and recipient_hash<>repeat('a',64)),
  'LGPD anonymization scrubs notification recipient evidence while keeping delivery history'
);
select is((select count(*)::integer from public.audit_logs where entity_type='CUSTOMER' and action='CUSTOMER_ANONYMIZED' and entity_id=(select customer_id from public.customer_balance_movements where idempotency_key='etapa4-finance-idempotency')),1,'LGPD anonymization is audited once');
select is(
  (select count(*)::integer from public.customer_identity_keys where normalized_value !~ '^sha256:[0-9a-f]{64}$'),
  0,
  'migration leaves no plaintext identity keys in the append-only identity table'
);

select * from finish();
rollback;
