begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(7);

select has_function(
  'public','canonical_change_policy_snapshot_contract',array['jsonb'],
  'canonical snapshot compatibility function exists'
);
select has_view('public','appointment_change_policy_snapshot_contract_v2','canonical snapshot read view exists');

select is(
  public.canonical_change_policy_snapshot_contract(jsonb_build_object(
    'snapshot_schema_version','CONSOLIDATED_POLICY_V2',
    'notice_hours',48,
    'reschedule_first_early_percent',0,
    'reschedule_first_late_percent',20,
    'reschedule_repeat_percent',30,
    'cancellation_late_percent',30,
    'max_customer_reschedules',3
  ))->>'normalization_status',
  'CANONICAL',
  'V2 snapshot is already canonical'
);

select is(
  public.canonical_change_policy_snapshot_contract(jsonb_build_object(
    'snapshot_schema_version','CHANGE_POLICY_SNAPSHOT_V1',
    'notice_hours',48,
    'reschedule_first_penalty_type','NONE',
    'reschedule_first_penalty_value',0,
    'reschedule_late_penalty_type','PERCENT',
    'reschedule_late_penalty_value',20,
    'reschedule_repeat_penalty_type','PERCENT',
    'reschedule_repeat_penalty_value',30,
    'cancellation_late_penalty_type','PERCENT',
    'cancellation_late_penalty_value',30
  ))->>'normalization_status',
  'CANONICAL',
  'lossless V1 percentage snapshot normalizes canonically'
);

select is(
  public.canonical_change_policy_snapshot_contract(jsonb_build_object(
    'snapshot_schema_version','CHANGE_POLICY_SNAPSHOT_V1',
    'notice_hours',48,
    'reschedule_first_penalty_type','FIXED',
    'reschedule_first_penalty_value',50,
    'reschedule_late_penalty_type','PERCENT',
    'reschedule_late_penalty_value',20,
    'reschedule_repeat_penalty_type','PERCENT',
    'reschedule_repeat_penalty_value',30,
    'cancellation_late_penalty_type','PERCENT',
    'cancellation_late_penalty_value',30
  ))->>'normalization_status',
  'UNSUPPORTED_LEGACY_SHAPE',
  'lossy legacy FIXED penalty fails closed instead of inventing V2 semantics'
);

select is(
  (public.canonical_change_policy_snapshot_contract(jsonb_build_object(
    'snapshot_schema_version','FIXTURE_RECONSTRUCTION_V1',
    'fixture_only',true,
    'notice_hours',0,
    'reschedule_first_early_percent',0,
    'reschedule_first_late_percent',0,
    'reschedule_repeat_percent',0,
    'cancellation_late_percent',0,
    'max_customer_reschedules',0
  ))->>'max_customer_reschedules')::integer,
  0,
  'fixture reconstruction keeps its explicit synthetic max-reschedule evidence'
);

select ok(
  not has_table_privilege('anon','public.appointment_change_policy_snapshot_contract_v2','SELECT')
  and not has_table_privilege('authenticated','public.appointment_change_policy_snapshot_contract_v2','SELECT'),
  'canonical snapshot read model is not exposed to public application roles'
);

select * from finish();
rollback;
