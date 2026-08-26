begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(17);

select has_table('public','notification_template_configs','notification template config table exists');
select has_table('public','notification_template_services','notification service scope table exists');
select has_table('public','notification_template_versions','notification version history exists');
select has_table('public','notification_delivery_logs','notification delivery evidence table exists');
select has_function('public','service_admin_list_notification_templates',array[]::text[],'notification list rpc exists');
select has_function('public','service_admin_upsert_notification_template',array['uuid','text','text','text','text','uuid','text','text','boolean','jsonb','integer','uuid[]','uuid'],'notification mutation rpc exists');
select has_function('public','service_admin_notification_template_versions',array['uuid'],'notification version rpc exists');
select ok(not has_function_privilege('anon','public.service_admin_list_notification_templates()','EXECUTE'),'anon cannot list notification configs');
select ok(not has_function_privilege('authenticated','public.service_admin_list_notification_templates()','EXECUTE'),'authenticated cannot list notification configs');
select ok(has_function_privilege('service_role','public.service_admin_list_notification_templates()','EXECUTE'),'service role can list notification configs');

create temporary table notification_result as
select public.service_admin_upsert_notification_template(
  null,
  'APPOINTMENT_APPROVED',
  'EMAIL',
  'CUSTOMER',
  'BLACKSHEEP',
  null,
  'Reserva {{appointment.public_code}} confirmada',
  'Olá {{customer.name}}',
  false,
  '["appointment.public_code","customer.name"]'::jsonb,
  null,
  '{}'::uuid[],
  '97800000-0000-0000-0000-000000000001'
) id;

select ok((select id is not null from notification_result),'template can be created disabled without activating provider');
select is((select event_key from public.notification_template_configs where id=(select id from notification_result)),'APPOINTMENT_APPROVED','event is persisted');
select is((select is_active from public.notification_template_configs where id=(select id from notification_result)),false,'new template remains explicitly disabled');
select is((select count(*)::integer from public.notification_template_versions where template_id=(select id from notification_result)),1,'create writes version history');
select ok(exists(
  select 1 from public.audit_logs
  where entity_type='NOTIFICATION_TEMPLATE'
    and entity_id=(select id from notification_result)
    and action='CREATE'
    and origin='ADMIN'
),'create writes append-only admin audit event');

select throws_ok(
  $$select public.service_admin_upsert_notification_template(null,'UNKNOWN','EMAIL','CUSTOMER',null,null,'X','',false,'[]'::jsonb,null,'{}'::uuid[],'97800000-0000-0000-0000-000000000001')$$,
  'P0001','NOTIFICATION_EVENT_INVALID','unknown events fail closed'
);
select throws_ok(
  $$select public.service_admin_upsert_notification_template(null,'APPOINTMENT_APPROVED','SMS','CUSTOMER',null,null,'X','',false,'[]'::jsonb,null,'{}'::uuid[],'97800000-0000-0000-0000-000000000001')$$,
  'P0001','NOTIFICATION_CHANNEL_INVALID','unsupported channels fail closed'
);

select * from finish();
rollback;
