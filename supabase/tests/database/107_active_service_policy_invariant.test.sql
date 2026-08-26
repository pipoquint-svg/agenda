begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(5);

insert into public.categories(id,name,slug,operation_scope,is_active)
values ('97100000-0000-0000-0000-000000000001','I09 Guard','i09-guard','BLACKSHEEP',true);

-- Draft creation remains possible without inventing a policy.
insert into public.services(id,category_id,name,slug,operation_scope,base_duration_minutes,base_price,is_active)
values ('97100000-0000-0000-0000-000000000002','97100000-0000-0000-0000-000000000001','I09 Draft','i09-draft','BLACKSHEEP',60,10,false);
select ok(not (select is_active from public.services where id='97100000-0000-0000-0000-000000000002'), 'inactive draft may exist without policy');

-- Force deferred guards inside this test transaction so pgTAP can observe them before rollback.
update public.services set is_active=true where id='97100000-0000-0000-0000-000000000002';
select throws_ok(
  $$ set constraints services_active_change_policy_guard immediate $$,
  '23514','ACTIVE_SERVICE_CHANGE_POLICY_REQUIRED',
  'activation without policy is rejected at the source invariant'
);
set constraints services_active_change_policy_guard deferred;
update public.services set is_active=false where id='97100000-0000-0000-0000-000000000002';

insert into public.service_change_policies(
  service_id,notice_hours,reschedule_first_early_percent,reschedule_first_late_percent,
  reschedule_repeat_percent,cancellation_late_percent
) values ('97100000-0000-0000-0000-000000000002',48,0,0,0,100);
update public.services set is_active=true where id='97100000-0000-0000-0000-000000000002';
set constraints services_active_change_policy_guard immediate;
select ok((select is_active from public.services where id='97100000-0000-0000-0000-000000000002'), 'service with explicit policy may activate');
set constraints services_active_change_policy_guard deferred;

-- Removal is guarded in the opposite direction.
delete from public.service_change_policies where service_id='97100000-0000-0000-0000-000000000002';
select throws_ok(
  $$ set constraints active_service_policy_delete_guard immediate $$,
  '23514','ACTIVE_SERVICE_CHANGE_POLICY_CANNOT_BE_REMOVED',
  'policy cannot be removed while service remains active'
);
set constraints active_service_policy_delete_guard deferred;

-- Deactivate then remove is valid in one transaction.
update public.services set is_active=false where id='97100000-0000-0000-0000-000000000002';
delete from public.service_change_policies where service_id='97100000-0000-0000-0000-000000000002';
set constraints active_service_policy_delete_guard immediate;
select ok(not exists(select 1 from public.service_change_policies where service_id='97100000-0000-0000-0000-000000000002'), 'inactive service may have policy removed');

select * from finish();
rollback;
