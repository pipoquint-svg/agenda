begin;

create extension if not exists pgtap with schema extensions;
set local search_path=public,extensions;

select plan(20);

select has_table('public','ops_edge_failure_events','Item C has a durable sanitized Edge failure stream');
select has_table('public','ops_alert_states','Item C has durable deduplication state');

select ok((select relrowsecurity from pg_class where oid='public.ops_edge_failure_events'::regclass),'Edge failure stream has RLS enabled');
select ok((select relrowsecurity from pg_class where oid='public.ops_alert_states'::regclass),'deduplication state has RLS enabled');

select ok(not has_table_privilege('anon','public.ops_edge_failure_events','SELECT'),'anon cannot read Edge failures');
select ok(not has_table_privilege('authenticated','public.ops_edge_failure_events','SELECT'),'authenticated cannot read Edge failures');
select ok(has_table_privilege('service_role','public.ops_edge_failure_events','SELECT'),'service role can monitor Edge failures');
select ok(not has_table_privilege('service_role','public.ops_edge_failure_events','DELETE'),'service role cannot delete Edge failure evidence');

select ok(not has_table_privilege('anon','public.ops_alert_states','SELECT'),'anon cannot read alert state');
select ok(not has_table_privilege('authenticated','public.ops_alert_states','SELECT'),'authenticated cannot read alert state');
select ok(has_table_privilege('service_role','public.ops_alert_states','SELECT'),'service role can monitor alert state');
select ok(has_table_privilege('service_role','public.ops_alert_states','UPDATE'),'service role can update alert deduplication state');

select has_function('public','service_record_ops_edge_failure',array['text','text','integer'],'Item C exposes the sanitized Edge telemetry RPC');
select ok(not has_function_privilege('anon','public.service_record_ops_edge_failure(text,text,integer)','EXECUTE'),'anon cannot record Edge telemetry');
select ok(not has_function_privilege('authenticated','public.service_record_ops_edge_failure(text,text,integer)','EXECUTE'),'authenticated cannot record Edge telemetry');
select ok(has_function_privilege('service_role','public.service_record_ops_edge_failure(text,text,integer)','EXECUTE'),'service role can record Edge telemetry');

select throws_ok(
  $$select public.service_record_ops_edge_failure('unknown-function','SAFE_CODE',500)$$,
  'P0001','OPS_EDGE_FUNCTION_DENIED','telemetry rejects unknown functions'
);
select throws_ok(
  $$select public.service_record_ops_edge_failure('booking-submit','unsafe:customer@example.test',500)$$,
  'P0001','OPS_EDGE_CODE_INVALID','telemetry rejects free-form error text'
);
select lives_ok(
  $$select public.service_record_ops_edge_failure('booking-submit','CHECKOUT_RPC_FAILED',500)$$,
  'telemetry accepts allowlisted function and sanitized code'
);
select is(
  (select count(*)::integer from public.ops_edge_failure_events where function_name='booking-submit' and error_code='CHECKOUT_RPC_FAILED'),
  1,
  'sanitized Edge failure was recorded without a payload column'
);

select * from finish();
rollback;
