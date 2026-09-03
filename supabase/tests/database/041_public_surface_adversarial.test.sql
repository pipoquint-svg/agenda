begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(28);

insert into public.categories (id,name,slug) values ('99000000-0000-0000-0000-000000000001','Adversarial Public','adversarial-public');
insert into public.resources (id,name,resource_type) values
 ('99000000-0000-0000-0000-000000000002','ADVERSARIAL STUDIO','PHYSICAL'),
 ('99000000-0000-0000-0000-000000000003','ADVERSARIAL PERSON','PERSON');
insert into public.employees (id,name,resource_id) values ('99000000-0000-0000-0000-000000000004','Adversarial Employee','99000000-0000-0000-0000-000000000003');
insert into public.services (id,category_id,name,slug,base_duration_minutes,base_price,minimum_people,maximum_people,maximum_booking_horizon_days,checkout_hold_minutes,payment_hold_minutes,requires_terms,confirmation_percentage)
values ('99000000-0000-0000-0000-000000000005','99000000-0000-0000-0000-000000000001','Adversarial Service','adversarial-service',60,500,1,2,5000,10,30,false,50);
insert into public.service_change_policies(service_id,notice_hours,reschedule_first_early_percent,reschedule_first_late_percent,reschedule_repeat_percent,cancellation_late_percent)
values ('99000000-0000-0000-0000-000000000005',48,0,20,20,20);
insert into public.service_employees (id,service_id,employee_id) values ('99000000-0000-0000-0000-000000000006','99000000-0000-0000-0000-000000000005','99000000-0000-0000-0000-000000000004');
insert into public.service_resources (service_id,resource_id,is_required) values
 ('99000000-0000-0000-0000-000000000005','99000000-0000-0000-0000-000000000002',true),
 ('99000000-0000-0000-0000-000000000005','99000000-0000-0000-0000-000000000003',true);
insert into public.extras (id,name,price,duration_delta_minutes) values ('99000000-0000-0000-0000-000000000007','Required Adversarial Extra',50,30);
insert into public.service_extras (service_id,extra_id,is_required,max_quantity,sort_order) values ('99000000-0000-0000-0000-000000000005','99000000-0000-0000-0000-000000000007',true,1,10);
insert into public.availability_rules (service_employee_id,weekday,start_local_time,end_local_time,slot_interval_minutes) values ('99000000-0000-0000-0000-000000000006',2,'09:00','14:00',30);
insert into public.resource_availability_rules (resource_id,weekday,start_local_time,end_local_time) values
 ('99000000-0000-0000-0000-000000000002',2,'09:00','14:00'),
 ('99000000-0000-0000-0000-000000000003',2,'09:00','14:00');
insert into public.booking_page_services (booking_page_id,service_id,sort_order)
select id,'99000000-0000-0000-0000-000000000005',10 from public.booking_pages where slug='sabrina';

select throws_ok($$select public.public_quote_booking('sabrina','99000000-0000-0000-0000-000000000005','99000000-0000-0000-0000-000000000006','[]'::jsonb,1)$$,'P0001','REQUIRED_EXTRA_MISSING','required extra cannot be bypassed');
select throws_ok($$select public.public_quote_booking('sabrina','99000000-0000-0000-0000-000000000005','99000000-0000-0000-0000-000000000006','[{"extra_id":"99000000-0000-0000-0000-000000000007","quantity":1}]'::jsonb,99)$$,'P0001','INVALID_PEOPLE_COUNT','people limit is server-side');
select is((public.public_quote_booking('sabrina','99000000-0000-0000-0000-000000000005','99000000-0000-0000-0000-000000000006','[{"extra_id":"99000000-0000-0000-0000-000000000007","quantity":1,"commercial_value":0,"duration_minutes":1,"resource_id":"00000000-0000-0000-0000-000000000000"}]'::jsonb,1)->>'commercial_value')::numeric,550::numeric,'crafted monetary/duration/resource fields do not override quote');

create temporary table hold_a as select public.public_create_checkout_hold('sabrina','99000000-0000-0000-0000-000000000005','99000000-0000-0000-0000-000000000006','[{"extra_id":"99000000-0000-0000-0000-000000000007","quantity":1}]'::jsonb,1,'2030-01-01 09:00:00-03'::timestamptz) payload;
create temporary table hold_b as select public.public_create_checkout_hold('sabrina','99000000-0000-0000-0000-000000000005','99000000-0000-0000-0000-000000000006','[{"extra_id":"99000000-0000-0000-0000-000000000007","quantity":1}]'::jsonb,1,'2030-01-01 11:00:00-03'::timestamptz) payload;
select is(public.public_get_checkout_context((select payload->>'checkout_hold_token' from hold_a))->>'checkout_hold_id',(select payload->>'checkout_hold_id' from hold_a),'hold A token resolves A');
select isnt(public.public_get_checkout_context((select payload->>'checkout_hold_token' from hold_a))->>'checkout_hold_id',(select payload->>'checkout_hold_id' from hold_b),'hold A token cannot resolve B');
select throws_ok($$select public.public_get_checkout_context('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa')$$,'P0001','CHECKOUT_HOLD_NOT_ACTIVE','random hold token is generic');
select throws_ok($$select public.public_get_checkout_context('short')$$,'P0001','CHECKOUT_HOLD_NOT_ACTIVE','truncated hold token is generic');
select throws_ok($$select public.public_get_checkout_context((select left(payload->>'checkout_hold_token',length(payload->>'checkout_hold_token')-1)||'X' from hold_a))$$,'P0001','CHECKOUT_HOLD_NOT_ACTIVE','modified hold token rejected');
update public.checkout_holds set created_at=now()-interval '10 minutes',expires_at=now()-interval '1 second' where id=((select payload->>'checkout_hold_id' from hold_b))::uuid;
select throws_ok($$select public.public_get_checkout_context((select payload->>'checkout_hold_token' from hold_b))$$,'P0001','CHECKOUT_HOLD_NOT_ACTIVE','expired hold token is generic');
update public.checkout_holds set status='PROMOTED',expires_at=now()+interval '10 minutes' where id=((select payload->>'checkout_hold_id' from hold_b))::uuid;
select throws_ok($$select public.public_get_checkout_context((select payload->>'checkout_hold_token' from hold_b))$$,'P0001','CHECKOUT_HOLD_NOT_ACTIVE','promoted hold token cannot replay');

update public.checkout_holds set status='EXPIRED',created_at=now()-interval '10 minutes',expires_at=now()-interval '1 minute' where id=((select payload->>'checkout_hold_id' from hold_b))::uuid;
update public.resource_allocations set status='EXPIRED' where checkout_hold_id=((select payload->>'checkout_hold_id' from hold_b))::uuid;
select throws_ok($$select public.get_checkout_hold_resume_context('recovery-adversarial-token-bbbbbbbbbbbbbbbb')$$,'P0001','CHECKOUT_RECOVERY_RETIRED','random legacy recovery bearer fails closed');
select throws_ok($$select public.get_checkout_hold_resume_context('recovery-adversarial-token-aaaaaaaaaaaaaaaa')$$,'P0001','CHECKOUT_RECOVERY_RETIRED','former valid-shaped recovery bearer cannot resume checkout');
select is((select count(*)::integer from public.resource_allocations where checkout_hold_id=((select payload->>'checkout_hold_id' from hold_b))::uuid and status in ('HELD','AWAITING_PAYMENT','CONFIRMED')),0,'retired recovery does not reactivate allocation');
select throws_ok($$select public.set_checkout_hold_recovery_contact((select payload->>'checkout_hold_token' from hold_b),'48999990000',true)$$,'P0001','CHECKOUT_RECOVERY_RETIRED','recovery mutation cannot resurrect an expired hold');

insert into public.customers (id,name,email,phone,cpf_cnpj) values
 ('99000000-0000-0000-0000-000000000020','Customer A','a@example.com','48999990001','52998224725'),
 ('99000000-0000-0000-0000-000000000021','Customer B','b@example.com','48999990002','39053344705');
insert into public.appointments (id,public_code,service_id,service_employee_id,service_name_snapshot,primary_customer_id,status,financial_status,start_at,end_at,duration_minutes,people_count,hold_expires_at,commercial_value) values
 ('99000000-0000-0000-0000-000000000030','ADV-A','99000000-0000-0000-0000-000000000005','99000000-0000-0000-0000-000000000006','Adversarial Service','99000000-0000-0000-0000-000000000020','AWAITING_PAYMENT','PENDING','2030-02-01 09:00:00-03','2030-02-01 10:00:00-03',60,1,now()+interval '30 minutes',500),
 ('99000000-0000-0000-0000-000000000031','ADV-B','99000000-0000-0000-0000-000000000005','99000000-0000-0000-0000-000000000006','Adversarial Service','99000000-0000-0000-0000-000000000021','AWAITING_PAYMENT','PENDING','2030-02-01 11:00:00-03','2030-02-01 12:00:00-03',60,1,now()+interval '30 minutes',500),
 ('99000000-0000-0000-0000-000000000032','ADV-CANCEL','99000000-0000-0000-0000-000000000005','99000000-0000-0000-0000-000000000006','Adversarial Service','99000000-0000-0000-0000-000000000020','CANCELLED','PENDING','2030-02-02 09:00:00-03','2030-02-02 10:00:00-03',60,1,null,500);
insert into public.appointment_access_tokens (appointment_id,token_hash,scope,expires_at,revoked_at) values
 ('99000000-0000-0000-0000-000000000030',encode(digest('pay-token-a-abcdefghijklmnopqrstuvwxyz-123456','sha256'),'hex'),'PAY',now()+interval '1 day',null),
 ('99000000-0000-0000-0000-000000000031',encode(digest('pay-token-b-abcdefghijklmnopqrstuvwxyz-123456','sha256'),'hex'),'PAY',now()+interval '1 day',null),
 ('99000000-0000-0000-0000-000000000030',encode(digest('view-only-token-abcdefghijklmnopqrstuvwxyz-12','sha256'),'hex'),'VIEW',now()+interval '1 day',null),
 ('99000000-0000-0000-0000-000000000030',encode(digest('expired-pay-token-abcdefghijklmnopqrstuvwxyz-12','sha256'),'hex'),'PAY',now()-interval '1 second',null),
 ('99000000-0000-0000-0000-000000000030',encode(digest('revoked-pay-token-abcdefghijklmnopqrstuvwxyz-12','sha256'),'hex'),'PAY',now()+interval '1 day',now()),
 ('99000000-0000-0000-0000-000000000032',encode(digest('cancelled-pay-token-abcdefghijklmnopqrstuvwxyz-1','sha256'),'hex'),'PAY',now()+interval '1 day',null);
select is(public.service_get_public_payment_context('pay-token-a-abcdefghijklmnopqrstuvwxyz-123456')->>'public_code','ADV-A','token A resolves appointment A');
select isnt(public.service_get_public_payment_context('pay-token-a-abcdefghijklmnopqrstuvwxyz-123456')->>'public_code','ADV-B','token A cannot read B');
select is(public.service_get_public_payment_context('pay-token-b-abcdefghijklmnopqrstuvwxyz-123456')->>'public_code','ADV-B','token B resolves appointment B');
select throws_ok($$select public.resolve_appointment_access_token('view-only-token-abcdefghijklmnopqrstuvwxyz-12','PAY')$$,'P0001','TOKEN_SCOPE_DENIED','VIEW cannot PAY');
select throws_ok($$select public.resolve_appointment_access_token('expired-pay-token-abcdefghijklmnopqrstuvwxyz-12','PAY')$$,'P0001','APPOINTMENT_TOKEN_EXPIRED','expired appointment token rejected');
select throws_ok($$select public.resolve_appointment_access_token('revoked-pay-token-abcdefghijklmnopqrstuvwxyz-12','PAY')$$,'P0001','APPOINTMENT_TOKEN_REVOKED','revoked appointment token rejected');
select throws_ok($$select public.resolve_appointment_access_token('random-token-abcdefghijklmnopqrstuvwxyz-123456789','PAY')$$,'P0001','APPOINTMENT_TOKEN_INVALID','random appointment token generic');
select throws_ok($$select public.resolve_appointment_access_token('short','PAY')$$,'P0001','APPOINTMENT_TOKEN_INVALID','truncated appointment token same invalid code');
select throws_ok($$select public.service_get_public_payment_context('cancelled-pay-token-abcdefghijklmnopqrstuvwxyz-1')$$,'P0001','APPOINTMENT_NOT_PAYABLE','cancelled appointment cannot pay');
create temporary table intent_first as select public.service_create_payment_intent_by_token('pay-token-a-abcdefghijklmnopqrstuvwxyz-123456','MINIMUM','PIX','adversarial_req_001') payload;
create temporary table intent_replay as select public.service_create_payment_intent_by_token('pay-token-a-abcdefghijklmnopqrstuvwxyz-123456','MINIMUM','PIX','adversarial_req_001') payload;
select is((select payload->>'transaction_id' from intent_replay),(select payload->>'transaction_id' from intent_first),'payment request replay returns same transaction');
select is((select count(*)::integer from public.payment_transactions where appointment_id='99000000-0000-0000-0000-000000000030' and idempotency_key='public:99000000-0000-0000-0000-000000000030:adversarial_req_001'),1,'payment replay persists one transaction');
select ok(not has_function_privilege('anon','public.service_submit_public_checkout(text,text,uuid[],jsonb,inet,text)','EXECUTE'),'anon cannot bypass booking Edge');
select ok(not has_function_privilege('anon','public.service_create_payment_intent_by_token(text,text,text,text)','EXECUTE'),'anon cannot bypass payment Edge');
select ok(not has_function_privilege('anon','public.create_payment_intent(uuid,numeric,text,text)','EXECUTE'),'anon cannot call core payment mutation');

select * from finish();
rollback;
