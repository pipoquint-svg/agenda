begin;
create extension if not exists pgtap with schema extensions;
set local search_path=public,extensions;
select no_plan();

insert into auth.users(id,instance_id,aud,role,email,encrypted_password,created_at,updated_at)
values('16000000-0000-4000-8000-000000000001','00000000-0000-0000-0000-000000000000','authenticated','authenticated','invoice-owner@example.test','',now(),now());
insert into public.admin_users(id,auth_user_id,display_name,role)
values('16000000-0000-4000-8000-000000000002','16000000-0000-4000-8000-000000000001','Invoice test owner','OWNER');
insert into public.categories(id,name,slug) values('16000000-0000-4000-8000-000000000010','Invoice test','invoice-test');
insert into public.resources(id,name,resource_type) values('16000000-0000-4000-8000-000000000011','Invoice test studio','PHYSICAL');
insert into public.employees(id,name) values('16000000-0000-4000-8000-000000000012','Invoice test employee');
insert into public.services(id,category_id,name,slug,base_duration_minutes,base_price,minimum_people,maximum_people,maximum_booking_horizon_days,requires_terms)
values('16000000-0000-4000-8000-000000000013','16000000-0000-4000-8000-000000000010','Invoice service','invoice-service',60,850,1,10,5000,false);
insert into public.service_employees(id,service_id,employee_id)
values('16000000-0000-4000-8000-000000000014','16000000-0000-4000-8000-000000000013','16000000-0000-4000-8000-000000000012');
insert into public.service_resources(service_id,resource_id)
values('16000000-0000-4000-8000-000000000013','16000000-0000-4000-8000-000000000011');
insert into public.customers(id,customer_type,name,email,phone)
values('16000000-0000-4000-8000-000000000015','BUSINESS','Invoice test company','invoice@example.test','+5548999990160');
select lives_ok($$insert into public.customer_commercial_terms(customer_id,can_prebook,billing_mode,invoice_due_days,requires_manual_confirmation)
 values('16000000-0000-4000-8000-000000000015',true,'INVOICE',14,false)$$,'invoice plus prebooking can be saved');
select is((select invoice_due_days from public.customer_commercial_terms where customer_id='16000000-0000-4000-8000-000000000015'),14,'saving prebooking preserves fourteen days');
insert into public.customer_prebook_authorized_services(customer_id,service_id)
values('16000000-0000-4000-8000-000000000015','16000000-0000-4000-8000-000000000013');

select throws_ok($$select public.service_admin_set_customer_commercial_terms(
 '16000000-0000-4000-8000-000000000015',true,2880,1,true,'INVOICE',14,true,
 array['16000000-0000-4000-8000-000000000013'::uuid],null)$$,
 'P0001','ADMIN_FINANCE_PERMISSION_REQUIRED','invoice approval changes require financial authority');
select lives_ok($$select public.service_admin_set_customer_commercial_terms(
 '16000000-0000-4000-8000-000000000015',true,2880,1,false,'INVOICE',14,true,
 array['16000000-0000-4000-8000-000000000013'::uuid],'16000000-0000-4000-8000-000000000002')$$,
 'administrative save accepts invoice plus prebooking without discarding terms');

create function pg_temp.invoice_hold(n integer,verified boolean default true,amount numeric default 850,private_invite boolean default false)
returns text language plpgsql as $$
declare v_id uuid:=gen_random_uuid(); v_token text:=repeat('invoice-checkout-',3)||n; v_start timestamptz:='2035-01-15 09:00:00-03'::timestamptz+n*interval '2 hours';
begin
 insert into public.checkout_holds(id,public_token_hash,service_id,service_employee_id,selection_hash,
 primary_customer_id,people_count,requested_start_at,requested_end_at,core_start_at,core_end_at,
 expires_at,extra_selections,commercial_value,pricing_version,duration_minutes,resource_ids,quote_snapshot,attribution_json)
 values(v_id,encode(digest(v_token,'sha256'),'hex'),'16000000-0000-4000-8000-000000000013',
 '16000000-0000-4000-8000-000000000014','invoice-selection-'||n,'16000000-0000-4000-8000-000000000015',
 1,v_start,v_start+interval '1 hour',v_start,v_start+interval '1 hour',now()+interval '30 minutes','[]',amount,'invoice-test',60,
 array['16000000-0000-4000-8000-000000000011'::uuid],
 jsonb_build_object('base_price',amount,'commercial_value',amount,'extras_total',0,'day_time_adjustment',0,'people_adjustment',0),
 case when private_invite then '{"source":"WAITLIST_PRIVATE_INVITE"}'::jsonb else '{}'::jsonb end);
 insert into public.resource_allocations(resource_id,checkout_hold_id,allocation_type,status,occupied_range)
 values('16000000-0000-4000-8000-000000000011',v_id,'CHECKOUT_HOLD','HELD',tstzrange(v_start,v_start+interval '1 hour','[)'));
 if verified then
  insert into public.checkout_customer_verifications(checkout_hold_id,customer_id,code_hash,status,expires_at,session_token_hash,session_expires_at,verified_at)
  values(v_id,'16000000-0000-4000-8000-000000000015','test-code','VERIFIED',now()+interval '30 minutes',
   encode(digest(repeat('verified-invoice-',3),'sha256'),'hex'),now()+interval '30 minutes',now());
 end if;
 return v_token;
end;
$$;
create function pg_temp.invoice_submit(token text,mode text default 'PAY_NOW',verified boolean default true)
returns jsonb language sql as $$
 select public.service_submit_public_checkout_choice_with_benefits(token,mode,null,'{}','[]',null,'pgTAP','invoice-test',
 case when verified then repeat('verified-invoice-',3) else null end,false);
$$;
create temp table invoice_cases(label text primary key,token text,result jsonb);
insert into invoice_cases values('normal',pg_temp.invoice_hold(1),null);
-- Volt's current configuration: invoice enabled, optional prebooking disabled.
update public.customer_commercial_terms set can_prebook=false where customer_id='16000000-0000-4000-8000-000000000015';
select ok((select (public.service_public_checkout_benefit_hint(token)->>'verification_required')::boolean from invoice_cases where label='normal'),'invoice entitlement uses the existing email verification flow');
select ok((select public.service_public_get_checkout_prebook_option(token)->>'billing_mode'='INVOICE'
 and not (public.service_public_get_checkout_prebook_option(token)->>'eligible')::boolean from invoice_cases where label='normal'),'invoice option is independent of prebook permission');
select throws_ok($$select pg_temp.invoice_submit(token,'PAY_NOW',false) from invoice_cases where label='normal'$$,'P0001','CUSTOMER_VERIFICATION_REQUIRED','typed customer data alone cannot authorize credit');
select is((select count(*)::integer from public.appointments where primary_customer_id='16000000-0000-4000-8000-000000000015'),0,'failed identity check creates no reservation');
update invoice_cases set result=pg_temp.invoice_submit(token) where label='normal';
select is((select result->>'status' from invoice_cases where label='normal'),'CONFIRMED','normal invoice checkout confirms without payment');
select is((select result->>'financial_status' from invoice_cases where label='normal'),'UNPAID_AUTHORIZED','invoice is not marked paid');
select is((select (result->>'cash_due')::numeric from invoice_cases where label='normal'),850::numeric,'invoice preserves full outstanding value, no PIX discount');
select ok((select result->>'payment_required'='false' and result->>'hold_expires_at' is null from invoice_cases where label='normal'),'confirmed invoice has no payment requirement or expiration deadline');
select ok((select a.invoice_due_at=a.core_start_at+interval '14 days' and a.invoice_due_base_at=a.core_start_at
 from public.appointments a join invoice_cases c on a.id=(c.result->>'appointment_id')::uuid where c.label='normal'),'invoice due date is service start plus fourteen days');
select is((select count(*)::integer from public.payment_transactions where appointment_id=(select (result->>'appointment_id')::uuid from invoice_cases where label='normal')),0,'invoice checkout creates no payment transaction');
select is((select status::text from public.resource_allocations where appointment_id=(select (result->>'appointment_id')::uuid from invoice_cases where label='normal')),'CONFIRMED','same resource allocation is confirmed');
select throws_ok($$select public.service_create_payment_intent_by_token(result->>'access_token','FULL','PIX','invoice-request-test') from invoice_cases where label='normal'$$,'P0001','INVOICE_CHECKOUT_PAYMENT_NOT_REQUIRED','stale checkout cannot create a PIX charge for invoice');
select ok((select public.service_get_public_payment_context(result->>'access_token')->>'payment_required'='false' from invoice_cases where label='normal'),'stale payment link reports invoice without payment');
select throws_ok($$select pg_temp.invoice_submit(token) from invoice_cases where label='normal'$$,'P0001','CHECKOUT_HOLD_NOT_ACTIVE','repeated submit cannot duplicate reservation');

update public.customer_commercial_terms set can_prebook=true where customer_id='16000000-0000-4000-8000-000000000015';
insert into invoice_cases values('prebook',pg_temp.invoice_hold(2),null);
update invoice_cases set result=pg_temp.invoice_submit(token,'PREBOOK') where label='prebook';
select ok((select result->>'pre_reservation'='true' and result->>'status'='AWAITING_PAYMENT' and result->>'payment_required'='false' from invoice_cases where label='prebook'),'invoice prebook holds the time without requesting payment');
select is((select public.public_get_pre_reservation_context(result->>'access_token')->>'billing_mode' from invoice_cases where label='prebook'),'INVOICE','resume link preserves invoice mode');
insert into invoice_cases values('quota',pg_temp.invoice_hold(3),null);
select throws_ok($$select pg_temp.invoice_submit(token,'PREBOOK') from invoice_cases where label='quota'$$,'P0001','MAX_ACTIVE_PREBOOKS_REACHED','temporary prebook quota is enforced');
update invoice_cases set result=pg_temp.invoice_submit(token) where label='quota';
select is((select result->>'status' from invoice_cases where label='quota'),'CONFIRMED','full prebook quota does not prevent normal invoiced checkout');
update public.customer_commercial_terms set invoice_due_days=30 where customer_id='16000000-0000-4000-8000-000000000015';
select is((select public.service_confirm_invoice_prebook_by_token(result->>'access_token')->>'status' from invoice_cases where label='prebook'),'CONFIRMED','customer confirms prebook using opaque management token without payment');
select is((select public.service_confirm_invoice_prebook_by_token(result->>'access_token')->>'status' from invoice_cases where label='prebook'),'CONFIRMED','invoice prebook confirmation is idempotent');
select is((select a.invoice_due_days_snapshot from public.appointments a join invoice_cases c on a.id=(c.result->>'appointment_id')::uuid where c.label='prebook'),14,'later terms edit does not rewrite agreed invoice snapshot');
select is((select count(*)::integer from public.appointments where primary_customer_id='16000000-0000-4000-8000-000000000015'),3,'confirmation reuses existing appointment instead of creating another');

update public.customer_commercial_terms set invoice_due_days=14,requires_manual_confirmation=true,can_prebook=false where customer_id='16000000-0000-4000-8000-000000000015';
select ok((select requires_manual_confirmation from public.customer_commercial_terms where customer_id='16000000-0000-4000-8000-000000000015'),'invoice manual-confirmation setting is preserved');
insert into invoice_cases values('manual',pg_temp.invoice_hold(4),null);
update invoice_cases set result=pg_temp.invoice_submit(token) where label='manual';
select ok((select result->>'confirmation_pending'='true' and result->>'requires_manual_confirmation'='true' and result->>'payment_required'='false' from invoice_cases where label='manual'),'manual invoice checkout accepts a pending request, never demands payment');
select throws_ok($$select public.service_confirm_invoice_prebook_by_token(result->>'access_token') from invoice_cases where label='manual'$$,'P0001','INVOICE_MANUAL_CONFIRMATION_REQUIRED','customer cannot bypass manual approval');
select throws_ok($$select public.service_admin_confirm_pre_reservation((result->>'pre_reservation_id')::uuid,null) from invoice_cases where label='manual'$$,'P0001','ADMIN_PERMISSION_DENIED','admin approval requires permission');
select is((select public.service_admin_confirm_pre_reservation((result->>'pre_reservation_id')::uuid,'16000000-0000-4000-8000-000000000002')->>'status' from invoice_cases where label='manual'),'CONFIRMED','authorized administrator confirms the linked invoice prebook');

update public.customer_commercial_terms set requires_manual_confirmation=false,can_prebook=true where customer_id='16000000-0000-4000-8000-000000000015';
insert into invoice_cases values('expired',pg_temp.invoice_hold(5),null);
update invoice_cases set result=pg_temp.invoice_submit(token,'PREBOOK') where label='expired';
update public.pre_reservations set created_at=now()-interval '49 hours',expires_at=now()-interval '1 hour' where id=(select (result->>'pre_reservation_id')::uuid from invoice_cases where label='expired');
update public.appointments set hold_expires_at=now()-interval '1 hour' where id=(select (result->>'appointment_id')::uuid from invoice_cases where label='expired');
select public.service_expire_pre_reservations();
select is((select status::text from public.appointments where id=(select (result->>'appointment_id')::uuid from invoice_cases where label='expired')),'EXPIRED','unconfirmed invoice prebook expires');
select is((select status::text from public.appointments where id=(select (result->>'appointment_id')::uuid from invoice_cases where label='normal')),'CONFIRMED','expiration worker never expires the confirmed invoice');
select throws_ok($$select public.service_confirm_invoice_prebook_by_token(result->>'access_token') from invoice_cases where label='expired'$$,'P0001','PRE_RESERVATION_NOT_ACTIVE','expired invoice prebook cannot be resurrected');

insert into invoice_cases values('private',pg_temp.invoice_hold(6,true,850,true),null);
select is((select public.service_public_get_checkout_prebook_option(token)->>'eligible' from invoice_cases where label='private'),'false','private waitlist still denies long prebooking');
select throws_ok($$select pg_temp.invoice_submit(token,'PREBOOK') from invoice_cases where label='private'$$,'P0001','PREBOOK_NOT_AVAILABLE','private restriction is enforced by submission');
update invoice_cases set result=pg_temp.invoice_submit(token) where label='private';
select is((select result->>'status' from invoice_cases where label='private'),'CONFIRMED','normal invoice confirmation does not extend a private waitlist hold');

update public.customer_commercial_terms set is_active=false where customer_id='16000000-0000-4000-8000-000000000015';
insert into invoice_cases values('ordinary',pg_temp.invoice_hold(7,false),null);
update invoice_cases set result=pg_temp.invoice_submit(token,'PAY_NOW',false) where label='ordinary';
select is((select result->>'status' from invoice_cases where label='ordinary'),'AWAITING_PAYMENT','inactive invoice terms cannot waive payment');
update public.customer_commercial_terms set is_active=true where customer_id='16000000-0000-4000-8000-000000000015';
insert into invoice_cases values('free',pg_temp.invoice_hold(8,false,0),null);
update invoice_cases set result=pg_temp.invoice_submit(token,'PAY_NOW',false) where label='free';
select is((select result->>'status' from invoice_cases where label='free'),'CONFIRMED','zero-value checkout remains automatic without credit verification');
select ok(not has_function_privilege('anon','public.service_confirm_invoice_prebook_by_token(text)','EXECUTE'),'anon cannot bypass rate-limited Edge');
select ok(not has_function_privilege('authenticated','public.service_submit_public_checkout_choice_with_benefits(text,text,text,uuid[],jsonb,inet,text,text,text,boolean)','EXECUTE'),'authenticated cannot bypass canonical verified submit');
select ok(not has_function_privilege('service_role','public.confirm_linked_invoice_prebook(uuid,uuid,boolean)','EXECUTE'),'internal confirmation helper has no direct service-role access');
select * from finish();
rollback;
