insert into public.notification_template_configs (
  id,
  event_key,
  channel,
  audience,
  operation_scope,
  title_template,
  body_template,
  is_active,
  variable_schema,
  created_at,
  updated_at
)
select
  gen_random_uuid(),
  'PAYMENT_PENDING_CREATED',
  'EMAIL',
  'CUSTOMER',
  'SABRINA',
  '{{operation.name}} | Conclua seu pagamento | {{appointment.public_code}}',
  'Olá, {{customer.name}}.\n\nSeu horário está reservado temporariamente enquanto aguardamos o pagamento.\n\nServiço: {{service.name}}\nData e horário: {{appointment.start_at}}\nDuração: {{appointment.duration}}\nCódigo: {{appointment.public_code}}\n\nPara concluir o pagamento e confirmar sua reserva, use o link abaixo:\n{{payment.resume_url}}\n\nEste link é válido enquanto o horário estiver protegido, até {{payment.expires_at}}. Se o prazo terminar sem a confirmação do pagamento, o horário volta a ficar disponível.\n\nEquipe {{operation.name}}',
  true,
  '["operation.name","customer.name","service.name","appointment.start_at","appointment.duration","appointment.public_code","payment.resume_url","payment.expires_at"]'::jsonb,
  now(),
  now()
where not exists (
  select 1
  from public.notification_template_configs
  where event_key = 'PAYMENT_PENDING_CREATED'
    and channel = 'EMAIL'
    and audience = 'CUSTOMER'
    and operation_scope = 'SABRINA'
);
