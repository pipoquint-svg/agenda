begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(24);

-- Deterministic clock: the first three requests in a 10-minute window are accepted.
select is((public.service_consume_public_rate_limit_at('TEST_LIMIT','client-a',3,600,'2030-01-01 10:00:00+00')->>'count')::integer,1,'first request starts bucket at 1');
select is((public.service_consume_public_rate_limit_at('TEST_LIMIT','client-a',3,600,'2030-01-01 10:00:01+00')->>'count')::integer,2,'second request shares the same bucket');
select is((public.service_consume_public_rate_limit_at('TEST_LIMIT','client-a',3,600,'2030-01-01 10:00:02+00')->>'count')::integer,3,'request exactly at configured limit is accepted');
select throws_ok(
  $$select public.service_consume_public_rate_limit_at('TEST_LIMIT','client-a',3,600,'2030-01-01 10:09:59+00')$$,
  'P0001','RATE_LIMITED','one second before reset remains rate limited'
);
select is((public.service_consume_public_rate_limit_at('TEST_LIMIT','client-a',3,600,'2030-01-01 10:10:00+00')->>'count')::integer,1,'exact reset boundary starts a new window');
select is((public.service_consume_public_rate_limit_at('TEST_LIMIT','client-a',3,600,'2030-01-01 10:10:01+00')->>'count')::integer,2,'one second after reset remains in new window');

-- Keys are isolated and raw identifying material is not persisted.
select is((public.service_consume_public_rate_limit_at('TEST_LIMIT','client-b',3,600,'2030-01-01 10:00:03+00')->>'count')::integer,1,'different client key gets independent bucket');
select is((select count(*)::integer from public.public_rate_limit_buckets where key_hash='client-a'),0,'raw client key is never stored');
select ok((select bool_and(key_hash ~ '^[0-9a-f]{64}$') from public.public_rate_limit_buckets),'persisted keys are SHA-256 hashes');

-- Application roles cannot tamper with counters. Only the SECURITY DEFINER consumer is exposed.
select ok(not has_table_privilege('anon','public.public_rate_limit_buckets','SELECT'),'anon cannot inspect limiter buckets');
select ok(not has_table_privilege('authenticated','public.public_rate_limit_buckets','UPDATE'),'authenticated cannot reset limiter buckets');
select ok(not has_table_privilege('service_role','public.public_rate_limit_buckets','UPDATE'),'service role cannot reset limiter buckets directly');
select ok(has_function_privilege('service_role','public.service_consume_public_rate_limit(text,text,integer,integer)','EXECUTE'),'service role can consume through controlled function');
select ok(not has_function_privilege('anon','public.service_consume_public_rate_limit(text,text,integer,integer)','EXECUTE'),'anon cannot choose its own limiter scope/key');

-- Stateful public write/token RPCs are no longer directly callable by anonymous clients.
select ok(not has_function_privilege('anon','public.public_create_checkout_hold(text,uuid,uuid,jsonb,integer,timestamptz)','EXECUTE'),'fixed hold creation cannot bypass gateway');
select ok(not has_function_privilege('anon','public.public_create_checkout_hold_tracked(text,uuid,uuid,jsonb,integer,timestamptz,jsonb)','EXECUTE'),'tracked fixed hold creation cannot bypass gateway');
select ok(not has_function_privilege('anon','public.public_create_checkout_hold_duration(text,uuid,uuid,integer,jsonb,integer,timestamptz)','EXECUTE'),'duration hold creation cannot bypass gateway');
select ok(not has_function_privilege('anon','public.public_create_checkout_hold_tracked_duration(text,uuid,uuid,integer,jsonb,integer,timestamptz,jsonb)','EXECUTE'),'tracked duration hold cannot bypass gateway');
select ok(not has_function_privilege('anon','public.public_get_checkout_context(text)','EXECUTE'),'checkout token context cannot bypass gateway');
select ok(not has_function_privilege('anon','public.public_bind_checkout_customer(text,text,text,text,text,boolean)','EXECUTE'),'customer bind cannot bypass gateway');
select ok(not has_function_privilege('anon','public.public_select_checkout_hour_package(text,uuid)','EXECUTE'),'package reservation cannot bypass gateway');
select ok(not has_function_privilege('anon','public.public_clear_checkout_hour_package(text)','EXECUTE'),'package release cannot bypass gateway');
select ok(not has_function_privilege('anon','public.get_checkout_hold_resume_context(text)','EXECUTE'),'recovery token resolution cannot bypass gateway');
select ok(not has_function_privilege('anon','public.public_promote_checkout_hold(text,text,uuid[],jsonb,text)','EXECUTE'),'legacy appointment promotion cannot bypass booking-submit');

select * from finish();
rollback;
