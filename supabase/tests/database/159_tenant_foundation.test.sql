begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(23);

select has_table('public', 'tenants', 'tenant foundation has tenants');
select has_table('public', 'tenant_members', 'tenant foundation has tenant_members');
select has_table('public', 'tenant_settings', 'tenant foundation has tenant_settings');
select has_table('public', 'tenant_capabilities', 'tenant foundation has tenant_capabilities');

select ok(exists(select 1 from public.tenants where slug = 'blacksheep' and status = 'ACTIVE'), 'BlackSheep bootstrap tenant exists');
select is((select count(*) from public.tenant_settings ts join public.tenants t on t.id = ts.tenant_id where t.slug = 'blacksheep'), 1::bigint, 'BlackSheep bootstrap has one settings row');

select throws_ok(
  $$insert into public.tenants(name, slug) values ('Duplicate', 'blacksheep')$$,
  '23505', null, 'tenant slug is unique'
);
select throws_ok(
  $$insert into public.tenants(name, slug) values ('Unnormalized', 'BlackSheep')$$,
  '23514', null, 'tenant slug must be normalized'
);

insert into auth.users(id, instance_id, aud, role, email, encrypted_password, created_at, updated_at)
values
  ('15900000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'tenant-owner@example.test', '', now(), now()),
  ('15900000-0000-4000-8000-000000000002', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'tenant-admin@example.test', '', now(), now());
insert into public.tenants(id, name, slug) values
  ('15900000-0000-4000-8000-000000000010', 'Tenant A', 'tenant-a'),
  ('15900000-0000-4000-8000-000000000011', 'Tenant B', 'tenant-b');
insert into public.tenant_members(tenant_id, user_id, role) values
  ('15900000-0000-4000-8000-000000000010', '15900000-0000-4000-8000-000000000001', 'OWNER'),
  ('15900000-0000-4000-8000-000000000011', '15900000-0000-4000-8000-000000000001', 'ADMIN');

select is((select count(*) from public.tenant_members where user_id = '15900000-0000-4000-8000-000000000001'), 2::bigint, 'one user may belong to multiple tenants');
select throws_ok(
  $$insert into public.tenant_members(tenant_id, user_id, role) values ('15900000-0000-4000-8000-000000000010', '15900000-0000-4000-8000-000000000001', 'OWNER')$$,
  '23505', null, 'duplicate membership in one tenant is rejected'
);
select throws_ok(
  $$insert into public.tenant_members(tenant_id, user_id, role) values ('15900000-0000-4000-8000-000000000099', '15900000-0000-4000-8000-000000000002', 'ADMIN')$$,
  '23503', null, 'tenant membership requires an existing tenant'
);
select throws_ok(
  $$insert into public.tenant_settings(tenant_id) values ('15900000-0000-4000-8000-000000000010')$$,
  '23505', null, 'one settings row per tenant is enforced'
);
insert into public.tenant_capabilities(tenant_id, capability_key, enabled, config)
values ('15900000-0000-4000-8000-000000000010', 'advanced-resources', true, '{"max_resources": 2}'::jsonb);
select throws_ok(
  $$insert into public.tenant_capabilities(tenant_id, capability_key) values ('15900000-0000-4000-8000-000000000010', 'advanced-resources')$$,
  '23505', null, 'duplicate capability key per tenant is rejected'
);
select throws_ok(
  $$insert into public.tenant_capabilities(tenant_id, capability_key) values ('15900000-0000-4000-8000-000000000010', 'Advanced-Resources')$$,
  '23514', null, 'capability key must be normalized'
);

select ok((select relrowsecurity from pg_class where oid = 'public.tenants'::regclass), 'tenants has RLS enabled');
select ok((select relrowsecurity from pg_class where oid = 'public.tenant_members'::regclass), 'tenant_members has RLS enabled');
select ok((select relrowsecurity from pg_class where oid = 'public.tenant_settings'::regclass), 'tenant_settings has RLS enabled');
select ok((select relrowsecurity from pg_class where oid = 'public.tenant_capabilities'::regclass), 'tenant_capabilities has RLS enabled');
select ok(not has_table_privilege('anon', 'public.tenants', 'SELECT') and not has_table_privilege('authenticated', 'public.tenants', 'SELECT'), 'anon and authenticated cannot directly read tenants');
select ok(not has_table_privilege('anon', 'public.tenant_members', 'SELECT') and not has_table_privilege('authenticated', 'public.tenant_members', 'SELECT'), 'anon and authenticated cannot directly read tenant_members');
select ok(has_table_privilege('service_role', 'public.tenants', 'SELECT') and has_table_privilege('service_role', 'public.tenant_members', 'INSERT'), 'service_role bootstrap boundary is explicit');
select ok(to_regprocedure('public.public_list_available_dates_month(text,uuid,uuid,integer,jsonb,integer,date)') is not null, 'monthly public endpoint remains available');
select ok((select pg_get_functiondef('agenda_public_bridge.list_available_dates_month_impl(text,uuid,uuid,integer,jsonb,integer,date)'::regprocedure)) like '%agenda_internal.list_available_dates_month_v2%', 'monthly bridge remains on V2');

select * from finish();
rollback;
