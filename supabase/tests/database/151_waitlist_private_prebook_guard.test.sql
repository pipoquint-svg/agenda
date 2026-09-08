begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(6);

create temporary table _private_prebook_def as
select pg_get_functiondef(
  'public.service_public_get_checkout_prebook_option(text)'::regprocedure
) as def;

select ok(
  exists (select 1 from _private_prebook_def where def is not null),
  'checkout prebook option function exists'
);

select ok(
  exists (
    select 1 from _private_prebook_def
    where def like '%WAITLIST_PRIVATE_INVITE%'
  ),
  'private waitlist checkout is recognized by the prebook boundary'
);

select ok(
  exists (
    select 1 from _private_prebook_def
    where def like '%PREBOOK_NOT_AVAILABLE%'
  ),
  'private waitlist checkout cannot become a long pre-reservation hold'
);

select ok(
  exists (
    select 1
    from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname = 'waitlist_private_slot_services'
      and t.tgname = 'waitlist_private_slot_service_page_guard_trg'
      and not t.tgisinternal
  ),
  'private slot services are guarded by booking-page membership'
);

select ok(
  not has_function_privilege('anon', 'public.trg_validate_waitlist_private_slot_service()', 'EXECUTE'),
  'anonymous users cannot execute the private slot page guard directly'
);

select ok(
  not has_function_privilege('authenticated', 'public.trg_validate_waitlist_private_slot_service()', 'EXECUTE'),
  'authenticated users cannot execute the private slot page guard directly'
);

select * from finish();
rollback;
