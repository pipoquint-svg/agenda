-- Audited OPEN/BLOCK exceptions for operational resources.

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
        'exceptions', coalesce((
          select jsonb_agg(
            jsonb_build_object(
              'id', ae.id,
              'exception_type', ae.exception_type,
              'start_at', ae.start_at,
              'end_at', ae.end_at,
              'reason', ae.reason,
              'created_at', ae.created_at
            ) order by ae.start_at desc, ae.id
          )
          from public.availability_exceptions ae
          where ae.resource_id = r.id
            and ae.end_at >= now() - interval '30 days'
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

create or replace function public.service_admin_add_resource_exception_audited(
  p_resource_id uuid,
  p_exception_type text,
  p_start_at timestamptz,
  p_end_at timestamptz,
  p_reason text,
  p_admin_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_type text := upper(btrim(coalesce(p_exception_type, '')));
  v_id uuid;
  v_after jsonb;
begin
  if not public.service_admin_has_permission(p_admin_id, 'SERVICES_MANAGE') then
    raise exception using errcode = 'P0001', message = 'ADMIN_PERMISSION_DENIED';
  end if;

  if not exists (select 1 from public.resources where id = p_resource_id) then
    raise exception using errcode = 'P0001', message = 'RESOURCE_NOT_FOUND';
  end if;

  if v_type not in ('OPEN', 'BLOCK') then
    raise exception using errcode = 'P0001', message = 'RESOURCE_EXCEPTION_TYPE_INVALID';
  end if;

  if p_start_at is null or p_end_at is null or p_end_at <= p_start_at then
    raise exception using errcode = 'P0001', message = 'RESOURCE_EXCEPTION_RANGE_INVALID';
  end if;

  insert into public.availability_exceptions(
    resource_id,
    exception_type,
    start_at,
    end_at,
    reason,
    created_by
  ) values (
    p_resource_id,
    v_type,
    p_start_at,
    p_end_at,
    nullif(btrim(coalesce(p_reason, '')), ''),
    p_admin_id
  )
  returning id into v_id;

  select jsonb_build_object(
    'id', ae.id,
    'resource_id', ae.resource_id,
    'exception_type', ae.exception_type,
    'start_at', ae.start_at,
    'end_at', ae.end_at,
    'reason', ae.reason,
    'created_at', ae.created_at
  )
  into v_after
  from public.availability_exceptions ae
  where ae.id = v_id;

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
    'RESOURCE_EXCEPTION',
    v_id,
    'RESOURCE_EXCEPTION_CREATED',
    null,
    v_after,
    'ADMIN'
  );

  return v_after;
end;
$$;

create or replace function public.service_admin_remove_resource_exception_audited(
  p_exception_id uuid,
  p_admin_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_before jsonb;
begin
  if not public.service_admin_has_permission(p_admin_id, 'SERVICES_MANAGE') then
    raise exception using errcode = 'P0001', message = 'ADMIN_PERMISSION_DENIED';
  end if;

  select jsonb_build_object(
    'id', ae.id,
    'resource_id', ae.resource_id,
    'exception_type', ae.exception_type,
    'start_at', ae.start_at,
    'end_at', ae.end_at,
    'reason', ae.reason,
    'created_at', ae.created_at
  )
  into v_before
  from public.availability_exceptions ae
  where ae.id = p_exception_id
    and ae.resource_id is not null;

  if v_before is null then
    raise exception using errcode = 'P0001', message = 'RESOURCE_EXCEPTION_NOT_FOUND';
  end if;

  delete from public.availability_exceptions
  where id = p_exception_id;

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
    'RESOURCE_EXCEPTION',
    p_exception_id,
    'RESOURCE_EXCEPTION_DELETED',
    v_before,
    null,
    'ADMIN'
  );

  return v_before;
end;
$$;

revoke all on function public.service_admin_add_resource_exception_audited(uuid, text, timestamptz, timestamptz, text, uuid) from public, anon, authenticated;
revoke all on function public.service_admin_remove_resource_exception_audited(uuid, uuid) from public, anon, authenticated;
grant execute on function public.service_admin_add_resource_exception_audited(uuid, text, timestamptz, timestamptz, text, uuid) to service_role;
grant execute on function public.service_admin_remove_resource_exception_audited(uuid, uuid) to service_role;
