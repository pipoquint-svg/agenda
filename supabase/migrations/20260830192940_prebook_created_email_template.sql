alter table public.notification_template_configs
  drop constraint notification_template_configs_event_key_check;

alter table public.notification_template_configs
  add constraint notification_template_configs_event_key_check
  check (event_key = any (array[
    'APPOINTMENT_APPROVED'::text,
    'APPOINTMENT_PENDING'::text,
    'APPOINTMENT_REJECTED'::text,
    'APPOINTMENT_CANCELLED'::text,
    'APPOINTMENT_CHANGED'::text,
    'APPOINTMENT_RESCHEDULED'::text,
    'APPOINTMENT_REMINDER'::text,
    'WAITLIST_AVAILABLE'::text,
    'BIRTHDAY'::text,
    'RENTAL_BALANCE_DUE'::text,
    'ADMIN_USER_INVITE'::text,
    'MANUAL'::text,
    'REFUND_FAILED'::text,
    'PRE_RESERVATION_CREATED'::text
  ]));

insert into public.notification_template_configs(
  event_key,channel,audience,operation_scope,title_template,body_template,is_active,variable_schema
)
select
  'PRE_RESERVATION_CREATED','EMAIL','CUSTOMER',scope,
  '{{operation.name}} | Pré-reserva recebida | {{appointment.public_code}}',
  'Olá, {{customer.name}}.\n\nSeu horário está pré-reservado.\n\nServiço: {{service.name}}\nData e horário: {{appointment.start_at}}\nDuração: {{appointment.duration}}\nCódigo: {{appointment.public_code}}\n\nO horário ficará reservado até {{pre_reservation.expires_at}}. Para confirmar sua reserva, o pagamento precisa ser aprovado até esse prazo.\n\nPagar e confirmar reserva: {{pre_reservation.payment_url}}\n\nSe o pagamento não for aprovado dentro do prazo, a pré-reserva expira automaticamente e o horário volta a ficar disponível.\n\nEquipe {{operation.name}}',
  true,
  jsonb_build_array(
    'operation.name','customer.name','service.name','appointment.start_at','appointment.duration',
    'appointment.public_code','pre_reservation.expires_at','pre_reservation.payment_url'
  )
from (values ('BLACKSHEEP'::text),('SABRINA'::text)) s(scope)
where not exists (
  select 1 from public.notification_template_configs c
  where c.event_key='PRE_RESERVATION_CREATED'
    and c.channel='EMAIL'
    and c.audience='CUSTOMER'
    and c.operation_scope=s.scope
);