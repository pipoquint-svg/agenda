begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(18);

-- Retention is explicit and non-destructive by default.
select is((select retention_mode from public.audit_retention_policy where id = 1),'INDEFINITE','retention mode is explicitly indefinite');
select is((select automatic_purge from public.audit_retention_policy where id = 1),false,'automatic audit purge is disabled');
select is((select retention_days from public.audit_retention_policy where id = 1),null::integer,'indefinite retention has no arbitrary day count');

-- Application-facing PostgreSQL roles do not receive destructive privileges.
select ok(not has_table_privilege('anon','public.audit_logs','UPDATE'),'anon cannot update audit logs');
select ok(not has_table_privilege('authenticated','public.audit_logs','DELETE'),'authenticated cannot delete audit logs');
select ok(not has_table_privilege('service_role','public.audit_logs','UPDATE'),'service_role cannot update audit logs directly');
select ok(not has_table_privilege('service_role','public.audit_logs','DELETE'),'service_role cannot delete audit logs directly');
select ok(not has_table_privilege('service_role','public.audit_logs','TRUNCATE'),'service_role cannot truncate audit logs');
select ok(not has_function_privilege('service_role','public.maintenance_purge_audit_logs(timestamptz,text,text)','EXECUTE'),'service_role cannot invoke maintenance purge');

insert into public.audit_logs(id,admin_user_id,entity_type,entity_id,action,before_json,after_json,origin,created_at)
values
 ('aa000000-0000-0000-0000-000000000001',null,'TEST','aa000000-0000-0000-0000-000000000101','BEFORE_CUTOFF',null,'{}'::jsonb,'TEST','2026-01-01 00:00:00+00'),
 ('aa000000-0000-0000-0000-000000000002',null,'TEST','aa000000-0000-0000-0000-000000000102','AT_CUTOFF',null,'{}'::jsonb,'TEST','2026-02-01 00:00:00+00'),
 ('aa000000-0000-0000-0000-000000000003',null,'TEST','aa000000-0000-0000-0000-000000000103','AFTER_CUTOFF',null,'{}'::jsonb,'TEST','2026-02-01 00:00:01+00');

-- Even database-owner direct mutation is rejected unless it comes through the guarded purge path.
select throws_ok(
  $$update public.audit_logs set action='TAMPERED' where id='aa000000-0000-0000-0000-000000000001'$$,
  '42501','AUDIT_TRAIL_APPEND_ONLY','direct update is rejected by database policy'
);
select throws_ok(
  $$delete from public.audit_logs where id='aa000000-0000-0000-0000-000000000001'$$,
  '42501','AUDIT_TRAIL_APPEND_ONLY','direct delete is rejected by database policy'
);
select throws_ok(
  $$truncate table public.audit_logs$$,
  '42501','AUDIT_TRAIL_APPEND_ONLY','truncate is rejected by database policy'
);

-- Dedicated maintenance purge removes only rows strictly older than the cutoff.
select is(
  public.maintenance_purge_audit_logs(
    '2026-02-01 00:00:00+00'::timestamptz,
    'Court-approved retention exception for test',
    'database-maintenance'
  ),
  1::bigint,
  'maintenance purge reports exactly one row removed'
);
select is((select count(*)::integer from public.audit_logs where id='aa000000-0000-0000-0000-000000000001'),0,'row before cutoff is removed');
select is((select count(*)::integer from public.audit_logs where id='aa000000-0000-0000-0000-000000000002'),1,'row exactly at cutoff is preserved');
select is((select count(*)::integer from public.audit_logs where id='aa000000-0000-0000-0000-000000000003'),1,'row after cutoff is preserved');
select is((select rows_planned from public.audit_purge_runs order by created_at desc,id desc limit 1),1::bigint,'purge evidence records planned row count before removal');
select throws_ok(
  $$update public.audit_purge_runs set reason='tampered evidence' where id=(select id from public.audit_purge_runs order by created_at desc,id desc limit 1)$$,
  '42501','AUDIT_TRAIL_APPEND_ONLY','purge evidence is itself append-only'
);

select * from finish();
rollback;
