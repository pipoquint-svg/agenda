begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(6);

insert into auth.users(id,instance_id,aud,role,email,encrypted_password,created_at,updated_at)
values('14000000-0000-4000-8000-000000000129','00000000-0000-0000-0000-000000000000','authenticated','authenticated','owner-lgpd-legacy@example.test','',now(),now());
insert into public.admin_users(id,auth_user_id,display_name,role)
values('24000000-0000-4000-8000-000000000129','14000000-0000-4000-8000-000000000129','Owner LGPD Legacy','OWNER');

select lives_ok(
  $$select public.service_admin_create_customer(
    'PERSON','Cliente Amelia LGPD','amelia.lgpd@example.test','48999990129',
    'Rua Amelia, 129','1989-01-29'::date,
    '24000000-0000-4000-8000-000000000129'::uuid
  )$$,
  'creates customer used by legacy snapshot test'
);

insert into public.legacy_amelia_bookings(
  amelia_booking_id,matched_customer_id,customer_name,customer_email,customer_phone,cpf_cnpj,
  service_name,start_at,end_at,amelia_price_amount,payment_status_raw,payment_method_raw,custom_fields_json,notes
)
select
  'lgpd-129',id,name,email,phone,'12345678901',
  'Ensaio histórico','2025-01-29 10:00:00-03'::timestamptz,'2025-01-29 11:00:00-03'::timestamptz,
  789.90,'paid','pix',jsonb_build_object('birth_date','1989-01-29','email',email),'observação pessoal'
from public.customers where name='Cliente Amelia LGPD';

select lives_ok(
  $$select public.service_admin_anonymize_customer(
    (select id from public.customers where name='Cliente Amelia LGPD'),
    '24000000-0000-4000-8000-000000000129'::uuid
  )$$,
  'anonymization cleans legacy Amelia customer snapshots'
);

select ok(
  exists(select 1 from public.legacy_amelia_bookings where amelia_booking_id='lgpd-129' and customer_name like 'Cliente anonimizado %' and customer_email is null and customer_phone is null and cpf_cnpj is null),
  'direct customer identifiers are removed from Amelia history'
);

select is(
  (select custom_fields_json from public.legacy_amelia_bookings where amelia_booking_id='lgpd-129'),
  '{}'::jsonb,
  'legacy custom fields that may contain customer PII are scrubbed'
);

select is(
  (select amelia_price_amount from public.legacy_amelia_bookings where amelia_booking_id='lgpd-129'),
  789.90::numeric,
  'legacy financial amount is preserved'
);

select ok(
  exists(
    select 1 from public.legacy_amelia_bookings b
    join public.customers c on c.id=b.matched_customer_id
    where b.amelia_booking_id='lgpd-129'
      and b.payment_status_raw='paid'
      and b.payment_method_raw='pix'
      and b.service_name='Ensaio histórico'
      and c.anonymized_at is not null
  ),
  'legacy operational and payment history stays linked to the anonymized customer UUID'
);

select * from finish();
rollback;
