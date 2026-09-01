begin;

alter table public.notification_template_configs
  drop constraint if exists notification_template_configs_event_key_check;

alter table public.notification_template_configs
  add constraint notification_template_configs_event_key_check
  check (
    event_key = any (array[
      'APPOINTMENT_APPROVED'::text,
      'APPOINTMENT_PENDING'::text,
      'APPOINTMENT_REJECTED'::text,
      'APPOINTMENT_CANCELLED'::text,
      'APPOINTMENT_CHANGED'::text,
      'APPOINTMENT_RESCHEDULED'::text,
      'APPOINTMENT_REMINDER'::text,
      'WAITLIST_AVAILABLE'::text,
      'WAITLIST_SIGNUP_TEAM'::text,
      'BIRTHDAY'::text,
      'RENTAL_BALANCE_DUE'::text,
      'ADMIN_USER_INVITE'::text,
      'MANUAL'::text,
      'REFUND_FAILED'::text,
      'REFUND_COMPLETED'::text,
      'PRE_RESERVATION_CREATED'::text
    ])
  );

insert into public.notification_template_configs (
  event_key,
  channel,
  audience,
  operation_scope,
  title_template,
  body_template,
  is_active,
  variable_schema,
  html_template
)
select
  'REFUND_COMPLETED',
  'EMAIL',
  'CUSTOMER',
  'BLACKSHEEP',
  '{{operation.name}} | Estorno realizado | {{appointment.public_code}}',
  E'Olá, {{customer.name}}.\n\nO estorno de {{refund.amount}} da reserva {{appointment.public_code}} foi processado com sucesso.\n\nDependendo do banco ou meio de pagamento, o crédito pode levar algum tempo para aparecer na sua conta.\n\nEquipe {{operation.name}}',
  true,
  '["appointment.public_code","customer.name","refund.amount","operation.name"]'::jsonb,
  null
where not exists (
  select 1
  from public.notification_template_configs
  where event_key = 'REFUND_COMPLETED'
    and channel = 'EMAIL'
    and audience = 'CUSTOMER'
    and operation_scope = 'BLACKSHEEP'
);

commit;
