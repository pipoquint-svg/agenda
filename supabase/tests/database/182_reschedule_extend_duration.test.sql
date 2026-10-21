begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(18);

-- Locação por blocos de 30 min: 2-3 blocos a R$ 100, 4-7 blocos a R$ 90 (faixa por bloco).
insert into public.customers(id,name,email) values ('98000000-0000-0000-0000-000000000001','Extend Customer','extend@example.test');
insert into public.employees(id,name) values ('98000000-0000-0000-0000-000000000002','Extend Employee');
insert into public.categories(id,name,slug) values ('98000000-0000-0000-0000-000000000003','Extend Test','extend-test');
insert into public.resources(id,name,resource_type) values ('98000000-0000-0000-0000-000000000004','Extend Studio','PHYSICAL');
insert into public.services(id,category_id,name,slug,base_duration_minutes,base_price,buffer_before_minutes,buffer_after_minutes,minimum_people,maximum_people,
  minimum_booking_notice_minutes,maximum_booking_horizon_days,duration_mode,booking_block_minutes,minimum_booking_blocks,maximum_booking_blocks,price_per_block)
values ('98000000-0000-0000-0000-000000000005','98000000-0000-0000-0000-000000000003','Extend Rental','extend-rental',30,100,0,30,1,10,0,365,'BLOCKS',30,2,8,100);
insert into public.service_duration_pricing_tiers(service_id,min_blocks,max_blocks,price_per_block,sort_order)
values ('98000000-0000-0000-0000-000000000005',2,3,100.00,10),('98000000-0000-0000-0000-000000000005',4,8,90.00,20);
insert into public.service_employees(id,service_id,employee_id) values ('98000000-0000-0000-0000-000000000006','98000000-0000-0000-0000-000000000005','98000000-0000-0000-0000-000000000002');
insert into public.service_resources(service_id,resource_id,is_required) values ('98000000-0000-0000-0000-000000000005','98000000-0000-0000-0000-000000000004',true);
insert into public.availability_rules(service_employee_id,weekday,start_local_time,end_local_time,slot_interval_minutes,is_active)
select '98000000-0000-0000-0000-000000000006',d,time '08:00',time '18:00',30,true from generate_series(0,6) d;
insert into public.resource_availability_rules(resource_id,weekday,start_local_time,end_local_time,is_active)
select '98000000-0000-0000-0000-000000000004',d,time '08:00',time '18:00',true from generate_series(0,6) d;
insert into public.service_change_policies(service_id,notice_hours,reschedule_first_early_percent,reschedule_first_late_percent,reschedule_repeat_percent,cancellation_late_percent)
values ('98000000-0000-0000-0000-000000000005',48,0,20,30,30);

-- 1h (2 blocos) às 10h, R$ 200 pagos integralmente.
insert into public.appointments(id,public_code,service_id,service_employee_id,status,financial_status,start_at,end_at,core_start_at,core_end_at,
  duration_minutes,contracted_minutes,duration_blocks,people_count,primary_customer_id,commercial_value,confirmed_at)
values ('98000000-0000-0000-0000-000000000010','EXTEND-1','98000000-0000-0000-0000-000000000005','98000000-0000-0000-0000-000000000006','CONFIRMED','PAID',
  ((current_date+5)+time '10:00') at time zone 'America/Sao_Paulo',((current_date+5)+time '11:00') at time zone 'America/Sao_Paulo',
  ((current_date+5)+time '10:00') at time zone 'America/Sao_Paulo',((current_date+5)+time '11:00') at time zone 'America/Sao_Paulo',
  60,60,2,1,'98000000-0000-0000-0000-000000000001',200,now());
insert into public.payment_transactions(appointment_id,transaction_type,method,provider,provider_payment_id,status,contract_amount_settled,cash_amount,paid_at,payment_purpose)
values ('98000000-0000-0000-0000-000000000010','CHARGE','PIX','MERCADO_PAGO','extend-paid','APPROVED',200,200,now(),'CONTRACT');
insert into public.resource_allocations(resource_id,appointment_id,allocation_type,status,occupied_range)
values ('98000000-0000-0000-0000-000000000004','98000000-0000-0000-0000-000000000010','APPOINTMENT','CONFIRMED',
  tstzrange(((current_date+5)+time '10:00') at time zone 'America/Sao_Paulo',((current_date+5)+time '11:30') at time zone 'America/Sao_Paulo','[)'));

select has_function('public','service_admin_list_reschedule_slots',array['uuid','date','integer'],'slots accept a duration');
select has_function('public','service_admin_create_reschedule_hold',array['uuid','timestamp with time zone','timestamp with time zone','text','uuid','integer'],'reschedule hold accepts a duration');
select has_function('public','service_create_reschedule_difference_payment_intent',array['uuid','text','text','text'],'difference payment accepts 50 percent or full');

select ok(
  exists(select 1 from jsonb_array_elements(public.service_admin_list_reschedule_slots('98000000-0000-0000-0000-000000000010',current_date+5,4)) s
    where (s->>'slot_start_at')::timestamptz=((current_date+5)+time '10:00') at time zone 'America/Sao_Paulo'),
  'a longer duration offers the same start (extend in place)'
);
select throws_ok(
  $$select public.service_admin_list_reschedule_slots('98000000-0000-0000-0000-000000000010',current_date+5,1)$$,
  'P0001','RESCHEDULE_DURATION_DECREASE_NOT_ALLOWED','the duration never goes down'
);

create temporary table h as select public.service_admin_create_reschedule_hold(
  '98000000-0000-0000-0000-000000000010',((current_date+5)+time '10:00') at time zone 'America/Sao_Paulo',now(),'CLIENT',null,4) data;
select is((select (data->>'new_contract_value')::numeric from h),360::numeric,'2h is priced by the 4-block tier (4 x R$ 90), not by the old block price');
select is((select (data->>'extension_increment')::numeric from h),160::numeric,'increment is the new total minus the current value');
select is((select (data->>'extension_minimum_payment')::numeric from h),80::numeric,'minimum is half of the increment');
select is((select (data->>'extension_full_payment')::numeric from h),160::numeric,'full is the whole increment');
select is((select data->>'policy_action_status' from h),'AWAITING_DIFFERENCE_PAYMENT','extension waits for the payment');
select is((select (data->>'penalty_retained')::numeric from h),0::numeric,'extending in place has no reschedule penalty');

create temporary table pmin as select public.service_create_reschedule_difference_payment_intent((select (data->>'policy_action_id')::uuid from h),'MINIMUM','PIX','extend-min-key') data;
create temporary table pfull as select public.service_create_reschedule_difference_payment_intent((select (data->>'policy_action_id')::uuid from h),'FULL','PIX','extend-full-key') data;
select is((select (data->>'contract_amount_settled')::numeric from pmin),80::numeric,'50 percent option charges R$ 80');
select is((select (data->>'contract_amount_settled')::numeric from pfull),160::numeric,'full option charges R$ 160');

-- Mercado Pago aprova o pagamento de 50%.
update public.payment_transactions set status='APPROVED',paid_at=now(),provider_payment_id='extend-min-paid'
where id=(select (data->>'transaction_id')::uuid from pmin);
create temporary table ap as select public.service_apply_paid_client_reschedule((select (data->>'transaction_id')::uuid from pmin)) data;
select ok((select (data->>'applied')::boolean from ap),'approved payment applies the extension right away');
select is((select duration_blocks from public.appointments where id='98000000-0000-0000-0000-000000000010'),4,'booking now has 4 blocks');
select is((select commercial_value from public.appointments where id='98000000-0000-0000-0000-000000000010'),360::numeric,'booking value is the new total');
select is((public.get_appointment_financial_summary('98000000-0000-0000-0000-000000000010')->>'contract_balance')::numeric,80::numeric,'the other half stays as balance');
select is(public.appointment_client_reschedule_count('98000000-0000-0000-0000-000000000010'),0,'extending in place does not count as a client reschedule');

select * from finish();
rollback;
