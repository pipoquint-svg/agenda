-- Performance follow-up from Supabase advisor.
-- Expand-only covering indexes for foreign keys introduced/used by birthday and notification flows.
-- No application behavior or authorization contract changes.

create index if not exists birthday_automation_cycles_coupon_id_idx
  on public.birthday_automation_cycles(coupon_id)
  where coupon_id is not null;

create index if not exists birthday_automation_cycles_customer_id_idx
  on public.birthday_automation_cycles(customer_id);

create index if not exists notification_delivery_logs_customer_id_idx
  on public.notification_delivery_logs(customer_id)
  where customer_id is not null;

create index if not exists notification_delivery_logs_employee_id_idx
  on public.notification_delivery_logs(employee_id)
  where employee_id is not null;

create index if not exists notification_delivery_logs_template_id_idx
  on public.notification_delivery_logs(template_id)
  where template_id is not null;
