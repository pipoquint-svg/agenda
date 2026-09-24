begin;

select plan(3);

select is(
  (select column_default
   from information_schema.columns
   where table_schema = 'public'
     and table_name = 'services'
     and column_name = 'minimum_booking_notice_minutes'),
  '0',
  'legacy core booking notice keeps zero as the default'
);

select ok(
  not exists (
    select 1
    from public.services
    where minimum_booking_notice_minutes <> 0
  ),
  'migrated services do not carry a legacy core lead-time restriction'
);

select ok(
  exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'services'
      and column_name = 'public_minimum_booking_notice_hours'
  ),
  'public booking lead time remains isolated in the public-only field'
);

select * from finish();
rollback;
