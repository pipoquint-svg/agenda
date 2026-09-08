begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(4);

create temporary table _private_hold_def as
select pg_get_functiondef(
  'public.public_create_waitlist_private_checkout_hold(text,uuid,jsonb,integer)'::regprocedure
) as def;

select ok(
  exists (select 1 from _private_hold_def where def is not null),
  'private waitlist checkout hold function exists'
);

select ok(
  exists (
    select 1 from _private_hold_def
    where def like '%v_slot.expires_at%'
      and def like '%v_invite.expires_at%'
  ),
  'private checkout hold cannot outlive slot or invite validity'
);

select ok(
  exists (
    select 1 from _private_hold_def
    where def like '%occupied_range%'
      and def like '%calculate_booking_resource_ranges%'
  ),
  'claimed allocation is narrowed to the selected service resource range'
);

select ok(
  exists (
    select 1 from _private_hold_def
    where def like '%WAITLIST_PRIVATE_SLOT_RESOURCE_INTEGRITY_ERROR%'
      and def like '%is distinct from r.occupied_range%'
  ),
  'private checkout verifies the persisted allocation range after claim'
);

select * from finish();
rollback;
