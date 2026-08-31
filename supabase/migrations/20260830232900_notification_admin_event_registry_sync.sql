-- Keep the admin notification mutation boundary aligned with notification events
-- that are already part of the production notification platform.
-- PRE_RESERVATION_CREATED and REFUND_FAILED were introduced by later migrations,
-- but the original admin upsert RPC still rejected them, so toggling those email
-- templates from Gestão returned HTTP 400.

do $migration$
declare
  v_oid oid;
  v_def text;
  v_old text := $old$    'APPOINTMENT_CHANGED','APPOINTMENT_RESCHEDULED','APPOINTMENT_REMINDER','WAITLIST_AVAILABLE','BIRTHDAY',
    'RENTAL_BALANCE_DUE','ADMIN_USER_INVITE','MANUAL'$old$;
  v_new text := $new$    'APPOINTMENT_CHANGED','APPOINTMENT_RESCHEDULED','APPOINTMENT_REMINDER','WAITLIST_AVAILABLE','BIRTHDAY',
    'RENTAL_BALANCE_DUE','ADMIN_USER_INVITE','PRE_RESERVATION_CREATED','REFUND_FAILED','MANUAL'$new$;
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
