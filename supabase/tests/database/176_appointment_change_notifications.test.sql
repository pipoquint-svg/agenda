begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(5);

select has_trigger('public', 'appointments', 'appointments_enqueue_confirmation_email_on_change', 'confirmed reservation changes still enqueue customer messages');
select ok(
  pg_get_functiondef('public.enqueue_confirmation_email_on_confirmed_appointment_change()'::regprocedure) like '%APPOINTMENT_RESCHEDULED%previous_start_at%',
  'a new date or time is announced as a reschedule with the previous times'
);
select ok(
  pg_get_functiondef('public.enqueue_confirmation_email_on_confirmed_appointment_change()'::regprocedure) like '%new.status = ''CANCELLED''%APPOINTMENT_CANCELLED%',
  'cancelling a confirmed reservation enqueues the cancellation message'
);
select ok(
  not has_function_privilege('anon', 'public.enqueue_confirmation_email_on_confirmed_appointment_change()', 'EXECUTE'),
  'anon cannot call the trigger function'
);
select ok(
  not has_function_privilege('authenticated', 'public.enqueue_confirmation_email_on_confirmed_appointment_change()', 'EXECUTE'),
  'authenticated users cannot call the trigger function'
);

select * from finish();
rollback;
