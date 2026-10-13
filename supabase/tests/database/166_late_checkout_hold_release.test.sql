begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(23);

-- Deterministic mirror of the BlackSheep regression scenario (13/10/2026,
-- 08:30, 4 hours, ends 12:30, mandatory 30-minute interval until 13:00).
-- The same Tuesday shape is used on a far-future date so the fixture never
-- becomes a past slot in CI.

insert into public.resources (id, name, resource_type)
values ('16600000-0000-4000-8000-000000000001', 'LATE HOLD TEST STUDIO', 'PHYSICAL');
insert into public.employees (id, name)
values ('16600000-0000-4000-8000-000000000002', 'Late Hold Employee');
insert into public.categories (id, name, slug)
values ('16600000-0000-4000-8000-000000000003', 'Late Hold Rental', 'late-hold-rental');
insert into public.services (
  id, category_id, name, slug, base_duration_minutes, base_price,
  minimum_people, maximum_people, maximum_booking_horizon_days,
  duration_mode, booking_block_minutes, minimum_booking_blocks,
  maximum_booking_blocks, price_per_block, buffer_after_minutes, operation_scope
) values (
  '16600000-0000-4000-8000-000000000004', '16600000-0000-4000-8000-000000000003',
  'Locação Late Hold', 'late-hold-rental', 60, 190.00,
  1, 10, 5000, 'BLOCKS', 30, 2, 16, 95.00, 30, 'BLACKSHEEP'
);
insert into public.service_change_policies(
  service_id, notice_hours, reschedule_first_early_percent, reschedule_first_late_percent,
  reschedule_repeat_percent, cancellation_late_percent
) values ('16600000-0000-4000-8000-000000000004', 12, 0, 20, 20, 20);
insert into public.service_employees (id, service_id, employee_id)
values ('16600000-0000-4000-8000-000000000005', '16600000-0000-4000-8000-000000000004', '16600000-0000-4000-8000-000000000002');
insert into public.service_resources (service_id, resource_id)
values ('16600000-0000-4000-8000-000000000004', '16600000-0000-4000-8000-000000000001');
insert into public.availability_rules (service_employee_id, weekday, start_local_time, end_local_time, slot_interval_minutes)
values ('16600000-0000-4000-8000-000000000005', 2, '08:00', '20:00', 30);
insert into public.resource_availability_rules (resource_id, weekday, start_local_time, end_local_time, is_active)
values ('16600000-0000-4000-8000-000000000001', 2, '08:00', '21:00', true);
insert into public.booking_pages (id, slug, display_name, title, brand_key, require_tax_id)
values ('16600000-0000-4000-8000-000000000006', 'late-hold-test', 'Late Hold Test', 'Late Hold Test', 'BLACKSHEEP', false);
insert into public.booking_page_services (booking_page_id, service_id)
values ('16600000-0000-4000-8000-000000000006', '16600000-0000-4000-8000-000000000004');

-- Selection, duration, extras and people are browsing state: quoting and
-- listing slots never create a hold.
select public.public_quote_booking_minutes('late-hold-test', '16600000-0000-4000-8000-000000000004',
  '16600000-0000-4000-8000-000000000005', 240, '[]'::jsonb, 3);
select count(*) from public.public_list_available_slots_minutes('late-hold-test', '16600000-0000-4000-8000-000000000004',
  '16600000-0000-4000-8000-000000000005', 240, '[]'::jsonb, 3, '2035-10-16'::date);
select is(
  (select count(*)::integer from public.checkout_holds where service_id = '16600000-0000-4000-8000-000000000004'),
  0, 'quotes and slot listing never create a checkout hold');
select ok(
  exists (
    select 1 from public.public_list_available_slots_minutes('late-hold-test',
      '16600000-0000-4000-8000-000000000004', '16600000-0000-4000-8000-000000000005', 240, '[]'::jsonb, 3,
      '2035-10-16'::date) slot
    where slot.core_start_at = '2035-10-16 08:30:00-03'::timestamptz
  ),
  'the 08:30 four-hour slot is visible to every customer before any hold');

-- Customer A enters the personal-data step: exactly one hold is created.
create temporary table late_hold_a as
select public.public_create_checkout_hold_tracked_minutes(
  'late-hold-test', '16600000-0000-4000-8000-000000000004', '16600000-0000-4000-8000-000000000005',
  240, '[]'::jsonb, 3, '2035-10-16 08:30:00-03'::timestamptz, '{}'::jsonb) as payload;

select is(
  (select count(*)::integer from public.checkout_holds where service_id = '16600000-0000-4000-8000-000000000004'),
  1, 'entering the data step creates exactly one hold');
select is(
  (select expires_at - created_at from public.checkout_holds
   where id = (select (payload->>'checkout_hold_id')::uuid from late_hold_a)),
  interval '10 minutes', 'the hold carries the authoritative 10-minute expiry');
select is(
  (select (payload->>'expires_at')::timestamptz from late_hold_a),
  (select expires_at from public.checkout_holds where id = (select (payload->>'checkout_hold_id')::uuid from late_hold_a)),
  'the backend returns the persisted expires_at to the browser');
select is(
  (select upper(occupied_range) from public.resource_allocations
   where checkout_hold_id = (select (payload->>'checkout_hold_id')::uuid from late_hold_a) and status = 'HELD'),
  '2035-10-16 13:00:00-03'::timestamptz,
  '08:30 + 4h ends 12:30 and the protected occupation includes the 30-minute interval until 13:00');

-- Customer B tried the same time in parallel: the database rejects it.
select throws_like(
  $$select public.public_create_checkout_hold_tracked_minutes(
    'late-hold-test', '16600000-0000-4000-8000-000000000004', '16600000-0000-4000-8000-000000000005',
    240, '[]'::jsonb, 2, '2035-10-16 08:30:00-03'::timestamptz, '{}'::jsonb)$$,
  '%AVAILABLE%', 'a concurrent customer cannot protect the same conflicting period');
select throws_like(
  $$select public.public_create_checkout_hold_tracked_minutes(
    'late-hold-test', '16600000-0000-4000-8000-000000000004', '16600000-0000-4000-8000-000000000005',
    60, '[]'::jsonb, 1, '2035-10-16 12:30:00-03'::timestamptz, '{}'::jsonb)$$,
  '%AVAILABLE%', 'a booking inside the 12:30-13:00 interval is rejected');
select ok(
  not exists (
    select 1 from public.public_list_available_slots_minutes('late-hold-test',
      '16600000-0000-4000-8000-000000000004', '16600000-0000-4000-8000-000000000005', 240, '[]'::jsonb, 3,
      '2035-10-16'::date) slot
    where slot.core_start_at = '2035-10-16 08:30:00-03'::timestamptz
  ),
  'an active hold hides the slot from other customers');

-- Selection updates on the protected hold never extend the expiry.
select public.public_update_checkout_hold_selection((select payload->>'checkout_hold_token' from late_hold_a), '[]'::jsonb, 4);
select is(
  (select expires_at from public.checkout_holds where id = (select (payload->>'checkout_hold_id')::uuid from late_hold_a)),
  (select (payload->>'expires_at')::timestamptz from late_hold_a),
  'updating people/extras keeps the original expires_at');

-- Release contract.
select is(public.service_public_release_checkout_hold((select payload->>'checkout_hold_token' from late_hold_a))->>'released',
  'true', 'the token holder releases the replaced hold');
select is(
  (select status from public.checkout_holds where id = (select (payload->>'checkout_hold_id')::uuid from late_hold_a)),
  'INVALIDATED', 'released hold is invalidated');
select is(
  (select count(*)::integer from public.resource_allocations
   where checkout_hold_id = (select (payload->>'checkout_hold_id')::uuid from late_hold_a) and status = 'HELD'),
  0, 'released hold leaves no orphan HELD allocation');
select is(public.service_public_release_checkout_hold((select payload->>'checkout_hold_token' from late_hold_a)),
  '{"released": false, "status": "INVALIDATED"}'::jsonb, 'release is idempotent');
select is(public.service_public_release_checkout_hold(repeat('f', 48)),
  '{"released": false, "status": "NOT_FOUND"}'::jsonb, 'unknown token is a no-op');
select throws_ok($$select public.service_public_release_checkout_hold('short')$$,
  'P0001', 'CHECKOUT_HOLD_TOKEN_REQUIRED', 'malformed token is rejected');
select throws_ok(
  format('select public.public_get_checkout_context(%L)', (select payload->>'checkout_hold_token' from late_hold_a)),
  'P0001', null, 'a released token can no longer drive the checkout');

-- After release, another customer can protect the same period.
create temporary table late_hold_b as
select public.public_create_checkout_hold_tracked_minutes(
  'late-hold-test', '16600000-0000-4000-8000-000000000004', '16600000-0000-4000-8000-000000000005',
  240, '[]'::jsonb, 2, '2035-10-16 08:30:00-03'::timestamptz, '{}'::jsonb) as payload;
select is((select payload->>'checkout_hold_id' is not null from late_hold_b), true,
  'the released period is immediately available to the next customer');

-- Expiry: an expired hold stops blocking even without a browser.
update public.checkout_holds
set created_at = now() - interval '11 minutes', expires_at = now() - interval '1 minute'
where id = (select (payload->>'checkout_hold_id')::uuid from late_hold_b);
select throws_ok(
  format('select public.public_get_checkout_context(%L)', (select payload->>'checkout_hold_token' from late_hold_b)),
  'P0001', null, 'an expired token is rejected');
create temporary table late_hold_c as
select public.public_create_checkout_hold_tracked_minutes(
  'late-hold-test', '16600000-0000-4000-8000-000000000004', '16600000-0000-4000-8000-000000000005',
  240, '[]'::jsonb, 1, '2035-10-16 08:30:00-03'::timestamptz, '{}'::jsonb) as payload;
select is(
  (select status from public.checkout_holds where id = (select (payload->>'checkout_hold_id')::uuid from late_hold_b)),
  'EXPIRED', 'the expired hold no longer blocks and is expired by the backend');
select is(public.service_public_release_checkout_hold((select payload->>'checkout_hold_token' from late_hold_b)),
  '{"released": false, "status": "EXPIRED"}'::jsonb, 'releasing an expired hold is a harmless no-op');

-- Holds outside the public booking-page contract are refused.
update public.checkout_holds set booking_page_id = null
where id = (select (payload->>'checkout_hold_id')::uuid from late_hold_c);
select throws_ok(
  format('select public.service_public_release_checkout_hold(%L)', (select payload->>'checkout_hold_token' from late_hold_c)),
  'P0001', 'CHECKOUT_HOLD_RELEASE_NOT_ALLOWED', 'non public-page holds keep their own contract');

select ok(
  has_function_privilege('service_role', 'public.service_public_release_checkout_hold(text)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.service_public_release_checkout_hold(text)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'public.service_public_release_checkout_hold(text)', 'EXECUTE'),
  'release RPC is executable only by service_role');

select * from finish();
rollback;
