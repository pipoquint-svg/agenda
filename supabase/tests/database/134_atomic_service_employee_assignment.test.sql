begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(11);

select has_function(
  'public',
  'service_admin_create_service_catalog_with_employee_audited',
  array['uuid','text','text','text','text','text','text','integer','numeric','integer','integer','integer','integer','numeric','uuid','uuid'],
  'atomic service and employee creation RPC exists'
);
select ok(
  not has_function_privilege(
    'anon',
    'public.service_admin_create_service_catalog_with_employee_audited(uuid,text,text,text,text,text,text,integer,numeric,integer,integer,integer,integer,numeric,uuid,uuid)',
    'EXECUTE'
  ),
  'anon cannot create service and employee assignment'
);
select ok(
  not has_function_privilege(
    'authenticated',
    'public.service_admin_create_service_catalog_with_employee_audited(uuid,text,text,text,text,text,text,integer,numeric,integer,integer,integer,integer,numeric,uuid,uuid)',
    'EXECUTE'
  ),
  'authenticated browser cannot bypass the Edge Function'
);
select ok(
  has_function_privilege(
    'service_role',
    'public.service_admin_create_service_catalog_with_employee_audited(uuid,text,text,text,text,text,text,integer,numeric,integer,integer,integer,integer,numeric,uuid,uuid)',
    'EXECUTE'
  ),
  'service role can execute the atomic RPC after Edge authorization'
);

insert into auth.users(id, instance_id, aud, role, email, encrypted_password, created_at, updated_at)
values (
  '13500000-0000-4000-8000-000000000001',
  '00000000-0000-0000-0000-000000000000',
  'authenticated',
  'authenticated',
  'atomic-service-owner@example.test',
  '',
  now(),
  now()
);

insert into public.admin_users(id, auth_user_id, display_name, role)
values (
  '23500000-0000-4000-8000-000000000001',
  '13500000-0000-4000-8000-000000000001',
  'Atomic Service Owner',
  'OWNER'
);

insert into public.categories(id, name, slug, operation_scope, is_active)
values (
  '93500000-0000-4000-8000-000000000001',
  'Atomic Service Category',
  'atomic-service-category',
  'SABRINA',
  true
);

insert into public.employees(id, name, is_active)
values (
  '93500000-0000-4000-8000-000000000002',
  'Atomic Employee',
  true
);

create temporary table atomic_create_result as
select public.service_admin_create_service_catalog_with_employee_audited(
  '93500000-0000-4000-8000-000000000001',
  'Atomic Service',
  'atomic-service',
  'SABRINA',
  null,
  null,
  'FIXED',
  60,
  100,
  0,
  0,
  1,
  1,
  0,
  '93500000-0000-4000-8000-000000000002',
  '23500000-0000-4000-8000-000000000001'
) as result;

select ok(
  exists (
    select 1
    from public.services
    where slug = 'atomic-service'
      and is_active = false
  ),
  'service remains an inactive draft'
);
select ok(
  exists (
    select 1
    from public.service_employees se
    join public.services s on s.id = se.service_id
    where s.slug = 'atomic-service'
      and se.employee_id = '93500000-0000-4000-8000-000000000002'
      and se.is_active
  ),
  'selected employee is assigned in the same creation call'
);
select ok(
  exists (
    select 1
    from public.audit_logs l
    join public.services s on s.id = l.entity_id
    where s.slug = 'atomic-service'
      and l.action = 'SERVICE_CREATED'
  ),
  'service creation remains audited'
);
select ok(
  exists (
    select 1
    from public.audit_logs
    where entity_type = 'SERVICE_EMPLOYEE'
      and action = 'SERVICE_EMPLOYEE_ASSIGNED_AT_CREATION'
      and after_json->>'employee_id' = '93500000-0000-4000-8000-000000000002'
  ),
  'employee assignment has append-only audit evidence'
);
select is(
  (select result->>'employee_id' from atomic_create_result),
  '93500000-0000-4000-8000-000000000002',
  'RPC returns the assigned employee id'
);
select throws_ok(
  $$select public.service_admin_create_service_catalog_with_employee_audited(
    '93500000-0000-4000-8000-000000000001',
    'Atomic Missing Employee',
    'atomic-missing-employee',
    'SABRINA',
    null,
    null,
    'FIXED',
    60,
    100,
    0,
    0,
    1,
    1,
    0,
    '93500000-0000-4000-8000-000000000099',
    '23500000-0000-4000-8000-000000000001'
  )$$,
  'P0001',
  'EMPLOYEE_NOT_AVAILABLE',
  'invalid employee aborts creation'
);
select ok(
  not exists(select 1 from public.services where slug = 'atomic-missing-employee'),
  'failed assignment leaves no orphan service'
);

select * from finish();
rollback;
