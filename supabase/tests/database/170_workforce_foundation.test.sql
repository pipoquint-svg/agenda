begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(68);

-- ---------------------------------------------------------------------------
-- Fixture: two tenants, two owners, an ADMIN, two non-owner logins.
-- ---------------------------------------------------------------------------
insert into auth.users(id, instance_id, aud, role, email, encrypted_password, created_at, updated_at)
values
  ('17000000-0000-4000-8000-000000000001', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'wf-owner-a@example.test', '', now(), now()),
  ('17000000-0000-4000-8000-000000000002', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'wf-owner-b@example.test', '', now(), now()),
  ('17000000-0000-4000-8000-000000000003', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'wf-employee-a@example.test', '', now(), now()),
  ('17000000-0000-4000-8000-000000000004', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'wf-admin-a@example.test', '', now(), now()),
  ('17000000-0000-4000-8000-000000000005', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'wf-member-x@example.test', '', now(), now()),
  ('17000000-0000-4000-8000-000000000006', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'wf-owner-unscoped@example.test', '', now(), now());

insert into public.admin_users(id, auth_user_id, display_name, role, is_active)
values
  ('17000000-0000-4000-8000-000000000011', '17000000-0000-4000-8000-000000000001', 'Owner A', 'OWNER', true),
  ('17000000-0000-4000-8000-000000000012', '17000000-0000-4000-8000-000000000002', 'Owner B', 'OWNER', true),
  ('17000000-0000-4000-8000-000000000013', '17000000-0000-4000-8000-000000000003', 'Employee A', 'OPERATION', true),
  ('17000000-0000-4000-8000-000000000014', '17000000-0000-4000-8000-000000000004', 'Admin A', 'ADMIN', true),
  ('17000000-0000-4000-8000-000000000015', '17000000-0000-4000-8000-000000000005', 'Member X', 'OPERATION', true),
  ('17000000-0000-4000-8000-000000000016', '17000000-0000-4000-8000-000000000006', 'Owner Unscoped', 'OWNER', true);

insert into public.tenants(id, name, slug) values
  ('17000000-0000-4000-8000-000000000021', 'Workforce Tenant A', 'wf-tenant-a'),
  ('17000000-0000-4000-8000-000000000022', 'Workforce Tenant B', 'wf-tenant-b');
insert into public.tenant_members(tenant_id, user_id, role) values
  ('17000000-0000-4000-8000-000000000021', '17000000-0000-4000-8000-000000000001', 'OWNER'),
  ('17000000-0000-4000-8000-000000000022', '17000000-0000-4000-8000-000000000002', 'OWNER'),
  ('17000000-0000-4000-8000-000000000021', '17000000-0000-4000-8000-000000000004', 'ADMIN');

create temp table wf_ids(k text primary key, v uuid not null) on commit drop;

-- ---------------------------------------------------------------------------
-- 1. Exposure: schema, tables and helpers are closed to every application role.
-- ---------------------------------------------------------------------------
select has_schema('workforce', 'workforce schema exists');
select ok(not has_schema_privilege('anon', 'workforce', 'USAGE'), 'anon has no usage on workforce');
select ok(not has_schema_privilege('authenticated', 'workforce', 'USAGE'), 'authenticated has no usage on workforce');
select ok(not has_schema_privilege('service_role', 'workforce', 'USAGE'), 'service_role has no usage on workforce');
select is((
  select count(*)
  from information_schema.role_table_grants g
  where g.table_schema = 'workforce' and g.grantee in ('PUBLIC', 'anon', 'authenticated', 'service_role')
), 0::bigint, 'no table privilege for application roles in workforce');
select is((
  select count(*)
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'workforce' and c.relkind = 'r' and not (c.relrowsecurity and c.relforcerowsecurity)
), 0::bigint, 'every workforce table has RLS enabled and forced');
select is((
  select count(*)
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'workforce'
    and (has_function_privilege('anon', p.oid, 'EXECUTE')
      or has_function_privilege('authenticated', p.oid, 'EXECUTE')
      or has_function_privilege('service_role', p.oid, 'EXECUTE'))
), 0::bigint, 'no workforce helper is executable by application roles');
select is((
  select count(*)
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname like 'service\_workforce\_%'
    and has_function_privilege('service_role', p.oid, 'EXECUTE')
    and not has_function_privilege('anon', p.oid, 'EXECUTE')
    and not has_function_privilege('authenticated', p.oid, 'EXECUTE')
    and p.prosecdef
    and pg_get_userbyid(p.proowner) = 'postgres'
    and 'search_path=""' = any(coalesce(p.proconfig, '{}'::text[]))
), 7::bigint, 'seven governed RPCs: service_role only, security definer, empty search_path');
select is((
  select count(*)
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname like 'service\_workforce\_%'
), 7::bigint, 'no other public workforce RPC exists');

set local role authenticated;
select throws_ok(
  $$insert into workforce.employers(tenant_id, legal_name, workplace_city, workplace_state)
    values ('17000000-0000-4000-8000-000000000021', 'Forged', 'Palhoça', 'SC')$$,
  '42501', null, 'authenticated cannot insert directly into workforce tables'
);
reset role;
set local role service_role;
select throws_ok(
  $$update workforce.employment_schedule_days set start_time = '08:00'$$,
  '42501', null, 'service_role cannot update raw schedule rows directly'
);
select throws_ok(
  $$select * from workforce.employees$$,
  '42501', null, 'service_role cannot read workforce tables directly'
);
reset role;

-- ---------------------------------------------------------------------------
-- 2. Pure helpers and seeds.
-- ---------------------------------------------------------------------------
select ok(workforce.cnpj_is_valid('11222333000181'), 'valid numeric CNPJ');
select ok(not workforce.cnpj_is_valid('11222333000182'), 'wrong CNPJ check digit rejected');
select ok(not workforce.cnpj_is_valid('00000000000000'), 'repeated-digit CNPJ rejected');
select ok(workforce.cnpj_is_valid('12ABC34501DE35'), 'valid alphanumeric CNPJ (IN RFB 2.229/2024)');
select is(workforce.easter_sunday(2026), '2026-04-05'::date, 'Easter 2026');
select is(workforce.easter_sunday(2027), '2027-03-28'::date, 'Easter 2027');

select ok(workforce.is_holiday(null, '2026-11-20'), 'Consciência Negra is national from 2024');
select ok(not workforce.is_holiday(null, '2023-11-20'), 'Consciência Negra is not a holiday before Lei 14.759/2023');
select ok(workforce.is_holiday(null, '2026-12-25'), 'Natal is national');
select ok(not workforce.is_holiday(null, '2026-04-03'), 'Good Friday is not seeded as national (municipal by Lei 9.093/1995)');
select is((select count(*) from workforce.holiday_calendar(null, 2026)), 9::bigint, 'nine national holidays in 2026');

select ok(exists (
  select 1
  from workforce.employers er
  join public.tenants t on t.id = er.tenant_id
  join workforce.payroll_settings ps on ps.employer_id = er.id
  where t.slug = 'blacksheep'
    and er.legal_name = 'Pierri Quint Produções'
    and er.trade_name = 'BlackSheep Estúdio Criativo'
    and er.cnpj is null
    and er.workplace_city = 'Palhoça' and er.workplace_state = 'SC'
    and er.timezone = 'America/Sao_Paulo'
    and ps.report_business_day_ordinal = 2
    and ps.report_local_time = '16:00'
    and not ps.auto_send_enabled
    and ps.max_extra_minutes_per_day = 120
    and ps.minimum_interjourney_rest_minutes = 660
    and ps.minimum_weekly_rest_minutes = 1440
    and ps.minimum_long_interval_minutes = 60
    and jsonb_array_length(ps.default_weekly_schedule) = 5
    and ps.default_weekly_schedule -> 0 = '{"iso_weekday":1,"block_index":1,"start_time":"13:15","end_time":"19:15"}'::jsonb
), 'BlackSheep employer seeded with Pierri Quint Produções, empty CNPJ and Mon–Fri 13:15–19:15 default');

-- ---------------------------------------------------------------------------
-- 3. Owner authorization and forged fields.
-- ---------------------------------------------------------------------------
insert into wf_ids
select 'employer_a', (r -> 'employer' ->> 'employer_id')::uuid
from public.service_workforce_owner_save_employer(
  '17000000-0000-4000-8000-000000000011', '17000000-0000-4000-8000-0000000000a1',
  '{"legal_name":"Empregadora A Ltda","trade_name":"Marca A","cnpj":"11.222.333/0001-81","workplace_city":"Palhoça","workplace_state":"sc"}'
) r;
select ok(exists (
  select 1 from workforce.employers er join wf_ids i on i.v = er.id
  where i.k = 'employer_a' and er.tenant_id = '17000000-0000-4000-8000-000000000021'
    and er.cnpj = '11222333000181' and er.workplace_state = 'SC'
), 'owner creates employer in the tenant derived server-side, CNPJ normalized');
select ok(exists (
  select 1 from workforce.payroll_settings ps join wf_ids i on i.v = ps.employer_id where i.k = 'employer_a'
), 'payroll settings row created with the employer');

select is(
  (public.service_workforce_owner_save_employer(
    '17000000-0000-4000-8000-000000000011', '17000000-0000-4000-8000-0000000000a1',
    '{"legal_name":"Empregadora A Ltda","trade_name":"Marca A","cnpj":"11.222.333/0001-81","workplace_city":"Palhoça","workplace_state":"sc"}'
  ) ->> 'replayed')::boolean,
  true, 'same idempotency key replays the original result'
);
select is((select count(*) from workforce.employers where tenant_id = '17000000-0000-4000-8000-000000000021'), 1::bigint,
  'replay does not create a second employer');
select throws_ok(
  $$select public.service_workforce_owner_save_employer(
    '17000000-0000-4000-8000-000000000011', '17000000-0000-4000-8000-0000000000a1',
    '{"legal_name":"Outra","workplace_city":"Palhoça","workplace_state":"SC"}')$$,
  'P0001', 'WORKFORCE_IDEMPOTENCY_KEY_REUSED', 'idempotency key reused with another payload is rejected'
);
select throws_ok(
  $$select public.service_workforce_owner_save_employer(
    '17000000-0000-4000-8000-000000000011', '17000000-0000-4000-8000-0000000000a2',
    '{"tenant_id":"17000000-0000-4000-8000-000000000022","legal_name":"Forjada","workplace_city":"Palhoça","workplace_state":"SC"}')$$,
  'P0001', 'WORKFORCE_PAYLOAD_FIELD_FORBIDDEN:tenant_id', 'forged tenant_id is rejected'
);
select throws_ok(
  $$select public.service_workforce_owner_save_employer(
    '17000000-0000-4000-8000-000000000011', '17000000-0000-4000-8000-0000000000a3',
    '{"organization_id":"17000000-0000-4000-8000-000000000022","legal_name":"Forjada","workplace_city":"Palhoça","workplace_state":"SC"}')$$,
  'P0001', 'WORKFORCE_PAYLOAD_FIELD_FORBIDDEN:organization_id', 'forged organization_id is rejected'
);
select throws_ok(
  $$select public.service_workforce_owner_save_employer(
    '17000000-0000-4000-8000-000000000011', '17000000-0000-4000-8000-0000000000a4',
    '{"legal_name":"CNPJ ruim","cnpj":"11222333000182","workplace_city":"Palhoça","workplace_state":"SC"}')$$,
  'P0001', 'WORKFORCE_CNPJ_INVALID', 'invalid CNPJ rejected'
);
select throws_ok(
  $$select public.service_workforce_owner_save_employer(
    '17000000-0000-4000-8000-000000000013', '17000000-0000-4000-8000-0000000000a5',
    '{"legal_name":"Membro","workplace_city":"Palhoça","workplace_state":"SC"}')$$,
  'P0001', 'WORKFORCE_OWNER_REQUIRED', 'OPERATION member cannot execute owner action'
);
select throws_ok(
  $$select public.service_workforce_owner_get_setup('17000000-0000-4000-8000-000000000014')$$,
  'P0001', 'WORKFORCE_OWNER_REQUIRED', 'ADMIN role does not inherit workforce owner rights'
);
select throws_ok(
  format($$select public.service_workforce_owner_save_employer(
    '17000000-0000-4000-8000-000000000012', '17000000-0000-4000-8000-0000000000b1',
    '{"employer_id":"%s","legal_name":"Sequestro"}')$$, (select v from wf_ids where k = 'employer_a')),
  'P0001', 'WORKFORCE_EMPLOYER_NOT_FOUND', 'tenant B owner cannot update tenant A employer (forged employer_id)'
);
select is(
  jsonb_array_length(public.service_workforce_owner_get_setup('17000000-0000-4000-8000-000000000012') -> 'employers'),
  0, 'tenant B owner sees no tenant A employer'
);

-- ---------------------------------------------------------------------------
-- 4. Employee binding.
-- ---------------------------------------------------------------------------
select ok(
  public.service_workforce_owner_get_setup('17000000-0000-4000-8000-000000000011') -> 'employee_candidates'
    @> '[{"admin_user_id":"17000000-0000-4000-8000-000000000013"}]',
  'non-owner login is offered as employee candidate'
);
select ok(
  not (public.service_workforce_owner_get_setup('17000000-0000-4000-8000-000000000012') -> 'employee_candidates'
    @> '[{"admin_user_id":"17000000-0000-4000-8000-000000000014"}]'),
  'a login that belongs only to tenant A is not offered to tenant B'
);

insert into wf_ids
select 'employee_a', (r -> 'employee' ->> 'employee_id')::uuid
from public.service_workforce_owner_save_employee(
  '17000000-0000-4000-8000-000000000011', '17000000-0000-4000-8000-0000000000c1',
  jsonb_build_object('employer_id', (select v from wf_ids where k = 'employer_a'),
                     'admin_user_id', '17000000-0000-4000-8000-000000000013',
                     'display_name', 'Funcionária A')
) r;
select ok(exists (
  select 1 from workforce.employees e join wf_ids i on i.v = e.id
  where i.k = 'employee_a' and e.tenant_id = '17000000-0000-4000-8000-000000000021'
    and e.admin_user_id = '17000000-0000-4000-8000-000000000013' and e.active
), 'owner binds an existing login as employee');
select throws_ok(
  format($$select public.service_workforce_owner_save_employee(
    '17000000-0000-4000-8000-000000000011', '17000000-0000-4000-8000-0000000000c2',
    '{"employer_id":"%s","admin_user_id":"17000000-0000-4000-8000-000000000013"}')$$, (select v from wf_ids where k = 'employer_a')),
  'P0001', 'WORKFORCE_LOGIN_ALREADY_BOUND', 'a login cannot hold two active employments'
);
select throws_ok(
  format($$select public.service_workforce_owner_save_employee(
    '17000000-0000-4000-8000-000000000012', '17000000-0000-4000-8000-0000000000c3',
    '{"employer_id":"%s","admin_user_id":"17000000-0000-4000-8000-000000000015"}')$$, (select v from wf_ids where k = 'employer_a')),
  'P0001', 'WORKFORCE_EMPLOYER_NOT_FOUND', 'tenant B owner cannot bind into tenant A employer'
);
select throws_ok(
  format($$select public.service_workforce_owner_save_employee(
    '17000000-0000-4000-8000-000000000011', '17000000-0000-4000-8000-0000000000c4',
    '{"employer_id":"%s","admin_user_id":"17000000-0000-4000-8000-000000000016"}')$$, (select v from wf_ids where k = 'employer_a')),
  'P0001', 'WORKFORCE_OWNER_CANNOT_BE_EMPLOYEE', 'an OWNER login cannot be bound as employee'
);
select throws_ok(
  format($$select public.service_workforce_owner_save_employee(
    '17000000-0000-4000-8000-000000000011', '17000000-0000-4000-8000-0000000000c6',
    '{"employer_id":"%s","admin_user_id":"17000000-0000-4000-8000-000000000012"}')$$, (select v from wf_ids where k = 'employer_a')),
  'P0001', 'WORKFORCE_LOGIN_NOT_FOUND', 'a login scoped to another tenant cannot be bound (cross-tenant)'
);
select throws_ok(
  format($$select public.service_workforce_owner_save_employee(
    '17000000-0000-4000-8000-000000000011', '17000000-0000-4000-8000-0000000000c5',
    '{"employee_id":"%s","employer_id":"%s"}')$$,
    (select v from wf_ids where k = 'employee_a'), (select v from wf_ids where k = 'employer_a')),
  'P0001', 'WORKFORCE_PAYLOAD_FIELD_FORBIDDEN:employer_id', 'employer of an employment is immutable'
);
select throws_ok(
  format($$update workforce.employees set admin_user_id = '17000000-0000-4000-8000-000000000015' where id = '%s'$$,
    (select v from wf_ids where k = 'employee_a')),
  'P0001', 'WORKFORCE_IMMUTABLE:employees', 'login binding is immutable even for the table owner'
);

-- ---------------------------------------------------------------------------
-- 5. Versioned schedule.
-- ---------------------------------------------------------------------------
select is(
  (public.service_workforce_owner_create_schedule_version(
    '17000000-0000-4000-8000-000000000011', '17000000-0000-4000-8000-0000000000d2',
    jsonb_build_object('employee_id', (select v from wf_ids where k = 'employee_a'), 'effective_from', '2026-01-01',
      'days', '[{"iso_weekday":1,"start_time":"13:15","end_time":"19:15"},
                {"iso_weekday":2,"start_time":"13:15","end_time":"19:15"},
                {"iso_weekday":3,"start_time":"13:15","end_time":"19:15"},
                {"iso_weekday":4,"start_time":"13:15","end_time":"19:15"},
                {"iso_weekday":5,"start_time":"13:15","end_time":"19:15"}]'::jsonb)
  ) -> 'employee' -> 'schedule_versions' -> 0 ->> 'effective_from'),
  '2026-01-01', 'first schedule version created'
);
select is(
  (public.service_workforce_owner_create_schedule_version(
    '17000000-0000-4000-8000-000000000011', '17000000-0000-4000-8000-0000000000d3',
    jsonb_build_object('employee_id', (select v from wf_ids where k = 'employee_a'), 'effective_from', '2026-11-01',
      'reason', 'Nova jornada',
      'days', '[{"iso_weekday":1,"start_time":"13:00","end_time":"19:00"}]'::jsonb)
  ) -> 'employee' -> 'schedule_versions' -> 1 ->> 'effective_to'),
  '2026-11-01', 'new version closes the previous one at its start date'
);
select is(
  (select count(*) from workforce.employment_schedules s join wf_ids i on i.v = s.employee_id where i.k = 'employee_a'),
  2::bigint, 'versions are preserved, not overwritten'
);
select is(
  (select count(*)
   from workforce.employment_schedule_days d
   join workforce.employment_schedules s on s.id = d.schedule_id
   join wf_ids i on i.v = s.employee_id
   where i.k = 'employee_a' and s.effective_from = '2026-01-01'),
  5::bigint, 'previous version keeps its five weekdays'
);
select throws_ok(
  format($$select public.service_workforce_owner_create_schedule_version(
    '17000000-0000-4000-8000-000000000011', '17000000-0000-4000-8000-0000000000d4',
    '{"employee_id":"%s","effective_from":"2026-06-01","days":[]}')$$, (select v from wf_ids where k = 'employee_a')),
  'P0001', 'WORKFORCE_SCHEDULE_VERSION_NOT_LATEST', 'backdated version in the middle of history is rejected'
);
select throws_ok(
  format($$select public.service_workforce_owner_create_schedule_version(
    '17000000-0000-4000-8000-000000000011', '17000000-0000-4000-8000-0000000000d5',
    '{"employee_id":"%s","effective_from":"2027-01-01","days":[{"iso_weekday":1,"start_time":"08:00","end_time":"12:00"},{"iso_weekday":1,"start_time":"11:00","end_time":"14:00"}]}')$$,
    (select v from wf_ids where k = 'employee_a')),
  'P0001', 'WORKFORCE_SCHEDULE_BLOCK_OVERLAP', 'overlapping blocks on the same day are rejected'
);
select throws_ok(
  format($$select public.service_workforce_owner_create_schedule_version(
    '17000000-0000-4000-8000-000000000012', '17000000-0000-4000-8000-0000000000d6',
    '{"employee_id":"%s","effective_from":"2027-01-01","days":[]}')$$, (select v from wf_ids where k = 'employee_a')),
  'P0001', 'WORKFORCE_EMPLOYEE_NOT_FOUND', 'tenant B owner cannot change tenant A schedule (forged employee_id)'
);
select throws_ok(
  $$update workforce.employment_schedule_days set start_time = '08:00'$$,
  'P0001', 'WORKFORCE_IMMUTABLE:employment_schedule_days', 'schedule days are immutable'
);
select throws_ok(
  format($$update workforce.employment_schedules set effective_from = '2025-01-01' where employee_id = '%s' and effective_to is null$$,
    (select v from wf_ids where k = 'employee_a')),
  'P0001', 'WORKFORCE_IMMUTABLE:employment_schedules', 'schedule version start is immutable'
);

-- ---------------------------------------------------------------------------
-- 6. Employee self-service read.
-- ---------------------------------------------------------------------------
select is(
  public.service_workforce_employee_get_profile('17000000-0000-4000-8000-000000000013') -> 'employee' ->> 'display_name',
  'Funcionária A', 'employee resolves only her own profile from the login'
);
select ok(
  not (public.service_workforce_employee_get_profile('17000000-0000-4000-8000-000000000013') ? 'employee_candidates')
  and not ((public.service_workforce_employee_get_profile('17000000-0000-4000-8000-000000000013') -> 'employee') ? 'admin_user_id'),
  'employee profile exposes no administrative data'
);
select throws_ok(
  $$select public.service_workforce_employee_get_profile('17000000-0000-4000-8000-000000000015')$$,
  'P0001', 'WORKFORCE_EMPLOYEE_REQUIRED', 'a login without employment has no Minha Jornada'
);
select throws_ok(
  $$select public.service_workforce_owner_get_setup('17000000-0000-4000-8000-000000000013')$$,
  'P0001', 'WORKFORCE_OWNER_REQUIRED', 'employee cannot call owner endpoints'
);

-- ---------------------------------------------------------------------------
-- 7. Payroll settings (accountant) and holidays.
-- ---------------------------------------------------------------------------
select is(
  public.service_workforce_owner_save_payroll_settings(
    '17000000-0000-4000-8000-000000000011', '17000000-0000-4000-8000-0000000000e1',
    jsonb_build_object('employer_id', (select v from wf_ids where k = 'employer_a'),
      'accountant_name', 'Contadora A', 'accountant_email', 'Contadora@Example.TEST')
  ) -> 'employer' -> 'payroll_settings' ->> 'accountant_email',
  'contadora@example.test', 'accountant e-mail is configured per employer and normalized'
);
select throws_ok(
  format($$select public.service_workforce_owner_save_payroll_settings(
    '17000000-0000-4000-8000-000000000011', '17000000-0000-4000-8000-0000000000e2',
    '{"employer_id":"%s","accountant_email_secondary":"contadora@example.test"}')$$, (select v from wf_ids where k = 'employer_a')),
  'P0001', 'WORKFORCE_ACCOUNTANT_SECONDARY_INVALID', 'secondary accountant e-mail must differ from the primary'
);
select throws_ok(
  format($$select public.service_workforce_owner_save_payroll_settings(
    '17000000-0000-4000-8000-000000000011', '17000000-0000-4000-8000-0000000000e3',
    '{"employer_id":"%s","auto_send_enabled":true}')$$, (select v from wf_ids where k = 'employer_a')),
  'P0001', 'WORKFORCE_PAYLOAD_FIELD_FORBIDDEN:auto_send_enabled', 'automatic sending cannot be enabled in S1'
);

select lives_ok(
  format($$select public.service_workforce_owner_manage_holiday(
    '17000000-0000-4000-8000-000000000011', '17000000-0000-4000-8000-0000000000f1',
    '{"action":"ADD","employer_id":"%s","scope":"MUNICIPAL","name":"Sexta-feira Santa","rule_kind":"EASTER_OFFSET","easter_offset_days":-2}')$$,
    (select v from wf_ids where k = 'employer_a')),
  'owner adds a municipal Easter-relative holiday'
);
select ok(workforce.is_holiday((select v from wf_ids where k = 'employer_a'), '2026-04-03'),
  'municipal Good Friday applies to the employer establishment');
select ok(not workforce.is_holiday((select id from workforce.employers er where er.tenant_id = (select id from public.tenants where slug = 'blacksheep')), '2026-04-03'),
  'municipal holiday of employer A does not leak to other employers');
select throws_ok(
  format($$select public.service_workforce_owner_manage_holiday(
    '17000000-0000-4000-8000-000000000012', '17000000-0000-4000-8000-0000000000f2',
    '{"action":"DEACTIVATE","holiday_id":"%s"}')$$,
    (select id from workforce.holidays where employer_id = (select v from wf_ids where k = 'employer_a'))),
  'P0001', 'WORKFORCE_HOLIDAY_NOT_FOUND', 'tenant B owner cannot deactivate tenant A holiday'
);
select throws_ok(
  format($$select public.service_workforce_owner_manage_holiday(
    '17000000-0000-4000-8000-000000000011', '17000000-0000-4000-8000-0000000000f3',
    '{"action":"DEACTIVATE","holiday_id":"%s"}')$$,
    (select id from workforce.holidays where source = 'FEDERAL_LAW_SEED' and month = 12 and day = 25)),
  'P0001', 'WORKFORCE_HOLIDAY_NOT_FOUND', 'federal holidays cannot be deactivated by an owner'
);

-- ---------------------------------------------------------------------------
-- 8. Audit trail.
-- ---------------------------------------------------------------------------
select ok(
  (select count(*) from workforce.audit_log where tenant_id = '17000000-0000-4000-8000-000000000021') >= 6,
  'owner mutations are audited'
);
select throws_ok(
  $$delete from workforce.audit_log$$,
  'P0001', 'WORKFORCE_IMMUTABLE:audit_log', 'audit log is append-only'
);

select * from finish();
rollback;
