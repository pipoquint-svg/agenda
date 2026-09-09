update public.notification_template_configs
set is_active = true,
    updated_at = now()
where event_key = 'APPOINTMENT_APPROVED'
  and channel = 'EMAIL'
  and audience = 'CUSTOMER'
  and operation_scope = 'SABRINA'
  and is_active = false;

insert into public.notification_template_configs (
  event_key,
  channel,
  audience,
  operation_scope,
  category_id,
  title_template,
  body_template,
  html_template,
  is_active,
  variable_schema,
  reminder_offset_minutes
)
select
  'APPOINTMENT_APPROVED',
  'EMAIL',
  'CUSTOMER',
  null,
  null,
  '{{operation.name}} | Reserva confirmada | {{appointment.public_code}}',
  E'Olá, {{customer.name}}.\n\nSua reserva está confirmada.\n\nServiço: {{service.name}}\nData e horário: {{appointment.start_at}}\nDuração: {{appointment.duration}}\nCódigo da reserva: {{appointment.public_code}}\nValor da reserva: {{payment.total}}\nValor pago: {{payment.paid}}\nSaldo: {{payment.balance}}\n\nAlterar minha reserva: {{appointment.manage_url}}\n\nEquipe {{operation.name}}',
  null,
  true,
  '["appointment.public_code","appointment.start_at","appointment.duration","appointment.manage_url","customer.name","service.name","operation.name","payment.total","payment.paid","payment.balance"]'::jsonb,
  null
where not exists (
  select 1
  from public.notification_template_configs
  where event_key = 'APPOINTMENT_APPROVED'
    and channel = 'EMAIL'
    and audience = 'CUSTOMER'
    and operation_scope is null
    and category_id is null
);
