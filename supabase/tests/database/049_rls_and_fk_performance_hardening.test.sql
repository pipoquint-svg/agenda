begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(12);

select ok(
  coalesce((select qual like '%SELECT auth.uid()%' from pg_policies where schemaname='public' and tablename='admin_users' and policyname='admin_users_self_select'),false),
  'admin self RLS evaluates auth.uid once'
);
select ok(
  coalesce((select qual like '%SELECT auth.uid()%' from pg_policies where schemaname='public' and tablename='legacy_amelia_bookings' and policyname='legacy_amelia_bookings_admin_select'),false),
  'Amelia booking RLS evaluates auth.uid once'
);
select ok(
  coalesce((select qual like '%SELECT auth.uid()%' from pg_policies where schemaname='public' and tablename='legacy_amelia_import_batches' and policyname='legacy_amelia_import_batches_admin_select'),false),
  'Amelia import RLS evaluates auth.uid once'
);

select has_index('public','appointments','appointments_service_id_idx','appointments service FK has covering index');
select has_index('public','appointments','appointments_service_employee_id_idx','appointments service employee FK has covering index');
select has_index('public','checkout_holds','checkout_holds_primary_customer_id_idx','checkout hold customer FK has covering index');
select has_index('public','pre_reservations','pre_reservations_service_id_idx','pre-reservation service FK has covering index');
select has_index('public','payment_incidents','payment_incidents_appointment_id_idx','payment incident appointment FK has covering index');
select has_index('public','appointment_change_settlements','appointment_change_settlements_customer_id_idx','change settlement customer FK has covering index');
select has_index('public','customer_balance_movements','customer_balance_movements_appointment_id_idx','customer balance appointment FK has covering index');
select has_index('public','appointment_package_usage','appointment_package_usage_hour_package_id_idx','package usage hour package FK has covering index');
select has_index('public','schedule_divergences','schedule_divergences_appointment_id_idx','schedule divergence appointment FK has covering index');

select * from finish();
rollback;
