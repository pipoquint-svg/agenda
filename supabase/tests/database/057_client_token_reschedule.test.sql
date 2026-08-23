begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(18);

insert into public.customers(id,name,email) values ('95400000-0000-0000-0000-000000000001','Client Reschedule Customer','client.reschedule@example.com');
insert into public.employees(id,name) values ('95400000-0000-0000-0000-000000000002','Client Reschedule Employee');
insert into public.categories(id,name,slug) values ('95400000-0000-0000-0000-000000000003','Client Reschedule','client-reschedule-test');
insert into public.resources(id,name,resource_type) values ('95400000-0000-0000-0000-000000000004','Client Reschedule Studio','PHYSICAL');
insert into public.services(id,category_id,name,slug,base_duration_minutes,base_price,buffer_before_minutes,buffer_after_minutes,minimum_people,maximum_people,minimum_booking_notice_minutes,maximum_booking_horizon_days,confirmation_percentage)
values ('95400000-0000-0000-0000-000000000005','95400000-0000-0000-0000-000000000003','Client Reschedule Service','client-reschedule-service',120,500,0,30,1,10,0,365,50);
insert into public.service_employees(id,service_id,employee_id) values ('95400000-0000-0000-0000-000000000006','95400000-0000-0000-0000-000000000005','95400000-0000-0000-0000-000000000002');
insert into public.service_resources(service_id,resource_id,is_required) values ('95400000-0000-0000-0000-000000000005','95400000-0000-0000-0000-000000000004',true);
insert into public.availability_rules(service_employee_id,weekday,start_local_time,end_local_time,slot_interval_minutes,is_active)
select '95400000-0000-0000-0000-000000000006',d,time '08:00',time '18:00',30,true from generate_series(0,6) d;
insert into public.service_change_policies(service_id,notice_hours,reschedule_first_early_percent,reschedule_first_late_percent,reschedule_repeat_percent,cancellation_late_percent)
values ('95400000-0000-0000-0000-000000000005',48,0,20,30,30);

insert into public.appointments(id,public_code,service_id,service_employee_id,status,financial_status,start_at,end_at,core_start_at,core_end_at,duration_minutes,contracted_minutes,people_count,primary_customer_id,commercial_value,confirmed_at)
values
('95400000-0000-0000-0000-000000000010','CLIENT-RESCHEDULE-FREE','95400000-0000-0000-0000-000000000005','95400000-0000-0000-0000-000000000006','CONFIRMED','PARTIALLY_PAID',((current_date+5)+time '10:00') at time zone 'America/Sao_Paulo',((current_date+5)+time '12:00') at time zone 'America/Sao_Paulo',((current_date+5)+time '10:00') at time zone 'America/Sao_Paulo',((current_date+5)+time '12:00') at time zone 'America/Sao_Paulo',120,120,1,'95400000-0000-0000-0000-000000000001',500,now()),
('95400000-0000-0000-0000-000000000020','CLIENT-RESCHEDULE-LATE','95400000-0000-0000-0000-000000000005','95400000-0000-0000-0000-000000000006','CONFIRMED','PARTIALLY_PAID',((current_date+1)+time '14:00') at time zone 'America/Sao_Paulo',((current_date+1)+time '16:00') at time zone 'America/Sao_Paulo',((current_date+1)+time '14:00') at time zone 'America/Sao_Paulo',((current_date+1)+time '16:00') at time zone 'America/Sao_Paulo',120,120,1,'95400000-0000-0000-0000-000000000001',500,now());
insert into public.payment_transactions(appointment_id,transaction_type,method,provider,provider_payment_id,status,contract_amount_settled,cash_amount,paid_at,payment_purpose)
values
('95400000-0000-0000-0000-000000000010','CHARGE','CARD','MERCADO_PAGO','client-reschedule-free-paid','APPROVED',250,250,now(),'CONTRACT'),
('95400000-0000-0000-0000-000000000020','CHARGE','CARD','MERCADO_PAGO','client-reschedule-late-paid','APPROVED',250,250,now(),'CONTRACT');
insert into public.resource_allocations(id,resource_id,appointment_id,allocation_type,status,occupied_range)
values
('95400000-0000-0000-0000-000000000011','95400000-0000-0000-0000-000000000004','95400000-0000-0000-0000-000000000010','APPOINTMENT','CONFIRMED',tstzrange(((current_date+5)+time '10:00') at time zone 'America/Sao_Paulo',((current_date+5)+time '12:30') at time zone 'America/Sao_Paulo','[)')),
('95400000-0000-0000-0000-000000000021','95400000-0000-0000-0000-000000000004','95400000-0000-0000-0000-000000000020','APPOINTMENT','CONFIRMED',tstzrange(((current_date+1)+time '14:00') at time zone 'America/Sao_Paulo',((current_date+1)+time '16:30') at time zone 'America/Sao_Paulo','[)'));

select has_function('public','service_client_reschedule_requirements',array['uuid','uuid'],'client reschedule requirements function exists');
select has_function('public','service_client_apply_reschedule_evidenced',array['uuid','uuid','inet','text','text','text'],'client reschedule apply wrapper exists');

create temporary table free_token as select public.service_issue_appointment_action_token('95400000-0000-0000-0000-000000000010','RESCHEDULE','EMAIL','c***@example.com','free-reschedule') payload;
create temporary table free_other as select public.service_issue_appointment_action_token('95400000-0000-0000-0000-000000000010','CANCEL','EMAIL','c***@example.com','free-cancel') payload;
create temporary table free_hold as select public.service_admin_create_reschedule_hold('95400000-0000-0000-0000-000000000010',((current_date+10)+time '10:00') at time zone 'America/Sao_Paulo',now(),'CLIENT',null) data;
create temporary table free_req as select public.service_client_reschedule_requirements(((select payload->>'token_id' from free_token))::uuid,((select data->>'policy_action_id' from free_hold))::uuid) data;

select is((select (data->>'difference_due')::numeric from free_hold),0::numeric,'free same-price reschedule has no payment difference');
select is((select (data->>'requires_email_verification')::boolean from free_req),false,'financially neutral reschedule needs token possession but no extra email proof');
create temporary table free_apply as select public.service_client_apply_reschedule_evidenced(((select payload->>'token_id' from free_token))::uuid,((select data->>'policy_action_id' from free_hold))::uuid,'203.0.113.80'::inet,'pgTAP reschedule','free-request','free-session') data;
select is((select data->>'status' from free_apply),'APPLIED','neutral client reschedule applies without email verification');
select ok((select consumed_at is not null from public.appointment_access_tokens where id=((select payload->>'token_id' from free_token))::uuid),'neutral reschedule consumes its token after successful apply');
select ok(exists(select 1 from public.appointment_authorship_events where appointment_id='95400000-0000-0000-0000-000000000010' and origin='CLIENT_TOKEN' and action='APPOINTMENT_RESCHEDULED' and request_id='free-request'),'neutral reschedule records CLIENT_TOKEN authorship');
select ok((select revoked_at is not null from public.appointment_access_tokens where id=((select payload->>'token_id' from free_other))::uuid),'reschedule revokes other outstanding appointment links');

create temporary table late_token as select public.service_issue_appointment_action_token('95400000-0000-0000-0000-000000000020','RESCHEDULE','EMAIL','c***@example.com','late-reschedule') payload;
create temporary table late_hold as select public.service_admin_create_reschedule_hold('95400000-0000-0000-0000-000000000020',((current_date+12)+time '14:00') at time zone 'America/Sao_Paulo',now(),'CLIENT',null) data;
create temporary table late_req_before as select public.service_client_reschedule_requirements(((select payload->>'token_id' from late_token))::uuid,((select data->>'policy_action_id' from late_hold))::uuid) data;
select ok((select (data->>'penalty_amount')::numeric from late_req_before)>0,'late reschedule carries a retained financial penalty');
select is((select (data->>'requires_email_verification')::boolean from late_req_before),true,'financial reschedule requires registered-email verification');
select is((select (data->>'requires_payment')::boolean from late_req_before),true,'late reschedule reports current payment difference before apply');

insert into public.payment_transactions(appointment_id,transaction_type,method,provider,provider_payment_id,status,contract_amount_settled,cash_amount,paid_at,payment_purpose)
select '95400000-0000-0000-0000-000000000020','CHARGE','PIX','MERCADO_PAGO','client-reschedule-late-difference','APPROVED',(data->>'outstanding_difference')::numeric,(data->>'outstanding_difference')::numeric,now(),'CONTRACT'
from late_req_before;
create temporary table late_req_after as select public.service_client_reschedule_requirements(((select payload->>'token_id' from late_token))::uuid,((select data->>'policy_action_id' from late_hold))::uuid) data;
select is((select (data->>'requires_payment')::boolean from late_req_after),false,'approved difference payment clears current outstanding amount');
select throws_ok(format('select public.service_client_apply_reschedule_evidenced(%L::uuid,%L::uuid,%L::inet,%L,%L,%L)',(select payload->>'token_id' from late_token),(select data->>'policy_action_id' from late_hold),'203.0.113.81','pgTAP reschedule','late-request','late-session'),'P0001','RESCHEDULE_EMAIL_VERIFICATION_REQUIRED','financial reschedule cannot execute without same-request email verification');
select is((select start_at from public.appointments where id='95400000-0000-0000-0000-000000000020'),((current_date+1)+time '14:00') at time zone 'America/Sao_Paulo','failed financial execution leaves original slot unchanged');
select is(public.service_verify_appointment_action_email(((select payload->>'token_id' from late_token))::uuid,'client.reschedule@example.com','203.0.113.81'::inet,'pgTAP reschedule','late-request'),true,'registered email verifies the financial reschedule request');
create temporary table late_apply as select public.service_client_apply_reschedule_evidenced(((select payload->>'token_id' from late_token))::uuid,((select data->>'policy_action_id' from late_hold))::uuid,'203.0.113.81'::inet,'pgTAP reschedule','late-request','late-session') data;
select is((select data->>'status' from late_apply),'APPLIED','verified financial client reschedule applies');
select ok((select consumed_at is not null from public.appointment_access_tokens where id=((select payload->>'token_id' from late_token))::uuid),'financial reschedule consumes token only after successful apply');
select ok(exists(select 1 from public.appointment_authorship_events where appointment_id='95400000-0000-0000-0000-000000000020' and origin='CLIENT_TOKEN' and action='APPOINTMENT_RESCHEDULED' and request_id='late-request'),'financial reschedule records CLIENT_TOKEN authorship');

select * from finish();
rollback;
