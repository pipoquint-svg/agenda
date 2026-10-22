begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(4);

create function pg_temp.save(p_id uuid, p_body text, p_active boolean) returns uuid language sql as $$
  select public.service_admin_upsert_notification_template_v3(
    p_id, 'APPOINTMENT_REMINDER', 'WHATSAPP', 'CUSTOMER', 'BLACKSHEEP', null,
    'Lembrete 185', p_body, null, p_active, '["customer.name"]'::jsonb, null, '{}'::uuid[],
    '97800000-0000-0000-0000-000000000001', 'BEFORE_START', 2880)
$$;

create temporary table t185 as select pg_temp.save(null, 'Olá {{customer.name}}', true) id;
select is((select is_active from public.notification_template_configs where id = (select id from t185)), false,
  'a new WhatsApp message starts off');

update public.notification_template_configs set is_active = true where id = (select id from t185);
select pg_temp.save((select id from t185), 'Olá {{customer.name}}, chegue 10 minutos antes.', false);
select is((select is_active from public.notification_template_configs where id = (select id from t185)), true,
  'editing an active WhatsApp message keeps it on');
select is((select body_template from public.notification_template_configs where id = (select id from t185)),
  'Olá {{customer.name}}, chegue 10 minutos antes.', 'and saves the new text');

update public.notification_template_configs set is_active = false where id = (select id from t185);
select pg_temp.save((select id from t185), 'Olá {{customer.name}}', true);
select is((select is_active from public.notification_template_configs where id = (select id from t185)), false,
  'saving never turns a WhatsApp message on');

select * from finish();
rollback;
