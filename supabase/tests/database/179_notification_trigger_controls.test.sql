begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(7);

create temporary table trigger_template as
select public.service_admin_upsert_notification_template_v3(
  null,
  'APPOINTMENT_REMINDER',
  'EMAIL',
  'CUSTOMER',
  'BLACKSHEEP',
  null,
  'Lembrete',
  'Olá {{customer.name}}',
  null,
  false,
  '["customer.name"]'::jsonb,
  null,
  '{}'::uuid[],
  '97900000-0000-0000-0000-000000000001',
  'BEFORE_START',
  60
) id;

create temporary table content_before as
select updated_at, body_template from public.notification_template_configs
where id = (select id from trigger_template);

select lives_ok(
  $$select public.service_admin_update_notification_trigger_v1(
      (select id from trigger_template), 'AFTER_START', 30, '{}'::uuid[],
      '97900000-0000-0000-0000-000000000001')$$,
  'trigger can move to after the start'
);

select is(
  (select schedule_mode || ':' || schedule_offset_minutes from public.notification_template_configs where id = (select id from trigger_template)),
  'AFTER_START:30',
  'only the trigger fields change'
);

select is(
  (select updated_at from public.notification_template_configs where id = (select id from trigger_template)),
  (select updated_at from content_before),
  'saving the trigger keeps updated_at, so an approved WhatsApp model stays approved'
);

select ok(
  (select trigger_updated_at is not null from public.notification_template_configs where id = (select id from trigger_template)),
  'trigger change is stamped separately'
);

select lives_ok(
  $$select public.service_admin_update_notification_trigger_v1(
      (select id from trigger_template), 'BEFORE_END', 15, '{}'::uuid[],
      '97900000-0000-0000-0000-000000000001')$$,
  'trigger accepts before the end'
);

select throws_ok(
  $$select public.service_admin_update_notification_trigger_v1(
      (select id from trigger_template), 'AFTER_START', null, '{}'::uuid[],
      '97900000-0000-0000-0000-000000000001')$$,
  'P0001',
  'NOTIFICATION_SCHEDULE_OFFSET_INVALID',
  'a timed trigger needs an offset'
);

select ok(
  exists (
    select 1 from public.audit_logs
    where entity_id = (select id from trigger_template) and action = 'UPDATE_TRIGGER'
  ),
  'trigger changes are audited'
);

select * from finish();
rollback;
