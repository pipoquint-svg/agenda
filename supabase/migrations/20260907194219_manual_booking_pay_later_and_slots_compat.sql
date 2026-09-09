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
    p_service_id,
    p_service_employee_id,
    p_duration_blocks,
    p_extra_selections,
    p_people_count,
    p_local_date,
    null::text
  );
$function$;

revoke all on function public.list_available_slots_for_duration(uuid,uuid,integer,jsonb,integer,date,uuid) from public, anon, authenticated;
grant execute on function public.list_available_slots_for_duration(uuid,uuid,integer,jsonb,integer,date,uuid) to service_role;

create or replace function public.service_admin_confirm_manual_appointment_unpaid(
  p_appointment_id uuid,
  p_reason text default 'Reserva manual — pagamento autorizado para depois'
)
returns jsonb
language plpgsql
security definer
set search_path to 'public','pg_temp'
as $function$
declare
  v_admin_id uuid;
  v_origin text;
begin
  if auth.uid() is null then
    raise exception 'ADMIN_AUTH_REQUIRED';
  end if;

  v_admin_id := public.service_admin_resolve_auth_user(auth.uid());
  if v_admin_id is null then
    raise exception 'ADMIN_ACCESS_DENIED';
  end if;

  if not public.service_admin_has_permission(v_admin_id, 'AGENDA_MANAGE') then
    raise exception 'ADMIN_PERMISSION_DENIED';
  end if;

  select a.origin into v_origin
  from public.appointments a
  where a.id = p_appointment_id;

  if not found then
    raise exception 'APPOINTMENT_NOT_FOUND';
  end if;

  if coalesce(v_origin,'') <> 'ADMIN' then
    raise exception 'MANUAL_APPOINTMENT_REQUIRED';
  end if;

  return public.service_admin_confirm_appointment_unpaid(
    p_appointment_id,
    coalesce(nullif(btrim(p_reason),''), 'Reserva manual — pagamento autorizado para depois'),
    v_admin_id
  );
end;
$function$;

revoke all on function public.service_admin_confirm_manual_appointment_unpaid(uuid,text) from public, anon;
grant execute on function public.service_admin_confirm_manual_appointment_unpaid(uuid,text) to authenticated;
