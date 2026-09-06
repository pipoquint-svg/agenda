create or replace function public.admin_copy_employee_availability_audited(
  p_source_service_employee_id uuid,
  p_target_service_employee_ids uuid[],
  p_copy_work_hours boolean,
  p_copy_blocks boolean,
  p_copy_opens boolean,
  p_admin_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_source_employee_id uuid;
  v_target_service_employee_id uuid;
  v_target_count integer;
  v_before jsonb;
  v_after jsonb;
  v_copy_work_hours boolean := coalesce(p_copy_work_hours, false);
  v_copy_blocks boolean := coalesce(p_copy_blocks, false);
  v_copy_opens boolean := coalesce(p_copy_opens, false);
begin
  if not public.service_admin_has_permission(p_admin_id, 'SERVICES_MANAGE') then
    raise exception using errcode = 'P0001', message = 'ADMIN_PERMISSION_DENIED';
  end if;

  if not (v_copy_work_hours or v_copy_blocks or v_copy_opens) then
    raise exception using errcode = 'P0001', message = 'AVAILABILITY_COPY_NOTHING_SELECTED';
  end if;

  select se.employee_id
    into v_source_employee_id
  from public.service_employees se
  where se.id = p_source_service_employee_id
    and se.is_active = true;

  if v_source_employee_id is null then
    raise exception using errcode = 'P0001', message = 'AVAILABILITY_COPY_SOURCE_NOT_FOUND';
  end if;

  select count(distinct u.target_id)
    into v_target_count
  from unnest(coalesce(p_target_service_employee_ids, '{}'::uuid[])) as u(target_id)
  where u.target_id is not null
    and u.target_id <> p_source_service_employee_id;

  if v_target_count < 1 then
    raise exception using errcode = 'P0001', message = 'AVAILABILITY_COPY_TARGET_REQUIRED';
  end if;
  if v_target_count > 25 then
    raise exception using errcode = 'P0001', message = 'AVAILABILITY_COPY_TOO_MANY_TARGETS';
  end if;

  if exists (
    select 1
    from (
      select distinct u.target_id
      from unnest(coalesce(p_target_service_employee_ids, '{}'::uuid[])) as u(target_id)
      where u.target_id is not null
        and u.target_id <> p_source_service_employee_id
    ) requested
    left join public.service_employees target on target.id = requested.target_id
    where target.id is null
       or target.employee_id <> v_source_employee_id
       or target.is_active is not true
  ) then
    raise exception using errcode = 'P0001', message = 'AVAILABILITY_COPY_TARGET_INVALID';
  end if;

  for v_target_service_employee_id in
    select distinct u.target_id
    from unnest(coalesce(p_target_service_employee_ids, '{}'::uuid[])) as u(target_id)
    where u.target_id is not null
      and u.target_id <> p_source_service_employee_id
  loop
    select jsonb_build_object(
      'work_hours', coalesce((
        select jsonb_agg(
          jsonb_build_object(
            'weekday', ar.weekday,
            'start_local_time', ar.start_local_time,
            'end_local_time', ar.end_local_time,
            'slot_interval_minutes', ar.slot_interval_minutes,
            'is_active', ar.is_active
          ) order by ar.weekday, ar.start_local_time, ar.id
        )
        from public.availability_rules ar
        where ar.service_employee_id = v_target_service_employee_id
      ), '[]'::jsonb),
      'manual_exceptions', coalesce((
        select jsonb_agg(
          jsonb_build_object(
            'exception_type', ax.exception_type,
            'start_at', ax.start_at,
            'end_at', ax.end_at,
            'reason', ax.reason
          ) order by ax.start_at, ax.end_at, ax.id
        )
        from public.availability_exceptions ax
        where ax.service_employee_id = v_target_service_employee_id
          and ax.special_calendar_date_id is null
          and ax.end_at >= now()
          and (
            (v_copy_blocks and ax.exception_type = 'BLOCK')
            or (v_copy_opens and ax.exception_type = 'OPEN')
          )
      ), '[]'::jsonb)
    ) into v_before;

    if v_copy_work_hours then
      delete from public.availability_rules
      where service_employee_id = v_target_service_employee_id;

      insert into public.availability_rules(
        service_employee_id,
        weekday,
        start_local_time,
        end_local_time,
        slot_interval_minutes,
        is_active
      )
      select
        v_target_service_employee_id,
        source.weekday,
        source.start_local_time,
        source.end_local_time,
        source.slot_interval_minutes,
        source.is_active
      from public.availability_rules source
      where source.service_employee_id = p_source_service_employee_id
      order by source.weekday, source.start_local_time, source.id;
    end if;

    if v_copy_blocks or v_copy_opens then
      delete from public.availability_exceptions ax
      where ax.service_employee_id = v_target_service_employee_id
        and ax.special_calendar_date_id is null
        and ax.end_at >= now()
        and (
          (v_copy_blocks and ax.exception_type = 'BLOCK')
          or (v_copy_opens and ax.exception_type = 'OPEN')
        );

      insert into public.availability_exceptions(
        service_employee_id,
        exception_type,
        start_at,
        end_at,
        reason,
        created_by
      )
      select
        v_target_service_employee_id,
        source.exception_type,
        source.start_at,
        source.end_at,
        source.reason,
        p_admin_id
      from public.availability_exceptions source
      where source.service_employee_id = p_source_service_employee_id
        and source.special_calendar_date_id is null
        and source.end_at >= now()
        and (
          (v_copy_blocks and source.exception_type = 'BLOCK')
          or (v_copy_opens and source.exception_type = 'OPEN')
        )
      order by source.start_at, source.end_at, source.id;
    end if;

    select jsonb_build_object(
      'work_hours', coalesce((
        select jsonb_agg(
          jsonb_build_object(
            'weekday', ar.weekday,
            'start_local_time', ar.start_local_time,
            'end_local_time', ar.end_local_time,
            'slot_interval_minutes', ar.slot_interval_minutes,
            'is_active', ar.is_active
          ) order by ar.weekday, ar.start_local_time, ar.id
        )
        from public.availability_rules ar
        where ar.service_employee_id = v_target_service_employee_id
      ), '[]'::jsonb),
      'manual_exceptions', coalesce((
        select jsonb_agg(
          jsonb_build_object(
            'exception_type', ax.exception_type,
            'start_at', ax.start_at,
            'end_at', ax.end_at,
            'reason', ax.reason
          ) order by ax.start_at, ax.end_at, ax.id
        )
        from public.availability_exceptions ax
        where ax.service_employee_id = v_target_service_employee_id
          and ax.special_calendar_date_id is null
          and ax.end_at >= now()
          and (
            (v_copy_blocks and ax.exception_type = 'BLOCK')
            or (v_copy_opens and ax.exception_type = 'OPEN')
          )
      ), '[]'::jsonb)
    ) into v_after;

    insert into public.audit_logs(
      admin_user_id,
      entity_type,
      entity_id,
      action,
      before_json,
      after_json,
      origin
    ) values (
      p_admin_id,
      'SERVICE_EMPLOYEE',
      v_target_service_employee_id,
      'AVAILABILITY_COPIED',
      jsonb_build_object('state', v_before),
      jsonb_build_object(
        'source_service_employee_id', p_source_service_employee_id,
        'copy_work_hours', v_copy_work_hours,
        'copy_blocks', v_copy_blocks,
        'copy_opens', v_copy_opens,
        'state', v_after
      ),
      'ADMIN'
    );
  end loop;

  return jsonb_build_object(
    'source_service_employee_id', p_source_service_employee_id,
    'target_count', v_target_count,
    'copy_work_hours', v_copy_work_hours,
    'copy_blocks', v_copy_blocks,
    'copy_opens', v_copy_opens,
    'copied', true
  );
end;
$function$;

revoke all on function public.admin_copy_employee_availability_audited(uuid, uuid[], boolean, boolean, boolean, uuid) from public, anon, authenticated;
grant execute on function public.admin_copy_employee_availability_audited(uuid, uuid[], boolean, boolean, boolean, uuid) to service_role;
