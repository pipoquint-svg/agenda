create index if not exists availability_exceptions_special_calendar_date_id_idx
  on public.availability_exceptions (special_calendar_date_id);

create index if not exists checkout_customer_verifications_customer_id_idx
  on public.checkout_customer_verifications (customer_id);

create index if not exists waitlist_private_invites_created_by_admin_id_idx
  on public.waitlist_private_invites (created_by_admin_id);

create index if not exists waitlist_private_round_invites_created_by_admin_id_idx
  on public.waitlist_private_round_invites (created_by_admin_id);

create index if not exists waitlist_private_rounds_booking_page_id_idx
  on public.waitlist_private_rounds (booking_page_id);

create index if not exists waitlist_private_rounds_created_by_admin_id_idx
  on public.waitlist_private_rounds (created_by_admin_id);

create index if not exists waitlist_private_slot_resources_resource_id_idx
  on public.waitlist_private_slot_resources (resource_id);

create index if not exists waitlist_private_slot_services_service_employee_id_idx
  on public.waitlist_private_slot_services (service_employee_id);

create index if not exists waitlist_private_slot_services_service_id_idx
  on public.waitlist_private_slot_services (service_id);

create index if not exists waitlist_private_slots_booking_page_id_idx
  on public.waitlist_private_slots (booking_page_id);

create index if not exists waitlist_private_slots_claimed_appointment_id_idx
  on public.waitlist_private_slots (claimed_appointment_id);

create index if not exists waitlist_private_slots_claimed_checkout_hold_id_idx
  on public.waitlist_private_slots (claimed_checkout_hold_id);

create index if not exists waitlist_private_slots_created_by_admin_id_idx
  on public.waitlist_private_slots (created_by_admin_id);
