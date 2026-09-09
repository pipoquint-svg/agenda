create or replace function public.list_available_slots_for_duration(
  p_service_id uuid,
  p_service_employee_id uuid,
  p_duration_blocks integer,
  p_extra_selections jsonb,
  p_people_count integer,
  p_local_date date,
  p_exclude_appointment_id uuid
)
returns table(
  slot_start_at timestamptz,
  slot_end_at timestamptz,
  core_start_at timestamptz,
  core_end_at timestamptz,
  pre_service_minutes integer,
  post_service_minutes integer,
  duration_minutes integer,
  commercial_value numeric
)
language sql
stable
set search_path to 'public','extensions'
as $function$
  select *
  from public.list_available_slots_for_duration(
    p_service_id => p_service_id,
    p_service_employee_id => p_service_employee_id,
    p_duration_blocks => p_duration_blocks,
    p_extra_selections => p_extra_selections,
    p_people_count => p_people_count,
    p_local_date => p_local_date,
    p_coupon_code => null
  );
$function$;

revoke all on function public.list_available_slots_for_duration(uuid,uuid,integer,jsonb,integer,date,uuid) from public, anon, authenticated;
grant execute on function public.list_available_slots_for_duration(uuid,uuid,integer,jsonb,integer,date,uuid) to service_role;

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
      'notes', nullif(btrim(coalesce(p_notes,'')), '')
    ),
    'ADMIN'
  );

  return v_result || jsonb_build_object(
    'manual_booking', true,
    'checkout_hold_id', v_hold_id
  );
end;
$function$;

revoke all on function public.service_admin_create_manual_appointment(uuid,uuid,uuid,timestamptz,uuid,integer,jsonb,integer,text) from public, anon, authenticated;
grant execute on function public.service_admin_create_manual_appointment(uuid,uuid,uuid,timestamptz,uuid,integer,jsonb,integer,text) to service_role;