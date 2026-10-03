begin;
create extension if not exists pgtap with schema extensions;
set local search_path=public,extensions;
select plan(17);
select set_config('agenda.test_now','2026-10-03 14:00:00-03',true);

select ok(
  not has_function_privilege('anon','public.service_issue_balance_collection_payment_token(uuid)','EXECUTE')
  and not has_function_privilege('authenticated','public.service_issue_balance_collection_payment_token(uuid)','EXECUTE'),
  'public roles cannot issue magic payment tokens'
);
select ok(
  has_function_privilege('service_role','public.service_issue_balance_collection_payment_token(uuid)','EXECUTE')
  and has_function_privilege('service_role','public.service_verify_balance_collection_payment_token(text)','EXECUTE'),
  'only the trusted backend can issue and verify magic payment tokens'
);

insert into auth.users(id,email,created_at,updated_at)
values('16400000-0000-4000-8000-000000000001','magic-finance@example.test',now(),now());
insert into public.admin_users(id,auth_user_id,display_name,role)
values('16400000-0000-4000-8000-000000000002','16400000-0000-4000-8000-000000000001','Magic Finance','FINANCE');
insert into public.categories(id,name,slug)
values('16400000-0000-4000-8000-000000000003','Magic Balance','magic-balance');
insert into public.employees(id,name)
values('16400000-0000-4000-8000-000000000004','Magic Employee');
insert into public.services(
  id,category_id,name,slug,base_duration_minutes,base_price,minimum_people,maximum_people,maximum_booking_horizon_days,
  duration_mode,booking_block_minutes,minimum_booking_blocks,maximum_booking_blocks,price_per_block,confirmation_percentage,max_reschedules,operation_scope
) values(
  '16400000-0000-4000-8000-000000000005','16400000-0000-4000-8000-000000000003','Locação Magic','magic-rental',120,1000,1,10,365,
  'BLOCKS',30,2,8,250,50,2,'BLACKSHEEP'
);
insert into public.service_change_policies(service_id,notice_hours,reschedule_first_early_percent,reschedule_first_late_percent,reschedule_repeat_percent,cancellation_late_percent)
values('16400000-0000-4000-8000-000000000005',12,0,20,20,20);
insert into public.service_employees(id,service_id,employee_id)
values('16400000-0000-4000-8000-000000000006','16400000-0000-4000-8000-000000000005','16400000-0000-4000-8000-000000000004');
insert into public.customers(id,name,email,phone)
values('16400000-0000-4000-8000-000000000007','Cliente Magic','magic@example.test','48999990001');
insert into public.appointments(
  id,public_code,service_id,service_employee_id,service_name_snapshot,primary_customer_id,status,financial_status,
  start_at,end_at,core_start_at,core_end_at,duration_minutes,contracted_minutes,pre_service_minutes,post_service_minutes,people_count,
  commercial_value,billing_mode_snapshot,confirmation_percentage_snapshot,confirmed_at
) values(
  '16400000-0000-4000-8000-000000000008','MAGIC-001','16400000-0000-4000-8000-000000000005','16400000-0000-4000-8000-000000000006','Locação Magic','16400000-0000-4000-8000-000000000007','CONFIRMED','PARTIALLY_PAID',
  '2026-10-03 14:00:00-03','2026-10-03 16:30:00-03','2026-10-03 14:00:00-03','2026-10-03 16:00:00-03',150,120,0,30,1,
  1000,'CHECKOUT',50,public.balance_collection_clock()
);
insert into public.payment_transactions(appointment_id,transaction_type,method,provider,status,contract_amount_settled,cash_amount,payment_purpose)
values('16400000-0000-4000-8000-000000000008','CHARGE','CARD','MERCADO_PAGO','APPROVED',500,500,'CONTRACT');

select set_config(
  'agenda.magic_collection_1',
  public.create_balance_collection('16400000-0000-4000-8000-000000000008','AUTO_START',null)->>'collection_id',
  true
);
select set_config(
  'agenda.magic_token_1',
  public.service_issue_balance_collection_payment_token(current_setting('agenda.magic_collection_1')::uuid)->>'access_token',
  true
);

select is(length(current_setting('agenda.magic_token_1')),64,'magic token has 256 bits encoded as hex');
select matches(current_setting('agenda.magic_token_1'),'^[0-9a-f]{64}$','magic token uses a URL-safe high-entropy representation');
select is((select count(*)::integer from public.appointment_access_tokens where balance_collection_id=current_setting('agenda.magic_collection_1')::uuid),1,'issuing a magic link stores one token row');
select is((select scope from public.appointment_access_tokens where balance_collection_id=current_setting('agenda.magic_collection_1')::uuid),'PAY','magic link is PAY-only');
select isnt((select token_hash from public.appointment_access_tokens where balance_collection_id=current_setting('agenda.magic_collection_1')::uuid),current_setting('agenda.magic_token_1'),'raw token is never persisted');
select is(
  (select token_hash from public.appointment_access_tokens where balance_collection_id=current_setting('agenda.magic_collection_1')::uuid),
  encode(digest(current_setting('agenda.magic_token_1'),'sha256'),'hex'),
  'database stores only the SHA-256 token hash'
);
select is(
  (select expires_at from public.appointment_access_tokens where balance_collection_id=current_setting('agenda.magic_collection_1')::uuid),
  (select expires_at from public.appointment_balance_collections where id=current_setting('agenda.magic_collection_1')::uuid),
  'token validity is bounded by the collection validity'
);
select is(
  (public.service_verify_balance_collection_payment_token(current_setting('agenda.magic_token_1'))->>'amount')::numeric,
  500::numeric,
  'verification returns the authoritative current balance'
);
select throws_ok(
  $$select public.service_verify_balance_collection_payment_token(repeat('f',64))$$,
  'P0001','BALANCE_COLLECTION_INVALID_OR_EXPIRED','unknown token fails closed'
);

-- Simulate a legacy status transition that omitted revocation. The successor
-- collection trigger must still revoke every older link.
update public.appointment_balance_collections
set status='EXPIRED',updated_at=public.balance_collection_clock()
where id=current_setting('agenda.magic_collection_1')::uuid;
select set_config(
  'agenda.magic_collection_2',
  public.service_admin_reissue_balance_collection('16400000-0000-4000-8000-000000000008','16400000-0000-4000-8000-000000000002')->>'collection_id',
  true
);
select ok((select revoked_at is not null from public.appointment_access_tokens where balance_collection_id=current_setting('agenda.magic_collection_1')::uuid),'reissue revokes a superseded collection token');

select set_config(
  'agenda.magic_token_2',
  public.service_issue_balance_collection_payment_token(current_setting('agenda.magic_collection_2')::uuid)->>'access_token',
  true
);
select set_config('agenda.test_now','2026-10-05 14:01:00-03',true);
select is(public.expire_due_balance_collections(),1,'collection expires after its 48-hour validity');
select ok((select revoked_at is not null from public.appointment_access_tokens where balance_collection_id=current_setting('agenda.magic_collection_2')::uuid),'expiration revokes the magic token');
select throws_ok(
  $$select public.service_verify_balance_collection_payment_token(current_setting('agenda.magic_token_2'))$$,
  'P0001','BALANCE_COLLECTION_INVALID_OR_EXPIRED','expired token cannot reopen checkout'
);

select set_config(
  'agenda.magic_collection_3',
  public.service_admin_reissue_balance_collection('16400000-0000-4000-8000-000000000008','16400000-0000-4000-8000-000000000002')->>'collection_id',
  true
);
select set_config(
  'agenda.magic_token_3',
  public.service_issue_balance_collection_payment_token(current_setting('agenda.magic_collection_3')::uuid)->>'access_token',
  true
);
insert into public.payment_transactions(
  id,appointment_id,transaction_type,method,provider,provider_payment_id,status,
  contract_amount_settled,cash_amount,payment_purpose,balance_collection_id
) values(
  '16400000-0000-4000-8000-000000000009','16400000-0000-4000-8000-000000000008','CHARGE','PIX','MERCADO_PAGO','magic-paid','PENDING',
  500,500,'CONTRACT',current_setting('agenda.magic_collection_3')::uuid
);
update public.payment_transactions set status='APPROVED' where id='16400000-0000-4000-8000-000000000009';
select is((select status from public.appointment_balance_collections where id=current_setting('agenda.magic_collection_3')::uuid),'PAID','full payment closes the collection');
select ok((select revoked_at is not null from public.appointment_access_tokens where balance_collection_id=current_setting('agenda.magic_collection_3')::uuid),'full payment revokes the magic token');

select * from finish();
rollback;
