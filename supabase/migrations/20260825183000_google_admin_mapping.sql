create or replace function public.service_admin_add_google_calendar_resource_mapping(
  p_google_calendar_id uuid,
  p_resource_id uuid,
  p_admin_user_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_calendar record;
  v_resource public.resources%rowtype;
  v_exists boolean;
begin
  select gc.id, gc.name, gc.access_role, gc.is_active, gconn.status as connection_status
  into v_calendar
  from public.google_calendars gc
  join public.google_connections gconn on gconn.id = gc.google_connection_id
  where gc.id = p_google_calendar_id
  for update of gc;

  if not found or not v_calendar.is_active then
    raise exception using errcode = 'P0001', message = 'GOOGLE_CALENDAR_NOT_ACTIVE';
  end if;
  if v_calendar.connection_status <> 'ACTIVE' then
    raise exception using errcode = 'P0001', message = 'GOOGLE_CONNECTION_NOT_ACTIVE';
  end if;
  if coalesce(v_calendar.access_role, '') not in ('writer', 'owner') then
    raise exception using errcode = 'P0001', message = 'GOOGLE_CALENDAR_WRITE_ACCESS_REQUIRED';
  end if;

  select * into v_resource
  from public.resources
  where id = p_resource_id
    and is_active
  for update;
  if not found then
    raise exception using errcode = 'P0001', message = 'RESOURCE_NOT_ACTIVE';
  end if;

  select exists(
    select 1 from public.google_calendar_resources
    where google_calendar_id = p_google_calendar_id
      and resource_id = p_resource_id
  ) into v_exists;

  insert into public.google_calendar_resources (google_calendar_id, resource_id)
  values (p_google_calendar_id, p_resource_id)
  on conflict do nothing;

  insert into public.audit_logs (
    admin_user_id, entity_type, entity_id, action, before_json, after_json, origin
  ) values (
    p_admin_user_id,
    'RESOURCE',
    p_resource_id,
    case when v_exists then 'GOOGLE_CALENDAR_RESOURCE_MAPPING_RECONFIRMED' else 'GOOGLE_CALENDAR_RESOURCE_MAPPED' end,
    jsonb_build_object('mapped', v_exists),
    jsonb_build_object(
      'mapped', true,
      'google_calendar_id', p_google_calendar_id,
      'calendar_name', v_calendar.name,
      'resource_name', v_resource.name
    ),
    'ADMIN'
  );

  return jsonb_build_object(
    'google_calendar_id', p_google_calendar_id,
    'resource_id', p_resource_id,
    'mapped', true,
    'already_mapped', v_exists
  );
end;
$$;

revoke all on function public.service_admin_add_google_calendar_resource_mapping(uuid,uuid,uuid) from public, anon, authenticated;
grant execute on function public.service_admin_add_google_calendar_resource_mapping(uuid,uuid,uuid) to service_role;

create or replace function public.service_admin_remove_google_calendar_resource_mapping(
  p_google_calendar_id uuid,
  p_resource_id uuid,
  p_admin_user_id uuid,
  p_reason text default 'ADMIN_UNMAP'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_calendar_name text;
  v_resource_name text;
  v_released integer := 0;
  v_deleted integer := 0;
begin
  if coalesce(btrim(p_reason), '') = '' then
    raise exception using errcode = 'P0001', message = 'UNMAP_REASON_REQUIRED';
  end if;

  select name into v_calendar_name
  from public.google_calendars
  where id = p_google_calendar_id;
  select name into v_resource_name
  from public.resources
  where id = p_resource_id;

  update public.resource_allocations ra
  set status = 'RELEASED',
      updated_at = now()
  where ra.resource_id = p_resource_id
    and ra.allocation_type = 'EXTERNAL_BLOCK'
    and ra.status in ('EXTERNAL_ACTIVE', 'IGNORED_BY_ADMIN')
    and exists (
      select 1
      from public.google_calendar_events gce
      where gce.id = ra.google_calendar_event_id
        and gce.google_calendar_id = p_google_calendar_id
    );
  get diagnostics v_released = row_count;

  update public.schedule_divergences sd
  set status = 'RESOLVED',
      resolved_at = now(),
      resolution_notes = coalesce(sd.resolution_notes || E'\n', '') || 'Google calendar resource mapping removed by admin.',
      updated_at = now()
  where sd.resource_id = p_resource_id
    and sd.status = 'OPEN'
    and exists (
      select 1
      from public.google_calendar_events gce
      where gce.id = sd.google_calendar_event_id
        and gce.google_calendar_id = p_google_calendar_id
    );

  delete from public.google_calendar_resources
  where google_calendar_id = p_google_calendar_id
    and resource_id = p_resource_id;
  get diagnostics v_deleted = row_count;

  insert into public.audit_logs (
    admin_user_id, entity_type, entity_id, action, before_json, after_json, origin
  ) values (
    p_admin_user_id,
    'RESOURCE',
    p_resource_id,
    'GOOGLE_CALENDAR_RESOURCE_UNMAPPED',
    jsonb_build_object(
      'mapped', v_deleted > 0,
      'google_calendar_id', p_google_calendar_id,
      'calendar_name', v_calendar_name,
      'resource_name', v_resource_name
    ),
    jsonb_build_object('mapped', false, 'released_external_blocks', v_released, 'reason', p_reason),
    'ADMIN'
  );

  return jsonb_build_object(
    'google_calendar_id', p_google_calendar_id,
    'resource_id', p_resource_id,
    'mapped', false,
    'mapping_removed', v_deleted > 0,
    'released_external_blocks', v_released
  );
end;
$$;

revoke all on function public.service_admin_remove_google_calendar_resource_mapping(uuid,uuid,uuid,text) from public, anon, authenticated;
grant execute on function public.service_admin_remove_google_calendar_resource_mapping(uuid,uuid,uuid,text) to service_role;
