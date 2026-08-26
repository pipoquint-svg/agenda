begin;

select plan(2);

select is(
  (
    select convalidated
    from pg_constraint
    where conrelid = 'public.appointments'::regclass
      and conname = 'appointments_confirmed_requires_policy_snapshot_ck'
  ),
  true,
  'I-09 confirmed-state CHECK is validated'
);

select is(
  (
    select convalidated
    from pg_constraint
    where conrelid = 'public.appointments'::regclass
      and conname = 'appointments_change_policy_snapshot_fk'
  ),
  true,
  'I-09 snapshot FK is validated'
);

select * from finish();
rollback;
