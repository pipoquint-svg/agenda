-- Keep checkout-hold creation on the same injectable clock used by availability
-- and autonomous expiry tests. In production agenda.test_now is unset, so this
-- remains exactly equivalent to now().

do $migration$
declare
  v_oid oid;
  v_def text;
  v_old text := $old$  v_expires_at := now() + make_interval(mins => v_hold_minutes);$old$;
  v_new text := $new$  v_expires_at := coalesce(
    nullif(current_setting('agenda.test_now', true), '')::timestamptz,
    now()
  ) + make_interval(mins => v_hold_minutes);$new$;
begin
  select p.oid
    into v_oid
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname = 'create_checkout_hold_for_duration'
    and pg_get_function_identity_arguments(p.oid) = 'p_service_id uuid, p_service_employee_id uuid, p_duration_blocks integer, p_extra_selections jsonb, p_people_count integer, p_requested_start_at timestamp with time zone';

  if v_oid is null then
    raise exception 'create_checkout_hold_for_duration function not found';
  end if;

  v_def := pg_get_functiondef(v_oid);
  if position(v_old in v_def) = 0 then
    raise exception 'expected duration checkout hold expiry assignment not found';
  end if;

  execute replace(v_def, v_old, v_new);
end;
$migration$;

comment on function public.create_checkout_hold_for_duration(uuid,uuid,integer,jsonb,integer,timestamptz) is
  'Creates duration checkout holds. Production expiry uses transaction time; agenda.test_now is an explicit test-only clock override.';
