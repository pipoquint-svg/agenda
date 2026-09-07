begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(9);

select has_function(
  'public',
  'service_expire_waitlist_private_slots',
  array[]::text[],
  'private waitlist expiry service function exists'
);

select ok(
  not has_function_privilege('anon', 'public.service_expire_waitlist_private_slots()', 'EXECUTE'),
  'anonymous users cannot invoke private waitlist maintenance'
);

select ok(
  not has_function_privilege('authenticated', 'public.service_expire_waitlist_private_slots()', 'EXECUTE'),
  'authenticated users cannot invoke private waitlist maintenance'
);

select ok(
  has_function_privilege('service_role', 'public.service_expire_waitlist_private_slots()', 'EXECUTE'),
  'service role can invoke private waitlist maintenance'
);

create temporary table _private_expiry_ids (
  auth_user_id uuid not null,
  admin_id uuid not null,
  page_id uuid not null,
  expired_resource_id uuid not null,
  expired_allocation_id uuid not null,
  expired_slot_id uuid not null,
  live_resource_id uuid not null,
  live_allocation_id uuid not null,
  live_slot_id uuid not null
) on commit drop;

insert into _private_expiry_ids
select
  gen_random_uuid(), gen_random_uuid(), gen_random_uuid(),
  gen_random_uuid(), gen_random_uuid(), gen_random_uuid(),
  gen_random_uuid(), gen_random_uuid(), gen_random_uuid();

insert into auth.users(id, is_sso_user, is_anonymous)
select auth_user_id, false, false
from _private_expiry_ids;

insert into public.admin_users(id, auth_user_id, display_name, role, is_active)
select admin_id, auth_user_id, 'Private expiry test admin', 'ADMIN', true
from _private_expiry_ids;

insert into public.booking_pages(id, slug, display_name, title, brand_key, payment_provider, is_active)
select
  page_id,
  'private-expiry-' || substr(replace(page_id::text, '-', ''), 1, 12),
  'Private expiry test',
  'Private expiry test',
  'BLACKSHEEP',
  'MERCADO_PAGO',
  false
from _private_expiry_ids;

insert into public.resources(id, name, resource_type, is_active)
select expired_resource_id, 'Expired private slot resource', 'STUDIO', true
from _private_expiry_ids
union all
select live_resource_id, 'Live private slot resource', 'STUDIO', true
from _private_expiry_ids;

insert into public.resource_allocations(
  id, resource_id, allocation_type, status, occupied_range, reason, created_by_admin_id
)
select
  expired_allocation_id,
  expired_resource_id,
  'MANUAL_BLOCK',
  'BLOCKED',
  tstzrange(now() + interval '1 day', now() + interval '1 day 1 hour', '[)'),
  'WAITLIST_PRIVATE_EXPIRY_TEST',
  admin_id
from _private_expiry_ids
union all
select
  live_allocation_id,
  live_resource_id,
  'MANUAL_BLOCK',
  'BLOCKED',
  tstzrange(now() + interval '2 days', now() + interval '2 days 1 hour', '[)'),
  'WAITLIST_PRIVATE_EXPIRY_TEST_LIVE',
  admin_id
from _private_expiry_ids;

insert into public.waitlist_private_slots(
  id, booking_page_id, start_at, expires_at, status, created_by_admin_id, created_at, updated_at
)
select
  expired_slot_id,
  page_id,
  now() + interval '1 day',
  now() - interval '1 hour',
  'OPEN',
  admin_id,
  now() - interval '2 hours',
  now() - interval '2 hours'
from _private_expiry_ids
union all
select
  live_slot_id,
  page_id,
  now() + interval '2 days',
  now() + interval '1 day',
  'OPEN',
  admin_id,
  now(),
  now()
from _private_expiry_ids;

insert into public.waitlist_private_slot_resources(
  slot_id, resource_id, allocation_id, occupied_range_snapshot
)
select
  expired_slot_id,
  expired_resource_id,
  expired_allocation_id,
  tstzrange(now() + interval '1 day', now() + interval '1 day 1 hour', '[)')
from _private_expiry_ids
union all
select
  live_slot_id,
  live_resource_id,
  live_allocation_id,
  tstzrange(now() + interval '2 days', now() + interval '2 days 1 hour', '[)')
from _private_expiry_ids;

select ok(
  public.service_expire_waitlist_private_slots() >= 1,
  'maintenance expires at least the due private slot'
);

select is(
  (select s.status from public.waitlist_private_slots s join _private_expiry_ids i on i.expired_slot_id = s.id),
  'EXPIRED',
  'expired private slot is marked EXPIRED'
);

select is(
  (select ra.status from public.resource_allocations ra join _private_expiry_ids i on i.expired_allocation_id = ra.id),
  'RELEASED',
  'expired private slot releases its resource block'
);

select is(
  (select s.status from public.waitlist_private_slots s join _private_expiry_ids i on i.live_slot_id = s.id),
  'OPEN',
  'future private slot remains OPEN'
);

select is(
  (select ra.status from public.resource_allocations ra join _private_expiry_ids i on i.live_allocation_id = ra.id),
  'BLOCKED',
  'future private slot keeps its resource block'
);

select * from finish();
rollback;
