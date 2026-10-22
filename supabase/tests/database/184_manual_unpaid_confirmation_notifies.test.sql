begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(5);

-- Fixtures -------------------------------------------------------------------
insert into auth.users(id, email, created_at, updated_at)
values ('18400000-0000-4000-8000-000000000001', 'manual-184-owner@example.test', now(), now());
insert into public.admin_users(id, auth_user_id, display_name, role, is_active)
values ('18400000-0000-4000-8000-000000000002', '18400000-0000-4000-8000-000000000001', 'Manual 184 Owner', 'OWNER', true);
insert into public.resources(id, name, resource_type) values ('18400000-0000-4000-8000-000000000005', 'M184 studio', 'PHYSICAL');
insert into public.employees(id, name) values ('18400000-0000-4000-8000-000000000003', 'M184 staff');
insert into public.categories(id, name, slug) values ('18400000-0000-4000-8000-000000000004', 'M184', 'm184');
insert into public.services(
  id, category_id, name, slug, base_duration_minutes, base_price, buffer_before_minutes, buffer_after_minutes,
  minimum_people, maximum_people, minimum_booking_notice_minutes, maximum_booking_horizon_days, requires_terms,
  duration_mode, operation_scope, booking_product_type, service_type_id
) values ('18400000-0000-4000-8000-000000000010', '18400000-0000-4000-8000-000000000004', 'M184 rental', 'm184-rental', 60, 100, 0, 0, 1, 10, 0, 5000, false,
  'FIXED', 'BLACKSHEEP', 'STANDARD', (select id from public.service_type where key = 'LOCACAO'));
insert into public.service_employees(id, service_id, employee_id)
values ('18400000-0000-4000-8000-000000000020', '18400000-0000-4000-8000-000000000010', '18400000-0000-4000-8000-000000000003');
insert into public.service_resources(service_id, resource_id)
values ('18400000-0000-4000-8000-000000000010', '18400000-0000-4000-8000-000000000005');
insert into public.service_change_policies(service_id, notice_hours, reschedule_first_early_percent, reschedule_first_late_percent, reschedule_repeat_percent, cancellation_late_percent)
values ('18400000-0000-4000-8000-000000000010', 48, 0, 20, 30, 30);
insert into public.customers(id, name, email, phone)
values ('18400000-0000-4000-8000-0000000000c1', 'M184 Cliente', 'm184@example.test', '+5548999840001');
insert into public.appointments(
  id, public_code, service_id, service_employee_id, primary_customer_id, status, financial_status,
  start_at, end_at, duration_minutes, people_count, hold_expires_at, commercial_value
) values ('18400000-0000-4000-8000-0000000000a1', 'M184-LATER', '18400000-0000-4000-8000-000000000010', '18400000-0000-4000-8000-000000000020',
  '18400000-0000-4000-8000-0000000000c1', 'AWAITING_PAYMENT', 'PENDING', '2035-03-01 10:00:00-03', '2035-03-01 11:00:00-03', 60, 1,
  now() + interval '30 minutes', 100);
insert into public.resource_allocations(resource_id, appointment_id, allocation_type, status, occupied_range)
select '18400000-0000-4000-8000-000000000005', a.id, 'APPOINTMENT', 'AWAITING_PAYMENT', tstzrange(a.start_at, a.end_at, '[)')
from public.appointments a where a.id = '18400000-0000-4000-8000-0000000000a1';

-- Manual confirmation with payment later ---------------------------------------
select lives_ok(
  $$select public.service_admin_confirm_appointment_unpaid('18400000-0000-4000-8000-0000000000a1', 'Cliente paga no dia', '18400000-0000-4000-8000-000000000002')$$,
  'an admin confirms the reservation with payment later'
);
select is(
  (select row(status, financial_status)::text from public.appointments where id = '18400000-0000-4000-8000-0000000000a1'),
  row('CONFIRMED', 'UNPAID_AUTHORIZED')::text,
  'the reservation is confirmed with payment authorized for later'
);
select is(
  (select count(*)::integer from public.integration_jobs
   where entity_id = '18400000-0000-4000-8000-0000000000a1' and job_type = 'APPOINTMENT_CONFIRMED_MESSAGE'
     and entity_version = (select version from public.appointments where id = '18400000-0000-4000-8000-0000000000a1')
     and payload_json->>'reason' = 'ADMIN_CONFIRMED_WITHOUT_PAYMENT'),
  1, 'the confirmation message (WhatsApp and e-mail) is queued for the confirmed version'
);
select is(
  (select count(*)::integer from public.integration_jobs
   where entity_id = '18400000-0000-4000-8000-0000000000a1' and job_type = 'GOOGLE_APPOINTMENT_SYNC'),
  1, 'the reservation is queued for Google Calendar'
);
select is(
  (public.service_admin_confirm_appointment_unpaid('18400000-0000-4000-8000-0000000000a1', 'De novo', '18400000-0000-4000-8000-000000000002')->>'already_confirmed')::boolean
  and (select count(*) from public.integration_jobs where entity_id = '18400000-0000-4000-8000-0000000000a1' and job_type = 'APPOINTMENT_CONFIRMED_MESSAGE') = 1,
  true, 'confirming again sends nothing more'
);

select * from finish();
rollback;
