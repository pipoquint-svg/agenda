begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(15);

select has_function('public','run_birthday_automation',array['date'],'birthday daily runtime exists');
select ok(not has_function_privilege('anon','public.run_birthday_automation(date)','EXECUTE'),'anon cannot run birthday automation');
select ok(not has_function_privilege('authenticated','public.run_birthday_automation(date)','EXECUTE'),'authenticated cannot run birthday automation');
select ok(pg_get_constraintdef((select oid from pg_constraint where conrelid='public.coupons'::regclass and conname='coupons_source_check')) like '%BIRTHDAY%','coupon source explicitly supports BIRTHDAY');

insert into public.categories(id,name,slug,operation_scope)
values
 ('98600000-0000-0000-0000-000000000001','Birthday Sabrina','birthday-sabrina','SABRINA'),
 ('98600000-0000-0000-0000-000000000002','Birthday BlackSheep','birthday-blacksheep','BLACKSHEEP');

insert into public.services(id,category_id,name,slug,base_duration_minutes,base_price,minimum_people,maximum_people,operation_scope,is_active)
values
 ('98600000-0000-0000-0000-000000000003','98600000-0000-0000-0000-000000000001','Birthday Sabrina Service','birthday-sabrina-service',60,500,1,5,'SABRINA',false),
 ('98600000-0000-0000-0000-000000000004','98600000-0000-0000-0000-000000000002','Birthday BlackSheep Service','birthday-blacksheep-service',60,500,1,5,'BLACKSHEEP',false);

insert into public.service_change_policies(service_id,notice_hours,reschedule_first_early_percent,reschedule_first_late_percent,reschedule_repeat_percent,cancellation_late_percent)
values
 ('98600000-0000-0000-0000-000000000003',48,0,0,0,100),
 ('98600000-0000-0000-0000-000000000004',48,0,0,0,100);
update public.services set is_active=true where id in ('98600000-0000-0000-0000-000000000003','98600000-0000-0000-0000-000000000004');

insert into public.employees(id,name) values ('98600000-0000-0000-0000-000000000005','Birthday Employee');
insert into public.service_employees(id,service_id,employee_id)
values ('98600000-0000-0000-0000-000000000006','98600000-0000-0000-0000-000000000003','98600000-0000-0000-0000-000000000005');

insert into public.customers(id,customer_type,name,email,birth_date)
values ('98600000-0000-0000-0000-000000000007','PERSON','Birthday Customer','birthday-runtime@example.com','1990-08-26');

insert into public.appointments(
 id,public_code,service_id,service_employee_id,primary_customer_id,status,financial_status,
 start_at,end_at,duration_minutes,people_count,commercial_value
) values (
 '98600000-0000-0000-0000-000000000008','BDAY-HIST','98600000-0000-0000-0000-000000000003','98600000-0000-0000-0000-000000000006','98600000-0000-0000-0000-000000000007','CANCELLED','UNPAID',
 '2025-01-10 10:00:00-03','2025-01-10 11:00:00-03',60,1,500
);

insert into public.notification_template_configs(
 id,event_key,channel,audience,operation_scope,title_template,body_template,is_active,variable_schema
) values (
 '98600000-0000-0000-0000-000000000009','BIRTHDAY','EMAIL','CUSTOMER','SABRINA','Feliz aniversário','Mensagem sintética',true,'[]'::jsonb
);

update public.birthday_automation_settings
set is_active=true,
    send_message=true,
    generate_coupon=true,
    send_on_birthday=true,
    days_before=2,
    coupon_prefix='NIVER',
    coupon_discount_type='PERCENT',
    coupon_discount_value=10,
    coupon_validity_days=7,
    coupon_max_uses=1,
    coupon_max_uses_per_customer=1
where operation_scope='SABRINA';

create temporary table birthday_first_run as
select public.run_birthday_automation('2030-08-26'::date) as result;

select is((select (result->>'created_cycles')::integer from birthday_first_run),1,'birthday date creates one cycle');
select is((select (result->>'created_coupons')::integer from birthday_first_run),1,'birthday date creates one coupon');
select is((select (result->>'queued_messages')::integer from birthday_first_run),1,'birthday date queues one internal notification record');
select ok(exists(select 1 from public.coupons where customer_id='98600000-0000-0000-0000-000000000007' and source='BIRTHDAY' and code like 'NIVER-2030-D-%'),'birthday coupon is customer-bound and has explicit source');
select is((select count(*)::integer from public.coupon_services cs join public.services s on s.id=cs.service_id join public.coupons c on c.id=cs.coupon_id where c.customer_id='98600000-0000-0000-0000-000000000007' and s.operation_scope='BLACKSHEEP'),0,'birthday coupon never crosses operation eligibility');
select is((select count(*)::integer from public.notification_delivery_logs where event_key='BIRTHDAY' and customer_id='98600000-0000-0000-0000-000000000007' and status='PENDING'),1,'birthday message remains pending internal evidence without provider call');

create temporary table birthday_replay as
select public.run_birthday_automation('2030-08-26'::date) as result;
select is((select (result->>'skipped_existing')::integer from birthday_replay),1,'same date replay is idempotently skipped');
select is((select count(*)::integer from public.coupons where customer_id='98600000-0000-0000-0000-000000000007' and source='BIRTHDAY'),1,'replay does not duplicate coupon');
select is((select count(*)::integer from public.notification_delivery_logs where event_key='BIRTHDAY' and customer_id='98600000-0000-0000-0000-000000000007'),1,'replay does not duplicate notification evidence');

select is((public.run_birthday_automation('2031-08-25'::date)->>'created_cycles')::integer,0,'runtime does not perform retroactive or early catch-up outside exact configured date');
select is((public.run_birthday_automation('2031-08-24'::date)->>'created_cycles')::integer,1,'configured days-before date creates independent BEFORE cycle');

select * from finish();
rollback;
