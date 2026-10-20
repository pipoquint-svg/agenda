begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(7);

select has_table('public', 'notification_whatsapp_settings', 'WhatsApp draft fields live beside the notification template');
select col_is_pk('public', 'notification_whatsapp_settings', 'template_id', 'one settings row per template');
select col_is_fk('public', 'notification_whatsapp_settings', 'template_id', 'settings belong to an existing template');
select ok(
  not has_table_privilege('anon', 'public.notification_whatsapp_settings', 'SELECT'),
  'anon cannot read WhatsApp draft settings'
);
select ok(
  not has_table_privilege('authenticated', 'public.notification_whatsapp_settings', 'INSERT'),
  'authenticated users cannot write WhatsApp draft settings directly'
);
select throws_ok(
  $$insert into public.notification_whatsapp_settings(template_id, category, ttl_seconds)
    values (gen_random_uuid(), 'MARKETING', 600)$$,
  '23514',
  null,
  'a custom validity is accepted only for utility templates'
);
select throws_ok(
  $$insert into public.notification_whatsapp_settings(template_id, footer_text)
    values (gen_random_uuid(), 'Responda {{customer.name}}')$$,
  '23514',
  null,
  'the footer cannot carry variables'
);

select * from finish();
rollback;
