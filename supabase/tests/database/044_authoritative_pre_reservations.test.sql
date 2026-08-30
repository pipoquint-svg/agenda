begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(23);

select has_table('public','pre_reservation_access_tokens','opaque token table exists');
select has_column('public','resource_allocations','pre_reservation_id','allocation owns pre-reservation');
select has_column('public','appointments','invoice_due_base_at','invoice due base timestamp exists');
select has_function('public','service_admin_create_pre_reservation',array['uuid','uuid','uuid','timestamp with time zone','uuid','integer','jsonb','integer','text'],'create RPC exists');
select has_function('public','service_admin_confirm_pre_reservation',array['uuid','uuid'],'legacy confirm RPC still exists behind payment guard');
select has_function('public','service_admin_cancel_pre_reservation',array['uuid','uuid','text'],'cancel RPC exists');
select ok(not has_function_privilege('anon','public.public_get_pre_reservation_context(text)','EXECUTE'),'anon cannot bypass Edge token access');
select ok(not has_function_privilege('authenticated','public.public_get_pre_reservation_context(text)','EXECUTE'),'authenticated cannot bypass Edge token access');
select ok(not has_table_privilege('service_role','public.pre_reservations','INSERT'),'service_role cannot direct-insert pre-reservations');

insert into auth.users(id,instance_id,aud,role,email,encrypted_password,created_at,updated_at) values
('14400000-0000-4000-8000-000000000001','00000000-0000-0000-0000-000000000000','authenticated','authenticated','owner-prebook@example.test','',now(),now()),
('14400000-0000-4000-8000-000000000002','00000000-0000-0000-0000-000000000000','authenticated','authenticated','operation-prebook@example.test','',now(),now());
insert into public.admin_users(id,auth_user_id,display_name,role) values
('24400000-0000-4000-8000-000000000001','14400000-0000-4000-8000-000000000001','Owner Prebook','OWNER'),
('24400000-0000-4000-8000-000000000002','14400000-0000-4000-8000-000000000002','Operation Prebook','OPERATION');
insert into public.categories(id,name,slug) values ('94400000-0000-0000-0000-000000000001','Prebook Test','prebook-test');
insert into public.resources(id,name,resource_type) values
('94400000-0000-0000-0000-000000000002','PREBOOK TEST STUDIO','PHYSICAL'),
('94400000-0000-0000-0000-000000000003','PREBOOK TEST PERSON','PERSON');
insert into public.employees(id,name,resource_id) values ('94400000-0000-0000-0000-000000000004','Prebook Employee','94400000-0000-0000-0000-000000000003');
insert into public.services(id,category_id,name,slug,base_duration_minutes,base_price,buffer_before_minutes,buffer_after_minutes,minimum_people,maximum_people,maximum_booking_horizon_days,duration_mode,booking_block_minutes,minimum_booking_blocks,maximum_booking_blocks,price_per_block) values
('94400000-0000-0000-0000-000000000005','94400000-0000-0000-0000-000000000001','Locação Prebook','locacao-prebook',30,90,0,30,1,20,5000,'BLOCKS',30,2,12,90),
('94400000-0000-0000-0000-000000000015','94400000-0000-0000-0000-000000000001','Não Autorizado','nao-autorizado-prebook',60,150,0,0,1,5,5000,'FIXED',null,null,null,null);
insert into public.service_employees(id,service_id,employee_id) values
('94400000-0000-0000-0000-000000000006','94400000-0000-0000-0000-000000000005','94400000-0000-0000-0000-000000000004'),
('94400000-0000-0000-0000-000000000016','94400000-0000-0000-0000-000000000015','94400000-0000-0000-0000-000000000004');
insert into public.service_resources(service_id,resource_id,is_required) values
('94400000-0000-0000-0000-000000000005','94400000-0000-0000-0000-000000000002',true),
('94400000-0000-0000-0000-000000000015','94400000-0000-0000-0000-000000000002',true);
-- 2030-01-01 is Tuesday (PostgreSQL DOW=2).
insert into public.availability_rules(service_employee_id,weekday,start_local_time,end_local_time) values
('94400000-0000-0000-0000-000000000006',2,'08:00','18:00'),
('94400000-0000-0000-0000-000000000016',2,'08:00','18:00');
insert into public.resource_availability_rules(resource_id,weekday,start_local_time,end_local_time) values
('94400000-0000-0000-0000-000000000002',2,'08:00','18:30');
insert into public.customers(id,customer_type,name,email,phone) values
('94400000-0000-0000-0000-000000000007','BUSINESS','Corporate Prebook','billing@example.test','+5548999999999');
insert into public.customer_commercial_terms(customer_id,can_prebook,prebook_hold_minutes,max_active_prebooks,requires_manual_confirmation,billing_mode,invoice_due_days,is_active) values
('94400000-0000-0000-0000-000000000007',true,720,1,true,'CHECKOUT',null,true);
insert into public.customer_prebook_authorized_services(customer_id,service_id) values
('94400000-0000-0000-0000-000000000007','94400000-0000-0000-0000-000000000005');

select throws_ok($$select public.service_admin_create_pre_reservation('94400000-0000-0000-0000-000000000007','94400000-0000-0000-0000-000000000015','94400000-0000-0000-0000-000000000016','2030-01-01 08:00:00-03','24400000-0000-4000-8000-000000000001',null,'[]',1,null)$$,'P0001','SERVICE_NOT_AUTHORIZED_FOR_PREBOOK','allowlist enforced');

create temp table created as select public.service_admin_create_pre_reservation('94400000-0000-0000-0000-000000000007','94400000-0000-0000-0000-000000000005','94400000-0000-0000-0000-000000000006','2030-01-01 08:00:00-03','24400000-0000-4000-8000-000000000001',4,'[]',1,'test') payload;
select is((select payload->>'authoritative_resource_hold' from created),'true','pre-reservation reports authoritative hold');
select is((select count(*)::integer from public.resource_allocations where pre_reservation_id=(select (payload->>'pre_reservation_id')::uuid from created) and allocation_type='PRE_RESERVATION' and status='HELD'),1,'shared ledger contains blocking pre-reservation allocation');
select throws_ok($$select public.create_checkout_hold_for_duration('94400000-0000-0000-0000-000000000005','94400000-0000-0000-0000-000000000006',4,'[]',1,'2030-01-01 08:00:00-03')$$,'P0001','SLOT_NO_LONGER_AVAILABLE','normal hold cannot overlap pre-reservation');
select throws_ok($$select public.service_admin_create_pre_reservation('94400000-0000-0000-0000-000000000007','94400000-0000-0000-0000-000000000005','94400000-0000-0000-0000-000000000006','2030-01-01 11:00:00-03','24400000-0000-4000-8000-000000000001',4,'[]',1,null)$$,'P0001','MAX_ACTIVE_PREBOOKS_REACHED','max_active_prebooks enforced');
select ok((select (public.public_get_pre_reservation_context(payload->>'access_token')->>'authoritative_resource_hold')='true' and not (public.public_get_pre_reservation_context(payload->>'access_token') ?| array['customer_id','email','phone','cpf_cnpj']) from created),'opaque context confirms hold without PII');
select ok((select token_hash<>(select payload->>'access_token' from created) from public.pre_reservation_access_tokens where pre_reservation_id=(select (payload->>'pre_reservation_id')::uuid from created)),'raw token is not stored');
select throws_ok($$select public.service_admin_confirm_pre_reservation((select (payload->>'pre_reservation_id')::uuid from created),'24400000-0000-4000-8000-000000000001')$$,'P0001','PRE_RESERVATION_PAYMENT_REQUIRED','admin cannot confirm checkout pre-reservation without approved payment');
select ok((select prebook_hold_minutes=2880 and requires_manual_confirmation=false and billing_mode='CHECKOUT' from public.customer_commercial_terms where customer_id='94400000-0000-0000-0000-000000000007'),'customer prebook contract is normalized to global 48h and payment-only confirmation');

-- Release first fixture so the max-active-prebooks=1 rule permits expiry/cancel scenarios.
select public.service_admin_cancel_pre_reservation((select (payload->>'pre_reservation_id')::uuid from created),'24400000-0000-4000-8000-000000000001','test fixture release') from created;

create temp table expiring as select public.service_admin_create_pre_reservation('94400000-0000-0000-0000-000000000007','94400000-0000-0000-0000-000000000005','94400000-0000-0000-0000-000000000006','2030-01-01 11:00:00-03','24400000-0000-4000-8000-000000000001',4,'[]',1,null) payload;
update public.pre_reservations set created_at=now()-interval '49 hours',expires_at=now()-interval '1 hour' where id=(select (payload->>'pre_reservation_id')::uuid from expiring);
create temp table expired_result as select public.service_expire_pre_reservations() as expired_count;
select is((select expired_count from expired_result),1,'expiration worker expires exactly one due pre-reservation');
select ok((select pr.status='EXPIRED' and pr.released_at is not null and pr.released_by_admin_id is null and pr.release_reason='EXPIRED' from public.pre_reservations pr where pr.id=(select (payload->>'pre_reservation_id')::uuid from expiring)),'expiration stores release state and system actor semantics');
select is((select ra.status::text from public.resource_allocations ra where ra.pre_reservation_id=(select (payload->>'pre_reservation_id')::uuid from expiring)),'EXPIRED','expiration releases the shared resource allocation');
select is((select count(*)::integer from public.audit_logs where entity_type='PRE_RESERVATION' and entity_id=(select (payload->>'pre_reservation_id')::uuid from expiring) and action='PRE_RESERVATION_EXPIRED'),1,'expiration is append-only audited');

create temp table cancelling as select public.service_admin_create_pre_reservation('94400000-0000-0000-0000-000000000007','94400000-0000-0000-0000-000000000005','94400000-0000-0000-0000-000000000006','2030-01-01 14:00:00-03','24400000-0000-4000-8000-000000000001',4,'[]',1,null) payload;
create temp table cancelled_result as select public.service_admin_cancel_pre_reservation((select (payload->>'pre_reservation_id')::uuid from cancelling),'24400000-0000-4000-8000-000000000001','client requested release') payload;
select ok((select pr.status='CANCELLED' and pr.released_at is not null and pr.released_by_admin_id='24400000-0000-4000-8000-000000000001'::uuid and pr.release_reason='client requested release' from public.pre_reservations pr where pr.id=(select (payload->>'pre_reservation_id')::uuid from cancelling)) and (select ra.status='CANCELLED' from public.resource_allocations ra where ra.pre_reservation_id=(select (payload->>'pre_reservation_id')::uuid from cancelling)) and (select count(*)=1 from public.audit_logs where entity_type='PRE_RESERVATION' and entity_id=(select (payload->>'pre_reservation_id')::uuid from cancelling) and action='PRE_RESERVATION_CANCELLED'),'manual cancellation records actor, releases allocation and audits');

select * from finish();
rollback;
