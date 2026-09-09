begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(13);

select ok(
  exists (
    select 1
    from pg_constraint c
    join pg_index i on i.indrelid = c.conrelid
    where c.conname = 'availability_exceptions_special_calendar_date_id_fkey'
      and c.contype = 'f'
      and i.indisvalid
      and i.indisready
      and i.indislive
      and i.indpred is null
      and i.indnkeyatts >= 1
      and pg_get_indexdef(i.indexrelid, 1, true) = 'special_calendar_date_id'
  ),
  'availability_exceptions.special_calendar_date_id has a supporting left-prefix index'
);

select ok(
  exists (
    select 1
    from pg_constraint c
    join pg_index i on i.indrelid = c.conrelid
    where c.conname = 'checkout_customer_verifications_customer_id_fkey'
      and c.contype = 'f'
      and i.indisvalid
      and i.indisready
      and i.indislive
      and i.indpred is null
      and i.indnkeyatts >= 1
      and pg_get_indexdef(i.indexrelid, 1, true) = 'customer_id'
  ),
  'checkout_customer_verifications.customer_id has a supporting left-prefix index'
);

select ok(
  exists (
    select 1
    from pg_constraint c
    join pg_index i on i.indrelid = c.conrelid
    where c.conname = 'waitlist_private_invites_created_by_admin_id_fkey'
      and c.contype = 'f'
      and i.indisvalid
      and i.indisready
      and i.indislive
      and i.indpred is null
      and i.indnkeyatts >= 1
      and pg_get_indexdef(i.indexrelid, 1, true) = 'created_by_admin_id'
  ),
  'waitlist_private_invites.created_by_admin_id has a supporting left-prefix index'
);

select ok(
  exists (
    select 1
    from pg_constraint c
    join pg_index i on i.indrelid = c.conrelid
    where c.conname = 'waitlist_private_round_invites_created_by_admin_id_fkey'
      and c.contype = 'f'
      and i.indisvalid
      and i.indisready
      and i.indislive
      and i.indpred is null
      and i.indnkeyatts >= 1
      and pg_get_indexdef(i.indexrelid, 1, true) = 'created_by_admin_id'
  ),
  'waitlist_private_round_invites.created_by_admin_id has a supporting left-prefix index'
);

select ok(
  exists (
    select 1
    from pg_constraint c
    join pg_index i on i.indrelid = c.conrelid
    where c.conname = 'waitlist_private_rounds_booking_page_id_fkey'
      and c.contype = 'f'
      and i.indisvalid
      and i.indisready
      and i.indislive
      and i.indpred is null
      and i.indnkeyatts >= 1
      and pg_get_indexdef(i.indexrelid, 1, true) = 'booking_page_id'
  ),
  'waitlist_private_rounds.booking_page_id has a supporting left-prefix index'
);

select ok(
  exists (
    select 1
    from pg_constraint c
    join pg_index i on i.indrelid = c.conrelid
    where c.conname = 'waitlist_private_rounds_created_by_admin_id_fkey'
      and c.contype = 'f'
      and i.indisvalid
      and i.indisready
      and i.indislive
      and i.indpred is null
      and i.indnkeyatts >= 1
      and pg_get_indexdef(i.indexrelid, 1, true) = 'created_by_admin_id'
  ),
  'waitlist_private_rounds.created_by_admin_id has a supporting left-prefix index'
);

select ok(
  exists (
    select 1
    from pg_constraint c
    join pg_index i on i.indrelid = c.conrelid
    where c.conname = 'waitlist_private_slot_resources_resource_id_fkey'
      and c.contype = 'f'
      and i.indisvalid
      and i.indisready
      and i.indislive
      and i.indpred is null
      and i.indnkeyatts >= 1
      and pg_get_indexdef(i.indexrelid, 1, true) = 'resource_id'
  ),
  'waitlist_private_slot_resources.resource_id has a supporting left-prefix index'
);

select ok(
  exists (
    select 1
    from pg_constraint c
    join pg_index i on i.indrelid = c.conrelid
    where c.conname = 'waitlist_private_slot_services_service_employee_id_fkey'
      and c.contype = 'f'
      and i.indisvalid
      and i.indisready
      and i.indislive
      and i.indpred is null
      and i.indnkeyatts >= 1
      and pg_get_indexdef(i.indexrelid, 1, true) = 'service_employee_id'
  ),
  'waitlist_private_slot_services.service_employee_id has a supporting left-prefix index'
);

select ok(
  exists (
    select 1
    from pg_constraint c
    join pg_index i on i.indrelid = c.conrelid
    where c.conname = 'waitlist_private_slot_services_service_id_fkey'
      and c.contype = 'f'
      and i.indisvalid
      and i.indisready
      and i.indislive
      and i.indpred is null
      and i.indnkeyatts >= 1
      and pg_get_indexdef(i.indexrelid, 1, true) = 'service_id'
  ),
  'waitlist_private_slot_services.service_id has a supporting left-prefix index'
);

select ok(
  exists (
    select 1
    from pg_constraint c
    join pg_index i on i.indrelid = c.conrelid
    where c.conname = 'waitlist_private_slots_booking_page_id_fkey'
      and c.contype = 'f'
      and i.indisvalid
      and i.indisready
      and i.indislive
      and i.indpred is null
      and i.indnkeyatts >= 1
      and pg_get_indexdef(i.indexrelid, 1, true) = 'booking_page_id'
  ),
  'waitlist_private_slots.booking_page_id has a supporting left-prefix index'
);

select ok(
  exists (
    select 1
    from pg_constraint c
    join pg_index i on i.indrelid = c.conrelid
    where c.conname = 'waitlist_private_slots_claimed_appointment_id_fkey'
      and c.contype = 'f'
      and i.indisvalid
      and i.indisready
      and i.indislive
      and i.indpred is null
      and i.indnkeyatts >= 1
      and pg_get_indexdef(i.indexrelid, 1, true) = 'claimed_appointment_id'
  ),
  'waitlist_private_slots.claimed_appointment_id has a supporting left-prefix index'
);

select ok(
  exists (
    select 1
    from pg_constraint c
    join pg_index i on i.indrelid = c.conrelid
    where c.conname = 'waitlist_private_slots_claimed_checkout_hold_id_fkey'
      and c.contype = 'f'
      and i.indisvalid
      and i.indisready
      and i.indislive
      and i.indpred is null
      and i.indnkeyatts >= 1
      and pg_get_indexdef(i.indexrelid, 1, true) = 'claimed_checkout_hold_id'
  ),
  'waitlist_private_slots.claimed_checkout_hold_id has a supporting left-prefix index'
);

select ok(
  exists (
    select 1
    from pg_constraint c
    join pg_index i on i.indrelid = c.conrelid
    where c.conname = 'waitlist_private_slots_created_by_admin_id_fkey'
      and c.contype = 'f'
      and i.indisvalid
      and i.indisready
      and i.indislive
      and i.indpred is null
      and i.indnkeyatts >= 1
      and pg_get_indexdef(i.indexrelid, 1, true) = 'created_by_admin_id'
  ),
  'waitlist_private_slots.created_by_admin_id has a supporting left-prefix index'
);

select * from finish();
rollback;
