begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(12);

select has_table('public','kommo_integration_settings','Kommo settings table exists');
select has_table('public','kommo_customer_links','Kommo contact mapping exists');
select has_table('public','kommo_appointment_links','Kommo lead mapping exists');

select is((select enabled from public.kommo_integration_settings where id=1), false, 'Kommo starts disabled');
select is((select operation_scope from public.kommo_integration_settings where id=1), 'BLACKSHEEP', 'Kommo is BlackSheep-only');
select is((select booking_mailbox from public.kommo_integration_settings where id=1), 'agenda@blacksheepestudiocriativo.com.br', 'BlackSheep booking mailbox is recorded');

select ok(
  not has_function_privilege('anon','public.get_kommo_appointment_desired_state(uuid)','EXECUTE'),
  'anon cannot read Kommo desired state'
);
select ok(
  not has_function_privilege('authenticated','public.enqueue_kommo_appointment_sync(uuid,text)','EXECUTE'),
  'authenticated users cannot enqueue Kommo jobs'
);
select ok(
  exists(select 1 from pg_trigger where tgrelid='public.appointments'::regclass and tgname='appointments_enqueue_kommo_sync' and not tgisinternal),
  'appointment Kommo outbox trigger exists'
);

select is(
  (select is_active from public.message_templates where template_key='checkout_hold_expired_recovery'),
  false,
  'direct WhatsApp recovery template is inactive'
);
select ok(
  not has_function_privilege('anon','public.set_checkout_hold_recovery_contact(text,text,boolean)','EXECUTE'),
  'public recovery contact setter is retired'
);
select ok(
  position('CHECKOUT_HOLD_EXPIRED_RECOVERY' in pg_get_functiondef('public.expire_due_checkout_holds()'::regprocedure)) = 0,
  'hold expiry no longer enqueues direct WhatsApp recovery'
);

select * from finish();
rollback;
