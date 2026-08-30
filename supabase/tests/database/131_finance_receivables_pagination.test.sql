begin;
create extension if not exists pgtap with schema extensions;
set local search_path=public,extensions;
select plan(8);

insert into auth.users(id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,raw_app_meta_data,raw_user_meta_data)
values ('7c000000-0000-4000-8000-000000000001','00000000-0000-0000-0000-000000000000','authenticated','authenticated','finance-pagination@example.test','',now(),now(),now(),'{}'::jsonb,'{}'::jsonb);
insert into public.admin_users(id,auth_user_id,display_name,role,is_active)
values ('7c000000-0000-4000-8000-000000000002','7c000000-0000-4000-8000-000000000001','Finance Pagination Owner','OWNER',true);

insert into public.customers(id,name,email) values
('7c000000-0000-4000-8000-000000000010','Cliente Paginação','paginacao@example.test');
insert into public.employees(id,name) values
('7c000000-0000-4000-8000-000000000020','Finance Pagination Employee');
insert into public.categories(id,name,slug) values
('7c000000-0000-4000-8000-000000000021','Finance Pagination','finance-pagination');
insert into public.services(id,category_id,name,slug,base_duration_minutes,base_price,minimum_people,maximum_people,operation_scope)
values ('7c000000-0000-4000-8000-000000000022','7c000000-0000-4000-8000-000000000021','Finance Pagination Service','finance-pagination-service',60,100,1,10,'BLACKSHEEP');
insert into public.service_employees(id,service_id,employee_id)
values ('7c000000-0000-4000-8000-000000000023','7c000000-0000-4000-8000-000000000022','7c000000-0000-4000-8000-000000000020');

insert into public.appointments(id,public_code,service_id,service_employee_id,status,financial_status,start_at,end_at,duration_minutes,people_count,primary_customer_id,commercial_value,confirmed_at) values
('7c000000-0000-4000-8000-000000000040','PAGE-40','7c000000-0000-4000-8000-000000000022','7c000000-0000-4000-8000-000000000023','CONFIRMED','NOT_STARTED','2036-01-01 10:00:00-03','2036-01-01 11:00:00-03',60,1,'7c000000-0000-4000-8000-000000000010',100,now()),
('7c000000-0000-4000-8000-000000000041','PAGE-41','7c000000-0000-4000-8000-000000000022','7c000000-0000-4000-8000-000000000023','CONFIRMED','NOT_STARTED','2036-01-02 10:00:00-03','2036-01-02 11:00:00-03',60,1,'7c000000-0000-4000-8000-000000000010',100,now()),
('7c000000-0000-4000-8000-000000000042','PAGE-42','7c000000-0000-4000-8000-000000000022','7c000000-0000-4000-8000-000000000023','CONFIRMED','NOT_STARTED','2036-01-03 10:00:00-03','2036-01-03 11:00:00-03',60,1,'7c000000-0000-4000-8000-000000000010',100,now()),
('7c000000-0000-4000-8000-000000000043','PAGE-43','7c000000-0000-4000-8000-000000000022','7c000000-0000-4000-8000-000000000023','CONFIRMED','NOT_STARTED','2036-01-03 10:00:00-03','2036-01-03 11:00:00-03',60,1,'7c000000-0000-4000-8000-000000000010',100,now());

select is(
  public.service_admin_list_receivable_appointments_page(null,'BLACKSHEEP',null,null,2,'7c000000-0000-4000-8000-000000000002')->'appointments'->0->>'appointment_id',
  '7c000000-0000-4000-8000-000000000043',
  'first page sorts newest first and uses appointment id as deterministic tie breaker'
);
select is(
  public.service_admin_list_receivable_appointments_page(null,'BLACKSHEEP',null,null,2,'7c000000-0000-4000-8000-000000000002')->'appointments'->1->>'appointment_id',
  '7c000000-0000-4000-8000-000000000042',
  'first page returns exactly the second deterministic row'
);
select is(
  (public.service_admin_list_receivable_appointments_page(null,'BLACKSHEEP',null,null,2,'7c000000-0000-4000-8000-000000000002')->>'has_more')::boolean,
  true,
  'first page advertises a next page'
);
select is(
  public.service_admin_list_receivable_appointments_page(null,'BLACKSHEEP',null,null,2,'7c000000-0000-4000-8000-000000000002')->'next_cursor'->>'appointment_id',
  '7c000000-0000-4000-8000-000000000042',
  'cursor points at the last included row'
);
select is(
  public.service_admin_list_receivable_appointments_page(null,'BLACKSHEEP','2036-01-03 10:00:00-03','7c000000-0000-4000-8000-000000000042',2,'7c000000-0000-4000-8000-000000000002')->'appointments'->0->>'appointment_id',
  '7c000000-0000-4000-8000-000000000041',
  'second page resumes strictly after the cursor without duplication'
);
select is(
  public.service_admin_list_receivable_appointments_page(null,'BLACKSHEEP','2036-01-03 10:00:00-03','7c000000-0000-4000-8000-000000000042',2,'7c000000-0000-4000-8000-000000000002')->'appointments'->1->>'appointment_id',
  '7c000000-0000-4000-8000-000000000040',
  'second page returns the remaining row in stable order'
);
select is(
  (public.service_admin_list_receivable_appointments_page(null,'BLACKSHEEP','2036-01-03 10:00:00-03','7c000000-0000-4000-8000-000000000042',2,'7c000000-0000-4000-8000-000000000002')->>'has_more')::boolean,
  false,
  'last page has no next cursor'
);
select ok(
  not has_function_privilege('anon','public.service_admin_list_receivable_appointments_page(text,text,timestamptz,uuid,integer,uuid)','EXECUTE')
  and not has_function_privilege('authenticated','public.service_admin_list_receivable_appointments_page(text,text,timestamptz,uuid,integer,uuid)','EXECUTE'),
  'paginated finance RPC is service-role only'
);

select * from finish();
rollback;
