begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(10);

select has_function('public','resolve_notification_template',array['text','text','text','uuid'],'runtime resolver exists');
select ok(not has_function_privilege('anon','public.resolve_notification_template(text,text,text,uuid)','EXECUTE'),'anon cannot resolve templates');
select ok(not has_function_privilege('authenticated','public.resolve_notification_template(text,text,text,uuid)','EXECUTE'),'authenticated cannot resolve templates');
select ok(has_function_privilege('service_role','public.resolve_notification_template(text,text,text,uuid)','EXECUTE'),'service role can resolve templates');

insert into public.categories(id,name,slug,operation_scope,is_active)
values ('98100000-0000-0000-0000-000000000001','Runtime Category','runtime-category','BLACKSHEEP',true);
insert into public.services(id,category_id,name,slug,base_duration_minutes,base_price,is_active,operation_scope)
values
 ('98100000-0000-0000-0000-000000000010','98100000-0000-0000-0000-000000000001','Runtime Service A','runtime-service-a',60,100,false,'BLACKSHEEP'),
 ('98100000-0000-0000-0000-000000000011','98100000-0000-0000-0000-000000000001','Runtime Service B','runtime-service-b',60,100,false,'BLACKSHEEP');

insert into public.notification_template_configs(id,event_key,channel,audience,title_template,is_active)
values ('98100000-0000-0000-0000-000000000100','APPOINTMENT_PENDING','EMAIL','CUSTOMER','GLOBAL',true);
select is((select title_template from public.resolve_notification_template('APPOINTMENT_PENDING','EMAIL','CUSTOMER','98100000-0000-0000-0000-000000000010')),'GLOBAL','global template resolves');

insert into public.notification_template_configs(id,event_key,channel,audience,operation_scope,title_template,is_active)
values ('98100000-0000-0000-0000-000000000101','APPOINTMENT_PENDING','EMAIL','CUSTOMER','BLACKSHEEP','OPERATION',true);
select is((select title_template from public.resolve_notification_template('APPOINTMENT_PENDING','EMAIL','CUSTOMER','98100000-0000-0000-0000-000000000010')),'OPERATION','operation beats global');

insert into public.notification_template_configs(id,event_key,channel,audience,operation_scope,category_id,title_template,is_active)
values ('98100000-0000-0000-0000-000000000102','APPOINTMENT_PENDING','EMAIL','CUSTOMER','BLACKSHEEP','98100000-0000-0000-0000-000000000001','CATEGORY',true);
select is((select title_template from public.resolve_notification_template('APPOINTMENT_PENDING','EMAIL','CUSTOMER','98100000-0000-0000-0000-000000000010')),'CATEGORY','category beats operation');

insert into public.notification_template_configs(id,event_key,channel,audience,operation_scope,title_template,is_active)
values ('98100000-0000-0000-0000-000000000103','APPOINTMENT_PENDING','EMAIL','CUSTOMER','BLACKSHEEP','SERVICE',true);
insert into public.notification_template_services(template_id,service_id)
values ('98100000-0000-0000-0000-000000000103','98100000-0000-0000-0000-000000000010');
select is((select title_template from public.resolve_notification_template('APPOINTMENT_PENDING','EMAIL','CUSTOMER','98100000-0000-0000-0000-000000000010')),'SERVICE','service beats category');
select is((select title_template from public.resolve_notification_template('APPOINTMENT_PENDING','EMAIL','CUSTOMER','98100000-0000-0000-0000-000000000011')),'CATEGORY','service-scoped template does not leak to sibling service');

update public.notification_template_configs set is_active=false where id='98100000-0000-0000-0000-000000000102';
select is((select title_template from public.resolve_notification_template('APPOINTMENT_PENDING','EMAIL','CUSTOMER','98100000-0000-0000-0000-000000000011')),'OPERATION','inactive category template is ignored');

select * from finish();
rollback;
