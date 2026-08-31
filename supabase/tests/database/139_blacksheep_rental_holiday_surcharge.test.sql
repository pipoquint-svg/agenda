begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(12);

select ok(public.blacksheep_rental_special_date(date '2026-01-01'),'Ano Novo is a BlackSheep rental special date');
select ok(public.blacksheep_rental_special_date(date '2026-09-07'),'Independencia is a BlackSheep rental special date');
select ok(public.blacksheep_rental_special_date(date '2026-11-20'),'Consciencia Negra is a BlackSheep rental special date');
select ok(public.blacksheep_rental_special_date(date '2026-02-16'),'Carnaval Monday is treated commercially as a holiday');
select ok(public.blacksheep_rental_special_date(date '2026-02-17'),'Carnaval Tuesday is treated commercially as a holiday');
select ok(public.blacksheep_rental_special_date(date '2026-04-03'),'Good Friday is treated commercially as a holiday');
select ok(public.blacksheep_rental_special_date(date '2026-06-04'),'Corpus Christi is treated commercially as a holiday');
select ok(not public.blacksheep_rental_special_date(date '2026-09-08'),'ordinary weekday is not a special date');
select ok(public.blacksheep_rental_special_date(date '2027-02-08'),'future Carnaval is calculated dynamically');
select ok(public.blacksheep_rental_special_date(date '2027-05-27'),'future Corpus Christi is calculated dynamically');

select ok(
  position('public.blacksheep_rental_special_date(v_block_local_date)' in
    pg_get_functiondef('public.calculate_booking_quotes_for_duration_batch(uuid,uuid,integer,jsonb,integer,timestamptz[],text)'::regprocedure)
  ) > 0,
  'BLOCKS pricing engine checks BlackSheep special dates block by block'
);

select ok(
  position('greatest(v_block_matched_percent, 20)' in
    pg_get_functiondef('public.calculate_booking_quotes_for_duration_batch(uuid,uuid,integer,jsonb,integer,timestamptz[],text)'::regprocedure)
  ) > 0,
  'holiday surcharge is at least 20 percent without stacking another 20 percent over existing night/weekend surcharge'
);

select * from finish();
rollback;
