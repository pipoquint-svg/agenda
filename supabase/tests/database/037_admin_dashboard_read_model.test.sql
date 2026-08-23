begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(20);

select has_column('public', 'services', 'operation_scope', 'services have explicit operation scope');
select has_column('public', 'operation_settings', 'dashboard_occupancy_resource_id', 'operation settings can select occupancy resource');

select ok(
  (select column_default is null from information_schema.columns where table_schema='public' and table_name='services' and column_name='operation_scope'),
  'operation scope has no default and cannot silently classify existing services'
);

select has_function(
  'public', 'service_admin_get_dashboard', array['timestamp with time zone','timestamp with time zone','text'],
  'dashboard read model exists'
);
select ok(not has_function_privilege('anon','public.service_admin_get_dashboard(timestamptz,timestamptz,text)','EXECUTE'),'anonymous users cannot execute dashboard read model');
select ok(not has_function_privilege('authenticated','public.service_admin_get_dashboard(timestamptz,timestamptz,text)','EXECUTE'),'authenticated browsers cannot bypass admin edge function');
select ok(has_function_privilege('service_role','public.service_admin_get_dashboard(timestamptz,timestamptz,text)','EXECUTE'),'service role can execute dashboard after admin authorization');

select throws_ok($$select public.service_admin_get_dashboard('2030-01-01 00:00:00-03'::timestamptz,'2030-03-01 00:00:00-03'::timestamptz,null)$$,'P0001','ADMIN_DASHBOARD_RANGE_TOO_LARGE','dashboard rejects ranges above 31 days');
select throws_ok($$select public.service_admin_get_dashboard('2030-01-01 00:00:00-03'::timestamptz,'2030-01-02 00:00:00-03'::timestamptz,'INFER_BY_NAME')$$,'P0001','ADMIN_DASHBOARD_OPERATION_SCOPE_INVALID','dashboard rejects invented operation scopes');
select is(public.service_admin_get_dashboard('2040-01-01 00:00:00-03'::timestamptz,'2040-01-02 00:00:00-03'::timestamptz,null)->'operation_scope','null'::jsonb,'ALL scope is represented as null instead of inferred classification');
select is(jsonb_typeof(public.service_admin_get_dashboard('2040-01-01 00:00:00-03'::timestamptz,'2040-01-02 00:00:00-03'::timestamptz,null)->'pending_items'),'array','pending center is a typed array');
select is(jsonb_typeof(public.service_admin_get_dashboard('2040-01-01 00:00:00-03'::timestamptz,'2040-01-02 00:00:00-03'::timestamptz,null)->'by_employee'),'array','employee summary is always an array');
select is((public.service_admin_get_dashboard('2040-01-01 00:00:00-03'::timestamptz,'2040-01-02 00:00:00-03'::timestamptz,null)->'metrics'->'recurring_customers'->>'available')::boolean,false,'recurrence stays explicitly unavailable until its business definition exists');
select is(public.service_admin_get_dashboard('2040-01-01 00:00:00-03'::timestamptz,'2040-01-02 00:00:00-03'::timestamptz,null)->'metrics'->'recurring_customers'->>'reason','RECURRENCE_DEFINITION_NOT_CONFIGURED','recurrence explains why no number is returned');

update public.operation_settings set dashboard_occupancy_resource_id=null where id=1;
select is((public.service_admin_get_dashboard('2040-01-01 00:00:00-03'::timestamptz,'2040-01-02 00:00:00-03'::timestamptz,null)->'occupancy'->>'available')::boolean,false,'occupancy does not invent denominator when no resource configured');
select is(public.service_admin_get_dashboard('2040-01-01 00:00:00-03'::timestamptz,'2040-01-02 00:00:00-03'::timestamptz,null)->'occupancy'->>'reason','OCCUPANCY_RESOURCE_NOT_CONFIGURED','occupancy explicitly reports missing configuration');
select ok(pg_get_functiondef('public.service_admin_list_agenda(timestamptz,timestamptz)'::regprocedure) like '%operation_scope%','agenda exposes explicit operation scope');
select ok(pg_get_functiondef('public.service_admin_list_agenda(timestamptz,timestamptz)'::regprocedure) like '%created_at%','agenda exposes appointment creation time without deriving it');
select ok(pg_get_functiondef('public.service_admin_get_dashboard(timestamptz,timestamptz,text)'::regprocedure) like '%RESCHEDULE_DIFFERENCE_PENDING%','pending center names contractual difference instead of penalty payment');
select ok(pg_get_functiondef('public.service_admin_get_dashboard(timestamptz,timestamptz,text)'::regprocedure) not like '%AWAITING_PENALTY_PAYMENT%','dashboard no longer depends on removed separate-penalty state');

select * from finish();
rollback;