begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(13);

select ok(
  pg_get_constraintdef((
    select oid from pg_constraint
    where conrelid = 'public.notification_template_configs'::regclass
      and conname = 'notification_template_configs_event_key_check'
  )) like '%ADMIN_USER_INVITE%',
  'notification templates accept the internal-user invite event'
);

select ok(
  exists (
    select 1 from public.notification_template_configs
    where event_key = 'ADMIN_USER_INVITE'
      and channel = 'EMAIL'
      and audience = 'EMPLOYEE'
      and operation_scope = 'BLACKSHEEP'
      and is_active
  ),
  'BlackSheep internal-user invite template is seeded and active'
);

select ok(
  exists (
    select 1 from public.notification_template_configs
    where event_key = 'ADMIN_USER_INVITE'
      and variable_schema @> '["auth.invite_url"]'::jsonb
  ),
  'invite template exposes the one-time invite URL as an editable variable'
);

select has_function(
  'public',
  'service_admin_deactivate_admin_user',
  array['uuid','uuid'],
  'authoritative admin deactivation RPC exists'
);

select ok(
  (select p.prosecdef from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='service_admin_deactivate_admin_user'),
  'admin deactivation RPC is SECURITY DEFINER'
);

select is(
  (select p.proconfig::text from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='service_admin_deactivate_admin_user'),
  '{"search_path=public, pg_temp"}',
  'admin deactivation RPC pins search_path'
);

select ok(
  not has_function_privilege('anon', 'public.service_admin_deactivate_admin_user(uuid,uuid)', 'EXECUTE'),
  'anon cannot deactivate administrative users'
);
select ok(
  not has_function_privilege('authenticated', 'public.service_admin_deactivate_admin_user(uuid,uuid)', 'EXECUTE'),
  'authenticated clients cannot deactivate administrative users directly'
);
select ok(
  has_function_privilege('service_role', 'public.service_admin_deactivate_admin_user(uuid,uuid)', 'EXECUTE'),
  'service_role can execute the deactivation boundary'
);

insert into auth.users (id, instance_id, aud, role, email, encrypted_password, created_at, updated_at)
values
  ('13000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'owner-internal-user@example.test', '', now(), now()),
  ('13000000-0000-4000-8000-000000000002', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'operation-internal-user@example.test', '', now(), now());

insert into public.admin_users (id, auth_user_id, display_name, role)
values
  ('23000000-0000-4000-8000-000000000001', '13000000-0000-4000-8000-000000000001', 'Owner Internal User', 'OWNER'),
  ('23000000-0000-4000-8000-000000000002', '13000000-0000-4000-8000-000000000002', 'Operation Internal User', 'OPERATION');

select lives_ok(
  $$select public.service_admin_deactivate_admin_user(
    '23000000-0000-4000-8000-000000000002'::uuid,
    '23000000-0000-4000-8000-000000000001'::uuid
  )$$,
  'TEAM_MANAGE owner can deactivate a non-owner administrative user'
);

select is(
  public.service_admin_resolve_auth_user('13000000-0000-4000-8000-000000000002'::uuid),
  null::uuid,
  'deactivation blocks authoritative admin resolution immediately'
);

select is(
  (select count(*)::integer from public.audit_logs
   where entity_type='ADMIN_USER'
     and entity_id='23000000-0000-4000-8000-000000000002'
     and action='USER_DEACTIVATED'),
  1,
  'administrative deactivation is audited once'
);

select throws_ok(
  $$select public.service_admin_deactivate_admin_user(
    '23000000-0000-4000-8000-000000000001'::uuid,
    '23000000-0000-4000-8000-000000000001'::uuid
  )$$,
  'P0001','ADMIN_SELF_DEACTIVATION_FORBIDDEN',
  'an administrator cannot deactivate their own account'
);

select * from finish();
rollback;
