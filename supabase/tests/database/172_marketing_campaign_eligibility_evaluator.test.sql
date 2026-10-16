begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(36);

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
select has_function('public','service_issue_marketing_campaign_coupon',array['uuid','uuid','text'],'S4 coupon issuance action exists');
select ok(
  not has_function_privilege('anon','public.service_evaluate_marketing_campaign_eligibility(uuid,uuid)','EXECUTE')
  and not has_function_privilege('authenticated','public.service_evaluate_marketing_campaign_eligibility(uuid,uuid)','EXECUTE')
  and has_function_privilege('service_role','public.service_evaluate_marketing_campaign_eligibility(uuid,uuid)','EXECUTE'),
  'S3 evaluator remains private to the trusted backend'
);
select ok(
  not has_function_privilege('anon','public.service_issue_marketing_campaign_coupon(uuid,uuid,text)','EXECUTE')
  and not has_function_privilege('authenticated','public.service_issue_marketing_campaign_coupon(uuid,uuid,text)','EXECUTE')
  and has_function_privilege('service_role','public.service_issue_marketing_campaign_coupon(uuid,uuid,text)','EXECUTE'),
  'S4 issuance remains private to the trusted backend'
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

select set_config('agenda.s4.issued', public.service_issue_marketing_campaign_coupon(
  (current_setting('agenda.s3.created')::jsonb->>'campaign_id')::uuid,
  '17200000-0000-4000-8000-000000000020',
  'rewards-s4-eligible-source-0001'
)::text, true);
select is(
  (current_setting('agenda.s4.issued')::jsonb->>'replayed')::boolean,
  false,'first S4 issuance is not a replay'
);
select is(
  (select jsonb_build_object(
    'discount_type', c.discount_type,
    'discount_value', c.discount_value,
    'discount_scope', c.discount_scope,
    'validity_basis', c.validity_basis,
    'source', c.source,
    'customer_id', c.customer_id,
    'source_appointment_id', c.source_appointment_id,
    'max_uses', c.max_uses,
    'max_uses_per_customer', c.max_uses_per_customer,
    'used_count', c.used_count
  ) from public.coupons c where c.id=(current_setting('agenda.s4.issued')::jsonb->>'coupon_id')::uuid),
  jsonb_build_object(
    'discount_type','PERCENT','discount_value',20,'discount_scope','SERVICE_ONLY','validity_basis','BOOKING_CONFIRMATION',
    'source','PROMOTION','customer_id','17200000-0000-4000-8000-000000000017'::uuid,
    'source_appointment_id','17200000-0000-4000-8000-000000000020'::uuid,
    'max_uses',1,'max_uses_per_customer',1,'used_count',0
  ),'S4 coupon snapshots the published offer and eligible customer'
);
select ok(
  (select c.valid_from <= now()
    and c.valid_until > now() + interval '29 days'
    and c.valid_until <= now() + interval '30 days' + interval '2 seconds'
   from public.coupons c
   where c.id=(current_setting('agenda.s4.issued')::jsonb->>'coupon_id')::uuid),
  'S4 coupon validity is derived from the published version'
);
select ok(
  public.coupon_is_valid_for_booking(
    (select c from public.coupons c where c.id=(current_setting('agenda.s4.issued')::jsonb->>'coupon_id')::uuid),
    now() + interval '31 days'
  ),
  'S5 accepts a Rewards coupon for a rental after its window when confirmation is still in-window'
);
update public.coupons
set valid_from=now()-interval '1 day', valid_until=now()+interval '1 day'
where id='17200000-0000-4000-8000-000000000040';
select ok(
  not public.coupon_is_valid_for_booking(
    (select c from public.coupons c where c.id='17200000-0000-4000-8000-000000000040'),
    now() + interval '2 days'
  ),
  'S5 preserves rental-start validity for a legacy coupon'
);
select is(
  (select count(*)::integer from public.coupon_services where coupon_id=(current_setting('agenda.s4.issued')::jsonb->>'coupon_id')::uuid),
  1,'S4 coupon receives exactly the checkbox-selected service scope'
);
select is(
  (select service_id from public.coupon_services where coupon_id=(current_setting('agenda.s4.issued')::jsonb->>'coupon_id')::uuid),
  '17200000-0000-4000-8000-000000000013'::uuid,'S4 coupon service scope matches the checkbox selection'
);
select is(
  (select count(*)::integer from public.marketing_campaign_issuances where source_appointment_id='17200000-0000-4000-8000-000000000020'),
  1,'S4 links exactly one issuance to the source rental'
);
select is(
  (select event_kind from public.marketing_campaign_audit_events
   where campaign_id=(current_setting('agenda.s3.created')::jsonb->>'campaign_id')::uuid
     and after_snapshot->>'coupon_id'=(current_setting('agenda.s4.issued')::jsonb->>'coupon_id')),
  'ISSUANCE_LINKED','S4 records the immutable issuance audit event'
);
select is(
  (select actor_admin_id from public.marketing_campaign_audit_events
   where campaign_id=(current_setting('agenda.s3.created')::jsonb->>'campaign_id')::uuid
     and after_snapshot->>'coupon_id'=(current_setting('agenda.s4.issued')::jsonb->>'coupon_id')),
  '17200000-0000-4000-8000-000000000002'::uuid,'S4 audit attributes issuance to the publisher who authorized the active version'
);
insert into public.appointment_discounts(
  appointment_id,coupon_id,code_snapshot,discount_type_snapshot,discount_value_snapshot,calculated_discount_amount
) values (
  '17200000-0000-4000-8000-000000000022',
  (current_setting('agenda.s4.issued')::jsonb->>'coupon_id')::uuid,
  (current_setting('agenda.s4.issued')::jsonb->>'coupon_code'),
  'PERCENT',20,20
);
update public.coupons
set valid_until=now()-interval '1 second'
where id=(current_setting('agenda.s4.issued')::jsonb->>'coupon_id')::uuid;
select throws_ok(
  $$update public.appointments set status='CONFIRMED' where id='17200000-0000-4000-8000-000000000022'$$,
  'P0001','MARKETING_CAMPAIGN_COUPON_EXPIRED_AT_CONFIRMATION',
  'S5 blocks confirmation when the Rewards window expired after checkout'
);
select is(
  (select status from public.appointments where id='17200000-0000-4000-8000-000000000022'),
  'AWAITING_PAYMENT','S5 expiration rejection leaves the appointment unconfirmed'
);
select is(
  (public.service_issue_marketing_campaign_coupon(
    (current_setting('agenda.s3.created')::jsonb->>'campaign_id')::uuid,
    '17200000-0000-4000-8000-000000000020',
    'rewards-s4-eligible-source-0001'
  )->>'coupon_id')::uuid,
  (current_setting('agenda.s4.issued')::jsonb->>'coupon_id')::uuid,
  'same S4 idempotency key returns the original coupon'
);
select is(
  (public.service_issue_marketing_campaign_coupon(
    (current_setting('agenda.s3.created')::jsonb->>'campaign_id')::uuid,
    '17200000-0000-4000-8000-000000000020',
    'rewards-s4-eligible-source-0001'
  )->>'replayed')::boolean,
  true,'same S4 idempotency key is replay-safe'
);
select throws_ok(
  $$select public.service_issue_marketing_campaign_coupon((current_setting('agenda.s3.created')::jsonb->>'campaign_id')::uuid,'17200000-0000-4000-8000-000000000021','rewards-s4-unpaid-source-00001')$$,
  'P0001','MARKETING_CAMPAIGN_ISSUANCE_INELIGIBLE','S4 cannot issue from an unpaid rental'
);
select is(
  (select count(*)::integer from public.marketing_campaign_issuances where campaign_id=(current_setting('agenda.s3.created')::jsonb->>'campaign_id')::uuid),
  1,'failed S4 issuance does not create a ledger row'
);
select is(
  public.service_evaluate_marketing_campaign_eligibility((current_setting('agenda.s3.created')::jsonb->>'campaign_id')::uuid,'17200000-0000-4000-8000-000000000020')->>'reason_code',
  'MARKETING_CAMPAIGN_SOURCE_ALREADY_ISSUED','issued source cannot receive a second Reward'
);

update public.services set operation_scope='BLACKSHEEP' where id='17200000-0000-4000-8000-000000000013';

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
