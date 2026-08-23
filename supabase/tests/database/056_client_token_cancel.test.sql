begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(14);

insert into public.categories(id,name,slug)
values ('95600000-0000-0000-0000-000000000001','Client Token Cancel','client-token-cancel-test');
insert into public.employees(id,name)
values ('95600000-0000-0000-0000-000000000002','Client Token Employee');
insert into public.services(id,category_id,name,slug,base_duration_minutes,base_price,minimum_people,maximum_people,maximum_booking_horizon_days,confirmation_percentage)
values ('95600000-0000-0000-0000-000000000010','95600000-0000-0000-0000-000000000001','Client Token Service','client-token-service',60,1000,1,2,5000,50);
insert into public.service_employees(id,service_id,employee_id)
values ('95600000-0000-0000-0000-000000000011','95600000-0000-0000-0000-000000000010','95600000-0000-0000-0000-000000000002');
insert into public.service_change_policies(service_id,notice_hours,reschedule_first_early_percent,reschedule_first_late_percent,reschedule_repeat_percent,cancellation_late_percent)
values ('95600000-0000-0000-0000-000000000010',48,0,20,30,30);
insert into public.customers(id,name,email,phone)
values ('95600000-0000-0000-0000-000000000020','Client Token Customer','client.token@example.com','48999994444');
insert into public.appointments(id,public_code,service_id,service_employee_id,service_name_snapshot,primary_customer_id,status,financial_status,start_at,end_at,duration_minutes,people_count,commercial_value,confirmed_at)
values ('95600000-0000-0000-0000-000000000030','CLIENT-TOKEN-CANCEL-1','95600000-0000-0000-0000-000000000010','95600000-0000-0000-0000-000000000011','Client Token Service','95600000-0000-0000-0000-000000000020','CONFIRMED','PARTIALLY_PAID','2035-03-10 10:00:00-03','2035-03-10 11:00:00-03',60,1,1000,now());
insert into public.payment_transactions(appointment_id,transaction_type,method,provider,provider_payment_id,status,contract_amount_settled,cash_amount,paid_at,payment_purpose)
values ('95600000-0000-0000-0000-000000000030','CHARGE','PIX','MERCADO_PAGO','client-token-cancel-approved','APPROVED',500,500,now(),'CONTRACT');

create temporary table issued_cancel as
select public.service_issue_appointment_action_token('95600000-0000-0000-0000-000000000030','CANCEL','EMAIL','c***@example.com','issue-cancel') payload;
create temporary table issued_reschedule as
select public.service_issue_appointment_action_token('95600000-0000-0000-0000-000000000030','RESCHEDULE','EMAIL','c***@example.com','issue-reschedule') payload;

select has_function('public','service_client_cancel_appointment_evidenced',array['uuid','text','timestamp with time zone','inet','text','text','text'],'client cancellation wrapper exists');
select throws_ok(format('select public.service_client_cancel_appointment_evidenced(%L::uuid,%L,%L::timestamptz,%L::inet,%L,%L,null)',(select payload->>'token_id' from issued_cancel),'CLIENT_REQUEST','2035-03-01 10:00:00-03','203.0.113.55','pgTAP client token','req-no-verify'),'P0001','CANCEL_EMAIL_VERIFICATION_REQUIRED','cancel requires same-request verification');
select is((select status::text from public.appointments where id='95600000-0000-0000-0000-000000000030'),'CONFIRMED','unverified attempt leaves reservation untouched');

select is(public.service_verify_appointment_action_email(((select payload->>'token_id' from issued_cancel))::uuid,'client.token@example.com','203.0.113.55'::inet,'pgTAP client token','req-execute'),true,'registered email verifies request');
select throws_ok(format('select public.service_client_cancel_appointment_evidenced(%L::uuid,%L,%L::timestamptz,%L::inet,%L,%L,null)',(select payload->>'token_id' from issued_cancel),'CLIENT_REQUEST','2035-03-01 10:00:00-03','203.0.113.55','pgTAP client token','req-different'),'P0001','CANCEL_EMAIL_VERIFICATION_REQUIRED','verification cannot authorize a different request id');

create temporary table cancelled as
select public.service_client_cancel_appointment_evidenced(((select payload->>'token_id' from issued_cancel))::uuid,'CLIENT_REQUEST','2035-03-01 10:00:00-03','203.0.113.55'::inet,'pgTAP client token','req-execute','session-test') data;

select is((select data->>'status' from cancelled),'CANCELLED','verified client request cancels reservation');
select is((select data->>'settlement_choice' from cancelled),'REFUND','refund remains safe default');
select ok((select consumed_at is not null from public.appointment_access_tokens where id=((select payload->>'token_id' from issued_cancel))::uuid),'successful cancellation consumes token');
select is((select consumed_action from public.appointment_access_tokens where id=((select payload->>'token_id' from issued_cancel))::uuid),'CANCEL_CONFIRMED','consumed action is recorded');
select ok(exists(select 1 from public.appointment_authorship_events a where a.appointment_id='95600000-0000-0000-0000-000000000030' and a.origin='CLIENT_TOKEN' and a.action='APPOINTMENT_CANCELLED' and a.appointment_access_token_id=((select payload->>'token_id' from issued_cancel))::uuid),'mutation records CLIENT_TOKEN authorship');
select is((select request_id from public.appointment_authorship_events where appointment_id='95600000-0000-0000-0000-000000000030' and origin='CLIENT_TOKEN' order by occurred_at desc limit 1),'req-execute','authorship preserves request id');
select ok(exists(select 1 from public.appointment_authorship_events a where a.appointment_id='95600000-0000-0000-0000-000000000030' and a.origin='CLIENT_TOKEN' and a.ip_address='203.0.113.55'::inet and a.user_agent='pgTAP client token' and a.session_id='session-test'),'authorship preserves network and session evidence');
select ok((select revoked_at is not null from public.appointment_access_tokens where id=((select payload->>'token_id' from issued_reschedule))::uuid),'state change revokes other action links');
select throws_ok(format('select public.service_client_cancel_appointment_evidenced(%L::uuid,%L,%L::timestamptz,%L::inet,%L,%L,null)',(select payload->>'token_id' from issued_cancel),'REPLAY','2035-03-01 10:01:00-03','203.0.113.55','pgTAP client token','req-execute'),'P0001','APPOINTMENT_TOKEN_INVALID','consumed token cannot be replayed');

select * from finish();
rollback;
