begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(18);

select ok(
  not exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'checkout_holds'
      and column_name = 'recovery_public_token'
  ),
  'checkout holds no longer store a readable recovery capability'
);

select ok(
  exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'checkout_holds'
      and column_name = 'recovery_token_expires_at'
      and is_nullable = 'YES'
      and column_default is null
  ),
  'retired recovery expiry has no automatic capability lifetime'
);

select ok(
  exists (
    select 1
    from pg_constraint
    where conrelid = 'public.checkout_holds'::regclass
      and conname = 'checkout_holds_recovery_retired_check'
      and convalidated
      and pg_get_constraintdef(oid) ilike '%recovery_enabled%false%'
  ),
  'checkout holds are structurally prevented from re-enabling retired recovery'
);

select ok(
  position('CHECKOUT_RECOVERY_RETIRED' in pg_get_functiondef('public.get_checkout_hold_resume_context(text)'::regprocedure)) > 0
  and position('recovery_public_token' in pg_get_functiondef('public.get_checkout_hold_resume_context(text)'::regprocedure)) = 0,
  'stale recovery resume calls fail closed without a plaintext lookup'
);

select ok(
  position('CHECKOUT_RECOVERY_RETIRED' in pg_get_functiondef('public.set_checkout_hold_recovery_contact(text,text,boolean)'::regprocedure)) > 0,
  'stale recovery mutation calls fail closed'
);

select ok(
  position('CHECKOUT_RECOVERY_RETIRED' in pg_get_functiondef('public.public_bind_checkout_customer(text,text,text,text,text,boolean)'::regprocedure)) > 0,
  'customer binding explicitly fails closed when recovery is requested'
);

select ok(
  lower(pg_get_function_arguments('public.public_bind_checkout_customer(text,text,text,text,text,boolean)'::regprocedure))
    like '%p_recovery_enabled boolean default false%',
  'customer binding defaults recovery to false'
);

insert into public.resources (id, name, resource_type)
values ('95000000-0000-0000-0000-000000000001', 'RECOVERY RESOURCE', 'PERSON');

insert into public.employees (id, name, resource_id)
values (
  '95000000-0000-0000-0000-000000000010',
  'Recovery Employee',
  '95000000-0000-0000-0000-000000000001'
);

insert into public.categories (id, name, slug)
values ('95000000-0000-0000-0000-000000000020', 'Recovery', 'recovery-test');

insert into public.services (
  id, category_id, name, slug, base_duration_minutes, base_price,
  minimum_people, maximum_people, maximum_booking_horizon_days
) values (
  '95000000-0000-0000-0000-000000000030',
  '95000000-0000-0000-0000-000000000020',
  'Recovery Service',
  'recovery-service',
  60, 100.00, 1, 5, 365
);

insert into public.service_employees (id, service_id, employee_id)
values (
  '95000000-0000-0000-0000-000000000040',
  '95000000-0000-0000-0000-000000000030',
  '95000000-0000-0000-0000-000000000010'
);

insert into public.service_resources (service_id, resource_id, is_required)
values (
  '95000000-0000-0000-0000-000000000030',
  '95000000-0000-0000-0000-000000000001',
  true
);

insert into public.checkout_holds (
  id,
  public_token_hash,
  service_id,
  service_employee_id,
  selection_hash,
  people_count,
  requested_start_at,
  requested_end_at,
  core_start_at,
  core_end_at,
  status,
  expires_at,
  extra_selections,
  commercial_value,
  pricing_version,
  duration_minutes,
  resource_ids,
  quote_snapshot
) values (
  '95000000-0000-0000-0000-000000000050',
  encode(digest('checkout-recovery-token', 'sha256'), 'hex'),
  '95000000-0000-0000-0000-000000000030',
  '95000000-0000-0000-0000-000000000040',
  'recovery-selection',
  2,
  now() + interval '1 day',
  now() + interval '1 day 1 hour',
  now() + interval '1 day',
  now() + interval '1 day 1 hour',
  'ACTIVE',
  now() + interval '5 minutes',
  '[]'::jsonb,
  100.00,
  'recovery-v1',
  60,
  array['95000000-0000-0000-0000-000000000001'::uuid],
  '{}'::jsonb
);

insert into public.resource_allocations (
  resource_id,
  checkout_hold_id,
  allocation_type,
  status,
  occupied_range
) values (
  '95000000-0000-0000-0000-000000000001',
  '95000000-0000-0000-0000-000000000050',
  'CHECKOUT_HOLD',
  'HELD',
  tstzrange(now() + interval '1 day', now() + interval '1 day 1 hour', '[)')
);

select is(
  (select recovery_enabled from public.checkout_holds where id = '95000000-0000-0000-0000-000000000050'),
  false,
  'new holds cannot opt into retired recovery'
);

select ok(
  (select recovery_token_expires_at is null from public.checkout_holds where id = '95000000-0000-0000-0000-000000000050'),
  'new holds receive no automatic recovery expiry'
);

select ok(
  not has_function_privilege('anon','public.set_checkout_hold_recovery_contact(text,text,boolean)','EXECUTE'),
  'anonymous clients cannot mutate retired recovery'
);

select ok(
  not has_function_privilege('anon','public.get_checkout_hold_resume_context(text)','EXECUTE'),
  'anonymous clients cannot resolve retired recovery links'
);

select throws_ok(
  $$select public.public_bind_checkout_customer('checkout-recovery-token','Recovery Customer','recovery.customer@example.com','48999991234',null::text,true)$$,
  'P0001',
  'CHECKOUT_RECOVERY_RETIRED',
  'customer binding cannot re-enable retired recovery'
);

update public.checkout_holds
set created_at = now() - interval '10 minutes',
    expires_at = now() - interval '1 second'
where id = '95000000-0000-0000-0000-000000000050';

select public.expire_due_checkout_holds();

select is(
  (select status::text from public.checkout_holds where id = '95000000-0000-0000-0000-000000000050'),
  'EXPIRED',
  'expired short hold still expires normally'
);

select is(
  (select status::text from public.resource_allocations where checkout_hold_id = '95000000-0000-0000-0000-000000000050'),
  'EXPIRED',
  'resource allocation is immediately released on hold expiry'
);

select is(
  (
    select count(*)::integer
    from public.integration_jobs
    where entity_id = '95000000-0000-0000-0000-000000000050'
      and job_type = 'CHECKOUT_HOLD_EXPIRED_RECOVERY'
  ),
  0,
  'expiry does not enqueue direct WhatsApp recovery'
);

select ok(
  (select recovery_enqueued_at is null from public.checkout_holds where id = '95000000-0000-0000-0000-000000000050'),
  'hold does not record a retired recovery enqueue'
);

select is(
  (select is_active from public.message_templates where template_key = 'checkout_hold_expired_recovery'),
  false,
  'legacy WhatsApp recovery template remains inactive'
);

select ok(
  position('CHECKOUT_HOLD_EXPIRED_RECOVERY' in pg_get_functiondef('public.expire_due_checkout_holds()'::regprocedure)) = 0,
  'expiry implementation contains no direct WhatsApp job path'
);

select * from finish();
rollback;
