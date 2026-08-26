begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(2);

select like(
  pg_get_functiondef('public.capture_current_appointment_change_policy_snapshot()'::regprocedure),
  '%APPOINTMENT_SERVICE_CHANGE_POLICY_MISSING%',
  'snapshot capture raises an explicit missing-policy error'
);

select unlike(
  pg_get_functiondef('public.capture_current_appointment_change_policy_snapshot()'::regprocedure),
  '%if not found then return new; end if%',
  'snapshot capture no longer returns silently when policy is missing'
);

select * from finish();
rollback;
