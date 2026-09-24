-- Administrative/manual bookings are staff-authored reservations, not public checkout.
-- They must preserve inventory/price/allocation invariants while bypassing public-only
-- customer form/terms gates. Public checkout behavior remains unchanged.
--
-- A transaction-local GUC is set only inside the SECURITY DEFINER admin creation RPC.
-- The canonical promoter is not executable by anon/authenticated roles.

do $migration$
declare
  v_oid oid;
  v_def text;
  v_old_fields text := $old$if v_missing_required_fields > 0 then
    raise exception using errcode = 'P0001', message = 'REQUIRED_SERVICE_FIELDS_MISSING';
  end if;$old$;
  v_new_fields text := $new$if coalesce(current_setting('agenda.manual_booking', true), '') <> 'on'
     and v_missing_required_fields > 0 then
    raise exception using errcode = 'P0001', message = 'REQUIRED_SERVICE_FIELDS_MISSING';
  end if;$new$;
  v_old_terms text := $old$if v_service.requires_terms then$old$;
  v_new_terms text := $new$if coalesce(current_setting('agenda.manual_booking', true), '') <> 'on'
     and v_service.requires_terms then$new$;
begin
  select p.oid into v_oid
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

  if position(v_old_fields in v_def) = 0 then
    raise exception 'PROMOTE_REQUIRED_FIELDS_GUARD_NOT_FOUND';
  end if;
  v_def := replace(v_def, v_old_fields, v_new_fields);

  if position(v_old_terms in v_def) = 0 then
    raise exception 'PROMOTE_TERMS_GUARD_NOT_FOUND';
  end if;
  v_def := replace(v_def, v_old_terms, v_new_terms);

  execute v_def;
end
$migration$;

create or replace function public.service_admin_create_manual_appointment(
  p_customer_id uuid,
  p_service_id uuid,
  p_service_employee_id uuid,
  p_requested_start_at timestamptz,
  p_admin_id uuid,
  p_duration_blocks integer default null,
  p_extra_selections jsonb default '[]'::jsonb,
  p_people_count integer default 1,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public','extensions'
as $function$
declare
  v_hold jsonb;
  v_result jsonb;
  v_hold_id uuid;
  v_appointment_id uuid;
begin
  if not public.service_admin_has_permission(p_admin_id, 'AGENDA_MANAGE') then
    raise exception using errcode='P0001', message='ADMIN_PERMISSION_DENIED';
  end if;

  if not exists (select 1 from public.customers c where c.id = p_customer_id and c.anonymized_at is null) then
    raise exception using errcode='P0001', message='CUSTOMER_NOT_FOUND';
  end if;

  if p_duration_blocks is null then
    v_hold := public.create_checkout_hold(
      p_service_id,
      p_service_employee_id,
      coalesce(p_extra_selections, '[]'::jsonb),
      p_people_count,
      p_requested_start_at
    );
  else
    v_hold := public.create_checkout_hold_for_duration(
      p_service_id,
      p_service_employee_id,
      p_duration_blocks,
      coalesce(p_extra_selections, '[]'::jsonb),
      p_people_count,
      p_requested_start_at
    );
  end if;

  v_hold_id := (v_hold->>'checkout_hold_id')::uuid;
  if v_hold_id is null then
    raise exception using errcode='P0001', message='MANUAL_BOOKING_HOLD_CREATION_FAILED';
  end if;

  -- Public-only requirements (custom required questions and customer terms)
  -- do not apply to a reservation explicitly authored by an AGENDA_MANAGE admin.
  perform set_config('agenda.manual_booking', 'on', true);

  v_result := public.promote_checkout_hold_standard(
    v_hold_id,
    p_customer_id,
    null,
    '{}'::uuid[],
    '[]'::jsonb,
    '[]'::jsonb,
    null,
    null
  );

  perform set_config('agenda.manual_booking', 'off', true);

  v_appointment_id := (v_result->>'appointment_id')::uuid;
  if v_appointment_id is null then
    raise exception using errcode='P0001', message='MANUAL_BOOKING_APPOINTMENT_CREATION_FAILED';
  end if;

  update public.appointments
  set origin = 'ADMIN', updated_at = now()
  where id = v_appointment_id;

  insert into public.audit_logs(
    admin_user_id, entity_type, entity_id, action, before_json, after_json, origin
  ) values (
    p_admin_id,
    'APPOINTMENT',
    v_appointment_id,
    'ADMIN_MANUAL_BOOKING_CREATED',
    jsonb_build_object('checkout_hold_id', v_hold_id),
    jsonb_build_object(
      'service_id', p_service_id,
      'service_employee_id', p_service_employee_id,
      'customer_id', p_customer_id,
      'requested_start_at', p_requested_start_at,
      'people_count', p_people_count,
      'duration_blocks', p_duration_blocks,
      'notes', nullif(btrim(coalesce(p_notes,'')), ''),
      'public_requirements_bypassed', true
    ),
    'ADMIN'
  );

  return v_result || jsonb_build_object(
    'manual_booking', true,
    'checkout_hold_id', v_hold_id
  );
end;
$function$;

revoke all on function public.service_admin_create_manual_appointment(uuid,uuid,uuid,timestamptz,uuid,integer,jsonb,integer,text)
  from public, anon, authenticated;
grant execute on function public.service_admin_create_manual_appointment(uuid,uuid,uuid,timestamptz,uuid,integer,jsonb,integer,text)
  to service_role;
