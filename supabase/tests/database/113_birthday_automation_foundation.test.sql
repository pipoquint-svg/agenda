begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(12);

select has_column('public','customers','birth_date','customers has canonical birth date');
select has_table('public','birthday_automation_settings','birthday automation settings exists');
select has_table('public','birthday_automation_cycles','birthday automation idempotency ledger exists');
select ok(not has_table_privilege('anon','public.birthday_automation_settings','SELECT'),'anon cannot read birthday settings');
select ok(not has_table_privilege('authenticated','public.birthday_automation_settings','SELECT'),'authenticated cannot read birthday settings');
select ok(has_table_privilege('service_role','public.birthday_automation_settings','SELECT'),'service role can read birthday settings');
select is((select count(*)::integer from public.birthday_automation_settings),2,'both operation rows are seeded');
select is((select count(*)::integer from public.birthday_automation_settings where is_active),0,'birthday automation is disabled by default');
select is((select count(*)::integer from public.birthday_automation_settings where is_active and (send_message or generate_coupon)),0,'no birthday side effect is operationally enabled while automation is inactive');

insert into public.customers(id,customer_type,name,birth_date)
values ('97900000-0000-0000-0000-000000000001','PERSON','Birthday Fixture','1990-08-26');

insert into public.birthday_automation_cycles(operation_scope,customer_id,birthday_year,trigger_kind,target_date)
values ('SABRINA','97900000-0000-0000-0000-000000000001',2026,'BIRTHDAY','2026-08-26');

select throws_ok(
  $$insert into public.birthday_automation_cycles(operation_scope,customer_id,birthday_year,trigger_kind,target_date)
    values ('SABRINA','97900000-0000-0000-0000-000000000001',2026,'BIRTHDAY','2026-08-26')$$,
  '23505', null, 'same customer/year/trigger cannot be generated twice'
);

select throws_ok(
  $$update public.birthday_automation_settings
    set is_active=true
    where operation_scope='SABRINA'$$,
  '23514', null, 'cannot activate birthday automation without any side effect enabled'
);

select lives_ok(
  $$update public.birthday_automation_settings
    set send_message=true, is_active=true
    where operation_scope='SABRINA'$$,
  'message-only birthday automation configuration is structurally valid'
);

select * from finish();
rollback;
