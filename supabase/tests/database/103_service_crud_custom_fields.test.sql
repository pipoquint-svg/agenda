begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(12);

select has_function('public','service_admin_create_service_audited',array['text','text','text','text','text','text','integer','numeric','integer','integer','uuid'],'audited service create RPC exists');
select has_function('public','service_admin_update_catalog_audited',array['uuid','text','text','text','text','text','boolean','integer','uuid'],'audited service catalog update RPC exists');
select has_function('public','service_admin_remove_service_audited',array['uuid','uuid'],'audited service removal RPC exists');
select has_function('public','service_admin_replace_custom_fields_audited',array['uuid','jsonb','uuid'],'audited custom field replacement RPC exists');

select ok(not has_function_privilege('authenticated','public.service_admin_create_service_audited(text,text,text,text,text,text,integer,numeric,integer,integer,uuid)','EXECUTE'),'browser cannot create service directly');
select ok(not has_function_privilege('authenticated','public.service_admin_replace_custom_fields_audited(uuid,jsonb,uuid)','EXECUTE'),'browser cannot replace service fields directly');
select ok(has_function_privilege('service_role','public.service_admin_create_service_audited(text,text,text,text,text,text,integer,numeric,integer,integer,uuid)','EXECUTE'),'service role can call create after edge authorization');
select ok(has_function_privilege('service_role','public.service_admin_replace_custom_fields_audited(uuid,jsonb,uuid)','EXECUTE'),'service role can call custom fields after edge authorization');

insert into public.services(id,name,slug,base_duration_minutes,base_price,operation_scope)
values ('33333333-3333-4333-8333-333333333333','Custom Fields Test','custom-fields-test',60,0,'SABRINA');

insert into public.service_fields(service_id,field_key,label,field_type,options_json,is_required,sort_order)
values ('33333333-3333-4333-8333-333333333333','acompanhantes','Acompanhantes','MULTISELECT','["Parceiro(a)","Filhos","Avós"]'::jsonb,true,10);

select is((select field_type from public.service_fields where service_id='33333333-3333-4333-8333-333333333333'),'MULTISELECT','custom fields accept multi-select');

select ok((public.service_admin_list_service_settings() #> '{0}') is not null,'admin service list returns service objects');
select ok(exists(select 1 from jsonb_array_elements(public.service_admin_list_service_settings()) item where item->>'id'='33333333-3333-4333-8333-333333333333' and item->>'operation_scope'='SABRINA' and jsonb_array_length(item->'custom_fields')=1),'service list includes operation and its custom fields');
select ok(not exists(select 1 from jsonb_array_elements(public.service_admin_list_service_settings()) item where item ? 'category'),'admin service contract no longer exposes category');

select * from finish();
rollback;
