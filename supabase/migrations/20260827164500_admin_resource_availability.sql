-- Admin resource availability contracts.
-- Agenda remains the source of truth for operational resource availability.
-- Browser clients must access these RPCs only through the authenticated admin Edge boundary.

create or replace function public.service_admin_list_resource_settings()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', r.id,
        'name', r.name,
        'resource_type', r.resource_type,
        'is_active', r.is_active,
        'availability_rules', coalesce((
          select jsonb_agg(
            jsonb_build_object(
              'id', rar.id,
              'weekday', rar.weekday,
              'start_local_time', rar.start_local_time,
              'end_local_time', rar.end_local_time,
              'is_active', rar.is_active
            ) order by rar.weekday, rar.start_local_time, rar.end_local_time, rar.id
          )
          from public.resource_availability_rules rar
          where rar.resource_id = r.id
        ), '[]'::jsonb),
        'service_bindings', coalesce((
          select jsonb_agg(
            jsonb_build_object(
              'service_id', sr.service_id,
              'service_name', s.name,
              'operation_scope', s.operation_scope,
              'is_required', sr.is_required
            ) order by s.sort_order, s.name, s.id
          )
          from public.service_resources sr
          join public.services s on s.id = sr.service_id
          where sr.resource_id = r.id
        ), '[]'::jsonb)
      ) order by r.name, r.id
    ),
    '[]'::jsonb
  )
  from public.resources r;
$$;

create or replace function public.service_admin_replace_resource_availability_audited(
  p_resource_id uuid,
  p_rules jsonb,
  p_admin_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_before jsonb;
  v_after jsonb;
  v_rule jsonb;
  v_weekday integer;
  v_start time;
  v_end time;
  v_active boolean;
begin
  if not public.service_admin_has_permission(p_admin_id, 'SERVICES_MANAGE') then
    raise exception using errcode = 'P0001', message = 'ADMIN_PERMISSION_DENIED';
  end if;

  if not exists (select 1 from public.resources where id = p_resource_id) then
    raise exception using errcode = 'P0001', message = 'RESOURCE_NOT_FOUND';
  end if;

  if jsonb_typeof(coalesce(p_rules, '[]'::jsonb)) <> 'array' then
    raise exception using errcode = 'P0001', message = 'RESOURCE_AVAILABILITY_RULES_INVALID';
  end if;

  select coalesce(
    jsonb_agg(to_jsonb(rar) order by rar.weekday, rar.start_local_time, rar.end_local_time, rar.id),
    '[]'::jsonb
  )
  into v_before
  from public.resource_availability_rules rar
  where rar.resource_id = p_resource_id;

  delete from public.resource_availability_rules
  where resource_id = p_resource_id;

  for v_rule in
    select value from jsonb_array_elements(coalesce(p_rules, '[]'::jsonb))
  loop
    begin
      v_weekday := (v_rule ->> 'weekday')::integer;
    exception when others then
      raise exception using errcode = 'P0001', message = 'RESOURCE_WEEKDAY_INVALID';
    end;

    if v_weekday < 0 or v_weekday > 6 then
      raise exception using errcode = 'P0001', message = 'RESOURCE_WEEKDAY_INVALID';
    end if;

    if nullif(btrim(v_rule ->> 'start_local_time'), '') is null
       or nullif(btrim(v_rule ->> 'end_local_time'), '') is null then
      raise exception using errcode = 'P0001', message = 'RESOURCE_TIME_REQUIRED';
    end if;

    begin
      v_start := (v_rule ->> 'start_local_time')::time;
      v_end := (v_rule ->> 'end_local_time')::time;
    exception when others then
      raise exception using errcode = 'P0001', message = 'RESOURCE_TIME_INVALID';
    end;

    if v_start >= v_end then
      raise exception using errcode = 'P0001', message = 'RESOURCE_TIME_RANGE_INVALID';
    end if;

    begin
      v_active := coalesce((v_rule ->> 'is_active')::boolean, true);
    exception when others then
      raise exception using errcode = 'P0001', message = 'RESOURCE_ACTIVE_INVALID';
    end;

    insert into public.resource_availability_rules(
      resource_id,
      weekday,
      start_local_time,
      end_local_time,
      is_active,
      updated_at
    ) values (
      p_resource_id,
      v_weekday,
      v_start,
      v_end,
      v_active,
      now()
    );
  end loop;

  select coalesce(
    jsonb_agg(to_jsonb(rar) order by rar.weekday, rar.start_local_time, rar.end_local_time, rar.id),
    '[]'::jsonb
  )
  into v_after
  from public.resource_availability_rules rar
  where rar.resource_id = p_resource_id;

  if v_before is distinct from v_after then
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
      'RESOURCE',
      p_resource_id,
      'RESOURCE_AVAILABILITY_UPDATED',
      v_before,
      v_after,
      'ADMIN'
    );
  end if;

  return v_after;
end;
$$;

comment on function public.service_admin_list_resource_settings() is
  'Service-role-only read model for Agenda operational resources, weekly availability rules and service bindings.';
comment on function public.service_admin_replace_resource_availability_audited(uuid, jsonb, uuid) is
  'Replaces one resource weekly availability schedule after SERVICES_MANAGE authorization and writes an audit log.';

revoke all on function public.service_admin_list_resource_settings() from public, anon, authenticated;
revoke all on function public.service_admin_replace_resource_availability_audited(uuid, jsonb, uuid) from public, anon, authenticated;
grant execute on function public.service_admin_list_resource_settings() to service_role;
grant execute on function public.service_admin_replace_resource_availability_audited(uuid, jsonb, uuid) to service_role;
