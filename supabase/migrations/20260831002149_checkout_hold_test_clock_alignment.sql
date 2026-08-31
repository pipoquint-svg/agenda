-- Keep checkout-hold creation on the same injectable clock used by availability
-- and autonomous expiry tests. In production agenda.test_now is unset, so this
-- remains exactly equivalent to now().
--
-- Hosted production may have the same function formatted differently from a
-- clean migration rebuild. Patch the semantic assignment with a whitespace-
-- tolerant regex so the migration is safe across both representations.

do $migration$
declare
  v_oid oid;
  v_def text;
  v_patched text;
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

  if position('agenda.test_now' in v_def) > 0 then
    return;
  end if;

  v_patched := regexp_replace(
    v_def,
    'v_expires_at\s*:=\s*now\(\)\s*\+\s*make_interval\(mins\s*=>\s*v_hold_minutes\)\s*;',
    $replacement$v_expires_at := coalesce(
    nullif(current_setting('agenda.test_now', true), '')::timestamptz,
    now()
  ) + make_interval(mins => v_hold_minutes);$replacement$
  );

  if v_patched = v_def then
    raise exception 'expected duration checkout hold expiry assignment not found';
  end if;

  execute v_patched;
end;
$migration$;

comment on function public.create_checkout_hold_for_duration(uuid,uuid,integer,jsonb,integer,timestamptz) is
  'Creates duration checkout holds. Production expiry uses transaction time; agenda.test_now is an explicit test-only clock override.';
