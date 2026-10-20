begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(4);

select has_column('public', 'notification_whatsapp_settings', 'button_text', 'a WhatsApp draft can label a URL button');
select has_column('public', 'notification_whatsapp_settings', 'button_variable', 'a WhatsApp draft chooses the customer link behind the button');
select throws_ok(
  $$insert into public.notification_whatsapp_settings(template_id, button_text)
    values (gen_random_uuid(), 'Gerenciar reserva')$$,
  '23514',
  null,
  'a button needs both its label and its link'
);
select throws_ok(
  $$insert into public.notification_whatsapp_settings(template_id, button_text, button_variable)
    values (gen_random_uuid(), 'Abrir', 'customer.email')$$,
  '23514',
  null,
  'only customer links may sit behind a button'
);

select * from finish();
rollback;
