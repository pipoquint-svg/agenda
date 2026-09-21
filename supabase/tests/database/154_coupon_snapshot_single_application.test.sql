begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(5);

insert into public.resources (id, name, resource_type)
values ('95400000-0000-0000-0000-000000000001', 'COUPON SNAPSHOT TEST STUDIO', 'PHYSICAL');

insert into public.employees (id, name)
values ('95400000-0000-0000-0000-000000000002', 'Coupon Snapshot Employee');

insert into public.categories (id, name, slug)
values ('95400000-0000-0000-0000-000000000003', 'Coupon Snapshot', 'coupon-snapshot-test');

insert into public.services (
  id, category_id, name, slug, base_duration_minutes, base_price,
  minimum_people, maximum_people, maximum_booking_horizon_days, requires_terms
) values (
  '95400000-0000-0000-0000-000000000010',
  '95400000-0000-0000-0000-000000000003',
  'Coupon Snapshot Service', 'coupon-snapshot-service',
  60, 100, 1, 10, 5000, false
);

-- Promotion captures a mandatory policy snapshot even when the service has no terms.
-- Complete the synthetic service instead of bypassing the production snapshot guard.
insert into public.service_change_policies (
  service_id, notice_hours, reschedule_first_early_percent,
  reschedule_first_late_percent, reschedule_repeat_percent, cancellation_late_percent
) values (
  '95400000-0000-0000-0000-000000000010', 0, 0, 0, 0, 0
);

insert into public.service_employees (id, service_id, employee_id)
values (
  '95400000-0000-0000-0000-000000000020',
  '95400000-0000-0000-0000-000000000010',
  '95400000-0000-0000-0000-000000000002'
);

insert into public.service_resources (service_id, resource_id)
values (
  '95400000-0000-0000-0000-000000000010',
  '95400000-0000-0000-0000-000000000001'
);

insert into public.customers (id, name, email, phone)
values (
  '95400000-0000-0000-0000-000000000050',
  'Coupon Snapshot Customer', 'coupon-snapshot@example.com', '+5548999999540'
);

insert into public.coupons (
  id, code, discount_type, discount_value, valid_from, valid_until,
  is_active, source, customer_id, source_appointment_id, max_uses
) values (
  '95400000-0000-0000-0000-000000000071',
  'SNAP10', 'PERCENT', 10,
  now() - interval '1 day', now() + interval '90 days',
  true, 'PROMOTION', null, null, 10
);

insert into public.checkout_holds (
  id, public_token_hash, service_id, service_employee_id, selection_hash,
  people_count, requested_start_at, requested_end_at, expires_at,
  extra_selections, commercial_value, pricing_version, duration_minutes, resource_ids,
  quote_snapshot, applied_coupon_id, coupon_code_snapshot, coupon_discount, pre_discount_value
) values (
  '95400000-0000-0000-0000-000000000080',
  'coupon-snapshot-hold',
  '95400000-0000-0000-0000-000000000010',
  '95400000-0000-0000-0000-000000000020',
  'coupon-snapshot-selection',
  1,
  '2035-01-15 09:00:00-03', '2035-01-15 10:00:00-03',
  now() + interval '10 minutes',
  '[]'::jsonb,
  90.00,
  'coupon-snapshot-test',
  60,
  array['95400000-0000-0000-0000-000000000001'::uuid],
  jsonb_build_object(
    'base_price', 100.00,
    'commercial_value', 90.00,
    'coupon_discount', 10.00,
    'extras_total', 0,
    'day_time_adjustment', 0,
    'people_adjustment', 0
  ),
  '95400000-0000-0000-0000-000000000071',
  'SNAP10',
  10.00,
  100.00
);

insert into public.resource_allocations (
  resource_id, checkout_hold_id, allocation_type, status, occupied_range
) values (
  '95400000-0000-0000-0000-000000000001',
  '95400000-0000-0000-0000-000000000080',
  'CHECKOUT_HOLD', 'HELD',
  tstzrange('2035-01-15 09:00:00-03', '2035-01-15 10:00:00-03', '[)')
);

select is(
  (public.promote_checkout_hold(
    '95400000-0000-0000-0000-000000000080',
    '95400000-0000-0000-0000-000000000050',
    'SNAP10'
  )->>'cash_due')::numeric,
  90.00::numeric,
  'persisted 10 percent coupon is not applied a second time during promotion'
);

select is(
  (select a.commercial_value
   from public.appointments a
   join public.checkout_holds h on h.promoted_appointment_id = a.id
   where h.id = '95400000-0000-0000-0000-000000000080'),
  90.00::numeric,
  'appointment preserves the hold commercial value'
);

select is(
  (select a.coupon_discount
   from public.appointments a
   join public.checkout_holds h on h.promoted_appointment_id = a.id
   where h.id = '95400000-0000-0000-0000-000000000080'),
  10.00::numeric,
  'appointment preserves the hold coupon discount snapshot'
);

select is(
  (select ad.calculated_discount_amount
   from public.appointment_discounts ad
   join public.checkout_holds h on h.promoted_appointment_id = ad.appointment_id
   where h.id = '95400000-0000-0000-0000-000000000080'),
  10.00::numeric,
  'appointment discount audit records the coupon once'
);

select is(
  (select used_count from public.coupons where id = '95400000-0000-0000-0000-000000000071'),
  1,
  'coupon usage is incremented once'
);

select * from finish();
rollback;
