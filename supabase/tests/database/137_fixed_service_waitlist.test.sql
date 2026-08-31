begin;
create extension if not exists pgtap with schema extensions;
set local search_path=public,extensions;

select plan(18);

insert into public.categories(id,name,slug)
values ('98700000-0000-0000-0000-000000000001','Waitlist test','waitlist-test');

insert into public.employees(id,name)
values ('98700000-0000-0000-0000-000000000002','Waitlist employee');

insert into public.services(
  id,category_id,name,slug,base_duration_minutes,base_price,
  buffer_before_minutes,buffer_after_minutes,minimum_people,maximum_people,
  minimum_booking_notice_minutes,maximum_booking_horizon_days,duration_mode,
  booking_block_minutes,minimum_booking_blocks,maximum_booking_blocks,price_per_block
) values
  ('98700000-0000-0000-0000-000000000010','98700000-0000-0000-0000-000000000001','Fixed waitlist A','fixed-waitlist-a',60,300,0,0,1,5,0,5000,'FIXED',null,null,null,null),
  ('98700000-0000-0000-0000-000000000011','98700000-0000-0000-0000-000000000001','Fixed waitlist B','fixed-waitlist-b',60,300,0,0,1,5,0,5000,'FIXED',null,null,null,null),
  ('98700000-0000-0000-0000-000000000012','98700000-0000-0000-0000-000000000001','Blocks no waitlist','blocks-no-waitlist',30,80,0,0,1,5,0,5000,'BLOCKS',30,2,8,80);

insert into public.service_employees(id,service_id,employee_id) values
  ('98700000-0000-0000-0000-000000000020','98700000-0000-0000-0000-000000000010','98700000-0000-0000-0000-000000000002'),
  ('98700000-0000-0000-0000-000000000021','98700000-0000-0000-0000-000000000011','98700000-0000-0000-0000-000000000002'),
  ('98700000-0000-0000-0000-000000000022','98700000-0000-0000-0000-000000000012','98700000-0000-0000-0000-000000000002');

insert into public.booking_pages(id,slug,display_name,title,brand_key,is_active)
values ('98700000-0000-0000-0000-000000000030','waitlist-test','Waitlist','Waitlist test','SABRINA',true);
insert into public.booking_page_services(booking_page_id,service_id,is_active,sort_order) values
  ('98700000-0000-0000-0000-000000000030','98700000-0000-0000-0000-000000000010',true,10),
  ('98700000-0000-0000-0000-000000000030','98700000-0000-0000-0000-000000000011',true,20),
  ('98700000-0000-0000-0000-000000000030','98700000-0000-0000-0000-000000000012',true,30);

insert into public.admin_users(id,display_name,role,is_active) values
  ('98700000-0000-0000-0000-000000000040','Waitlist Owner','OWNER',true),
  ('98700000-0000-0000-0000-000000000041','Waitlist Operation','OPERATION',true),
  ('98700000-0000-0000-0000-000000000042','Waitlist Finance','FINANCE',true);

insert into public.customers(id,name,email,phone)
values ('98700000-0000-0000-0000-000000000050','Existing waitlist client','existing-waitlist@example.com','+55 (48) 99999-7050');

select is(
  (select count(*)::integer from public.list_available_slots(
    '98700000-0000-0000-0000-000000000010','98700000-0000-0000-0000-000000000020','[]'::jsonb,1,date '2035-03-12','America/Sao_Paulo'
  )),0,'FIXED fixture has a successful availability search with zero slots'
);

create temporary table first_signup as
select public.public_create_service_waitlist_entry(
  'waitlist-test','98700000-0000-0000-0000-000000000010','Pessoa Espera','pessoa.espera@example.com','+55 (48) 99999-7001'
) data;

select ok(exists(select 1 from public.service_waitlist_entries where id=(select (data->>'id')::uuid from first_signup)),'waitlist signup is created for a FIXED service with no slots');
select is((select service_id from public.service_waitlist_entries where id=(select (data->>'id')::uuid from first_signup)),'98700000-0000-0000-0000-000000000010'::uuid,'waitlist is stored by service rather than requested date');
select ok(exists(
  select 1 from public.notification_delivery_logs
  where idempotency_key=(select data->>'notification_idempotency_key' from first_signup)
    and event_key='WAITLIST_SIGNUP_TEAM' and audience='EMPLOYEE' and channel='EMAIL' and status='PENDING'
),'new signup creates the unified team email delivery evidence');

select throws_ok(
  $$select public.public_create_service_waitlist_entry('waitlist-test','98700000-0000-0000-0000-000000000010','Mesmo Email','pessoa.espera@example.com','+55 (48) 99999-7999')$$,
  'P0001','WAITLIST_ALREADY_REGISTERED','same email cannot join the same service twice'
);
select throws_ok(
  $$select public.public_create_service_waitlist_entry('waitlist-test','98700000-0000-0000-0000-000000000010','Mesmo Whats','outro@example.com','+55 48 99999-7001')$$,
  'P0001','WAITLIST_ALREADY_REGISTERED','same WhatsApp cannot join the same service twice'
);
select lives_ok(
  $$select public.public_create_service_waitlist_entry('waitlist-test','98700000-0000-0000-0000-000000000011','Pessoa Espera','pessoa.espera@example.com','+55 (48) 99999-7001')$$,
  'same person may join a different FIXED service'
);
select throws_ok(
  $$select public.public_create_service_waitlist_entry('waitlist-test','98700000-0000-0000-0000-000000000012','Pessoa Blocos','blocos@example.com','+55 (48) 99999-7012')$$,
  'P0001','WAITLIST_FIXED_ONLY','BLOCKS service is rejected by the backend guardrail'
);
select throws_ok(
  $$select public.public_create_service_waitlist_entry('waitlist-test','98700000-0000-0000-0000-000000000010','Email Ruim','email-invalido','+55 (48) 99999-7013')$$,
  'P0001','WAITLIST_EMAIL_INVALID','invalid email is rejected'
);
select throws_ok(
  $$select public.public_create_service_waitlist_entry('waitlist-test','98700000-0000-0000-0000-000000000010','Whats Ruim','whats@example.com','1234')$$,
  'P0001','WAITLIST_WHATSAPP_INVALID','invalid WhatsApp is rejected'
);

select public.public_create_service_waitlist_entry('waitlist-test','98700000-0000-0000-0000-000000000010','Page 2','page2@example.com','+55 48 99999-7002');
select public.public_create_service_waitlist_entry('waitlist-test','98700000-0000-0000-0000-000000000010','Page 3','page3@example.com','+55 48 99999-7003');
select public.public_create_service_waitlist_entry('waitlist-test','98700000-0000-0000-0000-000000000010','Page 4','page4@example.com','+55 48 99999-7004');
select public.public_create_service_waitlist_entry('waitlist-test','98700000-0000-0000-0000-000000000010','Existing','existing-waitlist@example.com','+55 48 99999-7050');

create temporary table page_one as
select * from public.service_admin_list_waitlist(
  '98700000-0000-0000-0000-000000000010',2,null,null,'98700000-0000-0000-0000-000000000040'
);
select is((select count(*)::integer from page_one),3,'keyset list returns page size plus one sentinel when more records exist');

create temporary table page_two as
with cursor_row as (
  select created_at,id from page_one order by created_at,id limit 1 offset 1
)
select w.* from cursor_row c cross join lateral public.service_admin_list_waitlist(
  '98700000-0000-0000-0000-000000000010',2,c.created_at,c.id,'98700000-0000-0000-0000-000000000040'
) w;
select ok((select count(*) from page_two)>=2,'next keyset page returns records beyond the first page limit');
select ok(not exists(
  select 1 from (select id from page_one order by created_at,id limit 2) p join page_two n using(id)
),'next page does not repeat rows already consumed from the previous page');

select ok(exists(
  select 1 from page_one where email='existing-waitlist@example.com' and is_existing_customer and customer_id='98700000-0000-0000-0000-000000000050'
) or exists(
  select 1 from page_two where email='existing-waitlist@example.com' and is_existing_customer and customer_id='98700000-0000-0000-0000-000000000050'
),'admin list identifies an already registered customer');

create temporary table contact_mark as
select public.service_admin_mark_waitlist_contacted(
  (select (data->>'id')::uuid from first_signup),'98700000-0000-0000-0000-000000000040'
) data;
select is((select (data->>'contacted_by_admin_id')::uuid from contact_mark),'98700000-0000-0000-0000-000000000040'::uuid,'mark contacted records authorship');
select ok((select (data->>'contacted_at') is not null from contact_mark),'mark contacted records timestamp');
select ok(exists(
  select 1 from public.audit_logs
  where entity_type='SERVICE_WAITLIST_ENTRY' and entity_id=(select (data->>'id')::uuid from first_signup)
    and action='WAITLIST_CONTACTED' and admin_user_id='98700000-0000-0000-0000-000000000040'
),'mark contacted is auditable');

select ok(public.service_admin_has_permission('98700000-0000-0000-0000-000000000041','WAITLIST_MANAGE'),'operation role receives waitlist management by default');
select ok(not public.service_admin_has_permission('98700000-0000-0000-0000-000000000042','WAITLIST_VIEW'),'finance role does not receive waitlist access by default');
select ok(not has_table_privilege('anon','public.service_waitlist_entries','SELECT') and not has_table_privilege('authenticated','public.service_waitlist_entries','SELECT'),'waitlist table is not directly exposed to public roles');

select * from finish();
rollback;