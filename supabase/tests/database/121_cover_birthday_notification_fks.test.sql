begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(5);

select has_index(
  'public','birthday_automation_cycles','birthday_automation_cycles_coupon_id_idx',
  'birthday cycles coupon FK has a covering index'
);
select has_index(
  'public','birthday_automation_cycles','birthday_automation_cycles_customer_id_idx',
  'birthday cycles customer FK has a covering index'
);
select has_index(
  'public','notification_delivery_logs','notification_delivery_logs_customer_id_idx',
  'notification delivery customer FK has a covering index'
);
select has_index(
  'public','notification_delivery_logs','notification_delivery_logs_employee_id_idx',
  'notification delivery employee FK has a covering index'
);
select has_index(
  'public','notification_delivery_logs','notification_delivery_logs_template_id_idx',
  'notification delivery template FK has a covering index'
);

select * from finish();
rollback;
