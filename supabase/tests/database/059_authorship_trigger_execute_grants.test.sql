begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(4);

select ok(
  not has_function_privilege('anon','public.reject_appointment_authorship_mutation()','EXECUTE'),
  'anon cannot execute trigger-only authorship guard'
);
select ok(
  not has_function_privilege('authenticated','public.reject_appointment_authorship_mutation()','EXECUTE'),
  'authenticated cannot execute trigger-only authorship guard'
);
select ok(
  not has_function_privilege('service_role','public.reject_appointment_authorship_mutation()','EXECUTE'),
  'service_role cannot execute trigger-only authorship guard'
);
select ok(
  has_function_privilege('postgres','public.reject_appointment_authorship_mutation()','EXECUTE'),
  'function owner retains trigger execution capability'
);

select * from finish();
rollback;
