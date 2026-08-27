begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(7);

select has_function(
  'public','service_admin_set_customer_birth_date',array['uuid','date','uuid'],
  'audited customer birth date RPC exists'
);
select ok(not has_function_privilege('anon','public.service_admin_set_customer_birth_date(uuid,date,uuid)','EXECUTE'),'anon cannot mutate birth date');
select ok(not has_function_privilege('authenticated','public.service_admin_set_customer_birth_date(uuid,date,uuid)','EXECUTE'),'authenticated cannot mutate birth date');
select ok(has_function_privilege('service_role','public.service_admin_set_customer_birth_date(uuid,date,uuid)','EXECUTE'),'service role can call audited birth date mutation');
select throws_ok(
  $$select public.service_admin_set_customer_birth_date('00000000-0000-0000-0000-000000000001'::uuid,current_date + 1,null::uuid)$$,
  'P0001','ADMIN_ACTOR_REQUIRED','admin actor is mandatory'
);
select ok(
  position('BIRTH_DATE_CHANGED' in pg_get_functiondef('public.service_admin_set_customer_birth_date(uuid,date,uuid)'::regprocedure)) > 0,
  'mutation writes a dedicated audit action'
);
select ok(
  position('CUSTOMERS_MANAGE' in pg_get_functiondef('public.service_admin_set_customer_birth_date(uuid,date,uuid)'::regprocedure)) > 0,
  'mutation enforces customer manage permission server-side'
);

select * from finish();
rollback;
