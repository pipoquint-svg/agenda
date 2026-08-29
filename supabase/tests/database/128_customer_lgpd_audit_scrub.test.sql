begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(6);

insert into auth.users(id,instance_id,aud,role,email,encrypted_password,created_at,updated_at)
values('14000000-0000-4000-8000-000000000128','00000000-0000-0000-0000-000000000000','authenticated','authenticated','owner-lgpd-audit@example.test','',now(),now());
insert into public.admin_users(id,auth_user_id,display_name,role)
values('24000000-0000-4000-8000-000000000128','14000000-0000-4000-8000-000000000128','Owner LGPD Audit','OWNER');

select lives_ok(
  $$select public.service_admin_create_customer(
    'PERSON','Cliente PII Audit','pii.audit@example.test','48999990128',
    'Rua PII, 128','1988-01-28'::date,
    '24000000-0000-4000-8000-000000000128'::uuid
  )$$,
  'creates customer used by LGPD audit scrub test'
);

insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
select
  '24000000-0000-4000-8000-000000000128'::uuid,
  'CUSTOMER',id,'LEGACY_CUSTOMER_SNAPSHOT',
  jsonb_build_object('name',name,'email',email,'phone',phone,'address',address,'birth_date',birth_date),
  jsonb_build_object('name',name,'email',email,'phone',phone,'address',address,'birth_date',birth_date),
  'ADMIN_UI'
from public.customers where name='Cliente PII Audit';

select lives_ok(
  $$select public.service_admin_anonymize_customer(
    (select id from public.customers where name='Cliente PII Audit'),
    '24000000-0000-4000-8000-000000000128'::uuid
  )$$,
  'anonymization scrubs customer audit snapshots'
);

select is(
  (select before_json from public.audit_logs where action='LEGACY_CUSTOMER_SNAPSHOT'),
  '{"lgpd_anonymized": true}'::jsonb,
  'old audit before snapshot no longer contains customer PII'
);
select is(
  (select after_json from public.audit_logs where action='LEGACY_CUSTOMER_SNAPSHOT'),
  '{"lgpd_anonymized": true}'::jsonb,
  'old audit after snapshot no longer contains customer PII'
);
select is(
  (select count(*)::integer from public.audit_logs where action='CUSTOMER_ANONYMIZED'),
  1,
  'anonymization leaves one non-PII audit marker'
);
select ok(
  exists(select 1 from public.customers where name like 'Cliente anonimizado %' and email is null and phone is null and address is null and birth_date is null and anonymized_at is not null),
  'canonical customer PII is removed while customer row remains'
);

select * from finish();
rollback;
