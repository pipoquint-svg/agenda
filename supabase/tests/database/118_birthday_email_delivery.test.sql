begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(19);

select has_function('public','claim_birthday_notification_deliveries',array['integer'],'birthday delivery claim function exists');
select has_function('public','prepare_birthday_notification_delivery_window',array['uuid'],'birthday delivery window function exists');
select has_function('public','finalize_birthday_notification_delivery',array['uuid','text'],'birthday delivery finalizer exists');
select has_function('public','fail_birthday_notification_delivery',array['uuid','text','boolean'],'birthday delivery failure handler exists');
select ok(not has_function_privilege('anon','public.claim_birthday_notification_deliveries(integer)','EXECUTE'),'anon cannot claim birthday deliveries');
select ok(pg_get_constraintdef((select oid from pg_constraint where conrelid='public.notification_delivery_logs'::regclass and conname='notification_delivery_logs_status_check')) like '%PROCESSING%','delivery status explicitly supports PROCESSING claims');

insert into public.categories(id,name,slug,operation_scope)
values ('98700000-0000-0000-0000-000000000001','Birthday Delivery BlackSheep','birthday-delivery-blacksheep','BLACKSHEEP');
insert into public.services(id,category_id,name,slug,base_duration_minutes,base_price,minimum_people,maximum_people,operation_scope,is_active)
values ('98700000-0000-0000-0000-000000000002','98700000-0000-0000-0000-000000000001','Birthday Delivery Rental','birthday-delivery-rental',60,180,1,10,'BLACKSHEEP',false);
insert into public.service_change_policies(service_id,notice_hours,reschedule_first_early_percent,reschedule_first_late_percent,reschedule_repeat_percent,cancellation_late_percent)
values ('98700000-0000-0000-0000-000000000002',48,0,0,0,100);
update public.services set is_active=true where id='98700000-0000-0000-0000-000000000002';

insert into public.employees(id,name) values ('98700000-0000-0000-0000-000000000003','Birthday Delivery Employee');
insert into public.service_employees(id,service_id,employee_id)
values ('98700000-0000-0000-0000-000000000004','98700000-0000-0000-0000-000000000002','98700000-0000-0000-0000-000000000003');
insert into public.customers(id,customer_type,name,email,birth_date)
values ('98700000-0000-0000-0000-000000000005','PERSON','Birthday Delivery Customer','birthday-delivery@example.com','1990-08-26');
insert into public.appointments(
 id,public_code,service_id,service_employee_id,primary_customer_id,status,financial_status,
 start_at,end_at,duration_minutes,people_count,commercial_value
) values (
 '98700000-0000-0000-0000-000000000006','BDAY-DELIVERY-HIST','98700000-0000-0000-0000-000000000002','98700000-0000-0000-0000-000000000004','98700000-0000-0000-0000-000000000005','CANCELLED','NOT_STARTED',
 '2025-01-10 10:00:00-03','2025-01-10 11:00:00-03',60,1,180
);

update public.birthday_automation_settings set is_active=true where operation_scope='BLACKSHEEP';

create temporary table delivery_runtime as
select public.run_birthday_automation('2030-08-19'::date) as result;
select is((select (result->>'created_cycles')::integer from delivery_runtime),1,'seven-days-before run creates the BlackSheep birthday cycle');
select is((select (result->>'queued_messages')::integer from delivery_runtime),1,'eligible birthday queues one delivery record');
select ok(exists(
  select 1 from public.coupons c
  where c.customer_id='98700000-0000-0000-0000-000000000005' and c.source='BIRTHDAY'
    and c.code like 'NIVER50-2030-P-%' and not c.is_active and c.valid_from is null and c.valid_until is null
),'email-bound birthday coupon stays inactive with no validity window before provider delivery');
select is((select count(*)::integer from public.notification_delivery_logs where event_key='BIRTHDAY' and customer_id='98700000-0000-0000-0000-000000000005' and status='PENDING'),1,'birthday delivery starts pending');

create temporary table claimed_delivery as
select * from public.claim_birthday_notification_deliveries(20)
where customer_id='98700000-0000-0000-0000-000000000005';
select is((select count(*)::integer from claimed_delivery),1,'worker claims the pending birthday delivery exactly once');
select ok(exists(
  select 1 from public.notification_delivery_logs l join claimed_delivery c on c.id=l.id
  where l.status='PROCESSING' and l.attempt_count=1
),'claim marks evidence PROCESSING and increments attempt count');

create temporary table delivery_window as
select public.prepare_birthday_notification_delivery_window((select id from claimed_delivery)) as value;
select is(
  ((select value->>'coupon_expires_at' from delivery_window)::timestamptz - (select value->>'delivery_window_started_at' from delivery_window)::timestamptz),
  interval '30 days',
  'delivery window is exactly 30 days from the first provider attempt'
);
select ok(not (select is_active from public.coupons where customer_id='98700000-0000-0000-0000-000000000005' and source='BIRTHDAY'),'pre-provider delivery window does not activate coupon');

select lives_ok(
  format($q$select public.finalize_birthday_notification_delivery('%s'::uuid,'provider-birthday-test')$q$,(select id from claimed_delivery)),
  'provider success finalizes birthday delivery atomically'
);
select ok(exists(
  select 1 from public.notification_delivery_logs l join claimed_delivery c on c.id=l.id
  where l.status='SENT' and l.provider_message_id='provider-birthday-test'
),'successful delivery evidence is SENT with provider id');
select ok(exists(
  select 1 from public.birthday_automation_cycles b
  where b.customer_id='98700000-0000-0000-0000-000000000005' and b.message_status='SENT'
),'birthday cycle mirrors SENT message status');
select ok(exists(
  select 1
  from public.coupons c
  join public.notification_delivery_logs l on (l.payload_snapshot->>'coupon_id')::uuid=c.id
  where l.id=(select id from claimed_delivery)
    and c.is_active
    and c.valid_from=(l.payload_snapshot->>'delivery_window_started_at')::timestamptz
    and c.valid_until=(l.payload_snapshot->>'coupon_expires_at')::timestamptz
),'coupon activates only after successful delivery with the exact stored 30-day window');
select is((select count(*)::integer from public.claim_birthday_notification_deliveries(20) where customer_id='98700000-0000-0000-0000-000000000005'),0,'SENT birthday delivery cannot be claimed again');

select * from finish();
rollback;
