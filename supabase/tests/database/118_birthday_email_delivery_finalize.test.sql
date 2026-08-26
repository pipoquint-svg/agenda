begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(10);

select has_function('public','finalize_birthday_email_delivery',array['uuid','uuid','text','text'],'birthday email finalizer exists');
select ok(not has_function_privilege('anon','public.finalize_birthday_email_delivery(uuid,uuid,text,text)','EXECUTE'),'anon cannot finalize birthday email');
select ok(not has_function_privilege('authenticated','public.finalize_birthday_email_delivery(uuid,uuid,text,text)','EXECUTE'),'authenticated cannot finalize birthday email');
select ok(has_function_privilege('service_role','public.finalize_birthday_email_delivery(uuid,uuid,text,text)','EXECUTE'),'service role can finalize birthday email');

insert into public.customers(id,customer_type,name,email,birth_date)
values ('98900000-0000-0000-0000-000000000001','PERSON','Birthday Delivery Fixture','birthday-delivery@example.com','1990-08-26');

insert into public.birthday_automation_cycles(id,operation_scope,customer_id,birthday_year,trigger_kind,target_date,message_status)
values ('98900000-0000-0000-0000-000000000002','BLACKSHEEP','98900000-0000-0000-0000-000000000001',2030,'BEFORE','2030-08-19','PENDING');

insert into public.notification_template_configs(
  id,event_key,channel,audience,operation_scope,title_template,body_template,is_active,variable_schema
) values (
  '98900000-0000-0000-0000-000000000003','BIRTHDAY','EMAIL','CUSTOMER','BLACKSHEEP',
  'Birthday delivery fixture','Fixture body',true,'[]'::jsonb
);

insert into public.notification_delivery_logs(
  id,template_id,event_key,channel,audience,customer_id,recipient_hash,status,attempt_count,idempotency_key,payload_snapshot
) values (
  '98900000-0000-0000-0000-000000000004','98900000-0000-0000-0000-000000000003',
  'BIRTHDAY','EMAIL','CUSTOMER','98900000-0000-0000-0000-000000000001',repeat('a',64),'PENDING',0,
  'birthday:BLACKSHEEP:fixture:2030:BEFORE',
  jsonb_build_object('birthday_cycle_id','98900000-0000-0000-0000-000000000002','operation_scope','BLACKSHEEP')
);

select lives_ok(
  $$select public.finalize_birthday_email_delivery(
    '98900000-0000-0000-0000-000000000004',
    '98900000-0000-0000-0000-000000000002',
    'provider-fixture-1',
    'b***@example.com'
  )$$,
  'successful provider response finalizes atomically'
);

select is((select status from public.notification_delivery_logs where id='98900000-0000-0000-0000-000000000004'),'SENT','delivery log becomes SENT');
select is((select attempt_count from public.notification_delivery_logs where id='98900000-0000-0000-0000-000000000004'),1,'finalization increments attempt count exactly once');
select is((select message_status from public.birthday_automation_cycles where id='98900000-0000-0000-0000-000000000002'),'SENT','birthday cycle becomes SENT');
select is((select count(*)::integer from public.audit_logs where entity_id='98900000-0000-0000-0000-000000000002' and action='BIRTHDAY_MESSAGE_SENT'),1,'sent evidence creates exactly one audit row');

select lives_ok(
  $$select public.finalize_birthday_email_delivery(
    '98900000-0000-0000-0000-000000000004',
    '98900000-0000-0000-0000-000000000002',
    'provider-fixture-1',
    'b***@example.com'
  )$$,
  'finalization replay is idempotent'
);

select * from finish();
rollback;
