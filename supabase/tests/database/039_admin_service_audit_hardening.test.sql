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

insert into public.categories(id, name, slug)
values ('97500000-0000-4000-8000-000000000001', 'Audit Service Category', 'audit-service-category');

insert into public.services(
  id, category_id, name, slug, base_duration_minutes, base_price,
  buffer_before_minutes, buffer_after_minutes, minimum_people, maximum_people,
  duration_mode, booking_block_minutes, minimum_booking_blocks, maximum_booking_blocks, price_per_block
) values (
  '97500000-0000-4000-8000-000000000002',
  '97500000-0000-4000-8000-000000000001',
  'Audit Block Service', 'audit-block-service', 60, 500.00,
  0, 30, 1, 10,
  'BLOCKS', 30, 2, 8, 100.00
);

select ok(exists(select 1 from public.services where id = '97500000-0000-4000-8000-000000000002' and duration_mode = 'BLOCKS'), 'fixture has a block service');

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
  'internal policy primitive is not directly executable by service role'
);

select throws_ok(
  $$select public.service_admin_update_timing_audited(
    '97500000-0000-4000-8000-000000000002'::uuid,
    'BLOCKS',60,30,2,8,501,100,0,30,
    '22000000-0000-4000-8000-000000000002'::uuid
  )$$,
  'P0001','ADMIN_PERMISSION_DENIED',
  'non-finance service manager cannot change price'
);

select lives_ok(
  $$select public.service_admin_update_timing_audited(
    '97500000-0000-4000-8000-000000000002'::uuid,
    'BLOCKS',60,30,2,8,500,100,1,30,
    '22000000-0000-4000-8000-000000000002'::uuid
  )$$,
  'non-finance service manager can change non-financial timing'
);

select lives_ok(
  $$select public.service_admin_update_timing_audited(
    '97500000-0000-4000-8000-000000000002'::uuid,
    'BLOCKS',60,30,2,8,null,null,2,30,
    '22000000-0000-4000-8000-000000000002'::uuid
  )$$,
  'hidden prices can be omitted and are preserved on non-financial timing edits'
);

select ok(exists(
  select 1 from public.audit_logs
  where admin_user_id = '22000000-0000-4000-8000-000000000002'
    and entity_id = '97500000-0000-4000-8000-000000000002'
    and action = 'SERVICE_TIMING_UPDATED'
    and before_json is not null and after_json is not null
), 'timing change records actor and before/after');

delete from public.service_change_policies
where service_id = '97500000-0000-4000-8000-000000000002';

select throws_ok(
  $$select public.service_admin_upsert_change_policy_audited(
    '97500000-0000-4000-8000-000000000002'::uuid,
    '{"notice_hours":48}'::jsonb,
    '22000000-0000-4000-8000-000000000001'::uuid
  )$$,
  'P0001','CHANGE_POLICY_COMPLETE_CONFIGURATION_REQUIRED',
  'first policy cannot be partial'
);

select lives_ok(
  $$select public.service_admin_upsert_change_policy_audited(
    '97500000-0000-4000-8000-000000000002'::uuid,
    '{
      "notice_hours":48,
      "reschedule_first_early_percent":0,
      "reschedule_first_late_percent":20,
      "reschedule_repeat_percent":30,
      "cancellation_late_percent":30
    }'::jsonb,
    '22000000-0000-4000-8000-000000000001'::uuid
  )$$,
  'complete V2 first policy is accepted without implicit commercial defaults'
);

select ok(exists(
  select 1 from public.audit_logs
  where admin_user_id = '22000000-0000-4000-8000-000000000001'
    and entity_id = '97500000-0000-4000-8000-000000000002'
    and action = 'SERVICE_CHANGE_POLICY_UPDATED'
    and before_json is not null and after_json is not null
), 'policy change records actor and before/after');

select lives_ok(
  $$select public.service_admin_replace_duration_configuration_audited(
    '97500000-0000-4000-8000-000000000002'::uuid,
    '[{"min_blocks":2,"max_blocks":8,"price_per_block":95,"is_active":true,"sort_order":0}]'::jsonb,
    '[{"block_count":4,"title":"4 blocos","description":null,"badge":null,"is_featured":false,"is_active":true,"sort_order":0}]'::jsonb,
    '22000000-0000-4000-8000-000000000001'::uuid
  )$$,
  'finance-authorized admin can replace duration configuration with an effective change'
);

select ok(exists(
  select 1 from public.audit_logs
  where admin_user_id = '22000000-0000-4000-8000-000000000001'
    and entity_id = '97500000-0000-4000-8000-000000000002'
    and action = 'SERVICE_DURATION_CONFIGURATION_UPDATED'
    and before_json is not null and after_json is not null
), 'duration configuration records actor and before/after');

select * from finish();
rollback;
