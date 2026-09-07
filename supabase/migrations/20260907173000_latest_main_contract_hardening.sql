-- Keep the latest-main database contracts aligned with the strict security and
-- notification registries exercised by the full database test suite.
--
-- 1) Trigger helpers are not client RPCs and must not inherit PUBLIC EXECUTE.
-- 2) PAYMENT_PENDING_CREATED is already a persisted notification event, so the
--    administrative template mutation boundary must accept it as well.

revoke execute on function public.enqueue_natal_2026_kommo_sync_trigger()
  from public, anon, authenticated;

do $migration$
declare
  v_oid oid;
  v_def text;
  v_old text := $old$'REFUND_FAILED','REFUND_COMPLETED','MANUAL'$old$;
  v_new text := $new$'REFUND_FAILED','REFUND_COMPLETED','PAYMENT_PENDING_CREATED','MANUAL'$new$;
begin
  select p.oid into v_oid
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname = 'service_admin_upsert_notification_template'
    and pg_get_function_identity_arguments(p.oid) =
      'p_template_id uuid, p_event_key text, p_channel text, p_audience text, p_operation_scope text, p_category_id uuid, p_title_template text, p_body_template text, p_is_active boolean, p_variable_schema jsonb, p_reminder_offset_minutes integer, p_service_ids uuid[], p_actor_admin_id uuid';

  if v_oid is null then
    raise exception 'service_admin_upsert_notification_template not found';
  end if;

  v_def := pg_get_functiondef(v_oid);

  if position('PAYMENT_PENDING_CREATED' in v_def) = 0 then
    if position(v_old in v_def) = 0 then
      raise exception 'expected notification event allowlist suffix not found';
    end if;
    execute replace(v_def, v_old, v_new);
  end if;
end;
$migration$;
