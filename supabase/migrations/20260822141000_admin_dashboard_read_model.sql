-- Explicit dashboard semantics for the unified BlackSheep + Sabrina admin hub.
-- Existing services remain unscoped on purpose: no operation is inferred from names.

alter table public.services
  add column operation_scope text
  check (operation_scope is null or operation_scope in ('BLACKSHEEP','SABRINA'));

create index services_operation_scope_idx
  on public.services(operation_scope)
  where operation_scope is not null;

alter table public.operation_settings
  add column dashboard_occupancy_resource_id uuid references public.resources(id) on delete set null;

-- Enrich the existing operational agenda with explicit scope and creation time.
create or replace function public.service_admin_list_agenda(
  p_start_at timestamptz,
  p_end_at timestamptz
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
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
        'customer', jsonb_build_object(
          'id', c.id,
          'name', c.name,
          'phone', c.phone,
          'email', c.email
        ),
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
            and ra.status not in ('RELEASED','CANCELLED','EXPIRED')
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
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function public.service_admin_get_dashboard(
  p_start_at timestamptz,
  p_end_at timestamptz,
  p_operation_scope text default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_scope text := nullif(upper(btrim(p_operation_scope)), '');
  v_occupancy_resource uuid;
  v_timezone text;
  v_overlap_rules boolean := false;
  v_exception_count integer := 0;
  v_capacity_minutes numeric := 0;
  v_appointment_minutes numeric := 0;
  v_filtered_appointment_minutes numeric := 0;
  v_external_minutes numeric := 0;
  v_manual_minutes numeric := 0;
  v_occupancy jsonb;
begin
  if p_start_at is null or p_end_at is null or p_end_at <= p_start_at then
    raise exception using errcode = 'P0001', message = 'ADMIN_DASHBOARD_INVALID_RANGE';
  end if;
  if p_end_at - p_start_at > interval '31 days' then
    raise exception using errcode = 'P0001', message = 'ADMIN_DASHBOARD_RANGE_TOO_LARGE';
  end if;
  if v_scope is not null and v_scope not in ('BLACKSHEEP','SABRINA') then
    raise exception using errcode = 'P0001', message = 'ADMIN_DASHBOARD_OPERATION_SCOPE_INVALID';
  end if;

  select os.dashboard_occupancy_resource_id, os.timezone
    into v_occupancy_resource, v_timezone
  from public.operation_settings os
  where os.id = 1;
  v_timezone := coalesce(v_timezone, 'America/Sao_Paulo');

  if v_occupancy_resource is null then
    v_occupancy := jsonb_build_object(
      'available', false,
      'reason', 'OCCUPANCY_RESOURCE_NOT_CONFIGURED',
      'resource_id', null,
      'capacity_minutes', null,
      'total_occupied_minutes', null,
      'appointment_minutes', null,
      'filtered_appointment_minutes', null,
      'external_block_minutes', null,
      'manual_block_minutes', null,
      'total_rate_percent', null,
      'appointment_rate_percent', null,
      'filtered_appointment_rate_percent', null
    );
  else
    select exists (
      select 1
      from public.resource_availability_rules a
      join public.resource_availability_rules b
        on b.resource_id = a.resource_id
       and b.weekday = a.weekday
       and b.is_active
       and b.id > a.id
       and a.start_local_time < b.end_local_time
       and b.start_local_time < a.end_local_time
      where a.resource_id = v_occupancy_resource
        and a.is_active
    ) into v_overlap_rules;

    select count(*)::integer into v_exception_count
    from public.availability_exceptions ae
    where ae.resource_id = v_occupancy_resource
      and ae.start_at < p_end_at
      and ae.end_at > p_start_at;

    if v_overlap_rules then
      v_occupancy := jsonb_build_object(
        'available', false,
        'reason', 'OCCUPANCY_AVAILABILITY_RULES_OVERLAP',
        'resource_id', v_occupancy_resource,
        'capacity_minutes', null,
        'total_rate_percent', null
      );
    elsif v_exception_count > 0 then
      v_occupancy := jsonb_build_object(
        'available', false,
        'reason', 'OCCUPANCY_HAS_AVAILABILITY_EXCEPTIONS',
        'resource_id', v_occupancy_resource,
        'capacity_minutes', null,
        'total_rate_percent', null
      );
    else
      with local_days as (
        select d::date as local_date
        from generate_series(
          (p_start_at at time zone v_timezone)::date,
          ((p_end_at - interval '1 microsecond') at time zone v_timezone)::date,
          interval '1 day'
        ) d
      ), ranges as (
        select tstzrange(
          greatest((ld.local_date + rar.start_local_time) at time zone v_timezone, p_start_at),
          least((ld.local_date + rar.end_local_time) at time zone v_timezone, p_end_at),
          '[)'
        ) as occupied_range
        from local_days ld
        join public.resource_availability_rules rar
          on rar.resource_id = v_occupancy_resource
         and rar.is_active
         and rar.weekday = extract(dow from ld.local_date)::smallint
      )
      select coalesce(sum(extract(epoch from (upper(occupied_range) - lower(occupied_range))) / 60.0), 0)
        into v_capacity_minutes
      from ranges
      where not isempty(occupied_range) and lower(occupied_range) < upper(occupied_range);

      with allocations as (
        select
          ra.allocation_type,
          s.operation_scope,
          extract(epoch from (
            least(upper(ra.occupied_range), p_end_at) - greatest(lower(ra.occupied_range), p_start_at)
          )) / 60.0 as minutes
        from public.resource_allocations ra
        left join public.appointments a on a.id = ra.appointment_id
        left join public.services s on s.id = a.service_id
        where ra.resource_id = v_occupancy_resource
          and ra.status in ('HELD','AWAITING_PAYMENT','CONFIRMED','BLOCKED','EXTERNAL_ACTIVE')
          and lower(ra.occupied_range) < p_end_at
          and upper(ra.occupied_range) > p_start_at
      )
      select
        coalesce(sum(minutes) filter (where allocation_type = 'APPOINTMENT'), 0),
        coalesce(sum(minutes) filter (where allocation_type = 'APPOINTMENT' and (v_scope is null or operation_scope = v_scope)), 0),
        coalesce(sum(minutes) filter (where allocation_type = 'EXTERNAL_BLOCK'), 0),
        coalesce(sum(minutes) filter (where allocation_type = 'MANUAL_BLOCK'), 0)
      into v_appointment_minutes, v_filtered_appointment_minutes, v_external_minutes, v_manual_minutes
      from allocations;

      if v_capacity_minutes <= 0 then
        v_occupancy := jsonb_build_object(
          'available', false,
          'reason', 'OCCUPANCY_CAPACITY_NOT_CONFIGURED_FOR_PERIOD',
          'resource_id', v_occupancy_resource,
          'capacity_minutes', 0,
          'total_rate_percent', null
        );
      else
        v_occupancy := jsonb_build_object(
          'available', true,
          'reason', null,
          'resource_id', v_occupancy_resource,
          'capacity_minutes', round(v_capacity_minutes, 2),
          'total_occupied_minutes', round(v_appointment_minutes + v_external_minutes + v_manual_minutes, 2),
          'appointment_minutes', round(v_appointment_minutes, 2),
          'filtered_appointment_minutes', round(v_filtered_appointment_minutes, 2),
          'external_block_minutes', round(v_external_minutes, 2),
          'manual_block_minutes', round(v_manual_minutes, 2),
          'total_rate_percent', round(100 * (v_appointment_minutes + v_external_minutes + v_manual_minutes) / v_capacity_minutes, 2),
          'appointment_rate_percent', round(100 * v_appointment_minutes / v_capacity_minutes, 2),
          'filtered_appointment_rate_percent', round(100 * v_filtered_appointment_minutes / v_capacity_minutes, 2)
        );
      end if;
    end if;
  end if;

  return jsonb_build_object(
    'range', jsonb_build_object('start_at', p_start_at, 'end_at', p_end_at),
    'operation_scope', v_scope,
    'metrics', jsonb_build_object(
      'booking_count', (
        select count(*) from public.appointments a
        join public.services s on s.id = a.service_id
        where a.deleted_at is null and a.status <> 'DRAFT'
          and a.start_at < p_end_at and a.end_at > p_start_at
          and (v_scope is null or s.operation_scope = v_scope)
      ),
      'booked_minutes', (
        select coalesce(sum(extract(epoch from (least(a.end_at,p_end_at) - greatest(a.start_at,p_start_at))) / 60.0), 0)
        from public.appointments a
        join public.services s on s.id = a.service_id
        where a.deleted_at is null and a.status <> 'DRAFT'
          and a.start_at < p_end_at and a.end_at > p_start_at
          and (v_scope is null or s.operation_scope = v_scope)
      ),
      'new_booking_count', (
        select count(*) from public.appointments a
        join public.services s on s.id = a.service_id
        where a.deleted_at is null and a.status <> 'DRAFT'
          and a.created_at >= p_start_at and a.created_at < p_end_at
          and (v_scope is null or s.operation_scope = v_scope)
      ),
      'cancellations_count', (
        select count(*) from public.appointments a
        join public.services s on s.id = a.service_id
        where a.deleted_at is null and a.cancelled_at >= p_start_at and a.cancelled_at < p_end_at
          and (v_scope is null or s.operation_scope = v_scope)
      ),
      'reschedules_count', (
        select count(*) from public.appointment_policy_actions apa
        join public.appointments a on a.id = apa.appointment_id
        join public.services s on s.id = a.service_id
        where apa.action_type = 'RESCHEDULE' and apa.status = 'APPLIED'
          and apa.updated_at >= p_start_at and apa.updated_at < p_end_at
          and (v_scope is null or s.operation_scope = v_scope)
      ),
      'recurring_customers', jsonb_build_object(
        'available', false,
        'reason', 'RECURRENCE_DEFINITION_NOT_CONFIGURED',
        'count', null
      )
    ),
    'by_employee', coalesce((
      select jsonb_agg(jsonb_build_object(
        'employee_id', x.employee_id,
        'employee_name', x.employee_name,
        'booking_count', x.booking_count,
        'booked_minutes', x.booked_minutes
      ) order by x.booked_minutes desc, x.employee_name)
      from (
        select e.id as employee_id, e.name as employee_name,
               count(*)::integer as booking_count,
               round(sum(extract(epoch from (least(a.end_at,p_end_at) - greatest(a.start_at,p_start_at))) / 60.0),2) as booked_minutes
        from public.appointments a
        join public.services s on s.id = a.service_id
        left join public.service_employees se on se.id = a.service_employee_id
        left join public.employees e on e.id = se.employee_id
        where a.deleted_at is null and a.status <> 'DRAFT'
          and a.start_at < p_end_at and a.end_at > p_start_at
          and (v_scope is null or s.operation_scope = v_scope)
        group by e.id, e.name
      ) x
    ), '[]'::jsonb),
    'pending_items', coalesce((
      select jsonb_agg(p.item order by p.sort_at, p.item->>'kind')
      from (
        select jsonb_build_object(
          'kind','PRE_RESERVATION_ACTIVE','entity_type','PRE_RESERVATION','entity_id',pr.id,
          'appointment_id',null,'customer_id',pr.customer_id,'customer_name',c.name,
          'service_id',pr.service_id,'service_name',s.name,'operation_scope',s.operation_scope,
          'status',pr.status,'start_at',pr.start_at,'expires_at',pr.expires_at
        ) item, pr.start_at sort_at
        from public.pre_reservations pr
        join public.services s on s.id = pr.service_id
        left join public.customers c on c.id = pr.customer_id
        where pr.status = 'ACTIVE' and pr.expires_at > now()
          and pr.start_at < p_end_at and pr.end_at > p_start_at
          and (v_scope is null or s.operation_scope = v_scope)

        union all
        select jsonb_build_object(
          'kind',case when a.status = 'HELD' then 'APPOINTMENT_HELD' else 'PAYMENT_AWAITING' end,
          'entity_type','APPOINTMENT','entity_id',a.id,'appointment_id',a.id,
          'customer_id',a.primary_customer_id,'customer_name',c.name,
          'service_id',a.service_id,'service_name',coalesce(a.service_name_snapshot,s.name),'operation_scope',s.operation_scope,
          'status',a.status,'start_at',a.start_at,'expires_at',a.hold_expires_at
        ) item, a.start_at sort_at
        from public.appointments a
        join public.services s on s.id = a.service_id
        left join public.customers c on c.id = a.primary_customer_id
        where a.deleted_at is null and a.status in ('HELD','AWAITING_PAYMENT')
          and a.start_at < p_end_at and a.end_at > p_start_at
          and (v_scope is null or s.operation_scope = v_scope)

        union all
        select jsonb_build_object(
          'kind',case when apa.action_type='RESCHEDULE' then 'RESCHEDULE_PENALTY_PENDING' else 'CANCELLATION_REFUND_PENDING' end,
          'entity_type','POLICY_ACTION','entity_id',apa.id,'appointment_id',a.id,
          'customer_id',a.primary_customer_id,'customer_name',c.name,
          'service_id',a.service_id,'service_name',coalesce(a.service_name_snapshot,s.name),'operation_scope',s.operation_scope,
          'status',apa.status,'start_at',a.start_at,'policy_action_id',apa.id
        ) item, a.start_at sort_at
        from public.appointment_policy_actions apa
        join public.appointments a on a.id = apa.appointment_id
        join public.services s on s.id = a.service_id
        left join public.customers c on c.id = a.primary_customer_id
        where ((apa.action_type='RESCHEDULE' and apa.status='AWAITING_PENALTY_PAYMENT')
            or (apa.action_type='CANCEL' and apa.status='PENDING_REFUND'))
          and a.start_at < p_end_at
          and (v_scope is null or s.operation_scope = v_scope)

        union all
        select jsonb_build_object(
          'kind','INTEGRATION_DIVERGENCE','entity_type','SCHEDULE_DIVERGENCE','entity_id',sd.id,
          'appointment_id',sd.appointment_id,'resource_id',sd.resource_id,'operation_scope',s.operation_scope,
          'status',sd.status,'reason',sd.reason,'detected_at',sd.detected_at
        ) item, sd.detected_at sort_at
        from public.schedule_divergences sd
        left join public.appointments a on a.id = sd.appointment_id
        left join public.services s on s.id = a.service_id
        where sd.status = 'OPEN'
          and (v_scope is null or s.operation_scope = v_scope)
      ) p
    ), '[]'::jsonb),
    'occupancy', v_occupancy
  );
end;
$$;

revoke all on function public.service_admin_get_dashboard(timestamptz,timestamptz,text) from public, anon, authenticated;
grant execute on function public.service_admin_get_dashboard(timestamptz,timestamptz,text) to service_role;

comment on column public.services.operation_scope is
  'Explicit admin scope. NULL means unclassified; never infer from service/employee names.';
comment on column public.operation_settings.dashboard_occupancy_resource_id is
  'Optional authoritative resource used as dashboard occupancy denominator. NULL disables occupancy percentage.';
comment on function public.service_admin_get_dashboard(timestamptz,timestamptz,text) is
  'Typed operational dashboard read model. Operation scope is explicit; unsupported metrics return availability metadata instead of guessed values.';
