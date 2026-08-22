begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(14);

select has_function(
  'public','service_admin_upsert_change_policy',array['uuid','jsonb'],
  'internal per-service change policy mutation exists'
);

select ok(
  not has_function_privilege('anon','public.service_admin_upsert_change_policy(uuid,jsonb)','EXECUTE'),
  'anonymous users cannot change service policy'
);

select ok(
  not has_function_privilege('service_role','public.service_admin_upsert_change_policy(uuid,jsonb)','EXECUTE'),
  'service_role cannot bypass the audited policy wrapper'
);

select ok(
  (select column_default is null from information_schema.columns
   where table_schema='public' and table_name='service_change_policies' and column_name='notice_hours'),
  'notice window has no silent database default'
);

insert into public.categories(id,name,slug)
values ('97400000-0000-0000-0000-000000000001','Policy Admin Test','policy-admin-test');

insert into public.services(
  id,category_id,name,slug,base_duration_minutes,base_price,
  buffer_before_minutes,buffer_after_minutes,minimum_people,maximum_people
) values (
  '97400000-0000-0000-0000-000000000002',
  '97400000-0000-0000-0000-000000000001',
  'Policy Test Service','policy-test-service',60,500.00,0,30,1,10
);

select throws_ok(
  $$select public.service_admin_upsert_change_policy(
    '97400000-0000-0000-0000-000000000002',
    '{"notice_hours":48,"reschedule_first_early_percent":0}'::jsonb
  )$$,
  'P0001','CHANGE_POLICY_COMPLETE_CONFIGURATION_REQUIRED',
  'first policy creation requires window plus all four percentages'
);

select throws_ok(
  $$select public.service_admin_upsert_change_policy(
    '97400000-0000-0000-0000-000000000002',
    '{
      "notice_hours":48,
      "reschedule_first_early_percent":0,
      "reschedule_first_late_percent":20,
      "reschedule_repeat_percent":30,
      "cancellation_late_percent":30,
      "cancellation_credit_validity_days":90
    }'::jsonb
  )$$,
  'P0001','LEGACY_CHANGE_POLICY_FIELDS_NOT_ACCEPTED',
  'legacy credit/validity knobs are rejected by the V2 admin write contract'
);

select lives_ok(
  $$select public.service_admin_upsert_change_policy(
    '97400000-0000-0000-0000-000000000002',
    '{
      "notice_hours":48,
      "reschedule_first_early_percent":0,
      "reschedule_first_late_percent":20,
      "reschedule_repeat_percent":30,
      "cancellation_late_percent":30
    }'::jsonb
  )$$,
  'complete V2 policy can be created explicitly'
);

select is(
  (select notice_hours from public.service_change_policies where service_id='97400000-0000-0000-0000-000000000002'),
  48,
  'notice window is stored explicitly per service'
);

select is(
  (select reschedule_first_late_percent from public.service_change_policies where service_id='97400000-0000-0000-0000-000000000002'),
  20.00::numeric,
  'first late-reschedule percentage is stored explicitly'
);

select is(
  (select reschedule_repeat_percent from public.service_change_policies where service_id='97400000-0000-0000-0000-000000000002'),
  30.00::numeric,
  'repeat-reschedule percentage is stored explicitly'
);

select ok(
  (select cancellation_credit_validity_days is null
          and not cancellation_early_credit_allowed
          and not cancellation_late_credit_allowed
   from public.service_change_policies
   where service_id='97400000-0000-0000-0000-000000000002'),
  'V2 policy has no expiring automatic cancellation-credit configuration'
);

select lives_ok(
  $$select public.service_admin_upsert_change_policy(
    '97400000-0000-0000-0000-000000000002',
    '{"reschedule_first_late_percent":25}'::jsonb
  )$$,
  'patching an existing V2 policy preserves only already-configured omitted values'
);

select ok(
  (select reschedule_first_late_percent=25
          and reschedule_first_early_percent=0
          and reschedule_repeat_percent=30
          and cancellation_late_percent=30
          and notice_hours=48
   from public.service_change_policies
   where service_id='97400000-0000-0000-0000-000000000002'),
  'partial update changes requested value without inventing or resetting the rest'
);

select throws_ok(
  $$select public.service_admin_upsert_change_policy(
    '97400000-0000-0000-0000-000000000002',
    '{"cancellation_late_percent":101}'::jsonb
  )$$,
  'P0001','INVALID_CHANGE_POLICY',
  'invalid percentage is rejected'
);

select * from finish();
rollback;
