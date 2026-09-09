-- Reconcile two production contracts that were introduced independently:
-- 1) the Natal 2026 Kommo trigger must remain trigger-only (never callable by app roles);
-- 2) PAYMENT_PENDING_CREATED is a persisted notification event and must be accepted by
--    both notification admin mutation RPCs.

revoke all on function public.enqueue_natal_2026_kommo_sync_trigger() from public, anon, authenticated;
grant execute on function public.enqueue_natal_2026_kommo_sync_trigger() to service_role;

do $migration$
declare
  v_oid oid;
  v_def text;
  v_old text := $old$'REFUND_FAILED','REFUND_COMPLETED','MANUAL'$old$;
  v_new text := $new$'REFUND_FAILED','REFUND_COMPLETED','PAYMENT_PENDING_CREATED','MANUAL'$new$;
  v_name text;
begin
  foreach v_name in array array[
    'service_admin_upsert_notification_template',
    'service_admin_upsert_notification_template_v2'
  ] loop
    select p.oid into v_oid
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = v_name
    order by p.oid desc
    limit 1;

    if v_oid is null then
      raise exception '% not found', v_name;
    end if;

    v_def := pg_get_functiondef(v_oid);
    if position('''PAYMENT_PENDING_CREATED''' in v_def) > 0 then
      continue;
    end if;
    if position(v_old in v_def) = 0 then
      raise exception 'expected notification event allowlist not found in %', v_name;
    end if;

    execute replace(v_def, v_old, v_new);
  end loop;
end;
$migration$;
