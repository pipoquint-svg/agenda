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
  'creates customer without writing direct PII into audit evidence'
);

select lives_ok(
  $$select public.service_admin_anonymize_customer(
    (select id from public.customers where name='Cliente PII Audit'),
    '24000000-0000-4000-8000-000000000128'::uuid
  )$$,
  'anonymization succeeds without mutating append-only audit history'
);

select is(
  (select count(*)::integer from public.audit_logs where action='CUSTOMER_ANONYMIZED'),
  1,
  'anonymization leaves one non-PII audit marker'
);

select is(
  (
    select count(*)::integer
    from public.audit_logs a
    where a.entity_type='CUSTOMER'
      and a.entity_id=(select id from public.customers where name like 'Cliente anonimizado %' limit 1)
      and (
        coalesce(a.before_json,'{}'::jsonb) ?| array['name','legal_name','cpf_cnpj','email','phone','address','birth_date','notes']
        or coalesce(a.after_json,'{}'::jsonb) ?| array['name','legal_name','cpf_cnpj','email','phone','address','birth_date','notes']
      )
  ),
  0,
  'customer audit evidence contains no direct PII keys'
);

select throws_ok(
  $$update public.audit_logs set after_json='{}'::jsonb where action='CUSTOMER_ANONYMIZED'$$,
  '42501',
  'AUDIT_TRAIL_APPEND_ONLY',
  'audit trail remains append-only after LGPD implementation'
);

select ok(
  exists(select 1 from public.customers where name like 'Cliente anonimizado %' and email is null and phone is null and address is null and birth_date is null and anonymized_at is not null),
  'canonical customer PII is removed while customer row remains'
);

select * from finish();
rollback;
