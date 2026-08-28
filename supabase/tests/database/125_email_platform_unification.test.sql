begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(11);

select ok(
  pg_get_constraintdef((
    select oid from pg_constraint
    where conrelid = 'public.notification_template_configs'::regclass
      and conname = 'notification_template_configs_event_key_check'
  )) like '%RENTAL_BALANCE_DUE%',
  'notification templates accept the rental balance due event'
);

select has_column('public', 'notification_delivery_logs', 'is_test', 'delivery logs distinguish test sends from operational sends');
select has_column('public', 'notification_delivery_logs', 'recipient_masked', 'delivery history retains a safe recipient hint');

select has_function(
  'public',
  'service_admin_list_notification_delivery_logs',
  array['text','text','text','integer','integer'],
  'admin delivery history RPC exists'
);

select ok(
  not has_function_privilege('anon', 'public.service_admin_list_notification_delivery_logs(text,text,text,integer,integer)', 'EXECUTE'),
  'anon cannot read notification delivery history'
);

select ok(
  not has_function_privilege('authenticated', 'public.service_admin_list_notification_delivery_logs(text,text,text,integer,integer)', 'EXECUTE'),
  'authenticated cannot read notification delivery history directly'
);

select ok(
  has_function_privilege('service_role', 'public.service_admin_list_notification_delivery_logs(text,text,text,integer,integer)', 'EXECUTE'),
  'service_role can read notification delivery history'
);

select ok(
  exists (
    select 1 from public.notification_template_configs
    where event_key = 'RENTAL_BALANCE_DUE' and channel = 'EMAIL' and audience = 'CUSTOMER' and operation_scope = 'BLACKSHEEP'
  ),
  'a BlackSheep balance email template is seeded'
);

select ok(
  exists (
    select 1 from public.notification_template_configs
    where event_key = 'RENTAL_BALANCE_DUE' and variable_schema @> '["balance.payment_url"]'::jsonb
  ),
  'balance template exposes the payment URL as an editable variable'
);

select ok(
  exists (
    select 1 from public.notification_template_configs
    where event_key = 'APPOINTMENT_APPROVED' and channel = 'EMAIL' and audience = 'CUSTOMER' and operation_scope = 'BLACKSHEEP'
  ),
  'BlackSheep reservation confirmation has an editable database template'
);

select ok(
  exists (
    select 1 from public.notification_template_configs
    where event_key = 'APPOINTMENT_APPROVED' and channel = 'EMAIL' and audience = 'CUSTOMER' and operation_scope = 'SABRINA'
  ),
  'Sabrina reservation confirmation has an editable database template'
);

select * from finish();
rollback;
