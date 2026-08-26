begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(6);

select has_function('public','guard_birthday_coupon_service_scope',array[]::text[],'birthday coupon service-scope guard exists');
select has_function('public','assert_birthday_coupon_has_locacao_service',array[]::text[],'birthday coupon deferred LOCACAO invariant exists');

insert into public.categories(id,name,slug,operation_scope)
values ('98800000-0000-0000-0000-000000000001','Birthday Scope Fixture','birthday-scope-fixture','BLACKSHEEP');

insert into public.services(
  id,category_id,name,slug,base_duration_minutes,base_price,minimum_people,maximum_people,
  operation_scope,is_active,service_type_id
)
select
  '98800000-0000-0000-0000-000000000002','98800000-0000-0000-0000-000000000001',
  'Birthday Rental Fixture','birthday-rental-fixture',60,180,1,10,'BLACKSHEEP',false,st.id
from public.service_type st where st.key='LOCACAO';

insert into public.services(
  id,category_id,name,slug,base_duration_minutes,base_price,minimum_people,maximum_people,
  operation_scope,is_active,service_type_id
)
select
  '98800000-0000-0000-0000-000000000003','98800000-0000-0000-0000-000000000001',
  'Birthday Session Fixture','birthday-session-fixture',60,180,1,10,'BLACKSHEEP',false,st.id
from public.service_type st where st.key='ENSAIO';

insert into public.customers(id,customer_type,name,email)
values ('98800000-0000-0000-0000-000000000004','PERSON','Birthday Scope Customer','birthday-scope@example.com');

insert into public.coupons(
  id,code,discount_type,discount_value,is_active,source,customer_id,max_uses,max_uses_per_customer,used_count
) values (
  '98800000-0000-0000-0000-000000000005','NIVER50-SCOPE-TEST','PERCENT',50,false,'BIRTHDAY',
  '98800000-0000-0000-0000-000000000004',1,1,0
);

insert into public.coupon_services(coupon_id,service_id)
values ('98800000-0000-0000-0000-000000000005','98800000-0000-0000-0000-000000000002');
select is(
  (select count(*)::integer from public.coupon_services where coupon_id='98800000-0000-0000-0000-000000000005'),
  1,
  'BIRTHDAY coupon accepts LOCACAO service'
);

insert into public.coupon_services(coupon_id,service_id)
values ('98800000-0000-0000-0000-000000000005','98800000-0000-0000-0000-000000000003');
select is(
  (select count(*)::integer from public.coupon_services where coupon_id='98800000-0000-0000-0000-000000000005'),
  1,
  'BIRTHDAY coupon excludes ENSAIO service'
);

select ok(
  not exists (
    select 1
    from public.coupon_services cs
    join public.services s on s.id=cs.service_id
    join public.service_type st on st.id=s.service_type_id
    where cs.coupon_id='98800000-0000-0000-0000-000000000005'
      and st.key <> 'LOCACAO'
  ),
  'BIRTHDAY coupon cannot retain a non-LOCACAO service link'
);

set constraints birthday_coupon_requires_locacao_service immediate;
set constraints birthday_coupon_requires_locacao_service deferred;

insert into public.coupons(
  id,code,discount_type,discount_value,is_active,source,customer_id,max_uses,max_uses_per_customer,used_count
) values (
  '98800000-0000-0000-0000-000000000006','NIVER50-NO-RENTAL','PERCENT',50,false,'BIRTHDAY',
  '98800000-0000-0000-0000-000000000004',1,1,0
);
insert into public.coupon_services(coupon_id,service_id)
values ('98800000-0000-0000-0000-000000000006','98800000-0000-0000-0000-000000000003');
select throws_ok(
  $$set constraints birthday_coupon_requires_locacao_service immediate$$,
  'P0001',
  'BIRTHDAY_COUPON_REQUIRES_LOCACAO_SERVICE',
  'BIRTHDAY coupon fails closed when no LOCACAO service survives eligibility filtering'
);

select * from finish();
rollback;
