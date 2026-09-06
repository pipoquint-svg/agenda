update public.notification_template_configs
set body_template = $body$Olá, {{customer.name}}.

Seu horário está reservado temporariamente enquanto aguardamos o pagamento.

Serviço: {{service.name}}
Data e horário: {{appointment.start_at}}
Duração: {{appointment.duration}}
Código: {{appointment.public_code}}

Para concluir o pagamento e confirmar sua reserva, use o link abaixo:
{{payment.resume_url}}

Este link é válido enquanto o horário estiver protegido, até {{payment.expires_at}}. Se o prazo terminar sem a confirmação do pagamento, o horário volta a ficar disponível.

Equipe {{operation.name}}$body$,
    updated_at = now()
where event_key='PAYMENT_PENDING_CREATED'
  and channel='EMAIL'
  and audience='CUSTOMER'
  and operation_scope='SABRINA';
