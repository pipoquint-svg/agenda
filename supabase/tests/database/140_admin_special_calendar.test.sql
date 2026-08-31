begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(20);

select has_table('public','special_calendar_dates','special calendar table exists');

select is((select treatment from public.special_calendar_dates where local_date = date '2026-01-01'),'CLOSED','1 January starts permanently closed');
select is((select treatment from public.special_calendar_dates where local_date = date '2026-12-25'),'CLOSED','Christmas starts permanently closed');
select is((select treatment from public.special_calendar_dates where local_date = date '2030-01-01'),'CLOSED','future 1 January stays closed');
select is((select treatment from public.special_calendar_dates where local_date = date '2030-12-25'),'CLOSED','future Christmas stays closed');

select is((select treatment from public.special_calendar_dates where local_date = date '2026-02-16'),'SURCHARGE','official Carnival Monday has surcharge');
select is((select source_status from public.special_calendar_dates where local_date = date '2027-02-08'),'PROJECTED','future optional holiday is clearly projected');
select is((select treatment from public.special_calendar_dates where local_date = date '2028-02-29'),'SURCHARGE','projected optional holiday keeps surcharge default');
select is((select treatment from public.special_calendar_dates where local_date = date '2026-04-24'),'SURCHARGE','Palhoca municipal anniversary has surcharge');
select is((select treatment from public.special_calendar_dates where local_date = date '2030-06-20'),'SURCHARGE','future Palhoca Corpus Christi has surcharge');
select is((select category from public.special_calendar_dates where local_date = date '2026-08-16'),'STATE','Santa Catarina Data Magna observed date is represented');

select ok(public.blacksheep_rental_special_date(date '2026-01-01'),'closed date remains a special commercial date for pricing compatibility');
select ok(public.blacksheep_rental_special_date(date '2027-05-27'),'future Corpus Christi is driven by the seeded calendar');
select ok(not public.blacksheep_rental_special_date(date '2026-09-08'),'ordinary date is not special');

select has_column('public','availability_exceptions','special_calendar_date_id','resource exceptions can identify calendar-managed blocks');

insert into public.categories(id, name, slug)
values ('98500000-0000-0000-0000-000000000001', 'Special Calendar Test', 'special-calendar-test');

insert into public.resources(id, name, resource_type)
values ('98500000-0000-0000-0000-000000000002', 'SPECIAL CALENDAR STUDIO', 'PHYSICAL');

insert into public.services(
  id, category_id, name, slug,
  base_duration_minutes, base_price,
  buffer_before_minutes, buffer_after_minutes,
  minimum_people, maximum_people, maximum_booking_horizon_days,
  operation_scope
) values (
  '98500000-0000-0000-0000-000000000003',
  '98500000-0000-0000-0000-000000000001',
  'Special Calendar Rental', 'locacao-estudio',
  60, 180.00,
  0, 0,
  1, 20, 5000,
  'BLACKSHEEP'
);

insert into public.service_resources(service_id, resource_id, is_required)
values ('98500000-0000-0000-0000-000000000003', '98500000-0000-0000-0000-000000000002', true);

select is(
  (select count(*)::integer
   from public.availability_exceptions ae
   where ae.resource_id = '98500000-0000-0000-0000-000000000002'
     and ae.special_calendar_date_id is not null),
  10,
  'binding the BlackSheep rental resource materializes five years of Jan 1 and Christmas blocks'
);

select ok(not has_function_privilege('anon','public.service_admin_list_special_calendar_dates(integer,integer,uuid)','EXECUTE'),'anon cannot list admin special calendar through RPC');
select ok(not has_function_privilege('authenticated','public.service_admin_upsert_special_calendar_date_audited(uuid,date,text,text,text,text,text,uuid)','EXECUTE'),'authenticated users cannot mutate admin special calendar directly');
select ok(not has_function_privilege('authenticated','public.service_admin_delete_special_calendar_date_audited(uuid,uuid)','EXECUTE'),'authenticated users cannot delete admin special dates directly');
select ok(has_function_privilege('service_role','public.service_admin_upsert_special_calendar_date_audited(uuid,date,text,text,text,text,text,uuid)','EXECUTE'),'service role can invoke audited special calendar mutation');

select * from finish();
rollback;
