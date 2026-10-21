begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(16);

insert into public.tenants(id, name, slug, status)
values ('17700000-0000-4000-8000-000000000099', 'Other tenant', 'rewards-177-other', 'ACTIVE');
insert into auth.users(id, email, created_at, updated_at)
values ('17700000-0000-4000-8000-000000000001', 'rewards-177-owner@example.test', now(), now());
insert into public.admin_users(id, auth_user_id, display_name, role, is_active)
values ('17700000-0000-4000-8000-000000000002', '17700000-0000-4000-8000-000000000001', 'Rewards 177 Owner', 'OWNER', true);
insert into public.marketing_campaigns(id, tenant_id, campaign_key, internal_name)
values ('17700000-0000-4000-8000-000000000010', '8fba3c57-c0e6-4a37-b7d3-4cf41e5fb65f', 'rewards-177', 'Rewards 177');

select ok(
  has_function_privilege('service_role', 'public.service_admin_upsert_rewards_message_template(uuid,uuid,text,text,text,jsonb,uuid)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.service_admin_upsert_rewards_message_template(uuid,uuid,text,text,text,jsonb,uuid)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.service_admin_upsert_rewards_message_template(uuid,uuid,text,text,text,jsonb,uuid)', 'EXECUTE'),
  'the Rewards template upsert is executable only by the trusted backend'
);
select ok(
  has_table_privilege('service_role', 'public.marketing_campaign_message_templates', 'SELECT')
  and not has_table_privilege('service_role', 'public.marketing_campaign_message_templates', 'INSERT')
  and not has_table_privilege('anon', 'public.marketing_campaign_message_templates', 'SELECT')
  and not has_table_privilege('authenticated', 'public.marketing_campaign_message_templates', 'SELECT'),
  'campaign template links are written only through the audited RPC'
);

select set_config('agenda.r177.issued', public.service_admin_upsert_rewards_message_template(
  '8fba3c57-c0e6-4a37-b7d3-4cf41e5fb65f', '17700000-0000-4000-8000-000000000010', 'rewards_coupon_issued',
  'Cupom liberado', 'Oi {{customer.name}}, seu cupom {{coupon.code}} já está liberado.', '["customer.name","coupon.code"]'::jsonb,
  '17700000-0000-4000-8000-000000000002'
)::text, true);

select is(
  (select row(event_key, channel, audience, operation_scope, is_active)::text from public.notification_template_configs
   where id = current_setting('agenda.r177.issued')::uuid),
  row('REWARDS_COUPON_ISSUED', 'WHATSAPP', 'CUSTOMER', 'BLACKSHEEP', false)::text,
  'creates an inactive BlackSheep customer WhatsApp draft'
);
select is(
  (select template_id::text from public.marketing_campaign_message_templates
   where campaign_id = '17700000-0000-4000-8000-000000000010' and event_key = 'REWARDS_COUPON_ISSUED'),
  current_setting('agenda.r177.issued'),
  'links the draft to its campaign and event'
);
select is(
  (select count(*)::integer from public.notification_template_services where template_id = current_setting('agenda.r177.issued')::uuid),
  0,
  'Rewards drafts are not tied to rental services'
);

select is(
  public.service_admin_upsert_rewards_message_template(
    '8fba3c57-c0e6-4a37-b7d3-4cf41e5fb65f', '17700000-0000-4000-8000-000000000010', 'REWARDS_COUPON_ISSUED',
    'Cupom liberado', 'Oi {{customer.name}}, seu cupom {{coupon.code}} vale até {{coupon.expires_at}}.', '["customer.name","coupon.code","coupon.expires_at"]'::jsonb,
    '17700000-0000-4000-8000-000000000002'
  )::text,
  current_setting('agenda.r177.issued'),
  'editing the same campaign event updates the same draft'
);
select is(
  (select count(*)::integer from public.notification_template_versions where template_id = current_setting('agenda.r177.issued')::uuid),
  2,
  'each save adds a version'
);
select is(
  (select array_agg(action order by created_at) from public.audit_logs
   where entity_type = 'NOTIFICATION_TEMPLATE' and entity_id = current_setting('agenda.r177.issued')::uuid),
  array['CREATE', 'UPDATE'],
  'creation and edit are audited'
);

select isnt(
  public.service_admin_upsert_rewards_message_template(
    '8fba3c57-c0e6-4a37-b7d3-4cf41e5fb65f', '17700000-0000-4000-8000-000000000010', 'REWARDS_WINBACK',
    'Volte ao estúdio', 'Faz tempo, {{customer.name}}! Use {{coupon.code}} na próxima locação.', '["customer.name","coupon.code"]'::jsonb,
    '17700000-0000-4000-8000-000000000002'
  )::text,
  current_setting('agenda.r177.issued'),
  'each event of a campaign has its own draft'
);

select ok(
  public.service_admin_upsert_rewards_message_template(
    '8fba3c57-c0e6-4a37-b7d3-4cf41e5fb65f', '17700000-0000-4000-8000-000000000010', 'REWARDS_REFERRAL_REWARD',
    'Indicação premiada', 'Obrigado, {{customer.name}}! {{referral.referred_name}} locou e você ganhou o cupom {{coupon.code}}.',
    '["customer.name","referral.referred_name","coupon.code"]'::jsonb, '17700000-0000-4000-8000-000000000002'
  ) is not null,
  'referral messages are campaign drafts too'
);

select throws_ok(
  $$select public.service_admin_upsert_rewards_message_template(
    '17700000-0000-4000-8000-000000000099', '17700000-0000-4000-8000-000000000010', 'REWARDS_WINBACK',
    'x', 'y', '[]'::jsonb, '17700000-0000-4000-8000-000000000002')$$,
  'P0001', 'REWARDS_CAMPAIGN_NOT_FOUND',
  'another tenant cannot write a campaign''s messages'
);
select throws_ok(
  $$select public.service_admin_upsert_rewards_message_template(
    '8fba3c57-c0e6-4a37-b7d3-4cf41e5fb65f', '17700000-0000-4000-8000-000000000010', 'APPOINTMENT_APPROVED',
    'x', 'y', '[]'::jsonb, '17700000-0000-4000-8000-000000000002')$$,
  'P0001', 'NOTIFICATION_EVENT_INVALID',
  'only Rewards events go through the Rewards upsert'
);
select throws_ok(
  $$select public.service_admin_upsert_notification_template_v2(
    null, 'REWARDS_COUPON_ISSUED', 'WHATSAPP', 'CUSTOMER', 'BLACKSHEEP', null, 'x', 'y', null, false, '[]'::jsonb, null, '{}'::uuid[],
    '17700000-0000-4000-8000-000000000002')$$,
  'P0001', 'NOTIFICATION_EVENT_INVALID',
  'the rental editor path cannot create Rewards drafts'
);
select throws_ok(
  $$update public.notification_template_configs set is_active = true where id = current_setting('agenda.r177.issued')::uuid$$,
  '23514', null,
  'a Rewards WhatsApp draft can never be activated'
);
select is(
  (select count(*)::integer from public.integration_jobs where payload_json->>'event_key' like 'REWARDS_%'),
  0,
  'no delivery job exists for Rewards events'
);

select lives_ok(
  $$insert into public.notification_whatsapp_settings(template_id, category, button_text, button_variable)
    values (current_setting('agenda.r177.issued')::uuid, 'MARKETING', 'Reservar com cupom', 'booking.url')$$,
  'a Rewards draft may carry a button to the booking page'
);

select * from finish();
rollback;
