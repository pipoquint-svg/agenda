begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(12);

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
  quote_snapshot,
  recovery_public_token,
  recovery_token_expires_at
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
  '{}'::jsonb,
  'resume-recovery-token',
  now() + interval '7 days'
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
  public.set_checkout_hold_recovery_contact(
    'checkout-recovery-token',
    '+55 (48) 99999-1234',
    true
  )->>'recovery_enabled',
  'true',
  'recovery can be enabled while the short hold is active'
);

select is(
  (select recovery_phone from public.checkout_holds where id = '95000000-0000-0000-0000-000000000050'),
  '5548999991234',
  'recovery phone is normalized before persistence'
);

update public.checkout_holds
set expires_at = now() - interval '1 second'
where id = '95000000-0000-0000-0000-000000000050';

select public.expire_due_checkout_holds();

select is(
  (select status::text from public.checkout_holds where id = '95000000-0000-0000-0000-000000000050'),
  'EXPIRED',
  'expired short hold releases its reservation state'
);

select is(
  (select status::text from public.resource_allocations where checkout_hold_id = '95000000-0000-0000-0000-000000000050'),
  'EXPIRED',
  'resource allocation is immediately released on hold expiry'
);

select ok(
  exists (
    select 1 from public.integration_jobs
    where entity_id = '95000000-0000-0000-0000-000000000050'
      and job_type = 'CHECKOUT_HOLD_EXPIRED_RECOVERY'
      and status = 'PENDING'
  ),
  'expiry enqueues a recovery message job'
);

select is(
  (
    select payload_json->>'template_key'
    from public.integration_jobs
    where entity_id = '95000000-0000-0000-0000-000000000050'
      and job_type = 'CHECKOUT_HOLD_EXPIRED_RECOVERY'
  ),
  'checkout_hold_expired_recovery',
  'recovery job points to the dedicated transactional template'
);

select is(
  (
    select payload_json->>'resume_token'
    from public.integration_jobs
    where entity_id = '95000000-0000-0000-0000-000000000050'
      and job_type = 'CHECKOUT_HOLD_EXPIRED_RECOVERY'
  ),
  'resume-recovery-token',
  'recovery job carries only the opaque resume token needed for the link'
);

select ok(
  (select recovery_enqueued_at is not null from public.checkout_holds where id = '95000000-0000-0000-0000-000000000050'),
  'hold records that recovery was enqueued'
);

select public.expire_due_checkout_holds();

select is(
  (
    select count(*)::integer
    from public.integration_jobs
    where entity_id = '95000000-0000-0000-0000-000000000050'
      and job_type = 'CHECKOUT_HOLD_EXPIRED_RECOVERY'
  ),
  1,
  'running expiry repeatedly never duplicates the recovery message'
);

select ok(
  exists (
    select 1 from public.message_templates
    where template_key = 'checkout_hold_expired_recovery'
      and channel = 'WHATSAPP'
      and is_active
  ),
  'logical WhatsApp recovery template is registered'
);

select is(
  public.get_checkout_hold_resume_context('resume-recovery-token')->>'service_id',
  '95000000-0000-0000-0000-000000000030',
  'resume context restores the selected service'
);

select ok(
  not (public.get_checkout_hold_resume_context('resume-recovery-token') ? 'recovery_phone'),
  'public resume context never exposes the recovery phone'
);

select * from finish();
rollback;
