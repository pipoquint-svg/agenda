begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(5);

select ok(
  exists(
    select 1 from pg_constraint
    where conrelid='public.appointments'::regclass
      and conname='appointments_confirmed_requires_policy_snapshot_ck'
      and contype='c'
      and not convalidated
  ),
  'CONFIRMED timestamp/snapshot check exists as NOT VALID'
);

select ok(
  exists(
    select 1 from pg_constraint
    where conrelid='public.appointments'::regclass
      and conname='appointments_change_policy_snapshot_fk'
      and contype='f'
      and condeferrable
      and condeferred
      and not convalidated
  ),
  'snapshot marker FK is deferred and NOT VALID'
);

insert into public.employees(id,name)
values ('90900000-0000-0000-0000-000000000001','I09 Confirmation Employee');
insert into public.services(
  id,name,slug,base_duration_minutes,base_price,minimum_people,maximum_people,is_active
) values (
  '90900000-0000-0000-0000-000000000002','I09 Confirmation Service','i09-confirmation-service',60,100,1,1,false
);
insert into public.service_change_policies(
  service_id,notice_hours,reschedule_first_early_percent,reschedule_first_late_percent,reschedule_repeat_percent,cancellation_late_percent
) values ('90900000-0000-0000-0000-000000000002',48,0,0,0,0);
update public.services set is_active=true where id='90900000-0000-0000-0000-000000000002';
insert into public.service_employees(id,service_id,employee_id)
values ('90900000-0000-0000-0000-000000000003','90900000-0000-0000-0000-000000000002','90900000-0000-0000-0000-000000000001');

insert into public.appointments(
  id,public_code,service_id,service_employee_id,status,financial_status,
  start_at,end_at,duration_minutes,people_count,commercial_value,confirmed_at
) values (
  '90900000-0000-0000-0000-000000000010','I09-VALID',
  '90900000-0000-0000-0000-000000000002','90900000-0000-0000-0000-000000000003',
  'CONFIRMED','PENDING','2035-06-01 10:00:00-03','2035-06-01 11:00:00-03',60,1,100,now()
);

select is(
  (select change_policy_snapshot_appointment_id from public.appointments where id='90900000-0000-0000-0000-000000000010'),
  '90900000-0000-0000-0000-000000000010'::uuid,
  'valid confirmation is marked for its own immutable policy snapshot'
);

select ok(
  exists(select 1 from public.appointment_change_policy_snapshots where appointment_id='90900000-0000-0000-0000-000000000010'),
  'valid confirmation captures the referenced policy snapshot'
);

create temporary table i09_violation(seen boolean not null default false);
insert into i09_violation default values;
do $$
begin
  begin
    insert into public.appointments(
      id,public_code,service_id,service_employee_id,status,financial_status,
      start_at,end_at,duration_minutes,people_count,commercial_value,confirmed_at
    ) values (
      '90900000-0000-0000-0000-000000000011','I09-NO-TIMESTAMP',
      '90900000-0000-0000-0000-000000000002','90900000-0000-0000-0000-000000000003',
      'CONFIRMED','PENDING','2035-06-01 12:00:00-03','2035-06-01 13:00:00-03',60,1,100,null
    );
  exception when check_violation then
    update i09_violation set seen=true;
  end;
end;
$$;

select is((select seen from i09_violation),true,'direct CONFIRMED state without confirmed_at is rejected');

select * from finish();
rollback;
