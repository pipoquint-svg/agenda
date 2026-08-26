begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(2);

select ok(
  position(
    'APPOINTMENT_SERVICE_CHANGE_POLICY_MISSING'
    in pg_get_functiondef('public.capture_current_appointment_change_policy_snapshot()'::regprocedure)
  ) > 0,
  'snapshot capture raises an explicit missing-policy error'
);

select ok(
  position(
    'if not found then return new; end if'
    in lower(pg_get_functiondef('public.capture_current_appointment_change_policy_snapshot()'::regprocedure))
  ) = 0,
  'snapshot capture no longer returns silently when policy is missing'
);

select * from finish();
rollback;
