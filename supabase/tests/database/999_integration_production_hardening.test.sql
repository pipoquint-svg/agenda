begin;
select plan(15);

select ok(not has_table_privilege('anon', 'public.customers', 'SELECT'), 'anon cannot read customers directly');
select ok(not has_table_privilege('anon', 'public.appointments', 'SELECT'), 'anon cannot read appointments directly');
select ok(not has_table_privilege('anon', 'public.payment_transactions', 'SELECT'), 'anon cannot read payments directly');
select ok(not has_table_privilege('anon', 'public.integration_jobs', 'SELECT'), 'anon cannot read integration queue directly');
select ok(not has_table_privilege('anon', 'public.google_connections', 'SELECT'), 'anon cannot read Google connections directly');

select ok(not has_table_privilege('authenticated', 'public.customers', 'SELECT'), 'authenticated cannot read customers directly');
select ok(not has_table_privilege('authenticated', 'public.appointments', 'UPDATE'), 'authenticated cannot mutate appointments directly');
select ok(not has_table_privilege('authenticated', 'public.payment_transactions', 'INSERT'), 'authenticated cannot insert payments directly');
select ok(not has_table_privilege('authenticated', 'public.integration_jobs', 'DELETE'), 'authenticated cannot mutate integration queue directly');
select ok(not has_table_privilege('authenticated', 'public.google_connections', 'SELECT'), 'authenticated cannot read Google credentials/connections directly');

select ok(has_function_privilege('anon', 'public.public_get_booking_page(text)', 'EXECUTE'), 'anon can execute public booking page RPC');
select ok(has_function_privilege('anon', 'public.public_list_available_slots_duration(text,uuid,uuid,integer,jsonb,integer,date)', 'EXECUTE'), 'anon can execute public duration slots RPC');
select ok(has_function_privilege('anon', 'public.public_quote_booking_duration(text,uuid,uuid,integer,jsonb,integer)', 'EXECUTE'), 'anon can execute public duration quote RPC');
select ok(not has_schema_privilege('anon', 'public', 'CREATE'), 'anon cannot shadow SECURITY DEFINER dependencies in public schema');
select ok(not has_schema_privilege('authenticated', 'public', 'CREATE'), 'authenticated cannot shadow SECURITY DEFINER dependencies in public schema');

select * from finish();
rollback;
