begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(18);

insert into auth.users(id,email,created_at,updated_at)
values ('17200000-0000-4000-8000-000000000001','rewards-s3-owner@example.test',now(),now());
insert into public.admin_users(id,auth_user_id,display_name,role,is_active)
values ('17200000-0000-4000-8000-000000000002','17200000-0000-4000-8000-000000000001','Rewards S3 Owner','OWNER',true);

insert into public.resources(id,name,resource_type)
values ('17200000-0000-4000-8000-000000000010','Rewards S3 studio','PHYSICAL');
insert into public.employees(id,name)
values ('17200000-0000-4000-8000-000000000011','Rewards S3 employee');
insert into public.categories(id,name,slug)
values ('17200000-0000-4000-8000-000000000012','Rewards S3 category','rewards-s3-category');
insert into public.services(
  id,category_id,name,slug,base_duration_minutes,base_price,
  buffer_before_minutes,buffer_after_minutes,minimum_people,maximum_people,
  minimum_booking_notice_minutes,maximum_booking_horizon_days,requires_terms,
  duration_mode,operation_scope,service_type_id
) values (
  '17200000-0000-4000-8000-000000000013','17200000-0000-4000-8000-000000000012','Rewards S3 rental','rewards-s3-rental',60,100,
  0,0,1,10,0,365,false,'FIXED','BLACKSHEEP',(select id from public.service_type where key='LOCACAO')
),(
  '17200000-0000-4000-8000-000000000014','17200000-0000-4000-8000-000000000012','Rewards S3 foreign','rewards-s3-foreign',60,100,
  0,0,1,10,0,365,false,'FIXED','SABRINA',(select id from public.service_type where key='LOCACAO')
);
insert into public.service_employees(id,service_id,employee_id) values
  ('17200000-0000-4000-8000-000000000015','17200000-0000-4000-8000-000000000013','17200000-0000-4000-8000-000000000011'),
  ('17200000-0000-4000-8000-000000000016','17200000-0000-4000-8000-000000000014','17200000-0000-4000-8000-000000000011');
insert into public.service_change_policies(
  service_id,notice_hours,reschedule_first_early_percent,reschedule_first_late_percent,
  reschedule_repeat_percent,cancellation_late_percent
) values
  ('17200000-0000-4000-8000-000000000013',48,0,20,30,30),
  ('17200000-0000-4000-8000-000000000014',48,0,20,30,30);
insert into public.customers(id,name,email,phone)
values ('17200000-0000-4000-8000-000000000017','Rewards S3 customer','rewards-s3@example.test','+5548999991720');
insert into public.appointments(
  id,public_code,service_id,service_employee_id,primary_customer_id,
  status,financial_status,start_at,end_at,duration_minutes,people_count,service_name_snapshot,commercial_value
) values
  ('17200000-0000-4000-8000-000000000020','REWARDS-S3-ELIGIBLE','17200000-0000-4000-8000-000000000013','17200000-0000-4000-8000-000000000015','17200000-0000-4000-8000-000000000017','COMPLETED','PAID',now()-interval '3 days',now()-interval '3 days'+interval '1 hour',60,1,'Rewards S3 rental',100),
  ('17200000-0000-4000-8000-000000000021','REWARDS-S3-UNPAID','17200000-0000-4000-8000-000000000013','17200000-0000-4000-8000-000000000015','17200000-0000-4000-8000-000000000017','COMPLETED','PARTIALLY_PAID',now()-interval '2 days',now()-interval '2 days'+interval '1 hour',60,1,'Rewards S3 rental',100),
  ('17200000-0000-4000-8000-000000000022','REWARDS-S3-PENDING','17200000-0000-4000-8000-000000000013','17200000-0000-4000-8000-000000000015','17200000-0000-4000-8000-000000000017','AWAITING_PAYMENT','PAID',now()-interval '1 day',now()-interval '1 day'+interval '1 hour',60,1,'Rewards S3 rental',100),
  ('17200000-0000-4000-8000-000000000023','REWARDS-S3-FOREIGN','17200000-0000-4000-8000-000000000014','17200000-0000-4000-8000-000000000016','17200000-0000-4000-8000-000000000017','COMPLETED','PAID',now()-interval '4 days',now()-interval '4 days'+interval '1 hour',60,1,'Rewards S3 foreign',100);

select set_config('agenda.s3.offer', jsonb_build_object(
  'trigger_kind','RENTAL_COMPLETED_FINANCIALLY_CLEARED','discount_type','PERCENT','discount_value',20,
  'discount_scope','SERVICE_ONLY','validity_basis','BOOKING_CONFIRMATION','validity_days',30,
  'max_uses',1,'max_uses_per_customer',1,'applies_to_extras',false,'applies_to_hour_packages',false,
  'stacking_policy','EXCLUSIVE','recurring_after_discounted_rental',false,
  'eligibility_rules',jsonb_build_object('service_ids',jsonb_build_array('17200000-0000-4000-8000-000000000013'))
)::text,true);
select set_config('agenda.s3.created', public.service_admin_create_marketing_campaign(
  '8fba3c57-c0e6-4a37-b7d3-4cf41e5fb65f','rewards-s3','Rewards S3',null,null,current_setting('agenda.s3.offer')::jsonb,
  '17200000-0000-4000-8000-000000000002','17200000-0000-4000-8000-000000000030'
)::text,true);
select set_config('agenda.s3.active', public.service_admin_transition_marketing_campaign(
  (current_setting('agenda.s3.created')::jsonb->>'campaign_id')::uuid,'ACTIVE',
  (current_setting('agenda.s3.created')::jsonb->>'version_id')::uuid,'S3 evaluator fixture',
  '17200000-0000-4000-8000-000000000002','17200000-0000-4000-8000-000000000031'
)::text,true);

select has_function('public','service_evaluate_marketing_campaign_eligibility',array['uuid','uuid'],'S3 evaluator exists');
select ok(
  not has_function_privilege('anon','public.service_evaluate_marketing_campaign_eligibility(uuid,uuid)','EXECUTE')
  and not has_function_privilege('authenticated','public.service_evaluate_marketing_campaign_eligibility(uuid,uuid)','EXECUTE')
  and has_function_privilege('service_role','public.service_evaluate_marketing_campaign_eligibility(uuid,uuid)','EXECUTE'),
  'S3 evaluator remains private to the trusted backend'
);
select is(
  public.service_evaluate_marketing_campaign_eligibility((current_setting('agenda.s3.created')::jsonb->>'campaign_id')::uuid,'17200000-0000-4000-8000-000000000020')->>'decision',
  'ELIGIBLE','completed and paid BlackSheep rental is eligible'
);
select is((select rewards_source_operation_scope_snapshot from public.appointments where id='17200000-0000-4000-8000-000000000020'),'BLACKSHEEP','source operation scope is captured on the appointment');
select is(
  public.service_evaluate_marketing_campaign_eligibility((current_setting('agenda.s3.created')::jsonb->>'campaign_id')::uuid,'17200000-0000-4000-8000-000000000020')->>'customer_id',
  '17200000-0000-4000-8000-000000000017','eligible response identifies the canonical customer for S4 without issuing'
);
select is((select count(*)::integer from public.marketing_campaign_issuances),0,'evaluation does not issue a coupon or write the issuance ledger');
select is(
  public.service_evaluate_marketing_campaign_eligibility((current_setting('agenda.s3.created')::jsonb->>'campaign_id')::uuid,'17200000-0000-4000-8000-000000000021')->>'reason_code',
  'MARKETING_CAMPAIGN_SOURCE_NOT_FINANCIALLY_CLEARED','partial payment is not financially cleared'
);
select is(
  public.service_evaluate_marketing_campaign_eligibility((current_setting('agenda.s3.created')::jsonb->>'campaign_id')::uuid,'17200000-0000-4000-8000-000000000022')->>'reason_code',
  'MARKETING_CAMPAIGN_SOURCE_NOT_COMPLETED','uncompleted rental is not eligible'
);
select is(
  public.service_evaluate_marketing_campaign_eligibility((current_setting('agenda.s3.created')::jsonb->>'campaign_id')::uuid,'17200000-0000-4000-8000-000000000023')->>'reason_code',
  'MARKETING_CAMPAIGN_SOURCE_NOT_BLACKSHEEP_RENTAL','other operational scope cannot satisfy the BlackSheep source bridge'
);
select throws_ok($$update public.appointments set rewards_source_operation_scope_snapshot='BLACKSHEEP', rewards_source_service_type_key_snapshot='LOCACAO' where id='17200000-0000-4000-8000-000000000023'$$,'P0001','MARKETING_CAMPAIGN_SOURCE_SNAPSHOT_IMMUTABLE','appointment update cannot forge source ownership snapshots');
select is(
  public.service_evaluate_marketing_campaign_eligibility((current_setting('agenda.s3.created')::jsonb->>'campaign_id')::uuid,'17200000-0000-4000-8000-000000000023')->>'reason_code',
  'MARKETING_CAMPAIGN_SOURCE_NOT_BLACKSHEEP_RENTAL','rejected snapshot spoofing preserves source ownership'
);
update public.services set operation_scope='BLACKSHEEP' where id='17200000-0000-4000-8000-000000000014';
update public.appointments set status=status where id='17200000-0000-4000-8000-000000000023';
select is(
  public.service_evaluate_marketing_campaign_eligibility((current_setting('agenda.s3.created')::jsonb->>'campaign_id')::uuid,'17200000-0000-4000-8000-000000000023')->>'reason_code',
  'MARKETING_CAMPAIGN_SOURCE_NOT_BLACKSHEEP_RENTAL','later catalog reclassification and unrelated appointment updates cannot rewrite history'
);

update public.marketing_campaigns
set starts_at=now()+interval '1 day'
where id=(current_setting('agenda.s3.created')::jsonb->>'campaign_id')::uuid;
select is(
  public.service_evaluate_marketing_campaign_eligibility((current_setting('agenda.s3.created')::jsonb->>'campaign_id')::uuid,'17200000-0000-4000-8000-000000000020')->>'reason_code',
  'MARKETING_CAMPAIGN_OUTSIDE_WINDOW','campaign start window is enforced'
);
update public.marketing_campaigns
set starts_at=null
where id=(current_setting('agenda.s3.created')::jsonb->>'campaign_id')::uuid;

insert into public.coupons(id,code,discount_type,discount_value,is_active,source,customer_id,max_uses,discount_scope)
values ('17200000-0000-4000-8000-000000000040','REWARDS-S3-OLD','PERCENT',10,true,'PROMOTION','17200000-0000-4000-8000-000000000017',1,'SERVICE_ONLY');
insert into public.appointment_discounts(appointment_id,coupon_id,code_snapshot,discount_type_snapshot,discount_value_snapshot,calculated_discount_amount)
values ('17200000-0000-4000-8000-000000000020','17200000-0000-4000-8000-000000000040','REWARDS-S3-OLD','PERCENT',10,10);
update public.appointment_discounts set coupon_id=null where appointment_id='17200000-0000-4000-8000-000000000020';
select is(
  public.service_evaluate_marketing_campaign_eligibility((current_setting('agenda.s3.created')::jsonb->>'campaign_id')::uuid,'17200000-0000-4000-8000-000000000020')->>'reason_code',
  'MARKETING_CAMPAIGN_RECURRING_DISCOUNTED_RENTAL_DISABLED','discounted rental cannot recur unless its published version permits it'
);
update public.marketing_campaign_versions
set recurring_after_discounted_rental=true
where id=(current_setting('agenda.s3.created')::jsonb->>'version_id')::uuid;
select is(
  public.service_evaluate_marketing_campaign_eligibility((current_setting('agenda.s3.created')::jsonb->>'campaign_id')::uuid,'17200000-0000-4000-8000-000000000020')->>'decision',
  'ELIGIBLE','published recurring policy permits a discounted completed rental'
);
update public.services set operation_scope='SABRINA' where id='17200000-0000-4000-8000-000000000013';
select is(
  public.service_evaluate_marketing_campaign_eligibility((current_setting('agenda.s3.created')::jsonb->>'campaign_id')::uuid,'17200000-0000-4000-8000-000000000020')->>'decision',
  'ELIGIBLE','later catalog reclassification cannot rewrite the rental source snapshot'
);

insert into public.marketing_campaign_issuances(tenant_id,campaign_id,campaign_version_id,coupon_id,customer_id,source_appointment_id,idempotency_key)
values ('8fba3c57-c0e6-4a37-b7d3-4cf41e5fb65f',(current_setting('agenda.s3.created')::jsonb->>'campaign_id')::uuid,(current_setting('agenda.s3.created')::jsonb->>'version_id')::uuid,'17200000-0000-4000-8000-000000000040','17200000-0000-4000-8000-000000000017','17200000-0000-4000-8000-000000000020','rewards-s3-existing-source');
select is(
  public.service_evaluate_marketing_campaign_eligibility((current_setting('agenda.s3.created')::jsonb->>'campaign_id')::uuid,'17200000-0000-4000-8000-000000000020')->>'reason_code',
  'MARKETING_CAMPAIGN_SOURCE_ALREADY_ISSUED','existing source issuance blocks a second Reward before S4'
);

insert into public.tenants(id,name,slug,status)
values ('17200000-0000-4000-8000-000000000050','Rewards S3 unmapped','rewards-s3-unmapped','ACTIVE');
select set_config('agenda.s3.unmapped', public.service_admin_create_marketing_campaign(
  '17200000-0000-4000-8000-000000000050','rewards-s3-unmapped','Rewards S3 unmapped',null,null,current_setting('agenda.s3.offer')::jsonb,
  '17200000-0000-4000-8000-000000000002','17200000-0000-4000-8000-000000000051'
)::text,true);
select set_config('agenda.s3.unmapped_active', public.service_admin_transition_marketing_campaign(
  (current_setting('agenda.s3.unmapped')::jsonb->>'campaign_id')::uuid,'ACTIVE',
  (current_setting('agenda.s3.unmapped')::jsonb->>'version_id')::uuid,'S3 unmapped fixture',
  '17200000-0000-4000-8000-000000000002','17200000-0000-4000-8000-000000000052'
)::text,true);
select is(
  public.service_evaluate_marketing_campaign_eligibility((current_setting('agenda.s3.unmapped')::jsonb->>'campaign_id')::uuid,'17200000-0000-4000-8000-000000000020')->>'reason_code',
  'MARKETING_CAMPAIGN_SOURCE_TENANT_UNMAPPED','legacy appointment cannot cross an unmapped tenant boundary'
);

select * from finish();
rollback;
