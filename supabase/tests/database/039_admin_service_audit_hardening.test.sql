begin;
create extension if not exists pgtap with schema extensions;
set local search_path=public,extensions;
select plan(13);

insert into auth.users (id, instance_id, aud, role, email, encrypted_password, created_at, updated_at)
values
  ('12000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'owner-service-audit@example.test', '', now(), now()),
  ('12000000-0000-4000-8000-000000000002', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'operation-service-audit@example.test', '', now(), now());

insert into public.admin_users (id, auth_user_id, display_name, role)
values
  ('22000000-0000-4000-8000-000000000001', '12000000-0000-4000-8000-000000000001', 'Owner Service Audit', 'OWNER'),
  ('22000000-0000-4000-8000-000000000002', '12000000-0000-4000-8000-000000000002', 'Operation Service Audit', 'OPERATION');

insert into public.admin_user_permissions(admin_user_id, permission, is_granted)
values ('22000000-0000-4000-8000-000000000002', 'SERVICES_MANAGE', true);

create temp table audit_service_target as
select id, duration_mode, base_duration_minutes, booking_block_minutes, minimum_booking_blocks,
       maximum_booking_blocks, base_price, price_per_block, buffer_before_minutes, buffer_after_minutes
from public.services
where duration_mode = 'BLOCKS'
order by created_at, id
limit 1;

select ok((select count(*) from audit_service_target) = 1, 'fixture has a block service');

select ok(
  not has_function_privilege('service_role', 'public.service_admin_update_timing(uuid,text,integer,integer,integer,integer,numeric,numeric,integer,integer)', 'EXECUTE'),
  'legacy timing mutation is no longer directly executable by service role'
);
select ok(
  not has_function_privilege('service_role', 'public.service_admin_replace_duration_configuration(uuid,jsonb,jsonb)', 'EXECUTE'),
  'legacy duration configuration mutation is no longer directly executable by service role'
);
select ok(
  not has_function_privilege('service_role', 'public.service_admin_upsert_change_policy(uuid,jsonb)', 'EXECUTE'),
  'legacy policy mutation is no longer directly executable by service role'
);

select throws_ok(format($q$
  select public.service_admin_update_timing_audited(
    %L::uuid, %L, %s, %s, %s, %s, %s, %s, %s, %s,
    '22000000-0000-4000-8000-000000000002'::uuid
  )
$q$,
  (select id from audit_service_target),
  (select duration_mode from audit_service_target),
  (select base_duration_minutes from audit_service_target),
  coalesce((select booking_block_minutes from audit_service_target)::text, 'null'),
  coalesce((select minimum_booking_blocks from audit_service_target)::text, 'null'),
  coalesce((select maximum_booking_blocks from audit_service_target)::text, 'null'),
  ((select base_price from audit_service_target) + 1)::text,
  coalesce((select price_per_block from audit_service_target)::text, 'null'),
  (select buffer_before_minutes from audit_service_target),
  (select buffer_after_minutes from audit_service_target)
), 'P0001', 'ADMIN_PERMISSION_DENIED', 'non-finance service manager cannot change price');

select lives_ok(format($q$
  select public.service_admin_update_timing_audited(
    %L::uuid, %L, %s, %s, %s, %s, %s, %s, %s, %s,
    '22000000-0000-4000-8000-000000000002'::uuid
  )
$q$,
  (select id from audit_service_target),
  (select duration_mode from audit_service_target),
  (select base_duration_minutes from audit_service_target),
  coalesce((select booking_block_minutes from audit_service_target)::text, 'null'),
  coalesce((select minimum_booking_blocks from audit_service_target)::text, 'null'),
  coalesce((select maximum_booking_blocks from audit_service_target)::text, 'null'),
  (select base_price from audit_service_target),
  coalesce((select price_per_block from audit_service_target)::text, 'null'),
  (select buffer_before_minutes from audit_service_target) + 1,
  (select buffer_after_minutes from audit_service_target)
), 'non-finance service manager can change non-financial timing');

select lives_ok(format($q$
  select public.service_admin_update_timing_audited(
    %L::uuid, %L, %s, %s, %s, %s, null, null, %s, %s,
    '22000000-0000-4000-8000-000000000002'::uuid
  )
$q$,
  (select id from audit_service_target),
  (select duration_mode from audit_service_target),
  (select base_duration_minutes from audit_service_target),
  coalesce((select booking_block_minutes from audit_service_target)::text, 'null'),
  coalesce((select minimum_booking_blocks from audit_service_target)::text, 'null'),
  coalesce((select maximum_booking_blocks from audit_service_target)::text, 'null'),
  (select buffer_before_minutes from audit_service_target) + 2,
  (select buffer_after_minutes from audit_service_target)
), 'hidden prices can be omitted and are preserved on non-financial timing edits');

select ok(exists(
  select 1 from public.audit_logs
  where admin_user_id = '22000000-0000-4000-8000-000000000002'
    and entity_id = (select id from audit_service_target)
    and action = 'SERVICE_TIMING_UPDATED'
    and before_json is not null and after_json is not null
), 'timing change records actor and before/after');

delete from public.service_change_policies
where service_id = (select id from audit_service_target);

select throws_ok(format($q$
  select public.service_admin_upsert_change_policy_audited(
    %L::uuid,
    '{"notice_hours":48}'::jsonb,
    '22000000-0000-4000-8000-000000000001'::uuid
  )
$q$, (select id from audit_service_target)), 'P0001', 'CHANGE_POLICY_COMPLETE_CONFIGURATION_REQUIRED', 'first policy cannot be partial');

select lives_ok(format($q$
  select public.service_admin_upsert_change_policy_audited(
    %L::uuid,
    '{
      "notice_hours":48,
      "reschedule_first_penalty_type":"NONE","reschedule_first_penalty_value":0,
      "reschedule_repeat_penalty_type":"NONE","reschedule_repeat_penalty_value":0,
      "reschedule_late_penalty_type":"NONE","reschedule_late_penalty_value":0,
      "cancellation_early_penalty_type":"NONE","cancellation_early_penalty_value":0,
      "cancellation_late_penalty_type":"NONE","cancellation_late_penalty_value":0,
      "cancellation_early_refund_allowed":false,"cancellation_early_credit_allowed":false,
      "cancellation_late_refund_allowed":false,"cancellation_late_credit_allowed":false,
      "cancellation_credit_validity_days":1
    }'::jsonb,
    '22000000-0000-4000-8000-000000000001'::uuid
  )
$q$, (select id from audit_service_target)), 'complete first policy is accepted without implicit commercial defaults');

select ok(exists(
  select 1 from public.audit_logs
  where admin_user_id = '22000000-0000-4000-8000-000000000001'
    and entity_id = (select id from audit_service_target)
    and action = 'SERVICE_CHANGE_POLICY_UPDATED'
    and before_json is not null and after_json is not null
), 'policy change records actor and before/after');

select lives_ok(format($q$
  select public.service_admin_replace_duration_configuration_audited(
    %L::uuid, '[]'::jsonb, '[]'::jsonb,
    '22000000-0000-4000-8000-000000000001'::uuid
  )
$q$, (select id from audit_service_target)), 'finance-authorized admin can replace duration configuration');

select ok(exists(
  select 1 from public.audit_logs
  where admin_user_id = '22000000-0000-4000-8000-000000000001'
    and entity_id = (select id from audit_service_target)
    and action = 'SERVICE_DURATION_CONFIGURATION_UPDATED'
    and before_json is not null and after_json is not null
), 'duration configuration records actor and before/after');

select * from finish();
rollback;
