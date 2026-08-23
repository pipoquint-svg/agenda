begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(8);

insert into public.categories(id,name,slug)
values ('95000000-0000-0000-0000-000000000001','Token Revoke','token-revoke-test');
insert into public.employees(id,name)
values ('95000000-0000-0000-0000-000000000002','Token Revoke Employee');
insert into public.services(id,category_id,name,slug,base_duration_minutes,base_price,minimum_people,maximum_people,maximum_booking_horizon_days,confirmation_percentage)
values ('95000000-0000-0000-0000-000000000010','95000000-0000-0000-0000-000000000001','Token Revoke Service','token-revoke-service',60,100,1,1,5000,50);
insert into public.service_employees(id,service_id,employee_id)
values ('95000000-0000-0000-0000-000000000011','95000000-0000-0000-0000-000000000010','95000000-0000-0000-0000-000000000002');
insert into public.customers(id,name,email,phone,cpf_cnpj)
values ('95000000-0000-0000-0000-000000000020','Token Revoke Customer','revoke@example.com','48999994444','52998224725');
insert into public.appointments(id,public_code,service_id,service_employee_id,service_name_snapshot,primary_customer_id,status,financial_status,start_at,end_at,core_start_at,core_end_at,duration_minutes,people_count,commercial_value)
values ('95000000-0000-0000-0000-000000000030','TOKEN-REVOKE-1','95000000-0000-0000-0000-000000000010','95000000-0000-0000-0000-000000000011','Token Revoke Service','95000000-0000-0000-0000-000000000020','CONFIRMED','PARTIALLY_PAID','2035-11-01 09:00:00-03','2035-11-01 10:00:00-03','2035-11-01 09:00:00-03','2035-11-01 10:00:00-03',60,1,100);

create temporary table token_one as
select public.service_issue_appointment_action_token('95000000-0000-0000-0000-000000000030','RESCHEDULE','EMAIL','r***@example.com','revoke-issue-1') payload;

select ok(
  (select revoked_at is null from public.appointment_access_tokens where id=((select payload->>'token_id' from token_one))::uuid),
  'fresh action token is active'
);

update public.appointments
set start_at='2035-11-01 11:00:00-03',end_at='2035-11-01 12:00:00-03',core_start_at='2035-11-01 11:00:00-03',core_end_at='2035-11-01 12:00:00-03'
where id='95000000-0000-0000-0000-000000000030';

select ok(
  (select revoked_at is not null from public.appointment_access_tokens where id=((select payload->>'token_id' from token_one))::uuid),
  'changing appointment start revokes prior action token'
);
select is(
  (select count(*)::integer from public.appointment_token_events where appointment_access_token_id=((select payload->>'token_id' from token_one))::uuid and event_type='REVOKED'),
  1,
  'start change appends a revoked evidence event'
);
select throws_ok(
  format('select public.service_resolve_appointment_action_token(%L,%L,null,null,null)',(select payload->>'access_token' from token_one),'RESCHEDULE'),
  'P0001','APPOINTMENT_TOKEN_INVALID',
  'revoked token cannot resolve after start change'
);

create temporary table token_two as
select public.service_issue_appointment_action_token('95000000-0000-0000-0000-000000000030','CANCEL','EMAIL','r***@example.com','revoke-issue-2') payload;
select ok(
  (select revoked_at is null from public.appointment_access_tokens where id=((select payload->>'token_id' from token_two))::uuid),
  'new token can be issued for the new appointment start'
);

update public.appointments
set status='CANCELLED',cancelled_at=now()
where id='95000000-0000-0000-0000-000000000030';

select ok(
  (select revoked_at is not null from public.appointment_access_tokens where id=((select payload->>'token_id' from token_two))::uuid),
  'appointment status change revokes active action token'
);
select is(
  (select count(*)::integer from public.appointment_token_events where appointment_access_token_id=((select payload->>'token_id' from token_two))::uuid and event_type='REVOKED'),
  1,
  'status change appends a revoked evidence event'
);
select ok(
  not has_function_privilege('anon','public.revoke_action_tokens_after_appointment_change()','EXECUTE'),
  'anonymous clients cannot invoke revocation trigger helper'
);

select * from finish();
rollback;
