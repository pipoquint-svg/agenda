begin;

select plan(5);

select ok(
  to_regprocedure('public.service_bootstrap_first_owner_authenticated(text)') is null,
  'temporary authenticated owner bootstrap function is removed'
);

select ok(
  not has_function_privilege('authenticated', 'public.service_bootstrap_first_owner(uuid,text,uuid)', 'EXECUTE'),
  'authenticated cannot execute low-level owner bootstrap'
);

select ok(
  not has_function_privilege('anon', 'public.service_bootstrap_first_owner(uuid,text,uuid)', 'EXECUTE'),
  'anon cannot execute low-level owner bootstrap'
);

select ok(
  not has_function_privilege('public', 'public.service_bootstrap_first_owner(uuid,text,uuid)', 'EXECUTE'),
  'PUBLIC cannot execute low-level owner bootstrap'
);

select ok(
  has_function_privilege('service_role', 'public.service_bootstrap_first_owner(uuid,text,uuid)', 'EXECUTE'),
  'service_role retains controlled fresh-environment bootstrap capability'
);

select * from finish();
rollback;
