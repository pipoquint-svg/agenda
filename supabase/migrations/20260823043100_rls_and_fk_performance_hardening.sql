-- Performance hardening for hot operational paths.
-- 1) Evaluate auth.uid() once per statement in RLS policies.
-- 2) Add covering indexes for foreign keys used in booking/payment/change workflows.

alter policy admin_users_self_select on public.admin_users
  using ((select auth.uid()) = auth_user_id);

alter policy legacy_amelia_import_batches_admin_select on public.legacy_amelia_import_batches
  using (exists (
    select 1
    from public.admin_users au
    where au.auth_user_id = (select auth.uid())
      and au.is_active
  ));

alter policy legacy_amelia_bookings_admin_select on public.legacy_amelia_bookings
  using (exists (
    select 1
    from public.admin_users au
    where au.auth_user_id = (select auth.uid())
      and au.is_active
  ));

create index if not exists appointments_service_id_idx
  on public.appointments(service_id);
create index if not exists appointments_service_employee_id_idx
  on public.appointments(service_employee_id);

create index if not exists checkout_holds_service_id_idx
  on public.checkout_holds(service_id);
create index if not exists checkout_holds_service_employee_id_idx
  on public.checkout_holds(service_employee_id);
create index if not exists checkout_holds_primary_customer_id_idx
  on public.checkout_holds(primary_customer_id);
create index if not exists checkout_holds_promoted_appointment_id_idx
  on public.checkout_holds(promoted_appointment_id);

create index if not exists pre_reservations_service_id_idx
  on public.pre_reservations(service_id);
create index if not exists pre_reservations_employee_id_idx
  on public.pre_reservations(employee_id);
create index if not exists pre_reservations_service_employee_id_idx
  on public.pre_reservations(service_employee_id);

create index if not exists payment_incidents_appointment_id_idx
  on public.payment_incidents(appointment_id);
create index if not exists payment_transactions_parent_transaction_id_idx
  on public.payment_transactions(parent_transaction_id);

create index if not exists appointment_participants_customer_id_idx
  on public.appointment_participants(customer_id);
create index if not exists appointment_answers_service_field_id_idx
  on public.appointment_answers(service_field_id);
create index if not exists appointment_extras_extra_id_idx
  on public.appointment_extras(extra_id);
create index if not exists appointment_discounts_coupon_id_idx
  on public.appointment_discounts(coupon_id);
create index if not exists appointment_term_acceptances_terms_version_id_idx
  on public.appointment_term_acceptances(terms_version_id);

create index if not exists appointment_change_policy_snapshots_service_id_idx
  on public.appointment_change_policy_snapshots(service_id);
create index if not exists appointment_change_policy_snapshot_terms_terms_version_id_idx
  on public.appointment_change_policy_snapshot_terms(terms_version_id);
create index if not exists appointment_change_settlements_customer_id_idx
  on public.appointment_change_settlements(customer_id);
create index if not exists appointment_final_settlements_customer_id_idx
  on public.appointment_final_settlements(customer_id);
create index if not exists appointment_final_settlements_balance_movement_id_idx
  on public.appointment_final_settlements(balance_movement_id);

create index if not exists customer_balance_movements_appointment_id_idx
  on public.customer_balance_movements(appointment_id);
create index if not exists customer_balance_movements_policy_action_id_idx
  on public.customer_balance_movements(policy_action_id);
create index if not exists customer_balance_refund_requests_customer_id_idx
  on public.customer_balance_refund_requests(customer_id);

create index if not exists appointment_package_usage_hour_package_id_idx
  on public.appointment_package_usage(hour_package_id);
create index if not exists appointment_package_usage_debit_movement_id_idx
  on public.appointment_package_usage(debit_movement_id);
create index if not exists appointment_package_usage_reversal_movement_id_idx
  on public.appointment_package_usage(reversal_movement_id);
create index if not exists hour_package_movements_appointment_id_idx
  on public.hour_package_movements(appointment_id);

create index if not exists schedule_divergences_resource_id_idx
  on public.schedule_divergences(resource_id);
create index if not exists schedule_divergences_appointment_id_idx
  on public.schedule_divergences(appointment_id);

create index if not exists services_category_id_idx
  on public.services(category_id);
create index if not exists service_employees_employee_id_idx
  on public.service_employees(employee_id);
create index if not exists service_extras_extra_id_idx
  on public.service_extras(extra_id);
create index if not exists service_resources_resource_id_idx
  on public.service_resources(resource_id);
