begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(3);

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

select * from finish();
rollback;
