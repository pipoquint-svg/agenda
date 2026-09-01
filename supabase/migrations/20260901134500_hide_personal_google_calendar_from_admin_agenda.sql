create or replace function public.service_admin_list_agenda(
  p_start_at timestamptz,
  p_end_at timestamptz
)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
begin
  if p_start_at is null or p_end_at is null or p_end_at <= p_start_at then
    raise exception using errcode = 'P0001', message = 'ADMIN_AGENDA_INVALID_RANGE';
  end if;
  if p_end_at - p_start_at > interval '31 days' then
    raise exception using errcode = 'P0001', message = 'ADMIN_AGENDA_RANGE_TOO_LARGE';
  end if;

  return jsonb_build_object(
    'range', jsonb_build_object('start_at', p_start_at, 'end_at', p_end_at),
    'appointments', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', a.id,
        'public_code', a.public_code,
        'status', a.status,
        'financial_status', a.financial_status,
        'start_at', a.start_at,
        'end_at', a.end_at,
        'created_at', a.created_at,
        'duration_minutes', a.duration_minutes,
        'duration_blocks', a.duration_blocks,
        'contracted_minutes', a.contracted_minutes,
        'people_count', a.people_count,
        'origin', a.origin,
        'operation_scope', s.operation_scope,
        'service_name', coalesce(a.service_name_snapshot, s.name),
        'duration_mode', s.duration_mode,
        'buffer_before_minutes', s.buffer_before_minutes,
        'buffer_after_minutes', s.buffer_after_minutes,
        'employee_name', e.name,
        'customer', jsonb_build_object('id', c.id, 'name', c.name, 'phone', c.phone, 'email', c.email),
        'commercial_value', a.commercial_value,
        'financial', public.get_appointment_financial_summary(a.id),
        'resources', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', r.id,
            'name', r.name,
            'type', r.resource_type,
            'occupied_start_at', lower(ra.occupied_range),
            'occupied_end_at', upper(ra.occupied_range)
          ) order by r.name)
          from public.resource_allocations ra
          join public.resources r on r.id = ra.resource_id
          where ra.appointment_id = a.id
            and ra.allocation_type = 'APPOINTMENT'
            and ra.status not in ('RELEASED', 'CANCELLED', 'EXPIRED')
        ), '[]'::jsonb)
      ) order by a.start_at, a.public_code)
      from public.appointments a
      left join public.services s on s.id = a.service_id
      left join public.service_employees se on se.id = a.service_employee_id
      left join public.employees e on e.id = se.employee_id
      left join public.customers c on c.id = a.primary_customer_id
      where a.deleted_at is null
        and a.status <> 'DRAFT'
        and a.start_at < p_end_at
        and a.end_at > p_start_at
    ), '[]'::jsonb),
    'external_blocks', coalesce((
      select jsonb_agg(jsonb_build_object(
        'allocation_id', ra.id,
        'resource_id', r.id,
        'resource_name', r.name,
        'start_at', lower(ra.occupied_range),
        'end_at', upper(ra.occupied_range),
        'status', ra.status,
        'reason', ra.reason,
        'source', coalesce(ra.external_source, 'GOOGLE'),
        'calendar_name', gc.name,
        'event_summary', gce.summary,
        'event_qualification', gce.qualification
      ) order by lower(ra.occupied_range), r.name)
      from public.resource_allocations ra
      join public.resources r on r.id = ra.resource_id
      left join public.google_calendar_events gce on gce.id = ra.google_calendar_event_id
      left join public.google_calendars gc on gc.id = gce.google_calendar_id
      where ra.allocation_type = 'EXTERNAL_BLOCK'
        and ra.status = 'EXTERNAL_ACTIVE'
        and lower(ra.occupied_range) < p_end_at
        and upper(ra.occupied_range) > p_start_at
        and lower(trim(coalesce(gc.name, ''))) <> lower('Compromissos Pessoais')
    ), '[]'::jsonb)
  );
end;
$function$;

comment on function public.service_admin_list_agenda(timestamptz, timestamptz) is
'Agenda administrativa. Compromissos Pessoais continuam bloqueando disponibilidade, mas não são exibidos como bloqueios externos na agenda visual.';
