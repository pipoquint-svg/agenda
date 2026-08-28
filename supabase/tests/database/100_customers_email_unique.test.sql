begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(4);

select ok(
  exists (
    select 1
    from pg_indexes
    where schemaname = 'public'
      and tablename = 'customers'
      and indexname = 'customers_email_lower_uq'
      and indexdef ilike 'create unique index%lower(email)%'
  ),
  'customers e-mail has a case-insensitive unique index'
);

insert into public.customers (name, email)
values ('QA Unique Email A', 'qa-customer@example.test');

select throws_ok(
  $$insert into public.customers (name, email) values ('QA Unique Email B', 'QA-CUSTOMER@EXAMPLE.TEST')$$,
  '23505',
  'duplicate key value violates unique constraint "customers_email_lower_uq"',
  'same customer e-mail with different casing is rejected'
);

insert into public.customers (name, email)
values ('QA Null Email A', null), ('QA Null Email B', null);

select is(
  (select count(*)::integer from public.customers where name like 'QA Null Email %' and email is null),
  2,
  'multiple customers without e-mail remain allowed'
);

select is(
  (select count(*)::integer from public.customers where lower(email) = 'qa-customer@example.test'),
  1,
  'the original customer record remains unchanged'
);

select * from finish();
rollback;
