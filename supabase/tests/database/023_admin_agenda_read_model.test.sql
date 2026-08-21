begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(10);

select has_function(
  'public', 'service_admin_list_agenda', array['timestamp with time zone','timestamp with time zone'],
  'admin operational agenda read model exists'
);

select has_function(
  'public', 'service_admin_get_appointment', array['uuid'],
  'admin appointment detail read model exists'
);

select has_function(
  'public', 'service_admin_list_amelia_history', array['timestamp with time zone','timestamp with time zone','text'],
  'separate Amelia history read model exists'
);

select ok(
  not has_function_privilege('anon', 'public.service_admin_list_agenda(timestamptz,timestamptz)', 'EXECUTE'),
  'anonymous users cannot read the operational admin agenda'
);

select ok(
  not has_function_privilege('authenticated', 'public.service_admin_get_appointment(uuid)', 'EXECUTE'),
  'authenticated browser users cannot bypass the admin backend for appointment details'
);

select ok(
  has_function_privilege('service_role', 'public.service_admin_list_amelia_history(timestamptz,timestamptz,text)', 'EXECUTE'),
  'service role can read Amelia history after admin authentication is checked by the Edge Function'
);

select throws_ok(
  $$ select public.service_admin_list_agenda('2030-01-01 00:00:00-03'::timestamptz, '2030-03-01 00:00:00-03'::timestamptz) $$,
  'P0001', 'ADMIN_AGENDA_RANGE_TOO_LARGE',
  'operational agenda rejects ranges above 31 days'
);

select throws_ok(
  $$ select public.service_admin_list_amelia_history('2030-01-01 00:00:00-03'::timestamptz, '2032-01-01 00:00:00-03'::timestamptz, null) $$,
  'P0001', 'ADMIN_AMELIA_RANGE_TOO_LARGE',
  'Amelia history rejects excessive ranges'
);

select is(
  jsonb_typeof(public.service_admin_list_agenda('2040-01-01 00:00:00-03'::timestamptz, '2040-01-02 00:00:00-03'::timestamptz)->'appointments'),
  'array',
  'operational agenda always returns an appointments array'
);

select is(
  jsonb_typeof(public.service_admin_list_amelia_history('2040-01-01 00:00:00-03'::timestamptz, '2040-01-02 00:00:00-03'::timestamptz, null)->'records'),
  'array',
  'Amelia history always returns a separate records array'
);

select * from finish();
rollback;
