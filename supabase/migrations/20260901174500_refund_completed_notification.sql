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

do $migration$
declare
  v_oid oid;
  v_def text;
  v_old text := $old$    'RENTAL_BALANCE_DUE','ADMIN_USER_INVITE','PRE_RESERVATION_CREATED','REFUND_FAILED','MANUAL'$old$;
  v_new text := $new$    'RENTAL_BALANCE_DUE','ADMIN_USER_INVITE','PRE_RESERVATION_CREATED','REFUND_FAILED','REFUND_COMPLETED','MANUAL'$new$;
begin
  select p.oid into v_oid
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname = 'service_admin_upsert_notification_template'
    and pg_get_function_identity_arguments(p.oid) = 'p_template_id uuid, p_event_key text, p_channel text, p_audience text, p_operation_scope text, p_category_id uuid, p_title_template text, p_body_template text, p_is_active boolean, p_variable_schema jsonb, p_reminder_offset_minutes integer, p_service_ids uuid[], p_actor_admin_id uuid';

  if v_oid is null then
    raise exception 'service_admin_upsert_notification_template not found';
  end if;

  v_def := pg_get_functiondef(v_oid);
  if position(v_old in v_def) = 0 then
    raise exception 'expected notification event allowlist not found';
  end if;

  execute replace(v_def, v_old, v_new);
end;
$migration$;

commit;
