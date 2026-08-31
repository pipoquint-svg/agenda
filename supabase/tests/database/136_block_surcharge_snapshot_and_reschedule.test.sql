begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(15);

insert into public.customers(id,name,email,phone)
values ('98600000-0000-0000-0000-000000000001','Block surcharge customer','block-surcharge@example.com','+5548999999860');

insert into public.employees(id,name)
values ('98600000-0000-0000-0000-000000000002','Block surcharge employee');

insert into public.categories(id,name,slug)
values ('98600000-0000-0000-0000-000000000003','Block surcharge test','block-surcharge-test');

insert into public.resources(id,name,resource_type)
values ('98600000-0000-0000-0000-000000000004','Block surcharge studio','PHYSICAL');

insert into public.services(
  id,category_id,name,slug,base_duration_minutes,base_price,
  buffer_before_minutes,buffer_after_minutes,minimum_people,maximum_people,
  minimum_booking_notice_minutes,maximum_booking_horizon_days,
  duration_mode,booking_block_minutes,minimum_booking_blocks,maximum_booking_blocks,price_per_block
) values
  ('98600000-0000-0000-0000-000000000010','98600000-0000-0000-0000-000000000003','Block surcharge rental','block-surcharge-rental',30,80,0,0,1,10,0,5000,'BLOCKS',30,8,16,80),
  ('98600000-0000-0000-0000-000000000011','98600000-0000-0000-0000-000000000003','Fixed legacy service','fixed-legacy-surcharge-test',240,640,0,0,1,10,0,5000,'FIXED',null,null,null,null);

insert into public.service_employees(id,service_id,employee_id)
values
  ('98600000-0000-0000-0000-000000000020','98600000-0000-0000-0000-000000000010','98600000-0000-0000-0000-000000000002'),
  ('98600000-0000-0000-0000-000000000021','98600000-0000-0000-0000-000000000011','98600000-0000-0000-0000-000000000002');

insert into public.service_resources(service_id,resource_id,is_required)
values
  ('98600000-0000-0000-0000-000000000010','98600000-0000-0000-0000-000000000004',true),
  ('98600000-0000-0000-0000-000000000011','98600000-0000-0000-0000-000000000004',true);

insert into public.availability_rules(service_employee_id,weekday,start_local_time,end_local_time,slot_interval_minutes,is_active)
values
  ('98600000-0000-0000-0000-000000000020',1,time '08:00',time '23:59',30,true),
  ('98600000-0000-0000-0000-000000000021',1,time '08:00',time '23:59',30,true);

insert into public.resource_availability_rules(resource_id,weekday,start_local_time,end_local_time,is_active)
values ('98600000-0000-0000-0000-000000000004',1,time '08:00',time '23:59',true);

insert into public.service_change_policies(
  service_id,notice_hours,reschedule_first_early_percent,reschedule_first_late_percent,
  reschedule_repeat_percent,cancellation_late_percent
) values
  ('98600000-0000-0000-0000-000000000010',48,0,20,20,20),
  ('98600000-0000-0000-0000-000000000011',48,0,20,20,20);

insert into public.service_duration_pricing_tiers(service_id,min_blocks,max_blocks,price_per_block,sort_order)
values ('98600000-0000-0000-0000-000000000010',8,16,80,10);

insert into public.pricing_rules(
  service_id,name,rule_scope,days_of_week,start_local_time,end_local_time,
  action_type,percentage,priority,is_active
) values
  ('98600000-0000-0000-0000-000000000010','Night BLOCKS +20','DAY_TIME',array[1]::smallint[],time '19:00',time '23:59:59','ADD_PERCENT',20,10,true),
  ('98600000-0000-0000-0000-000000000011','Night FIXED legacy +20','DAY_TIME',array[1]::smallint[],time '19:00',time '23:59:59','ADD_PERCENT',20,10,true);

create temporary table canonical_quote as
select public.calculate_booking_quote_for_duration(
  '98600000-0000-0000-0000-000000000010',
  '98600000-0000-0000-0000-000000000020',
  8,'[]'::jsonb,1,
  timestamp with time zone '2035-01-15 18:00:00-03',null
) data;

select is((select (data->>'base_amount')::numeric(12,2) from canonical_quote),640.00::numeric(12,2),'BLOCKS 4h resolves R$640 base from the total contracted tier');
select is((select (data->>'surcharge_amount')::numeric(12,2) from canonical_quote),96.00::numeric(12,2),'18:00-22:00 applies +20% only to the six 30-minute blocks from 19:00 onward');
select is((select (data->>'commercial_value')::numeric(12,2) from canonical_quote),736.00::numeric(12,2),'canonical BLOCKS quote totals R$736');

insert into public.checkout_holds(
  id,public_token_hash,service_id,service_employee_id,selection_hash,people_count,
  requested_start_at,requested_end_at,core_start_at,core_end_at,expires_at,
  extra_selections,commercial_value,pricing_version,duration_minutes,resource_ids,
  duration_blocks,contracted_minutes
) values (
  '98600000-0000-0000-0000-000000000030','block-surcharge-hold',
  '98600000-0000-0000-0000-000000000010','98600000-0000-0000-0000-000000000020','block-surcharge',1,
  timestamp with time zone '2035-01-15 18:00:00-03',timestamp with time zone '2035-01-15 22:00:00-03',
  timestamp with time zone '2035-01-15 18:00:00-03',timestamp with time zone '2035-01-15 22:00:00-03',now()+interval '10 minutes',
  '[]'::jsonb,736,'block-surcharge-test',240,array['98600000-0000-0000-0000-000000000004'::uuid],8,240
);

select is((select (quote_snapshot->>'commercial_value')::numeric(12,2) from public.checkout_holds where id='98600000-0000-0000-0000-000000000030'),736.00::numeric(12,2),'checkout hold snapshot total equals the displayed canonical quote');
select is((select (quote_snapshot->>'base_amount')::numeric(12,2) from public.checkout_holds where id='98600000-0000-0000-0000-000000000030'),640.00::numeric(12,2),'checkout hold snapshot keeps R$640 base');
select is((select (quote_snapshot->>'surcharge_amount')::numeric(12,2) from public.checkout_holds where id='98600000-0000-0000-0000-000000000030'),96.00::numeric(12,2),'checkout hold snapshot keeps R$96 surcharge');

insert into public.resource_allocations(resource_id,checkout_hold_id,allocation_type,status,occupied_range)
values (
  '98600000-0000-0000-0000-000000000004','98600000-0000-0000-0000-000000000030',
  'CHECKOUT_HOLD','HELD',tstzrange(timestamp with time zone '2035-01-15 18:00:00-03',timestamp with time zone '2035-01-15 22:00:00-03','[)')
);

create temporary table promoted as
select public.promote_checkout_hold(
  '98600000-0000-0000-0000-000000000030',
  '98600000-0000-0000-0000-000000000001'
) data;

select is((select (data->>'cash_due')::numeric(12,2) from promoted),736.00::numeric(12,2),'promotion charges the same R$736 frozen in checkout');
select is((select commercial_value from public.appointments where id=(select promoted_appointment_id from public.checkout_holds where id='98600000-0000-0000-0000-000000000030')),736.00::numeric(12,2),'promoted appointment stores R$736 total');
select is((select base_price_snapshot from public.appointments where id=(select promoted_appointment_id from public.checkout_holds where id='98600000-0000-0000-0000-000000000030')),640.00::numeric(12,2),'promoted appointment stores R$640 base');
select is((select surcharge_amount_snapshot from public.appointments where id=(select promoted_appointment_id from public.checkout_holds where id='98600000-0000-0000-0000-000000000030')),96.00::numeric(12,2),'promoted appointment stores R$96 surcharge for Gestão');
select ok(position('surcharge_amount' in pg_get_functiondef('public.service_admin_get_appointment_base(uuid)'::regprocedure)) > 0,'admin appointment read model exposes surcharge_amount');

select is((public.calculate_booking_quote_for_duration(
  '98600000-0000-0000-0000-000000000011','98600000-0000-0000-0000-000000000021',null,'[]'::jsonb,1,
  timestamp with time zone '2035-01-15 18:00:00-03',null
)->>'commercial_value')::numeric(12,2),640.00::numeric(12,2),'FIXED crossing into night remains on legacy start-time pricing');
select is((public.calculate_booking_quote_for_duration(
  '98600000-0000-0000-0000-000000000011','98600000-0000-0000-0000-000000000021',null,'[]'::jsonb,1,
  timestamp with time zone '2035-01-15 19:00:00-03',null
)->>'commercial_value')::numeric(12,2),768.00::numeric(12,2),'FIXED starting inside DAY_TIME rule keeps legacy whole-quote adjustment');

insert into public.appointments(
  id,public_code,service_id,service_employee_id,status,financial_status,start_at,end_at,
  core_start_at,core_end_at,duration_minutes,contracted_minutes,duration_blocks,people_count,
  primary_customer_id,commercial_value,confirmed_at
) values
  ('98600000-0000-0000-0000-000000000040','BLOCK-DAY-1','98600000-0000-0000-0000-000000000010','98600000-0000-0000-0000-000000000020','CONFIRMED','PAID',timestamp with time zone '2035-01-22 10:00:00-03',timestamp with time zone '2035-01-22 14:00:00-03',timestamp with time zone '2035-01-22 10:00:00-03',timestamp with time zone '2035-01-22 14:00:00-03',240,240,8,1,'98600000-0000-0000-0000-000000000001',640,now()),
  ('98600000-0000-0000-0000-000000000041','BLOCK-NIGHT-1','98600000-0000-0000-0000-000000000010','98600000-0000-0000-0000-000000000020','CONFIRMED','PAID',timestamp with time zone '2035-02-05 18:00:00-03',timestamp with time zone '2035-02-05 22:00:00-03',timestamp with time zone '2035-02-05 18:00:00-03',timestamp with time zone '2035-02-05 22:00:00-03',240,240,8,1,'98600000-0000-0000-0000-000000000001',736,now());

insert into public.payment_transactions(appointment_id,transaction_type,method,provider,provider_payment_id,status,contract_amount_settled,cash_amount,paid_at,payment_purpose)
values
  ('98600000-0000-0000-0000-000000000040','CHARGE','CARD','MERCADO_PAGO','block-day-paid','APPROVED',640,640,now(),'CONTRACT'),
  ('98600000-0000-0000-0000-000000000041','CHARGE','CARD','MERCADO_PAGO','block-night-paid','APPROVED',736,736,now(),'CONTRACT');

insert into public.resource_allocations(id,resource_id,appointment_id,allocation_type,status,occupied_range)
values
  ('98600000-0000-0000-0000-000000000050','98600000-0000-0000-0000-000000000004','98600000-0000-0000-0000-000000000040','APPOINTMENT','CONFIRMED',tstzrange(timestamp with time zone '2035-01-22 10:00:00-03',timestamp with time zone '2035-01-22 14:00:00-03','[)')),
  ('98600000-0000-0000-0000-000000000051','98600000-0000-0000-0000-000000000004','98600000-0000-0000-0000-000000000041','APPOINTMENT','CONFIRMED',tstzrange(timestamp with time zone '2035-02-05 18:00:00-03',timestamp with time zone '2035-02-05 22:00:00-03','[)'));

create temporary table day_to_night as
select public.service_admin_create_reschedule_hold(
  '98600000-0000-0000-0000-000000000040',
  timestamp with time zone '2035-01-29 18:00:00-03',now(),'CLIENT',null
) data;
select is((select (data->>'difference_due')::numeric(12,2) from day_to_night),96.00::numeric(12,2),'daytime to night reschedule creates R$96 difference due');

create temporary table night_to_day as
select public.service_admin_create_reschedule_hold(
  '98600000-0000-0000-0000-000000000041',
  timestamp with time zone '2035-02-12 10:00:00-03',now(),'CLIENT',null
) data;
select is((select (data->>'excess_amount')::numeric(12,2) from night_to_day),96.00::numeric(12,2),'night to daytime reschedule creates R$96 returnable excess');

select * from finish();
rollback;
