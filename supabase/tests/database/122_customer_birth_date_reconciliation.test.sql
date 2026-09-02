begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(15);

select has_function(
  'public','service_admin_list_customer_birth_date_candidates',array['uuid','uuid'],
  'canonical customer birth-date reconciliation read model exists'
);
select ok(
  (select p.prosecdef
   from pg_proc p
   join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.oid = 'public.service_admin_list_customer_birth_date_candidates(uuid,uuid)'::regprocedure),
  'candidate read model is SECURITY DEFINER'
);
select is(
  (select p.proconfig::text
   from pg_proc p
   join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.oid = 'public.service_admin_list_customer_birth_date_candidates(uuid,uuid)'::regprocedure),
  '{"search_path=public, pg_temp"}',
  'candidate read model pins search_path'
);
select ok(
  not has_function_privilege('anon','public.service_admin_list_customer_birth_date_candidates(uuid,uuid)','EXECUTE'),
  'anon cannot list birth-date candidates'
);
select ok(
  not has_function_privilege('authenticated','public.service_admin_list_customer_birth_date_candidates(uuid,uuid)','EXECUTE'),
  'authenticated cannot list birth-date candidates directly'
);
select ok(
  has_function_privilege('service_role','public.service_admin_list_customer_birth_date_candidates(uuid,uuid)','EXECUTE'),
  'service role can call the admin reconciliation read model'
);
select ok(
  position('CUSTOMERS_VIEW' in pg_get_functiondef('public.service_admin_list_customer_birth_date_candidates(uuid,uuid)'::regprocedure)) > 0,
  'candidate read model enforces customer-view permission server-side'
);
select ok(
  position('legacy_customer_sources' in pg_get_functiondef('public.service_admin_list_customer_birth_date_candidates(uuid,uuid)'::regprocedure)) > 0
  and position('service_admin_set_customer_birth_date' in pg_get_functiondef('public.service_admin_list_customer_birth_date_candidates(uuid,uuid)'::regprocedure)) = 0
  and position('update public.customers' in lower(pg_get_functiondef('public.service_admin_list_customer_birth_date_candidates(uuid,uuid)'::regprocedure))) = 0,
  'candidate read model reads linked legacy snapshots and never promotes canonical birth date implicitly'
);

insert into auth.users(id,instance_id,aud,role,email,encrypted_password,created_at,updated_at)
values(
  '14500000-0000-4000-8000-000000000001',
  '00000000-0000-0000-0000-000000000000',
  'authenticated','authenticated','item02a-owner@example.test','',now(),now()
);

insert into public.admin_users(id,auth_user_id,display_name,role)
values(
  '24500000-0000-4000-8000-000000000001',
  '14500000-0000-4000-8000-000000000001',
  'Item 2A Owner','OWNER'
);

insert into public.customers(id,customer_type,name,email,phone,birth_date)
values
  ('34500000-0000-4000-8000-000000000001','PERSON','Item 2A Target','item02a-target@example.test','48999990010',null),
  ('34500000-0000-4000-8000-000000000002','PERSON','Item 2A Unrelated','item02a-unrelated@example.test','48999990011',null);

insert into public.legacy_import_batches(id,source,source_label,status)
values('44500000-0000-4000-8000-000000000001','ITEM02A_TEST','Item 2A birth-date reconciliation','IMPORTED');

insert into public.legacy_customer_sources(
  batch_id,source,source_key,customer_id,match_method,match_confidence,raw_snapshot
) values
  (
    '44500000-0000-4000-8000-000000000001','ITEM02A_A','target-ddmmyyyy',
    '34500000-0000-4000-8000-000000000001','EMAIL','HIGH',
    '{"birth_date":"14/09/1990"}'::jsonb
  ),
  (
    '44500000-0000-4000-8000-000000000001','ITEM02A_B','target-iso-same-date',
    '34500000-0000-4000-8000-000000000001','EMAIL','HIGH',
    '{"birth_date":"1990-09-14"}'::jsonb
  ),
  (
    '44500000-0000-4000-8000-000000000001','ITEM02A_C','target-second-date',
    '34500000-0000-4000-8000-000000000001','EMAIL','HIGH',
    '{"birth_date":"2001-02-03"}'::jsonb
  ),
  (
    '44500000-0000-4000-8000-000000000001','ITEM02A_D','target-invalid-date',
    '34500000-0000-4000-8000-000000000001','EMAIL','HIGH',
    '{"birth_date":"not-a-date"}'::jsonb
  ),
  (
    '44500000-0000-4000-8000-000000000001','ITEM02A_E','unrelated-date',
    '34500000-0000-4000-8000-000000000002','EMAIL','HIGH',
    '{"birth_date":"1988-01-01"}'::jsonb
  );

select is(
  public.service_admin_list_customer_birth_date_candidates(
    '34500000-0000-4000-8000-000000000001'::uuid,
    '24500000-0000-4000-8000-000000000001'::uuid
  )->>'canonical_birth_date',
  null::text,
  'customer without canonical birth date reports null canonical value'
);

select is(
  jsonb_array_length(
    public.service_admin_list_customer_birth_date_candidates(
      '34500000-0000-4000-8000-000000000001'::uuid,
      '24500000-0000-4000-8000-000000000001'::uuid
    )->'candidates'
  ),
  2,
  'only valid linked legacy dates become candidates'
);

select is(
  public.service_admin_list_customer_birth_date_candidates(
    '34500000-0000-4000-8000-000000000001'::uuid,
    '24500000-0000-4000-8000-000000000001'::uuid
  )->'candidates'->0->>'birth_date',
  '1990-09-14',
  'most frequent candidate is ordered first and DD/MM/YYYY is normalized'
);

select is(
  (public.service_admin_list_customer_birth_date_candidates(
    '34500000-0000-4000-8000-000000000001'::uuid,
    '24500000-0000-4000-8000-000000000001'::uuid
  )->'candidates'->0->>'occurrence_count')::integer,
  2,
  'equal dates from linked legacy snapshots are aggregated'
);

select is(
  public.service_admin_list_customer_birth_date_candidates(
    '34500000-0000-4000-8000-000000000001'::uuid,
    '24500000-0000-4000-8000-000000000001'::uuid
  )->'candidates'->1->>'birth_date',
  '2001-02-03',
  'second distinct valid linked date is preserved as a candidate'
);

select is(
  (public.service_admin_list_customer_birth_date_candidates(
    '34500000-0000-4000-8000-000000000001'::uuid,
    '24500000-0000-4000-8000-000000000001'::uuid
  )->>'has_conflict')::boolean,
  true,
  'multiple distinct candidate dates are reported as a conflict'
);

select ok(
  (select birth_date is null from public.customers where id='34500000-0000-4000-8000-000000000001'::uuid),
  'reading reconciliation candidates never mutates canonical customer birth date'
);

select * from finish();
rollback;
