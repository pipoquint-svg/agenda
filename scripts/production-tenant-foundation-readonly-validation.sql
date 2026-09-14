begin read only;

with blacksheep as (
  select id
  from public.tenants
  where slug = 'blacksheep'
), expected_members as (
  select
    au.auth_user_id as user_id,
    case au.role when 'OWNER' then 'OWNER' else 'ADMIN' end as role
  from public.admin_users au
  where au.is_active
    and au.role in ('OWNER', 'ADMIN')
), actual_members as (
  select tm.user_id, tm.role
  from public.tenant_members tm
  join blacksheep b on b.id = tm.tenant_id
  where tm.status = 'ACTIVE'
), rls_acl as (
  select
    bool_and(c.relrowsecurity) filter (where c.oid is not null) as rls_enabled_all,
    bool_and(not has_table_privilege('anon', c.oid, 'select')) filter (where c.oid is not null) as anon_select_denied_all,
    bool_and(not has_table_privilege('authenticated', c.oid, 'select')) filter (where c.oid is not null) as authenticated_select_denied_all,
    bool_and(has_table_privilege('service_role', c.oid, 'select,insert,update,delete')) filter (where c.oid is not null) as service_role_crud_granted_all
  from (values
    ('public.tenants'::regclass),
    ('public.tenant_members'::regclass),
    ('public.tenant_settings'::regclass),
    ('public.tenant_capabilities'::regclass)
  ) expected(oid)
  join pg_class c on c.oid = expected.oid
)
select jsonb_build_object(
  'tenant_count', (select count(*) from blacksheep),
  'tenant_settings_count', (
    select count(*)
    from public.tenant_settings ts
    join blacksheep b on b.id = ts.tenant_id
  ),
  'expected_active_owner_admin_count', (select count(*) from expected_members),
  'actual_active_members_count', (select count(*) from actual_members),
  'missing_expected_memberships_count', (
    select count(*) from (
      select user_id, role from expected_members
      except
      select user_id, role from actual_members
    ) missing
  ),
  'extra_active_memberships_count', (
    select count(*) from (
      select user_id, role from actual_members
      except
      select user_id, role from expected_members
    ) extra
  ),
  'inactive_memberships_count', (
    select count(*)
    from public.tenant_members tm
    join blacksheep b on b.id = tm.tenant_id
    where tm.status <> 'ACTIVE'
  ),
  'operation_finance_memberships_count', (
    select count(*)
    from public.tenant_members tm
    join blacksheep b on b.id = tm.tenant_id
    join public.admin_users au on au.auth_user_id = tm.user_id
    where au.role in ('OPERATION', 'FINANCE')
  ),
  'rls_enabled_all', (select rls_enabled_all from rls_acl),
  'anon_select_denied_all', (select anon_select_denied_all from rls_acl),
  'authenticated_select_denied_all', (select authenticated_select_denied_all from rls_acl),
  'service_role_crud_granted_all', (select service_role_crud_granted_all from rls_acl),
  'migration_20260913190000_applied', exists (
    select 1
    from supabase_migrations.schema_migrations
    where version = '20260913190000'
  )
) as tenant_foundation_validation;

commit;
