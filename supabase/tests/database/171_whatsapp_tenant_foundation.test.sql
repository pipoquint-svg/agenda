begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(8);

select has_table('public', 'whatsapp_tenant_integrations', 'tenant WhatsApp integrations are stored separately from credentials');
select has_table('public', 'whatsapp_tenant_phone_numbers', 'one integration can own future phone-number records');
select has_table('public', 'whatsapp_template_submissions', 'template submission state is auditable');
select col_is_pk('public', 'whatsapp_tenant_integrations', 'id', 'integration has a stable primary key');
select col_is_fk('public', 'whatsapp_tenant_integrations', 'tenant_id', 'integration belongs to the canonical tenant');
select col_is_fk('public', 'whatsapp_template_submissions', 'notification_template_id', 'submission references an existing notification draft');
select ok(
  not has_table_privilege('anon', 'public.whatsapp_tenant_integrations', 'SELECT'),
  'anon cannot access provider integration state'
);
select ok(
  not has_table_privilege('authenticated', 'public.whatsapp_template_submissions', 'SELECT'),
  'authenticated users cannot access submission state directly'
);

select * from finish();
rollback;
