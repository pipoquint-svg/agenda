begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(22);

insert into public.resources (id,name,resource_type)
values ('94600000-0000-0000-0000-000000000001','InfinitePay Test Studio','PHYSICAL');
insert into public.employees (id,name)
values ('94600000-0000-0000-0000-000000000002','InfinitePay Employee');
insert into public.categories (id,name,slug)
values ('94600000-0000-0000-0000-000000000003','InfinitePay','infinitepay-test');
insert into public.services (
  id,category_id,name,slug,base_duration_minutes,base_price,minimum_people,maximum_people,
  maximum_booking_horizon_days,confirmation_percentage,pix_discount_percent,payment_mode
) values (
  '94600000-0000-0000-0000-000000000010','94600000-0000-0000-0000-000000000003',
  'InfinitePay Service','infinitepay-service',60,1000,1,10,5000,50,5,'MINIMUM_OR_FULL'
);
insert into public.service_change_policies (
  service_id,notice_hours,reschedule_first_early_percent,reschedule_first_late_percent,
  reschedule_repeat_percent,cancellation_late_percent,reschedule_first_early_penalty_type,
  reschedule_first_early_penalty_value,reschedule_first_late_penalty_type,
  reschedule_first_late_penalty_value,reschedule_repeat_penalty_type,reschedule_repeat_penalty_value,
  cancellation_late_penalty_type,cancellation_late_penalty_value
) values (
  '94600000-0000-0000-0000-000000000010',48,0,20,20,20,
  'PERCENT',0,'PERCENT',20,'PERCENT',20,'PERCENT',20
);
insert into public.service_employees(id,service_id,employee_id)
values ('94600000-0000-0000-0000-000000000011','94600000-0000-0000-0000-000000000010','94600000-0000-0000-0000-000000000002');
insert into public.service_resources(service_id,resource_id)
values ('94600000-0000-0000-0000-000000000010','94600000-0000-0000-0000-000000000001');
insert into public.customers(id,name,email,phone,cpf_cnpj)
values ('94600000-0000-0000-0000-000000000020','InfinitePay Customer','infinitepay@example.com','48999999460','52998224725');

insert into public.appointments(
  id,public_code,service_id,service_employee_id,service_name_snapshot,primary_customer_id,
  status,financial_status,start_at,end_at,duration_minutes,people_count,hold_expires_at,
  commercial_value,payment_provider_snapshot
) values
 ('94600000-0000-0000-0000-000000000030','IP-FULL','94600000-0000-0000-0000-000000000010','94600000-0000-0000-0000-000000000011','InfinitePay Service','94600000-0000-0000-0000-000000000020','AWAITING_PAYMENT','PENDING','2035-04-01 09:00:00-03','2035-04-01 10:00:00-03',60,1,now()+interval '30 minutes',1000,'INFINITEPAY'),
 ('94600000-0000-0000-0000-000000000031','MP-GUARD','94600000-0000-0000-0000-000000000010','94600000-0000-0000-0000-000000000011','InfinitePay Service','94600000-0000-0000-0000-000000000020','AWAITING_PAYMENT','PENDING','2035-04-01 11:00:00-03','2035-04-01 12:00:00-03',60,1,now()+interval '30 minutes',1000,'MERCADO_PAGO'),
 ('94600000-0000-0000-0000-000000000032','IP-AMOUNT','94600000-0000-0000-0000-000000000010','94600000-0000-0000-0000-000000000011','InfinitePay Service','94600000-0000-0000-0000-000000000020','AWAITING_PAYMENT','PENDING','2035-04-01 13:00:00-03','2035-04-01 14:00:00-03',60,1,now()+interval '30 minutes',1000,'INFINITEPAY'),
 ('94600000-0000-0000-0000-000000000033','IP-CARD','94600000-0000-0000-0000-000000000010','94600000-0000-0000-0000-000000000011','InfinitePay Service','94600000-0000-0000-0000-000000000020','AWAITING_PAYMENT','PENDING','2035-04-01 15:00:00-03','2035-04-01 16:00:00-03',60,1,now()+interval '30 minutes',1000,'INFINITEPAY'),
 ('94600000-0000-0000-0000-000000000034','IP-REJECT','94600000-0000-0000-0000-000000000010','94600000-0000-0000-0000-000000000011','InfinitePay Service','94600000-0000-0000-0000-000000000020','AWAITING_PAYMENT','PENDING','2035-04-01 17:00:00-03','2035-04-01 18:00:00-03',60,1,now()+interval '30 minutes',1000,'INFINITEPAY');
insert into public.resource_allocations(resource_id,appointment_id,allocation_type,status,occupied_range)
select '94600000-0000-0000-0000-000000000001',a.id,'APPOINTMENT','AWAITING_PAYMENT',tstzrange(a.start_at,a.end_at,'[)')
from public.appointments a
where a.id in (
  '94600000-0000-0000-0000-000000000030','94600000-0000-0000-0000-000000000031',
  '94600000-0000-0000-0000-000000000032','94600000-0000-0000-0000-000000000033',
  '94600000-0000-0000-0000-000000000034'
);
insert into public.appointment_access_tokens(appointment_id,token_hash,scope)
values
 ('94600000-0000-0000-0000-000000000030',encode(digest('ip-full-token-abcdefghijklmnopqrstuvwxyz-123456','sha256'),'hex'),'MANAGE'),
 ('94600000-0000-0000-0000-000000000031',encode(digest('mp-guard-token-abcdefghijklmnopqrstuvwxyz-12345','sha256'),'hex'),'MANAGE'),
 ('94600000-0000-0000-0000-000000000032',encode(digest('ip-amount-token-abcdefghijklmnopqrstuvwxyz-12345','sha256'),'hex'),'MANAGE'),
 ('94600000-0000-0000-0000-000000000033',encode(digest('ip-card-token-abcdefghijklmnopqrstuvwxyz-123456','sha256'),'hex'),'MANAGE'),
 ('94600000-0000-0000-0000-000000000034',encode(digest('ip-reject-token-abcdefghijklmnopqrstuvwxyz-1234','sha256'),'hex'),'MANAGE');

select ok(
  has_function_privilege('service_role','public.service_create_infinitepay_payment_intent_by_token(text,text,text)','EXECUTE')
  and has_function_privilege('service_role','public.service_claim_infinitepay_checkout_by_token(text,text,text)','EXECUTE')
  and has_function_privilege('service_role','public.service_record_infinitepay_checkout_link_result(uuid,text,text,jsonb)','EXECUTE')
  and has_function_privilege('service_role','public.service_apply_infinitepay_payment_check(uuid,text,text,text,bigint,bigint,text,smallint,text,jsonb)','EXECUTE'),
  'InfinitePay service RPCs are executable by service_role'
);
select ok(
  not has_function_privilege('anon','public.service_create_infinitepay_payment_intent_by_token(text,text,text)','EXECUTE')
  and not has_function_privilege('authenticated','public.service_create_infinitepay_payment_intent_by_token(text,text,text)','EXECUTE')
  and not has_function_privilege('anon','public.service_claim_infinitepay_checkout_by_token(text,text,text)','EXECUTE')
  and not has_function_privilege('authenticated','public.service_claim_infinitepay_checkout_by_token(text,text,text)','EXECUTE')
  and not has_function_privilege('anon','public.service_record_infinitepay_checkout_link_result(uuid,text,text,jsonb)','EXECUTE')
  and not has_function_privilege('authenticated','public.service_record_infinitepay_checkout_link_result(uuid,text,text,jsonb)','EXECUTE')
  and not has_function_privilege('anon','public.service_apply_infinitepay_payment_check(uuid,text,text,text,bigint,bigint,text,smallint,text,jsonb)','EXECUTE')
  and not has_function_privilege('authenticated','public.service_apply_infinitepay_payment_check(uuid,text,text,text,bigint,bigint,text,smallint,text,jsonb)','EXECUTE'),
  'InfinitePay service RPCs are denied to browser roles'
);
select throws_ok(
  $$ select public.service_claim_infinitepay_checkout_by_token('mp-guard-token-abcdefghijklmnopqrstuvwxyz-12345','FULL','mp_guard_request_12345') $$,
  'P0001','PAYMENT_PROVIDER_MISMATCH','Mercado Pago appointment cannot enter InfinitePay checkout'
);

create temporary table ip_full as
select public.service_claim_infinitepay_checkout_by_token('ip-full-token-abcdefghijklmnopqrstuvwxyz-123456','FULL','ip_full_request_123456') payload;
select is((select payload->>'provider' from ip_full),'INFINITEPAY','InfinitePay claim creates an InfinitePay transaction');
select is((select payload->>'method' from ip_full),'OTHER','method stays unresolved until hosted checkout payment_check');
select is((select (payload->>'cash_amount')::numeric from ip_full),1000::numeric,'InfinitePay receives the base contract amount');
select is((select (payload->>'payment_discount_amount')::numeric from ip_full),0::numeric,'Agenda does not apply its Pix discount to InfinitePay');
select is((select (payload->>'link_creation_claimed')::boolean from ip_full),true,'first request atomically claims hosted-link creation');
select is(
  (public.service_claim_infinitepay_checkout_by_token('ip-full-token-abcdefghijklmnopqrstuvwxyz-123456','FULL','different_request_123456')->>'transaction_id'),
  (select payload->>'transaction_id' from ip_full),
  'different browser request key reuses the unresolved InfinitePay transaction'
);
select is(
  (public.service_claim_infinitepay_checkout_by_token('ip-full-token-abcdefghijklmnopqrstuvwxyz-123456','FULL','different_request_234567')->>'link_creation_claimed')::boolean,
  false,'unresolved claimed link cannot be automatically created a second time'
);
select lives_ok(
  format($$ select public.service_record_infinitepay_checkout_link_result(%L::uuid,'READY','https://checkout.infinitepay.com.br/local-test','{"url":"https://checkout.infinitepay.com.br/local-test"}'::jsonb) $$,(select payload->>'transaction_id' from ip_full)),
  'validated hosted checkout URL is stored on the claimed transaction'
);
select is(
  (public.service_claim_infinitepay_checkout_by_token('ip-full-token-abcdefghijklmnopqrstuvwxyz-123456','FULL','third_request_123456')->>'checkout_url'),
  'https://checkout.infinitepay.com.br/local-test','ready hosted checkout is reused instead of recreated'
);

select public.service_apply_infinitepay_payment_check(
  ((select payload->>'transaction_id' from ip_full))::uuid,(select payload->>'transaction_id' from ip_full),
  'ip-transaction-pix-946','ip-slug-pix-946',100000,101500,'pix',1,
  'https://example.com/receipt-pix','{"paid":true}'::jsonb
);
select is((select status::text from public.appointments where id='94600000-0000-0000-0000-000000000030'),'CONFIRMED','verified InfinitePay Pix confirms active booking');
select is((select method from public.payment_transactions where id=((select payload->>'transaction_id' from ip_full))::uuid),'PIX','verified capture method becomes Agenda PIX');
select is((select installments from public.payment_transactions where id=((select payload->>'transaction_id' from ip_full))::uuid),1::smallint,'verified Pix installments are persisted');
select is((select (provider_payload_json->>'paid_amount')::bigint from public.payment_transactions where id=((select payload->>'transaction_id' from ip_full))::uuid),101500::bigint,'paid_amount may differ from base amount and is preserved as outcome data');
select is(
  (public.service_apply_infinitepay_payment_check(
    ((select payload->>'transaction_id' from ip_full))::uuid,(select payload->>'transaction_id' from ip_full),
    'ip-transaction-pix-946','ip-slug-pix-946',100000,101500,'pix',1,'https://example.com/receipt-pix','{"paid":true}'::jsonb
  )->>'idempotent_replay')::boolean,true,'duplicate verified payment_check is idempotent'
);
select is((select count(*)::integer from public.payment_provider_events where provider='INFINITEPAY' and transaction_id=((select payload->>'transaction_id' from ip_full))::uuid),1,'duplicate payment_check does not duplicate provider events');

create temporary table ip_amount as
select public.service_claim_infinitepay_checkout_by_token('ip-amount-token-abcdefghijklmnopqrstuvwxyz-12345','FULL','ip_amount_request_123') payload;
select throws_ok(
  format($$ select public.service_apply_infinitepay_payment_check(%L::uuid,%L,'ip-transaction-bad-946','ip-slug-bad-946',99999,99999,'pix',1,null,'{}'::jsonb) $$,(select payload->>'transaction_id' from ip_amount),(select payload->>'transaction_id' from ip_amount)),
  'P0001','INFINITEPAY_PAYMENT_AMOUNT_MISMATCH','payment_check amount mismatch fails closed'
);
select is((select status from public.payment_transactions where id=((select payload->>'transaction_id' from ip_amount))::uuid),'PENDING','amount mismatch leaves transaction pending and unapplied');

create temporary table ip_card as
select public.service_claim_infinitepay_checkout_by_token('ip-card-token-abcdefghijklmnopqrstuvwxyz-123456','FULL','ip_card_request_12345') payload;
select public.service_apply_infinitepay_payment_check(
  ((select payload->>'transaction_id' from ip_card))::uuid,(select payload->>'transaction_id' from ip_card),
  'ip-transaction-card-946','ip-slug-card-946',100000,109670,'credit_card',6,null,'{"paid":true}'::jsonb
);
select ok(
  (select method='CARD' and installments=6 from public.payment_transactions where id=((select payload->>'transaction_id' from ip_card))::uuid),
  'verified hosted credit card becomes CARD with provider-selected installments'
);

create temporary table ip_reject as
select public.service_claim_infinitepay_checkout_by_token('ip-reject-token-abcdefghijklmnopqrstuvwxyz-1234','FULL','ip_reject_request_123') payload;
select public.service_record_infinitepay_checkout_link_result(((select payload->>'transaction_id' from ip_reject))::uuid,'REJECTED',null,'{"http_status":422}'::jsonb);
select ok(
  (select status='REJECTED' and provider_payload_json->>'link_state'='REJECTED' from public.payment_transactions where id=((select payload->>'transaction_id' from ip_reject))::uuid),
  'definitive provider link rejection closes only that local intent'
);

select * from finish();
rollback;
