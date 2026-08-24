begin;
create extension if not exists pgtap with schema extensions;
set local search_path=public,extensions;
select plan(10);

select is((select max_active_free_visits from public.customer_access_policy_settings where id=1),1,'free visit active limit defaults to one');
select is((select free_visit_confirmation_hours_before from public.customer_access_policy_settings where id=1),24,'free visit confirmation deadline is 24 hours before start');
select is((select free_visit_no_show_threshold from public.customer_access_policy_settings where id=1),1,'first free-visit no-show triggers restriction threshold');
select is((select history_retention_years from public.customer_access_policy_settings where id=1),5,'customer access history retention is five years');
select ok((select auto_no_free_visits from public.customer_access_policy_settings where id=1),'automatic NO_FREE_VISITS is enabled');

select has_function('public','service_admin_confirm_free_visit',array['uuid','uuid'],'admin free-visit confirmation RPC exists');
select ok(not has_function_privilege('anon','public.service_admin_confirm_free_visit(uuid,uuid)','EXECUTE'),'anonymous cannot confirm free visit');
select ok(not has_function_privilege('authenticated','public.service_admin_confirm_free_visit(uuid,uuid)','EXECUTE'),'authenticated browser cannot confirm free visit directly');
select ok(has_function_privilege('service_role','public.service_admin_confirm_free_visit(uuid,uuid)','EXECUTE'),'service role can confirm after admin authorization');
select ok(
  pg_get_functiondef('public.service_admin_confirm_free_visit(uuid,uuid)'::regprocedure) like '%AGENDA_MANAGE%'
  and pg_get_functiondef('public.service_admin_confirm_free_visit(uuid,uuid)'::regprocedure) like '%FREE_VISIT_CONFIRMATION_DEADLINE_PASSED%'
  and pg_get_functiondef('public.service_admin_confirm_free_visit(uuid,uuid)'::regprocedure) like '%FREE_VISIT_CONFIRMED%',
  'confirmation RPC enforces permission, deadline and audit action'
);

select * from finish();
rollback;
