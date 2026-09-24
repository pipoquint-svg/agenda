-- Manual/admin reservations are an operational flow, not public checkout.
--
-- The shared checkout promoter correctly enforces required public custom fields
-- and client terms acceptance. The admin manual booking path reuses that promoter
-- for its atomic allocation/price lifecycle, so it must explicitly bypass only
-- those two public-input requirements without weakening any public caller.
--
-- The bypass is transaction-local and can only be reached through service_role,
-- because promote_checkout_hold_standard is not executable by anon/authenticated.

do $migration$
declare
  v_oid oid;
  v_def text;
  v_expected text;
  v_replacement text;
begin
  select p.oid
    into v_oid
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname = 'promote_checkout_hold_standard'
    and pg_get_function_identity_arguments(p.oid) =
      'p_checkout_hold_id uuid, p_customer_id uuid, p_coupon_code text, p_term_version_ids uuid[], p_participants jsonb, p_answers jsonb, p_acceptance_ip inet, p_acceptance_user_agent text';

  if v_oid is null then
    raise exception 'PROMOTE_CHECKOUT_HOLD_STANDARD_NOT_FOUND';
  end if;

  v_def := pg_get_functiondef(v_oid);

  v_expected := E'  if v_missing_required_fields > 0 then\n    raise exception using errcode = ''P0001'', message = ''REQUIRED_SERVICE_FIELDS_MISSING'';\n  end if;';
  v_replacement := E'  if coalesce(current_setting(''agenda.manual_booking'', true), '''') <> ''on''\n     and v_missing_required_fields > 0 then\n    raise exception using errcode = ''P0001'', message = ''REQUIRED_SERVICE_FIELDS_MISSING'';\n  end if;';
  if position(v_expected in v_def) = 0 then
    raise exception 'MANUAL_BOOKING_REQUIRED_FIELDS_PATCH_POINT_NOT_FOUND';
  end if;
  v_def := replace(v_def, v_expected, v_replacement);

  v_expected := E'  if v_service.requires_terms then';
  v_replacement := E'  if coalesce(current_setting(''agenda.manual_booking'', true), '''') <> ''on''\n     and v_service.requires_terms then';
  if position(v_expected in v_def) = 0 then
    raise exception 'MANUAL_BOOKING_TERMS_PATCH_POINT_NOT_FOUND';
  end if;
  v_def := replace(v_def, v_expected, v_replacement);

  execute v_def;
end
$migration$;

do $migration$
declare
  v_oid oid;
  v_def text;
  v_expected text;
  v_replacement text;
begin
  select p.oid
    into v_oid
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname = 'service_admin_create_manual_appointment'
    and pg_get_function_identity_arguments(p.oid) =
      'p_customer_id uuid, p_service_id uuid, p_service_employee_id uuid, p_requested_start_at timestamp with time zone, p_admin_id uuid, p_duration_blocks integer, p_extra_selections jsonb, p_people_count integer, p_notes text';

  if v_oid is null then
    raise exception 'SERVICE_ADMIN_CREATE_MANUAL_APPOINTMENT_NOT_FOUND';
  end if;

  v_def := pg_get_functiondef(v_oid);

  v_expected := E'  v_result := public.promote_checkout_hold_standard(';
  v_replacement := E'  perform set_config(''agenda.manual_booking'', ''on'', true);\n\n  v_result := public.promote_checkout_hold_standard(';
  if position(v_expected in v_def) = 0 then
    raise exception 'MANUAL_BOOKING_PROMOTION_PATCH_POINT_NOT_FOUND';
  end if;
  v_def := replace(v_def, v_expected, v_replacement);

  v_expected := E'  v_appointment_id := (v_result->>''appointment_id'')::uuid;';
  v_replacement := E'  perform set_config(''agenda.manual_booking'', ''off'', true);\n\n  v_appointment_id := (v_result->>''appointment_id'')::uuid;';
  if position(v_expected in v_def) = 0 then
    raise exception 'MANUAL_BOOKING_RESET_PATCH_POINT_NOT_FOUND';
  end if;
  v_def := replace(v_def, v_expected, v_replacement);

  execute v_def;
end
$migration$;
