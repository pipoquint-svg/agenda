begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(31);

select has_function('public','service_admin_update_marketing_campaign',array['uuid','uuid','text','text','text','jsonb','uuid','uuid'],'update action exists');
select has_function('public','service_admin_delete_marketing_campaign',array['uuid','uuid','uuid','uuid'],'delete action exists');
select ok(
  not has_function_privilege('anon','public.service_admin_update_marketing_campaign(uuid,uuid,text,text,text,jsonb,uuid,uuid)','EXECUTE')
  and not has_function_privilege('authenticated','public.service_admin_delete_marketing_campaign(uuid,uuid,uuid,uuid)','EXECUTE')
  and has_function_privilege('service_role','public.service_admin_delete_marketing_campaign(uuid,uuid,uuid,uuid)','EXECUTE'),
  'edit and delete stay private to the trusted backend'
);

insert into auth.users(id,email,created_at,updated_at) values
  ('18000000-0000-4000-8000-000000000001','edit-owner@example.test',now(),now()),
  ('18000000-0000-4000-8000-000000000003','edit-operation@example.test',now(),now());
insert into public.admin_users(id,auth_user_id,display_name,role,is_active) values
  ('18000000-0000-4000-8000-000000000011','18000000-0000-4000-8000-000000000001','Edit Owner','OWNER',true),
  ('18000000-0000-4000-8000-000000000013','18000000-0000-4000-8000-000000000003','Edit Operation','OPERATION',true);
insert into public.tenants(id,name,slug,status) values
  ('18000000-0000-4000-8000-000000000020','Edit tenant','edit-tenant','ACTIVE'),
  ('18000000-0000-4000-8000-000000000030','Other tenant','edit-other-tenant','ACTIVE');
insert into public.categories(id,name,slug)
values ('18000000-0000-4000-8000-000000000021','Edit services','edit-services');
insert into public.services(id,category_id,name,slug,base_duration_minutes,base_price,minimum_people,maximum_people,operation_scope) values
  ('18000000-0000-4000-8000-000000000022','18000000-0000-4000-8000-000000000021','Edit service A','edit-service-a',60,100,1,10,'BLACKSHEEP'),
  ('18000000-0000-4000-8000-000000000023','18000000-0000-4000-8000-000000000021','Edit service B','edit-service-b',60,100,1,10,'BLACKSHEEP');

select set_config('agenda.offer', jsonb_build_object(
  'trigger_kind','RENTAL_COMPLETED_FINANCIALLY_CLEARED','discount_type','PERCENT','discount_value',20,
  'discount_scope','SERVICE_ONLY','validity_basis','BOOKING_CONFIRMATION','validity_days',30,
  'max_uses',1,'max_uses_per_customer',1,'applies_to_extras',false,'applies_to_hour_packages',false,
  'stacking_policy','EXCLUSIVE',
  'eligibility_rules',jsonb_build_object('service_ids',jsonb_build_array('18000000-0000-4000-8000-000000000022'))
)::text, true);
select set_config('agenda.offer2', jsonb_set(jsonb_set(current_setting('agenda.offer')::jsonb,'{discount_value}','35'::jsonb),
  '{eligibility_rules,service_ids}', jsonb_build_array('18000000-0000-4000-8000-000000000023'))::text, true);

-- Draft A: edited, then deleted. Draft B: published, then "deleted" (archived).
select set_config('agenda.a', (public.service_admin_create_marketing_campaign(
  '18000000-0000-4000-8000-000000000020','edit-a','Edit A',null,null,current_setting('agenda.offer')::jsonb,
  '18000000-0000-4000-8000-000000000011','18000000-0000-4000-8000-000000000101')->>'campaign_id'), true);
select set_config('agenda.b', public.service_admin_create_marketing_campaign(
  '18000000-0000-4000-8000-000000000020','edit-b','Edit B',null,null,current_setting('agenda.offer')::jsonb,
  '18000000-0000-4000-8000-000000000011','18000000-0000-4000-8000-000000000102')::text, true);

-- Names only.
select is((public.service_admin_update_marketing_campaign(
  '18000000-0000-4000-8000-000000000020',current_setting('agenda.a')::uuid,'  Edit A renamed ','Volte já','nova descrição',null,
  '18000000-0000-4000-8000-000000000011','18000000-0000-4000-8000-000000000201')->>'version_id'),null,'renaming creates no version');
select is((select internal_name||'|'||public_name||'|'||description from public.marketing_campaigns where id=current_setting('agenda.a')::uuid),
  'Edit A renamed|Volte já|nova descrição','names and description are saved trimmed');
select is((select count(*)::integer from public.marketing_campaign_versions where campaign_id=current_setting('agenda.a')::uuid),1,'the offer is unchanged');
select is((select count(*)::integer from public.marketing_campaign_audit_events where campaign_id=current_setting('agenda.a')::uuid and event_kind='UPDATED'),1,'the edit is audited');

-- New offer.
select set_config('agenda.edit', public.service_admin_update_marketing_campaign(
  '18000000-0000-4000-8000-000000000020',current_setting('agenda.a')::uuid,'Edit A renamed','Volte já',null,current_setting('agenda.offer2')::jsonb,
  '18000000-0000-4000-8000-000000000011','18000000-0000-4000-8000-000000000202')::text, true);
select is((select version_number from public.marketing_campaign_versions where id=(current_setting('agenda.edit')::jsonb->>'version_id')::uuid),2,'a new offer becomes version 2');
select is((select discount_value from public.marketing_campaign_versions where id=(current_setting('agenda.edit')::jsonb->>'version_id')::uuid),35.00::numeric,'version 2 has the new discount');
select is((select service_id from public.marketing_campaign_version_services where campaign_version_id=(current_setting('agenda.edit')::jsonb->>'version_id')::uuid),'18000000-0000-4000-8000-000000000023'::uuid,'version 2 has the new services');
select is((select discount_value from public.marketing_campaign_versions where campaign_id=current_setting('agenda.a')::uuid and version_number=1),20.00::numeric,'version 1 stays as history');
select is((select description from public.marketing_campaigns where id=current_setting('agenda.a')::uuid),null,'an empty description clears it');
select is((public.service_admin_update_marketing_campaign(
  '18000000-0000-4000-8000-000000000020',current_setting('agenda.a')::uuid,'Ignored',null,null,current_setting('agenda.offer')::jsonb,
  '18000000-0000-4000-8000-000000000011','18000000-0000-4000-8000-000000000202')->>'replayed')::boolean,true,'the same edit request is a replay');
select is((select count(*)::integer from public.marketing_campaign_versions where campaign_id=current_setting('agenda.a')::uuid),2,'the replay adds no version');

select throws_ok($$select public.service_admin_update_marketing_campaign('18000000-0000-4000-8000-000000000030',current_setting('agenda.a')::uuid,'X',null,null,null,'18000000-0000-4000-8000-000000000011','18000000-0000-4000-8000-000000000203')$$,
  'P0001','MARKETING_CAMPAIGN_NOT_FOUND','another tenant cannot edit the campaign');
select throws_ok($$select public.service_admin_update_marketing_campaign('18000000-0000-4000-8000-000000000020',current_setting('agenda.a')::uuid,'  ',null,null,null,'18000000-0000-4000-8000-000000000011','18000000-0000-4000-8000-000000000204')$$,
  '22023','MARKETING_CAMPAIGN_IDENTITY_INVALID','the name is required');
select throws_ok($$select public.service_admin_update_marketing_campaign('18000000-0000-4000-8000-000000000020',current_setting('agenda.a')::uuid,'X',null,null,null,'18000000-0000-4000-8000-000000000013','18000000-0000-4000-8000-000000000205')$$,
  '42501','MARKETING_CAMPAIGN_ADMIN_PERMISSION_DENIED','only OWNER and ADMIN can edit');

-- Active campaign: names yes, offer no.
select public.service_admin_transition_marketing_campaign((current_setting('agenda.b')::jsonb->>'campaign_id')::uuid,'ACTIVE',
  (current_setting('agenda.b')::jsonb->>'version_id')::uuid,null,'18000000-0000-4000-8000-000000000011','18000000-0000-4000-8000-000000000103');
select throws_ok($$select public.service_admin_update_marketing_campaign('18000000-0000-4000-8000-000000000020',(current_setting('agenda.b')::jsonb->>'campaign_id')::uuid,'Edit B',null,null,current_setting('agenda.offer2')::jsonb,'18000000-0000-4000-8000-000000000011','18000000-0000-4000-8000-000000000206')$$,
  '22023','MARKETING_CAMPAIGN_PAUSE_TO_EDIT_OFFER','the offer of an active campaign needs a pause');
select lives_ok($$select public.service_admin_update_marketing_campaign('18000000-0000-4000-8000-000000000020',(current_setting('agenda.b')::jsonb->>'campaign_id')::uuid,'Edit B renamed',null,null,null,'18000000-0000-4000-8000-000000000011','18000000-0000-4000-8000-000000000207')$$,
  'an active campaign can be renamed');
select public.service_admin_transition_marketing_campaign((current_setting('agenda.b')::jsonb->>'campaign_id')::uuid,'PAUSED',null,null,'18000000-0000-4000-8000-000000000011','18000000-0000-4000-8000-000000000104');
select set_config('agenda.b2', public.service_admin_update_marketing_campaign('18000000-0000-4000-8000-000000000020',(current_setting('agenda.b')::jsonb->>'campaign_id')::uuid,'Edit B renamed',null,null,current_setting('agenda.offer2')::jsonb,'18000000-0000-4000-8000-000000000011','18000000-0000-4000-8000-000000000208')::text, true);
select is((select active_version_id from public.marketing_campaigns where id=(current_setting('agenda.b')::jsonb->>'campaign_id')::uuid),(current_setting('agenda.b')::jsonb->>'version_id')::uuid,'a paused campaign keeps its published version until resumed');
select is((select publication_status from public.marketing_campaign_versions where id=(current_setting('agenda.b2')::jsonb->>'version_id')::uuid),'DRAFT','its new offer waits as a draft');

-- Delete: published campaign is archived, never removed.
select is((public.service_admin_delete_marketing_campaign('18000000-0000-4000-8000-000000000020',(current_setting('agenda.b')::jsonb->>'campaign_id')::uuid,'18000000-0000-4000-8000-000000000011','18000000-0000-4000-8000-000000000301')->>'outcome'),'ARCHIVED','a campaign that was published is archived');
select is((select state from public.marketing_campaigns where id=(current_setting('agenda.b')::jsonb->>'campaign_id')::uuid),'ARCHIVED','its row and history remain');
select throws_ok($$select public.service_admin_update_marketing_campaign('18000000-0000-4000-8000-000000000020',(current_setting('agenda.b')::jsonb->>'campaign_id')::uuid,'X',null,null,null,'18000000-0000-4000-8000-000000000011','18000000-0000-4000-8000-000000000209')$$,
  '22023','MARKETING_CAMPAIGN_CLOSED','an archived campaign cannot be edited');

-- Delete: never-published draft is removed, with a snapshot in audit_logs.
select throws_ok($$select public.service_admin_delete_marketing_campaign('18000000-0000-4000-8000-000000000030',current_setting('agenda.a')::uuid,'18000000-0000-4000-8000-000000000011','18000000-0000-4000-8000-000000000302')$$,
  'P0001','MARKETING_CAMPAIGN_NOT_FOUND','another tenant cannot delete the campaign');
select is((public.service_admin_delete_marketing_campaign('18000000-0000-4000-8000-000000000020',current_setting('agenda.a')::uuid,'18000000-0000-4000-8000-000000000011','18000000-0000-4000-8000-000000000303')->>'outcome'),'DELETED','a never-published draft is deleted');
select ok(not exists(select 1 from public.marketing_campaigns where id=current_setting('agenda.a')::uuid)
  and not exists(select 1 from public.marketing_campaign_versions where campaign_id=current_setting('agenda.a')::uuid)
  and not exists(select 1 from public.marketing_campaign_audit_events where campaign_id=current_setting('agenda.a')::uuid),
  'its versions and campaign events are gone');
select is((select jsonb_array_length(before_json->'versions') from public.audit_logs where request_id='18000000-0000-4000-8000-000000000303'),2,'the deletion keeps a snapshot of both versions');
select is((public.service_admin_delete_marketing_campaign('18000000-0000-4000-8000-000000000020',current_setting('agenda.a')::uuid,'18000000-0000-4000-8000-000000000011','18000000-0000-4000-8000-000000000303')->>'replayed')::boolean,true,'the same delete request is a replay');

-- A draft with a saved Rewards message: the message draft goes with it.
select set_config('agenda.c', (public.service_admin_create_marketing_campaign(
  '18000000-0000-4000-8000-000000000020','edit-c','Edit C',null,null,current_setting('agenda.offer')::jsonb,
  '18000000-0000-4000-8000-000000000011','18000000-0000-4000-8000-000000000105')->>'campaign_id'), true);
select set_config('agenda.c_template', public.service_admin_upsert_rewards_message_template(
  '18000000-0000-4000-8000-000000000020',current_setting('agenda.c')::uuid,'REWARDS_WINBACK','Volte','Oi {{customer.name}}, volte!',
  '["customer.name"]'::jsonb,'18000000-0000-4000-8000-000000000011')::text, true);
select is((public.service_admin_delete_marketing_campaign('18000000-0000-4000-8000-000000000020',current_setting('agenda.c')::uuid,'18000000-0000-4000-8000-000000000011','18000000-0000-4000-8000-000000000304')->>'outcome'),'DELETED','a draft with a message draft is deleted');
select ok(not exists(select 1 from public.notification_template_configs where id=current_setting('agenda.c_template')::uuid),'its message draft is removed too');

select * from finish();
rollback;
