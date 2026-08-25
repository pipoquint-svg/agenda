begin;
create extension if not exists pgtap with schema extensions;
set local search_path=public,extensions;
select plan(13);

select col_type_is('public','employees','notes','text','employees can store internal notes');
select has_function('public','admin_list_employees',array[]::text[],'employee list RPC exists');
select has_function('public','admin_create_employee_audited',array['text','text','text','text','uuid'],'employee create RPC exists');
select has_function('public','admin_update_employee_audited',array['uuid','text','text','text','text','boolean','uuid'],'employee update RPC exists');
select has_function('public','admin_replace_employee_services_audited',array['uuid','uuid[]','uuid'],'service assignment RPC exists');
select has_function('public','admin_replace_work_hours_audited',array['uuid','jsonb','uuid'],'work-hour replacement RPC exists');
select has_function('public','admin_add_employee_exception_audited',array['uuid','text','timestamp with time zone','timestamp with time zone','text','uuid'],'availability exception add RPC exists');
select has_function('public','admin_remove_employee_exception_audited',array['uuid','uuid'],'availability exception remove RPC exists');
select ok(not has_function_privilege('anon','public.admin_list_employees()','EXECUTE'),'anon cannot list employees directly');
select ok(not has_function_privilege('authenticated','public.admin_list_employees()','EXECUTE'),'authenticated browser cannot bypass employee edge auth');
select ok(has_function_privilege('service_role','public.admin_list_employees()','EXECUTE'),'service role can list employees behind edge auth');
select ok(not has_function_privilege('authenticated','public.admin_replace_work_hours_audited(uuid,jsonb,uuid)','EXECUTE'),'work-hour mutation is internal only');
select ok(not has_function_privilege('authenticated','public.admin_add_employee_exception_audited(uuid,text,timestamp with time zone,timestamp with time zone,text,uuid)','EXECUTE'),'exception mutation is internal only');

select * from finish();
rollback;
