begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(6);

select ok(
  exists (
    select 1 from pg_constraint c
    join pg_class t on t.oid = c.conrelid
    join pg_namespace n on n.oid = t.relnamespace
    where n.nspname = 'public'
      and t.relname = 'notification_template_configs'
      and c.conname = 'notification_template_configs_channel_check'
      and pg_get_constraintdef(c.oid) like '%WHATSAPP%'
  ),
  'notification templates accept WhatsApp only as a stored channel'
);

create temporary table whatsapp_draft as
select public.service_admin_upsert_notification_template_v3(
  null,
  'APPOINTMENT_APPROVED',
  'WHATSAPP',
  'CUSTOMER',
  'BLACKSHEEP',
  null,
  'Confirmação de reserva',
  'Olá {{customer.name}}',
  null,
  true,
  '["customer.name"]'::jsonb,
  null,
  '{}'::uuid[],
  '97800000-0000-0000-0000-000000000001',
  'IMMEDIATE',
  null
) id;

select is(
  (select channel from public.notification_template_configs where id = (select id from whatsapp_draft)),
  'WHATSAPP',
  'WhatsApp draft is persisted through the current admin RPC'
);

select is(
  (select is_active from public.notification_template_configs where id = (select id from whatsapp_draft)),
  false,
  'WhatsApp draft stays inactive even when activation is requested'
);

select is(
  (select count(*)::integer from public.notification_template_versions where template_id = (select id from whatsapp_draft)),
  1,
  'WhatsApp draft keeps the same version audit trail'
);

select ok(
  not exists (
    select 1 from public.notification_template_configs
    where id = (select id from whatsapp_draft)
      and is_active
  ),
  'WhatsApp draft cannot become dispatchable in this slice'
);

-- Since 20261021080000_whatsapp_dispatch_go_live the database no longer blocks an
-- active WhatsApp template: activation is done there only for templates approved by
-- Meta, and whatsapp-send re-checks approval and WHATSAPP_CUSTOMER_DISPATCH_ENABLED.
select lives_ok(
  $$update public.notification_template_configs
      set is_active = true
    where id = (select id from whatsapp_draft)$$,
  'database allows activating a WhatsApp template after go-live'
);

select * from finish();
rollback;
