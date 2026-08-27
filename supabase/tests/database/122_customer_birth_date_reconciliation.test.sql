begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(14);

select has_column('public','service_fields','semantic_key','service fields have explicit semantic mapping');
select has_column('public','appointment_answers','semantic_key_snapshot','appointment answers freeze semantic meaning');
select has_trigger('public','appointment_answers','trg_appointment_answers_semantic_snapshot','answer semantic snapshot trigger exists');

select has_function(
  'public','service_admin_set_service_field_semantic_key',array['uuid','text','uuid'],
  'audited service field semantic mapping RPC exists'
);
select has_function(
  'public','service_admin_list_customer_birth_date_candidates',array['uuid','uuid'],
  'customer birth date reconciliation read model exists'
);

select ok(not has_function_privilege('anon','public.service_admin_set_service_field_semantic_key(uuid,text,uuid)','EXECUTE'),'anon cannot map semantic keys');
select ok(not has_function_privilege('authenticated','public.service_admin_set_service_field_semantic_key(uuid,text,uuid)','EXECUTE'),'authenticated cannot map semantic keys');
select ok(has_function_privilege('service_role','public.service_admin_set_service_field_semantic_key(uuid,text,uuid)','EXECUTE'),'service role can call audited semantic mapping RPC');
select ok(not has_function_privilege('anon','public.service_admin_list_customer_birth_date_candidates(uuid,uuid)','EXECUTE'),'anon cannot list reconciliation candidates');
select ok(not has_function_privilege('authenticated','public.service_admin_list_customer_birth_date_candidates(uuid,uuid)','EXECUTE'),'authenticated cannot list reconciliation candidates');
select ok(has_function_privilege('service_role','public.service_admin_list_customer_birth_date_candidates(uuid,uuid)','EXECUTE'),'service role can read reconciliation candidates');

select ok(
  position('SERVICES_MANAGE' in pg_get_functiondef('public.service_admin_set_service_field_semantic_key(uuid,text,uuid)'::regprocedure)) > 0
  and position('SERVICE_FIELD_SEMANTIC_MAPPING_CHANGED' in pg_get_functiondef('public.service_admin_set_service_field_semantic_key(uuid,text,uuid)'::regprocedure)) > 0,
  'semantic mapping requires permission and writes a dedicated audit action'
);
select ok(
  position('semantic_key_snapshot' in pg_get_functiondef('public.service_snapshot_appointment_answer_semantic_key()'::regprocedure)) > 0
  and position('service_field_id' in pg_get_functiondef('public.service_snapshot_appointment_answer_semantic_key()'::regprocedure)) > 0,
  'answer semantics are copied from the referenced service field at insert time'
);
select ok(
  position('CUSTOMERS_VIEW' in pg_get_functiondef('public.service_admin_list_customer_birth_date_candidates(uuid,uuid)'::regprocedure)) > 0
  and position('service_admin_set_customer_birth_date' in pg_get_functiondef('public.service_admin_list_customer_birth_date_candidates(uuid,uuid)'::regprocedure)) = 0
  and position('update public.customers' in lower(pg_get_functiondef('public.service_admin_list_customer_birth_date_candidates(uuid,uuid)'::regprocedure))) = 0,
  'candidate read model is permission-gated and never promotes canonical birth date implicitly'
);

select * from finish();
rollback;
