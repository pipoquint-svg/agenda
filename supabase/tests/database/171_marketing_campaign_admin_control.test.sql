begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(31);

select has_function('public','service_admin_create_marketing_campaign',array['uuid','text','text','text','text','jsonb','uuid','uuid'],'S2 create campaign action exists');
select has_function('public','service_admin_create_marketing_campaign_version',array['uuid','jsonb','uuid','uuid'],'S2 append version action exists');
select has_function('public','service_admin_transition_marketing_campaign',array['uuid','text','uuid','text','uuid','uuid'],'S2 transition action exists');
select ok(
  not has_function_privilege('anon','public.service_admin_create_marketing_campaign(uuid,text,text,text,text,jsonb,uuid,uuid)','EXECUTE')
  and not has_function_privilege('authenticated','public.service_admin_transition_marketing_campaign(uuid,text,uuid,text,uuid,uuid)','EXECUTE')
  and has_function_privilege('service_role','public.service_admin_create_marketing_campaign(uuid,text,text,text,text,jsonb,uuid,uuid)','EXECUTE'),
  'S2 mutations remain private to the trusted backend'
);
select ok(
  not has_table_privilege('service_role','public.marketing_campaigns','INSERT')
  and not has_table_privilege('service_role','public.marketing_campaign_versions','UPDATE')
  and not has_table_privilege('service_role','public.marketing_campaign_audit_events','INSERT'),
  'S2 retains no direct table-write bypass around the audited actions'
);

insert into auth.users(id,email,created_at,updated_at) values
  ('17100000-0000-4000-8000-000000000001','rewards-owner@example.test',now(),now()),
  ('17100000-0000-4000-8000-000000000002','rewards-admin@example.test',now(),now()),
  ('17100000-0000-4000-8000-000000000003','rewards-operation@example.test',now(),now());
insert into public.admin_users(id,auth_user_id,display_name,role,is_active) values
  ('17100000-0000-4000-8000-000000000011','17100000-0000-4000-8000-000000000001','Rewards Owner','OWNER',true),
  ('17100000-0000-4000-8000-000000000012','17100000-0000-4000-8000-000000000002','Rewards Admin','ADMIN',true),
  ('17100000-0000-4000-8000-000000000013','17100000-0000-4000-8000-000000000003','Rewards Operation','OPERATION',true);
insert into public.tenants(id,name,slug,status)
values ('17100000-0000-4000-8000-000000000020','Rewards S2','rewards-s2','ACTIVE');

select set_config('agenda.rewards_offer', jsonb_build_object(
  'trigger_kind','RENTAL_COMPLETED_FINANCIALLY_CLEARED','discount_type','PERCENT','discount_value',20,
  'discount_scope','SERVICE_ONLY','validity_basis','BOOKING_CONFIRMATION','validity_days',30,
  'max_uses',1,'max_uses_per_customer',1,'applies_to_extras',false,'applies_to_hour_packages',false,
  'stacking_policy','EXCLUSIVE'
)::text, true);
select set_config('agenda.rewards_create', public.service_admin_create_marketing_campaign(
  '17100000-0000-4000-8000-000000000020','volte-sempre-s2','Volte Sempre S2','Volte Sempre','S2 test',
  current_setting('agenda.rewards_offer')::jsonb,'17100000-0000-4000-8000-000000000011','17100000-0000-4000-8000-000000000101'
)::text, true);

select is((current_setting('agenda.rewards_create')::jsonb->>'replayed')::boolean,false,'first campaign create is not a replay');
select is((select state from public.marketing_campaigns where id=(current_setting('agenda.rewards_create')::jsonb->>'campaign_id')::uuid),'DRAFT','new campaign is inert');
select ok((select active_version_id is null from public.marketing_campaigns where id=(current_setting('agenda.rewards_create')::jsonb->>'campaign_id')::uuid),'draft has no active version pointer');
select is((select publication_status from public.marketing_campaign_versions where id=(current_setting('agenda.rewards_create')::jsonb->>'version_id')::uuid),'DRAFT','initial offer is not published implicitly');
select is((select count(*)::integer from public.marketing_campaign_audit_events where campaign_id=(current_setting('agenda.rewards_create')::jsonb->>'campaign_id')::uuid),2,'create records campaign and version audit events atomically');
select is((select actor_admin_id from public.marketing_campaign_audit_events where request_id='17100000-0000-4000-8000-000000000101'),'17100000-0000-4000-8000-000000000011'::uuid,'create audit keeps immutable admin actor');
select is((public.service_admin_create_marketing_campaign(
  '17100000-0000-4000-8000-000000000020','ignored-on-retry','Ignored','Ignored',null,current_setting('agenda.rewards_offer')::jsonb,
  '17100000-0000-4000-8000-000000000011','17100000-0000-4000-8000-000000000101'
)->>'campaign_id')::uuid,(current_setting('agenda.rewards_create')::jsonb->>'campaign_id')::uuid,'same create request is replay-safe');
select is((select count(*)::integer from public.marketing_campaigns where tenant_id='17100000-0000-4000-8000-000000000020'),1,'create replay does not add a campaign');
select throws_ok($$select public.service_admin_create_marketing_campaign('17100000-0000-4000-8000-000000000020','operation-denied','Denied',null,null,current_setting('agenda.rewards_offer')::jsonb,'17100000-0000-4000-8000-000000000013','17100000-0000-4000-8000-000000000102')$$,'42501','MARKETING_CAMPAIGN_ADMIN_PERMISSION_DENIED','only OWNER and ADMIN can administer campaigns');
select throws_ok($$select public.service_admin_create_marketing_campaign('17100000-0000-4000-8000-000000000020','extras-denied','Denied',null,null,jsonb_set(current_setting('agenda.rewards_offer')::jsonb,'{applies_to_extras}','true'::jsonb),'17100000-0000-4000-8000-000000000011','17100000-0000-4000-8000-000000000103')$$,'22023','MARKETING_CAMPAIGN_REWARDS_POLICY_INVALID','S2 rejects rewards that include extras');
select throws_ok($$select public.service_admin_create_marketing_campaign('17100000-0000-4000-8000-000000000020','multi-use-denied','Denied',null,null,jsonb_set(current_setting('agenda.rewards_offer')::jsonb,'{max_uses}','2'::jsonb),'17100000-0000-4000-8000-000000000011','17100000-0000-4000-8000-000000000104')$$,'22023','MARKETING_CAMPAIGN_REWARDS_POLICY_INVALID','S2 rejects multi-use rewards');

select throws_ok($$select public.service_admin_transition_marketing_campaign((current_setting('agenda.rewards_create')::jsonb->>'campaign_id')::uuid,'ACTIVE',null,null,'17100000-0000-4000-8000-000000000011','17100000-0000-4000-8000-000000000105')$$,'22023','MARKETING_CAMPAIGN_PUBLISHED_VERSION_REQUIRED','campaign cannot activate without an explicit published version');
select set_config('agenda.rewards_active', public.service_admin_transition_marketing_campaign(
  (current_setting('agenda.rewards_create')::jsonb->>'campaign_id')::uuid,'ACTIVE',(current_setting('agenda.rewards_create')::jsonb->>'version_id')::uuid,'ready',
  '17100000-0000-4000-8000-000000000011','17100000-0000-4000-8000-000000000106'
)::text,true);
select is((select state from public.marketing_campaigns where id=(current_setting('agenda.rewards_create')::jsonb->>'campaign_id')::uuid),'ACTIVE','explicit transition activates the campaign');
select is((select active_version_id from public.marketing_campaigns where id=(current_setting('agenda.rewards_create')::jsonb->>'campaign_id')::uuid),(current_setting('agenda.rewards_create')::jsonb->>'version_id')::uuid,'active campaign points to its published version');
select is((select publication_status from public.marketing_campaign_versions where id=(current_setting('agenda.rewards_create')::jsonb->>'version_id')::uuid),'PUBLISHED','activation publishes the chosen version');
select is((select event_kind from public.marketing_campaign_audit_events where request_id='17100000-0000-4000-8000-000000000106'),'ACTIVATED','activation is audited');
select is((public.service_admin_transition_marketing_campaign(
  (current_setting('agenda.rewards_create')::jsonb->>'campaign_id')::uuid,'ACTIVE',(current_setting('agenda.rewards_create')::jsonb->>'version_id')::uuid,'retry',
  '17100000-0000-4000-8000-000000000011','17100000-0000-4000-8000-000000000106'
)->>'replayed')::boolean,true,'same transition request is replay-safe');
select throws_ok($$select public.service_admin_transition_marketing_campaign((current_setting('agenda.rewards_create')::jsonb->>'campaign_id')::uuid,'SCHEDULED',null,null,'17100000-0000-4000-8000-000000000011','17100000-0000-4000-8000-000000000107')$$,'22023','MARKETING_CAMPAIGN_STATE_TRANSITION_INVALID','active campaign cannot move backwards to scheduled');

select set_config('agenda.rewards_version_2', public.service_admin_create_marketing_campaign_version(
  (current_setting('agenda.rewards_create')::jsonb->>'campaign_id')::uuid,
  jsonb_set(current_setting('agenda.rewards_offer')::jsonb,'{discount_value}','15'::jsonb),
  '17100000-0000-4000-8000-000000000012','17100000-0000-4000-8000-000000000108'
)::text,true);
select is((select version_number from public.marketing_campaign_versions where id=(current_setting('agenda.rewards_version_2')::jsonb->>'version_id')::uuid),2,'edits create a new immutable version');
select is((select publication_status from public.marketing_campaign_versions where id=(current_setting('agenda.rewards_version_2')::jsonb->>'version_id')::uuid),'DRAFT','new version does not become active implicitly');
select set_config('agenda.rewards_pause', public.service_admin_transition_marketing_campaign(
  (current_setting('agenda.rewards_create')::jsonb->>'campaign_id')::uuid,'PAUSED',null,'review',
  '17100000-0000-4000-8000-000000000012','17100000-0000-4000-8000-000000000109'
)::text,true);
select set_config('agenda.rewards_resume', public.service_admin_transition_marketing_campaign(
  (current_setting('agenda.rewards_create')::jsonb->>'campaign_id')::uuid,'ACTIVE',(current_setting('agenda.rewards_version_2')::jsonb->>'version_id')::uuid,'new terms',
  '17100000-0000-4000-8000-000000000012','17100000-0000-4000-8000-000000000110'
)::text,true);
select is((select active_version_id from public.marketing_campaigns where id=(current_setting('agenda.rewards_create')::jsonb->>'campaign_id')::uuid),(current_setting('agenda.rewards_version_2')::jsonb->>'version_id')::uuid,'audited transition changes the active-version pointer');
select is((select publication_status from public.marketing_campaign_versions where id=(current_setting('agenda.rewards_create')::jsonb->>'version_id')::uuid),'SUPERSEDED','replaced published version is superseded');
select is((select publication_status from public.marketing_campaign_versions where id=(current_setting('agenda.rewards_version_2')::jsonb->>'version_id')::uuid),'PUBLISHED','replacement version is published');
select ok((select count(*) = 1 from public.marketing_campaign_versions where campaign_id=(current_setting('agenda.rewards_create')::jsonb->>'campaign_id')::uuid and publication_status='PUBLISHED'),'campaign has exactly one published version');
select throws_ok($$delete from public.admin_users where id='17100000-0000-4000-8000-000000000012'$$,'23503',null,'audit actor cannot be deleted after an audited action');
select throws_ok($$select public.service_admin_create_marketing_campaign_version((current_setting('agenda.rewards_create')::jsonb->>'campaign_id')::uuid,jsonb_set(current_setting('agenda.rewards_offer')::jsonb,'{applies_to_hour_packages}','true'::jsonb),'17100000-0000-4000-8000-000000000012','17100000-0000-4000-8000-000000000111')$$,'22023','MARKETING_CAMPAIGN_REWARDS_POLICY_INVALID','S2 rejects hour-package eligibility');

select * from finish();
rollback;
