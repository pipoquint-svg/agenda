begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(17);

insert into public.resources (id, name, resource_type)
values ('70000000-0000-0000-0000-000000000001', 'PROMOTION TEST STUDIO', 'PHYSICAL');

insert into public.employees (id, name)
values ('70000000-0000-0000-0000-000000000002', 'Promotion Employee');

insert into public.categories (id, name, slug)
values ('70000000-0000-0000-0000-000000000003', 'Promotion', 'promotion-test');

insert into public.services (
  id, category_id, name, slug, base_duration_minutes, base_price,
  minimum_people, maximum_people, maximum_booking_horizon_days, requires_terms
) values
  ('70000000-0000-0000-0000-000000000010', '70000000-0000-0000-0000-000000000003', 'Cash Service', 'promotion-cash', 60, 100, 1, 10, 5000, false),
  ('70000000-0000-0000-0000-000000000011', '70000000-0000-0000-0000-000000000003', 'Terms Service', 'promotion-terms', 60, 100, 1, 10, 5000, true),
  ('70000000-0000-0000-0000-000000000012', '70000000-0000-0000-0000-000000000003', 'Package Service', 'promotion-package', 60, 100, 1, 10, 5000, false);

insert into public.service_employees (id, service_id, employee_id)
values
  ('70000000-0000-0000-0000-000000000020', '70000000-0000-0000-0000-000000000010', '70000000-0000-0000-0000-000000000002'),
  ('70000000-0000-0000-0000-000000000021', '70000000-0000-0000-0000-000000000011', '70000000-0000-0000-0000-000000000002'),
  ('70000000-0000-0000-0000-000000000022', '70000000-0000-0000-0000-000000000012', '70000000-0000-0000-0000-000000000002');

insert into public.service_resources (service_id, resource_id)
values
  ('70000000-0000-0000-0000-000000000010', '70000000-0000-0000-0000-000000000001'),
  ('70000000-0000-0000-0000-000000000011', '70000000-0000-0000-0000-000000000001'),
  ('70000000-0000-0000-0000-000000000012', '70000000-0000-0000-0000-000000000001');

insert into public.extras (id, name, price, duration_delta_minutes)
values ('70000000-0000-0000-0000-000000000030', 'Cash Extra', 50, 0);

insert into public.service_extras (service_id, extra_id, max_quantity)
values ('70000000-0000-0000-0000-000000000012', '70000000-0000-0000-0000-000000000030', 1);

insert into public.service_fields (id, service_id, field_key, label, field_type, is_required)
values ('70000000-0000-0000-0000-000000000040', '70000000-0000-0000-0000-000000000011', 'required_note', 'Required note', 'TEXT', true);

insert into public.terms_versions (id, service_id, name, version, content)
values ('70000000-0000-0000-0000-000000000041', '70000000-0000-0000-0000-000000000011', 'Terms', '1.0', 'Terms snapshot test');

insert into public.customers (id, name, email, phone)
values
  ('70000000-0000-0000-0000-000000000050', 'Promotion Customer', 'promotion@example.com', '+5548999999100'),
  ('70000000-0000-0000-0000-000000000051', 'Other Customer', 'other@example.com', '+5548999999101');

insert into public.hour_packages (
  id, customer_id, name, total_minutes, purchased_value,
  valid_from, valid_until, standard_start_local_time, standard_end_local_time
) values (
  '70000000-0000-0000-0000-000000000060',
  '70000000-0000-0000-0000-000000000050',
  'Promotion Package', 600, 1000,
  '2034-01-01 00:00:00-03', '2036-01-01 00:00:00-03', '09:00', '18:00'
);

insert into public.hour_package_services (hour_package_id, service_id)
values ('70000000-0000-0000-0000-000000000060', '70000000-0000-0000-0000-000000000012');

insert into public.coupons (
  id, code, discount_type, discount_value, valid_from, valid_until,
  is_active, source, customer_id, source_appointment_id, max_uses
) values
  ('70000000-0000-0000-0000-000000000071', 'ONCE10', 'FIXED', 10, now() - interval '1 day', now() + interval '90 days', true, 'PROMOTION', null, null, 1);

insert into public.checkout_holds (
  id, public_token_hash, service_id, service_employee_id, selection_hash,
  people_count, requested_start_at, requested_end_at, expires_at,
  extra_selections, commercial_value, pricing_version, duration_minutes, resource_ids
) values
  ('70000000-0000-0000-0000-000000000080', 'promotion-hold-cash', '70000000-0000-0000-0000-000000000010', '70000000-0000-0000-0000-000000000020', 'cash', 1, '2035-01-15 09:00:00-03', '2035-01-15 10:00:00-03', now() + interval '10 minutes', '[]', 100, 'test', 60, array['70000000-0000-0000-0000-000000000001'::uuid]),
  ('70000000-0000-0000-0000-000000000081', 'promotion-hold-package', '70000000-0000-0000-0000-000000000012', '70000000-0000-0000-0000-000000000022', 'pkg', 1, '2035-01-15 10:00:00-03', '2035-01-15 11:00:00-03', now() + interval '10 minutes', '[]', 100, 'test', 60, array['70000000-0000-0000-0000-000000000001'::uuid]),
  ('70000000-0000-0000-0000-000000000082', 'promotion-hold-package-extra', '70000000-0000-0000-0000-000000000012', '70000000-0000-0000-0000-000000000022', 'pkg-extra', 1, '2035-01-15 11:00:00-03', '2035-01-15 12:00:00-03', now() + interval '10 minutes', '[{"extra_id":"70000000-0000-0000-0000-000000000030","quantity":1}]', 150, 'test', 60, array['70000000-0000-0000-0000-000000000001'::uuid]),
  ('70000000-0000-0000-0000-000000000083', 'promotion-hold-terms', '70000000-0000-0000-0000-000000000011', '70000000-0000-0000-0000-000000000021', 'terms', 1, '2035-01-15 12:00:00-03', '2035-01-15 13:00:00-03', now() + interval '10 minutes', '[]', 100, 'test', 60, array['70000000-0000-0000-0000-000000000001'::uuid]),
  ('70000000-0000-0000-0000-000000000084', 'promotion-hold-credit-wrong', '70000000-0000-0000-0000-000000000010', '70000000-0000-0000-0000-000000000020', 'credit-wrong', 1, '2035-01-15 13:00:00-03', '2035-01-15 14:00:00-03', now() + interval '10 minutes', '[]', 100, 'test', 60, array['70000000-0000-0000-0000-000000000001'::uuid]),
  ('70000000-0000-0000-0000-000000000085', 'promotion-hold-coupon-a', '70000000-0000-0000-0000-000000000010', '70000000-0000-0000-0000-000000000020', 'coupon-a', 1, '2035-01-15 14:00:00-03', '2035-01-15 15:00:00-03', now() + interval '10 minutes', '[]', 100, 'test', 60, array['70000000-0000-0000-0000-000000000001'::uuid]),
  ('70000000-0000-0000-0000-000000000086', 'promotion-hold-coupon-b', '70000000-0000-0000-0000-000000000010', '70000000-0000-0000-0000-000000000020', 'coupon-b', 1, '2035-01-15 15:00:00-03', '2035-01-15 16:00:00-03', now() + interval '10 minutes', '[]', 100, 'test', 60, array['70000000-0000-0000-0000-000000000001'::uuid]);

insert into public.resource_allocations (resource_id, checkout_hold_id, allocation_type, status, occupied_range)
select '70000000-0000-0000-0000-000000000001'::uuid, ch.id, 'CHECKOUT_HOLD', 'HELD', tstzrange(ch.requested_start_at, ch.requested_end_at, '[)')
from public.checkout_holds ch
where ch.id between '70000000-0000-0000-0000-000000000080'::uuid and '70000000-0000-0000-0000-000000000086'::uuid;

select is((public.promote_checkout_hold('70000000-0000-0000-0000-000000000080','70000000-0000-0000-0000-000000000050')->>'status'), 'AWAITING_PAYMENT', 'cash booking promotes to awaiting payment');

select ok(exists (
  select 1 from public.checkout_holds ch
  join public.resource_allocations ra on ra.appointment_id = ch.promoted_appointment_id
  where ch.id='70000000-0000-0000-0000-000000000080'
    and ch.status='PROMOTED' and ra.checkout_hold_id is null
    and ra.allocation_type='APPOINTMENT' and ra.status='AWAITING_PAYMENT'
), 'allocation ownership transfers without releasing interval');

select public.reserve_hour_package_for_checkout('70000000-0000-0000-0000-000000000060','70000000-0000-0000-0000-000000000081','70000000-0000-0000-0000-000000000050');
select public.reserve_hour_package_for_checkout('70000000-0000-0000-0000-000000000060','70000000-0000-0000-0000-000000000082','70000000-0000-0000-0000-000000000050');

select is((public.promote_checkout_hold('70000000-0000-0000-0000-000000000081','70000000-0000-0000-0000-000000000050')->>'status'), 'CONFIRMED', 'package-only booking confirms immediately');

select ok(exists (
  select 1 from public.checkout_holds ch
  join public.appointment_package_usage apu on apu.appointment_id=ch.promoted_appointment_id
  where ch.id='70000000-0000-0000-0000-000000000081' and apu.charged_seconds=3600
), 'immediate package confirmation consumes exact package time');

select is((
  select count(*)::integer from public.integration_jobs ij
  join public.checkout_holds ch on ch.promoted_appointment_id=ij.entity_id
  where ch.id='70000000-0000-0000-0000-000000000081' and ij.status='PENDING'
), 2, 'immediate confirmation writes outbox jobs');

select is((public.promote_checkout_hold('70000000-0000-0000-0000-000000000082','70000000-0000-0000-0000-000000000050')->>'status'), 'AWAITING_PAYMENT', 'package with cash extra waits for payment');
select is((select status from public.checkout_hour_package_reservations where checkout_hold_id='70000000-0000-0000-0000-000000000082'), 'HELD', 'package credit remains held while payment is pending');

select throws_ok(
  $$ select public.promote_checkout_hold('70000000-0000-0000-0000-000000000083','70000000-0000-0000-0000-000000000050',null,array['70000000-0000-0000-0000-000000000041'::uuid],'[]'::jsonb,'[]'::jsonb) $$,
  'P0001','REQUIRED_SERVICE_FIELDS_MISSING','required service field blocks promotion'
);

select ok(exists (
  select 1 from public.checkout_holds ch join public.resource_allocations ra on ra.checkout_hold_id=ch.id
  where ch.id='70000000-0000-0000-0000-000000000083' and ch.status='ACTIVE' and ch.promoted_appointment_id is null and ra.status='HELD'
), 'failed promotion rolls back and preserves checkout protection');

select throws_ok(
  $$ select public.promote_checkout_hold('70000000-0000-0000-0000-000000000083','70000000-0000-0000-0000-000000000050',null,'{}'::uuid[],'[]'::jsonb,'[{"service_field_id":"70000000-0000-0000-0000-000000000040","value":"ok"}]'::jsonb) $$,
  'P0001','TERMS_NOT_ACCEPTED','required terms must be accepted'
);

select throws_ok(
  $$ select public.promote_checkout_hold('70000000-0000-0000-0000-000000000084','70000000-0000-0000-0000-000000000050','OTHER-CREDIT') $$,
  'P0001','INVALID_COUPON','removed cancellation-credit codes are not accepted by checkout'
);

select is((public.promote_checkout_hold('70000000-0000-0000-0000-000000000085','70000000-0000-0000-0000-000000000050','ONCE10')->>'cash_due')::numeric, 90.00::numeric, 'one-use coupon reduces pending amount');

select throws_ok(
  $$ select public.promote_checkout_hold('70000000-0000-0000-0000-000000000086','70000000-0000-0000-0000-000000000050','ONCE10') $$,
  'P0001','COUPON_USAGE_LIMIT_REACHED','one-use coupon cannot be spent twice'
);

update public.appointments a set hold_expires_at=now()-interval '1 minute'
from public.checkout_holds ch where ch.id='70000000-0000-0000-0000-000000000085' and a.id=ch.promoted_appointment_id;
select public.expire_due_appointment_holds();

select is((select used_count from public.coupons where id='70000000-0000-0000-0000-000000000071'), 0, 'payment timeout restores coupon usage');

select ok(exists (
  select 1 from public.checkout_holds ch
  join public.appointments a on a.id=ch.promoted_appointment_id
  join public.resource_allocations ra on ra.appointment_id=a.id
  where ch.id='70000000-0000-0000-0000-000000000085' and a.status='EXPIRED' and ra.status='EXPIRED'
), 'payment timeout releases appointment allocation');

update public.appointments a set hold_expires_at=now()-interval '1 minute'
from public.checkout_holds ch where ch.id='70000000-0000-0000-0000-000000000082' and a.id=ch.promoted_appointment_id;
select public.expire_due_appointment_holds();

select is((select status from public.checkout_hour_package_reservations where checkout_hold_id='70000000-0000-0000-0000-000000000082'), 'RELEASED', 'payment timeout returns held package balance');

select is((public.promote_checkout_hold('70000000-0000-0000-0000-000000000086','70000000-0000-0000-0000-000000000050','ONCE10')->>'cash_due')::numeric, 90.00::numeric, 'restored one-use coupon can be used by later checkout');

select * from finish();
rollback;
