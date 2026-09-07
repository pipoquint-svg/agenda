begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(7);

create temporary table _private_rotate_def as
select lower(pg_get_functiondef(
  'public.service_admin_rotate_waitlist_private_invite(uuid,uuid)'::regprocedure
)) as def;

select ok(
  exists (select 1 from _private_rotate_def where def is not null),
  'private invite rotation function exists'
);

select ok(
  has_function_privilege('service_role', 'public.service_admin_rotate_waitlist_private_invite(uuid,uuid)', 'EXECUTE'),
  'service role can rotate an eligible private invite'
);

select ok(
  not has_function_privilege('anon', 'public.service_admin_rotate_waitlist_private_invite(uuid,uuid)', 'EXECUTE'),
  'anonymous users cannot rotate private invites'
);

select ok(
  not has_function_privilege('authenticated', 'public.service_admin_rotate_waitlist_private_invite(uuid,uuid)', 'EXECUTE'),
  'authenticated users cannot rotate private invites directly'
);

select ok(
  exists (
    select 1 from _private_rotate_def
    where def like '%service_expire_waitlist_private_slots%'
  ),
  'rotation first expires due open private slots'
);

select ok(
  exists (
    select 1 from _private_rotate_def
    where def like '%v_slot.status <> ''open''%'
      and def like '%waitlist_private_slot_not_available%'
  ),
  'rotation is allowed only while the shared private slot is OPEN'
);

select ok(
  exists (
    select 1 from _private_rotate_def
    where def like '%v_invite.checkout_hold_id is not null%'
      and def like '%waitlist_private_invite_in_progress%'
  ),
  'an invite with an active checkout claim cannot be rotated'
);

select * from finish();
rollback;
