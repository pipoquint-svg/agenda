begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(11);

select has_function(
  'public', 'service_admin_upsert_change_policy', array['uuid','jsonb'],
  'admin per-service change policy mutation exists'
);

select ok(
  not has_function_privilege('anon', 'public.service_admin_upsert_change_policy(uuid,jsonb)', 'EXECUTE'),
  'anonymous users cannot change service policy'
);

select ok(
  has_function_privilege('service_role', 'public.service_admin_upsert_change_policy(uuid,jsonb)', 'EXECUTE'),
  'service role can change service policy after admin authentication'
);

insert into public.categories(id, name, slug)
values ('97400000-0000-0000-0000-000000000001', 'Policy Admin Test', 'policy-admin-test');

insert into public.services(
  id, category_id, name, slug, base_duration_minutes, base_price,
  buffer_before_minutes, buffer_after_minutes, minimum_people, maximum_people
) values (
  '97400000-0000-0000-0000-000000000002',
  '97400000-0000-0000-0000-000000000001',
  'Policy Test Service', 'policy-test-service', 60, 500.00, 0, 30, 1, 10
);

select lives_ok(
  $$ select public.service_admin_upsert_change_policy(
    '97400000-0000-0000-0000-000000000002',
    '{
      "notice_hours":48,
      "reschedule_first_penalty_type":"NONE",
      "reschedule_first_penalty_value":0,
      "reschedule_repeat_penalty_type":"NONE",
      "reschedule_repeat_penalty_value":0,
      "reschedule_late_penalty_type":"NONE",
      "reschedule_late_penalty_value":0,
      "cancellation_early_penalty_type":"FIXED",
      "cancellation_early_penalty_value":100,
      "cancellation_late_penalty_type":"FIXED",
      "cancellation_late_penalty_value":100,
      "cancellation_early_refund_allowed":false,
      "cancellation_early_credit_allowed":false,
      "cancellation_late_refund_allowed":false,
      "cancellation_late_credit_allowed":false,
      "cancellation_credit_validity_days":90
    }'::jsonb
  ) $$,
  'admin can configure no-fee rescheduling and fixed cancellation retention independently'
);

select is(
  (select notice_hours from public.service_change_policies where service_id = '97400000-0000-0000-0000-000000000002'),
  48,
  'notice window is stored per service'
);

select is(
  (select reschedule_late_penalty_type::text from public.service_change_policies where service_id = '97400000-0000-0000-0000-000000000002'),
  'NONE',
  'late rescheduling can remain penalty-free for one service'
);

select is(
  (select cancellation_early_penalty_type::text from public.service_change_policies where service_id = '97400000-0000-0000-0000-000000000002'),
  'FIXED',
  'early cancellation can use a fixed retention'
);

select is(
  (select cancellation_early_penalty_value from public.service_change_policies where service_id = '97400000-0000-0000-0000-000000000002'),
  100.00::numeric(12,2),
  'fixed cancellation amount is stored independently from contract price'
);

select is(
  (select cancellation_early_refund_allowed from public.service_change_policies where service_id = '97400000-0000-0000-0000-000000000002'),
  false,
  'refund availability can be disabled per service'
);

select lives_ok(
  $$ select public.service_admin_upsert_change_policy(
    '97400000-0000-0000-0000-000000000002',
    '{"cancellation_early_refund_allowed":true}'::jsonb
  ) $$,
  'partial admin updates preserve unspecified policy fields'
);

select is(
  (select cancellation_early_penalty_value from public.service_change_policies where service_id = '97400000-0000-0000-0000-000000000002'),
  100.00::numeric(12,2),
  'partial update preserves the configured penalty amount'
);

select * from finish();
rollback;
