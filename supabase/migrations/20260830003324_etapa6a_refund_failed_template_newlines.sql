UPDATE public.notification_template_configs
SET body_template = E'Não foi possível concluir o estorno da reserva {{appointment.public_code}}.\n\nValor pendente: {{refund.amount}}\nMotivo técnico: {{refund.error_code}}\n\nA pendência continua registrada na Gestão. Confira o Mercado Pago e tente novamente.',
    updated_at = now()
WHERE event_key='REFUND_FAILED' AND channel='EMAIL' AND audience='EMPLOYEE' AND operation_scope IN ('BLACKSHEEP','SABRINA');
