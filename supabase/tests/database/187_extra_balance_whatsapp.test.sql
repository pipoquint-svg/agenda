begin;
create extension if not exists pgtap with schema extensions;
set local search_path=public,extensions;
select plan(5);
-- Collections and this rule use the agenda.test_now clock: it is 12:10 on a future day.
select set_config('agenda.test_now','2037-11-09 12:10:00-03',true);

insert into auth.users(id,email,created_at,updated_at)
values('18700000-0000-4000-8000-000000000001','extra-wa-admin@example.test',now(),now());
insert into public.admin_users(id,auth_user_id,display_name,role)
values('18700000-0000-4000-8000-000000000002','18700000-0000-4000-8000-000000000001','Extra WA Admin','OWNER');
insert into public.categories(id,name,slug) values('18700000-0000-4000-8000-000000000003','Extra WA','extra-wa');
insert into public.employees(id,name) values('18700000-0000-4000-8000-000000000004','Extra WA Employee');
insert into public.services(id,category_id,name,slug,base_duration_minutes,base_price,
  minimum_people,maximum_people,maximum_booking_horizon_days,duration_mode,
  booking_block_minutes,minimum_booking_blocks,maximum_booking_blocks,price_per_block,
  confirmation_percentage,max_reschedules,operation_scope)
values('18700000-0000-4000-8000-000000000005','18700000-0000-4000-8000-000000000003',
  'Locação Extra WA','extra-wa-rental',60,190,1,10,9999,'BLOCKS',30,2,8,95,50,2,'BLACKSHEEP');
insert into public.service_change_policies(service_id,notice_hours,reschedule_first_early_percent,
  reschedule_first_late_percent,reschedule_repeat_percent,cancellation_late_percent)
values('18700000-0000-4000-8000-000000000005',12,0,20,20,20);
insert into public.service_employees(id,service_id,employee_id)
values('18700000-0000-4000-8000-000000000006','18700000-0000-4000-8000-000000000005','18700000-0000-4000-8000-000000000004');
insert into public.customers(id,name,email,phone)
values('18700000-0000-4000-8000-000000000007','Cliente Extra WA','extra-wa@example.test','48999870001');

-- ENDED: paid, ended at 12:00 (its 25-minutes-before-end message time passed).
-- LATER: paid, ends at 15:00 (its message is still ahead, at 14:35).
insert into public.appointments(id,public_code,service_id,service_employee_id,service_name_snapshot,
  primary_customer_id,status,financial_status,start_at,end_at,core_start_at,core_end_at,
  duration_minutes,contracted_minutes,people_count,base_price_snapshot,coupon_discount,
  commercial_value,billing_mode_snapshot,confirmation_percentage_snapshot,confirmed_at)
values
('18700000-0000-4000-8000-0000000000a1','EXTRA-WA-ENDED','18700000-0000-4000-8000-000000000005',
 '18700000-0000-4000-8000-000000000006','Locação Extra WA','18700000-0000-4000-8000-000000000007',
 'CONFIRMED','PAID','2037-11-09 11:00:00-03','2037-11-09 12:00:00-03',
 '2037-11-09 11:00:00-03','2037-11-09 12:00:00-03',60,60,1,190,0,190,'CHECKOUT',50,now()),
('18700000-0000-4000-8000-0000000000b1','EXTRA-WA-LATER','18700000-0000-4000-8000-000000000005',
 '18700000-0000-4000-8000-000000000006','Locação Extra WA','18700000-0000-4000-8000-000000000007',
 'CONFIRMED','PAID','2037-11-09 14:00:00-03','2037-11-09 15:00:00-03',
 '2037-11-09 14:00:00-03','2037-11-09 15:00:00-03',60,60,1,190,0,190,'CHECKOUT',50,now());
insert into public.payment_transactions(appointment_id,transaction_type,method,provider,status,
  contract_amount_settled,cash_amount,payment_purpose)
values('18700000-0000-4000-8000-0000000000a1','CHARGE','CARD','MERCADO_PAGO','APPROVED',190,190,'CONTRACT'),
 ('18700000-0000-4000-8000-0000000000b1','CHARGE','CARD','MERCADO_PAGO','APPROVED',190,190,'CONTRACT');

-- The approved WhatsApp balance message: 25 minutes before the end.
select set_config('agenda.e187_template', public.service_admin_upsert_notification_template_v3(
  null,'RENTAL_BALANCE_DUE','WHATSAPP','CUSTOMER','BLACKSHEEP',null,'Saldo 187','Olá {{customer.name}}',null,false,
  '["customer.name"]'::jsonb,null,'{}'::uuid[],'18700000-0000-4000-8000-000000000002','IMMEDIATE',null)::text,true);
update public.notification_template_configs set is_active=true, schedule_mode='BEFORE_END', schedule_offset_minutes=25
where id=current_setting('agenda.e187_template')::uuid;

select set_config('agenda.e187_ended',public.service_admin_add_post_booking_extra(
  '18700000-0000-4000-8000-0000000000a1','EXTRA_TIME',null,1,
  '18700000-0000-4000-8000-000000000002','18700000-0000-4000-8000-000000000101')::text,true);
select is(current_setting('agenda.e187_ended')::jsonb->>'notification','EMAIL_QUEUED','the balance e-mail is queued as before');
select is(
  (select count(*)::integer from public.integration_jobs
   where idempotency_key='rental-balance-whatsapp:'||(current_setting('agenda.e187_ended')::jsonb->>'collection_id')||':'||current_setting('agenda.e187_template')),
  1,'an extra after the message time queues the WhatsApp balance message');
select is(
  (select row(payload_json->>'event_key',payload_json->>'channel',payload_json->>'schedule_key',run_after<=now())::text
   from public.integration_jobs
   where idempotency_key='rental-balance-whatsapp:'||(current_setting('agenda.e187_ended')::jsonb->>'collection_id')||':'||current_setting('agenda.e187_template')),
  row('RENTAL_BALANCE_DUE','WHATSAPP',
    current_setting('agenda.e187_template')||':'||(select version from public.appointments where id='18700000-0000-4000-8000-0000000000a1')||':BEFORE_END:25',
    true)::text,
  'right away, with the schedule key whatsapp-send accepts'
);

select set_config('agenda.e187_later',public.service_admin_add_post_booking_extra(
  '18700000-0000-4000-8000-0000000000b1','EXTRA_TIME',null,1,
  '18700000-0000-4000-8000-000000000002','18700000-0000-4000-8000-000000000102')::text,true);
select is(
  (select count(*)::integer from public.integration_jobs where idempotency_key like 'rental-balance-whatsapp:'||(current_setting('agenda.e187_later')::jsonb->>'collection_id')||':%'),
  0,'before the message time, the scheduled message carries the new balance');

select is(
  (public.service_admin_add_post_booking_extra('18700000-0000-4000-8000-0000000000a1','EXTRA_TIME',null,1,
    '18700000-0000-4000-8000-000000000002','18700000-0000-4000-8000-000000000101')->>'idempotent_replay')::boolean
  and (select count(*) from public.integration_jobs where idempotency_key like 'rental-balance-whatsapp:%:'||current_setting('agenda.e187_template')
       and entity_id='18700000-0000-4000-8000-0000000000a1')=1,
  true,'repeating the same request queues nothing more'
);

select * from finish();
rollback;
