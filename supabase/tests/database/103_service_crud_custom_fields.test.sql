begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(18);

select has_function('public','service_admin_create_service_audited',array['text','text','text','text','text','text','integer','numeric','integer','integer','uuid'],'legacy audited service create RPC remains available');
select has_function('public','service_admin_replace_custom_fields_audited',array['uuid','jsonb','uuid'],'audited custom field replacement RPC exists');
select has_function('public','service_admin_list_categories',array[]::text[],'category list RPC exists');
select has_function('public','service_admin_list_extras',array[]::text[],'extra list RPC exists');
select has_function('public','service_admin_create_service_catalog_audited',array['uuid','text','text','text','text','text','text','integer','numeric','integer','integer','integer','integer','numeric','uuid'],'complete catalog service create RPC exists');
select has_function('public','service_admin_replace_day_time_pricing_audited',array['uuid','jsonb','uuid'],'day/time pricing editor RPC exists');
select has_function('public','service_admin_replace_service_extras_audited',array['uuid','jsonb','uuid'],'service extra mapping RPC exists');

select ok(not has_function_privilege('authenticated','public.service_admin_create_service_catalog_audited(uuid,text,text,text,text,text,text,integer,numeric,integer,integer,integer,integer,numeric,uuid)','EXECUTE'),'browser cannot create catalog service directly');
select ok(not has_function_privilege('authenticated','public.service_admin_replace_custom_fields_audited(uuid,jsonb,uuid)','EXECUTE'),'browser cannot replace service fields directly');
select ok(has_function_privilege('service_role','public.service_admin_create_service_catalog_audited(uuid,text,text,text,text,text,text,integer,numeric,integer,integer,integer,integer,numeric,uuid)','EXECUTE'),'service role can call catalog create after edge authorization');

insert into public.categories(id,name,slug,operation_scope,sort_order)
values ('33333333-3333-4333-8333-333333333330','Gestante Teste','gestante-teste','SABRINA',10);

insert into public.services(id,category_id,name,slug,base_duration_minutes,base_price,operation_scope,minimum_people,maximum_people,price_per_extra_person)
values ('33333333-3333-4333-8333-333333333333','33333333-3333-4333-8333-333333333330','Custom Fields Test','custom-fields-test',60,100,'SABRINA',1,5,25);

insert into public.service_fields(service_id,field_key,label,field_type,options_json,is_required,sort_order)
values ('33333333-3333-4333-8333-333333333333','acompanhantes','Acompanhantes','MULTISELECT','["Parceiro(a)","Filhos","Avós"]'::jsonb,true,10);

insert into public.extras(id,name,description,price,duration_delta_minutes)
values ('33333333-3333-4333-8333-333333333334','Make teste','Descrição pública',50,30);
insert into public.service_extras(service_id,extra_id,sort_order,max_quantity,schedule_placement,default_schedule_minutes)
values ('33333333-3333-4333-8333-333333333333','33333333-3333-4333-8333-333333333334',10,1,'PREPEND',30);

insert into public.pricing_rules(service_id,name,rule_scope,days_of_week,start_local_time,end_local_time,action_type,amount,priority)
values ('33333333-3333-4333-8333-333333333333','Sábado manhã','DAY_TIME',array[6]::smallint[],'09:00','12:00','ADD_AMOUNT',30,10);

select is((select field_type from public.service_fields where service_id='33333333-3333-4333-8333-333333333333'),'MULTISELECT','custom fields accept multi-select');
select is((select operation_scope from public.categories where id='33333333-3333-4333-8333-333333333330'),'SABRINA','category belongs to operation');
select is((select price_per_extra_person from public.services where id='33333333-3333-4333-8333-333333333333'),25::numeric,'service stores simple extra-person price');
select throws_ok(
  $$ update public.services set operation_scope='BLACKSHEEP' where id='33333333-3333-4333-8333-333333333333' $$,
  'P0001','SERVICE_CATEGORY_OPERATION_MISMATCH','service cannot cross operation while linked to Sabrina category'
);
select ok(exists(select 1 from jsonb_array_elements(public.service_admin_list_service_settings()) item where item->>'id'='33333333-3333-4333-8333-333333333333' and item->>'category_name'='Gestante Teste' and (item->>'price_per_extra_person')::numeric=25 and jsonb_array_length(item->'custom_fields')=1 and jsonb_array_length(item->'service_extras')=1 and jsonb_array_length(item->'day_time_pricing_rules')=1),'service list exposes category, people pricing, fields, extras and day/time rules');
select ok(exists(select 1 from jsonb_array_elements(public.service_admin_list_categories()) item where item->>'id'='33333333-3333-4333-8333-333333333330'),'category list exposes test category');
select ok(exists(select 1 from jsonb_array_elements(public.service_admin_list_extras()) item where item->>'id'='33333333-3333-4333-8333-333333333334'),'extra list exposes reusable extra');
select ok((select schedule_placement='PREPEND' from public.service_extras where service_id='33333333-3333-4333-8333-333333333333' and extra_id='33333333-3333-4333-8333-333333333334'),'extra can extend before core service');

select * from finish();
rollback;
