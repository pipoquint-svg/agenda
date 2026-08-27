
-- BEGIN RC MIGRATION 20260822141000_admin_dashboard_read_model.sql
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
-- END RC MIGRATION 20260822141000_admin_dashboard_read_model.sql

-- BEGIN RC MIGRATION 20260822142000_admin_service_operation_scope.sql
-- Explicit operation classification for admin service settings.
-- Scope changes are audited; no service is classified automatically.

create or replace function public.service_admin_list_service_settings()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
select coalesce(jsonb_agg(jsonb_build_object(
  'id', s.id,
  'name', s.name,
  'slug', s.slug,
  'category', c.name,
  'is_active', s.is_active,
  'operation_scope', s.operation_scope,
  'duration_mode', s.duration_mode,
  'base_duration_minutes', s.base_duration_minutes,
  'booking_block_minutes', s.booking_block_minutes,
  'minimum_booking_blocks', s.minimum_booking_blocks,
  'maximum_booking_blocks', s.maximum_booking_blocks,
  'price_per_block', s.price_per_block,
  'base_price', s.base_price,
  'buffer_before_minutes', s.buffer_before_minutes,
  'buffer_after_minutes', s.buffer_after_minutes,
  'pricing_tiers', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', t.id,
      'min_blocks', t.min_blocks,
      'max_blocks', t.max_blocks,
      'price_per_block', t.price_per_block,
      'is_active', t.is_active,
      'sort_order', t.sort_order
    ) order by t.sort_order, t.min_blocks, t.id)
    from public.service_duration_pricing_tiers t
    where t.service_id = s.id
  ), '[]'::jsonb),
  'duration_presets', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', p.id,
      'block_count', p.block_count,
      'title', p.title,
      'description', p.description,
      'badge', p.badge,
      'is_featured', p.is_featured,
      'is_active', p.is_active,
      'sort_order', p.sort_order
    ) order by p.sort_order, p.block_count, p.id)
    from public.service_duration_presets p
    where p.service_id = s.id
  ), '[]'::jsonb),
  'change_policy', (
    select to_jsonb(cp) - 'service_id' - 'created_at' - 'updated_at'
    from public.service_change_policies cp
    where cp.service_id = s.id
  )
) order by c.sort_order, s.sort_order, s.name), '[]'::jsonb)
from public.services s
left join public.categories c on c.id = s.category_id;
$$;

create or replace function public.service_admin_update_operation_scope(
  p_service_id uuid,
  p_operation_scope text,
  p_admin_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_before text;
  v_scope text := nullif(upper(btrim(coalesce(p_operation_scope, ''))), '');
begin
  if v_scope is not null and v_scope not in ('BLACKSHEEP','SABRINA') then
    raise exception using errcode = 'P0001', message = 'SERVICE_OPERATION_SCOPE_INVALID';
  end if;

  select operation_scope into v_before
  from public.services
  where id = p_service_id
  for update;

  if not found then
    raise exception using errcode = 'P0001', message = 'SERVICE_NOT_FOUND';
  end if;

  if v_before is not distinct from v_scope then
    return jsonb_build_object(
      'service_id', p_service_id,
      'operation_scope', v_scope,
      'changed', false
    );
  end if;

  update public.services
  set operation_scope = v_scope,
      updated_at = now()
  where id = p_service_id;

  insert into public.audit_logs(admin_user_id, entity_type, entity_id, action, before_json, after_json, origin)
  values (
    p_admin_id,
    'SERVICE',
    p_service_id,
    'OPERATION_SCOPE_CHANGED',
    jsonb_build_object('operation_scope', v_before),
    jsonb_build_object('operation_scope', v_scope),
    'ADMIN'
  );

  return jsonb_build_object(
    'service_id', p_service_id,
    'operation_scope', v_scope,
    'changed', true
  );
end;
$$;

revoke all on function public.service_admin_update_operation_scope(uuid,text,uuid) from public, anon, authenticated;
grant execute on function public.service_admin_update_operation_scope(uuid,text,uuid) to service_role;

comment on function public.service_admin_update_operation_scope(uuid,text,uuid) is
  'Sets explicit BlackSheep/Sabrina service scope. NULL clears classification. Every actual change is audited.';
-- END RC MIGRATION 20260822142000_admin_service_operation_scope.sql

-- BEGIN RC MIGRATION 20260822143000_admin_operation_settings.sql
-- Explicit admin configuration for dashboard occupancy base resource.
-- No resource is inferred or auto-selected.

create or replace function public.service_admin_get_operation_settings()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'dashboard_occupancy_resource_id', os.dashboard_occupancy_resource_id,
    'dashboard_occupancy_resource', case
      when r.id is null then null
      else jsonb_build_object(
        'id', r.id,
        'name', r.name,
        'resource_type', r.resource_type,
        'is_active', r.is_active
      )
    end,
    'eligible_occupancy_resources', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', er.id,
        'name', er.name,
        'resource_type', er.resource_type,
        'is_active', er.is_active
      ) order by er.name)
      from public.resources er
      where er.resource_type = 'PHYSICAL'
        and er.is_active = true
    ), '[]'::jsonb)
  )
  from public.operation_settings os
  left join public.resources r on r.id = os.dashboard_occupancy_resource_id
  where os.id = 1;
$$;

create or replace function public.service_admin_set_dashboard_occupancy_resource(
  p_resource_id uuid,
  p_actor_admin_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_before jsonb;
  v_after jsonb;
  v_resource public.resources%rowtype;
  v_before_resource_id uuid;
  v_audit_entity_id uuid;
begin
  if not exists (
    select 1 from public.admin_users
    where id = p_actor_admin_id and is_active = true
  ) then
    raise exception using errcode = 'P0001', message = 'ADMIN_USER_NOT_FOUND';
  end if;

  if p_resource_id is not null then
    select * into v_resource from public.resources where id = p_resource_id;
    if not found then
      raise exception using errcode = 'P0001', message = 'OCCUPANCY_RESOURCE_NOT_FOUND';
    end if;
    if v_resource.resource_type <> 'PHYSICAL' or v_resource.is_active is not true then
      raise exception using errcode = 'P0001', message = 'OCCUPANCY_RESOURCE_NOT_ELIGIBLE';
    end if;
  end if;

  select public.service_admin_get_operation_settings() into v_before;
  v_before_resource_id := nullif(v_before->>'dashboard_occupancy_resource_id', '')::uuid;

  update public.operation_settings
  set dashboard_occupancy_resource_id = p_resource_id,
      updated_at = now()
  where id = 1;

  select public.service_admin_get_operation_settings() into v_after;

  if v_before_resource_id is distinct from p_resource_id then
    v_audit_entity_id := coalesce(p_resource_id, v_before_resource_id);
    insert into public.audit_logs(
      admin_user_id, entity_type, entity_id, action,
      before_json, after_json, origin
    ) values (
      p_actor_admin_id,
      'DASHBOARD_OCCUPANCY_RESOURCE',
      v_audit_entity_id,
      'DASHBOARD_OCCUPANCY_RESOURCE_CHANGED',
      v_before,
      v_after,
      'ADMIN'
    );
  end if;

  return v_after;
end;
$$;

revoke all on function public.service_admin_get_operation_settings() from public, anon, authenticated;
grant execute on function public.service_admin_get_operation_settings() to service_role;

revoke all on function public.service_admin_set_dashboard_occupancy_resource(uuid,uuid) from public, anon, authenticated;
grant execute on function public.service_admin_set_dashboard_occupancy_resource(uuid,uuid) to service_role;

comment on function public.service_admin_get_operation_settings() is
  'Admin read model for operation settings; occupancy resources are explicit active PHYSICAL resources only.';
comment on function public.service_admin_set_dashboard_occupancy_resource(uuid,uuid) is
  'Admin mutation for explicit dashboard occupancy resource selection with audit before/after against the involved resource.';
-- END RC MIGRATION 20260822143000_admin_operation_settings.sql

-- BEGIN RC MIGRATION 20260822151000_admin_service_audit_hardening.sql
-- Retrospective audit hardening for administrative service mutations.
-- New audited wrappers are the only service-role mutation surface. Historical
-- functions remain in the schema for migration compatibility but are no longer
-- executable by service_role directly.

create or replace function public.service_admin_service_snapshot(p_service_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'service', to_jsonb(s),
    'pricing_tiers', coalesce((
      select jsonb_agg(to_jsonb(t) order by t.sort_order, t.min_blocks, t.id)
      from public.service_duration_pricing_tiers t
      where t.service_id = s.id
    ), '[]'::jsonb),
    'duration_presets', coalesce((
      select jsonb_agg(to_jsonb(p) order by p.sort_order, p.block_count, p.id)
      from public.service_duration_presets p
      where p.service_id = s.id
    ), '[]'::jsonb),
    'change_policy', (
      select to_jsonb(cp)
      from public.service_change_policies cp
      where cp.service_id = s.id
    )
  )
  from public.services s
  where s.id = p_service_id;
$$;

create or replace function public.service_admin_update_timing_audited(
  p_service_id uuid,
  p_duration_mode text,
  p_base_duration_minutes integer,
  p_booking_block_minutes integer,
  p_minimum_booking_blocks integer,
  p_maximum_booking_blocks integer,
  p_base_price numeric,
  p_price_per_block numeric,
  p_buffer_before_minutes integer,
  p_buffer_after_minutes integer,
  p_admin_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_before jsonb;
  v_after jsonb;
  v_result jsonb;
  v_old_base numeric;
  v_old_block numeric;
  v_requested_base numeric;
  v_requested_block numeric;
begin
  if not public.service_admin_has_permission(p_admin_id, 'SERVICES_MANAGE') then
    raise exception using errcode = 'P0001', message = 'ADMIN_PERMISSION_DENIED';
  end if;

  select base_price, price_per_block into v_old_base, v_old_block
  from public.services where id = p_service_id for update;
  if not found then
    raise exception using errcode = 'P0001', message = 'SERVICE_NOT_FOUND';
  end if;

  -- Hidden financial fields may be omitted by non-finance clients. Omission means
  -- preserve the authoritative value, never zero it or invent a replacement.
  v_requested_base := coalesce(p_base_price, v_old_base);
  v_requested_block := case
    when p_duration_mode = 'BLOCKS' then coalesce(p_price_per_block, v_old_block)
    else null
  end;

  if v_old_base is distinct from v_requested_base
     or v_old_block is distinct from v_requested_block then
    if not public.service_admin_has_permission(p_admin_id, 'FINANCE_MANAGE') then
      raise exception using errcode = 'P0001', message = 'ADMIN_PERMISSION_DENIED';
    end if;
  end if;

  v_before := public.service_admin_service_snapshot(p_service_id);
  v_result := public.service_admin_update_timing(
    p_service_id, p_duration_mode, p_base_duration_minutes,
    p_booking_block_minutes, p_minimum_booking_blocks, p_maximum_booking_blocks,
    v_requested_base, v_requested_block, p_buffer_before_minutes, p_buffer_after_minutes
  );
  v_after := public.service_admin_service_snapshot(p_service_id);

  if v_before is distinct from v_after then
    insert into public.audit_logs(admin_user_id, entity_type, entity_id, action, before_json, after_json, origin)
    values (p_admin_id, 'SERVICE', p_service_id, 'SERVICE_TIMING_UPDATED', v_before, v_after, 'ADMIN');
  end if;
  return v_result;
end;
$$;

create or replace function public.service_admin_replace_duration_configuration_audited(
  p_service_id uuid,
  p_pricing_tiers jsonb,
  p_duration_presets jsonb,
  p_admin_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_before jsonb;
  v_after jsonb;
  v_result jsonb;
begin
  if not public.service_admin_has_permission(p_admin_id, 'SERVICES_MANAGE')
     or not public.service_admin_has_permission(p_admin_id, 'FINANCE_MANAGE') then
    raise exception using errcode = 'P0001', message = 'ADMIN_PERMISSION_DENIED';
  end if;

  v_before := public.service_admin_service_snapshot(p_service_id);
  if v_before is null then
    raise exception using errcode = 'P0001', message = 'SERVICE_NOT_FOUND';
  end if;

  v_result := public.service_admin_replace_duration_configuration(
    p_service_id, p_pricing_tiers, p_duration_presets
  );
  v_after := public.service_admin_service_snapshot(p_service_id);

  if v_before is distinct from v_after then
    insert into public.audit_logs(admin_user_id, entity_type, entity_id, action, before_json, after_json, origin)
    values (p_admin_id, 'SERVICE', p_service_id, 'SERVICE_DURATION_CONFIGURATION_UPDATED', v_before, v_after, 'ADMIN');
  end if;
  return v_result;
end;
$$;

create or replace function public.service_admin_upsert_change_policy_audited(
  p_service_id uuid,
  p_policy jsonb,
  p_admin_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_before jsonb;
  v_after jsonb;
  v_result jsonb;
  v_exists boolean;
  v_required_keys text[] := array[
    'notice_hours',
    'reschedule_first_penalty_type','reschedule_first_penalty_value',
    'reschedule_repeat_penalty_type','reschedule_repeat_penalty_value',
    'reschedule_late_penalty_type','reschedule_late_penalty_value',
    'cancellation_early_penalty_type','cancellation_early_penalty_value',
    'cancellation_late_penalty_type','cancellation_late_penalty_value',
    'cancellation_early_refund_allowed','cancellation_early_credit_allowed',
    'cancellation_late_refund_allowed','cancellation_late_credit_allowed',
    'cancellation_credit_validity_days'
  ];
begin
  if not public.service_admin_has_permission(p_admin_id, 'SERVICES_MANAGE')
     or not public.service_admin_has_permission(p_admin_id, 'FINANCE_MANAGE') then
    raise exception using errcode = 'P0001', message = 'ADMIN_PERMISSION_DENIED';
  end if;
  if p_policy is null or jsonb_typeof(p_policy) <> 'object' then
    raise exception using errcode = 'P0001', message = 'INVALID_CHANGE_POLICY';
  end if;

  select exists(select 1 from public.service_change_policies where service_id = p_service_id)
    into v_exists;
  if not v_exists and not (p_policy ?& v_required_keys) then
    raise exception using errcode = 'P0001', message = 'CHANGE_POLICY_COMPLETE_CONFIGURATION_REQUIRED';
  end if;

  v_before := public.service_admin_service_snapshot(p_service_id);
  if v_before is null then
    raise exception using errcode = 'P0001', message = 'SERVICE_NOT_FOUND';
  end if;

  v_result := public.service_admin_upsert_change_policy(p_service_id, p_policy);
  v_after := public.service_admin_service_snapshot(p_service_id);

  if v_before is distinct from v_after then
    insert into public.audit_logs(admin_user_id, entity_type, entity_id, action, before_json, after_json, origin)
    values (p_admin_id, 'SERVICE', p_service_id, 'SERVICE_CHANGE_POLICY_UPDATED', v_before, v_after, 'ADMIN');
  end if;
  return v_result;
end;
$$;

revoke all on function public.service_admin_service_snapshot(uuid) from public, anon, authenticated;
revoke all on function public.service_admin_update_timing_audited(uuid,text,integer,integer,integer,integer,numeric,numeric,integer,integer,uuid) from public, anon, authenticated;
revoke all on function public.service_admin_replace_duration_configuration_audited(uuid,jsonb,jsonb,uuid) from public, anon, authenticated;
revoke all on function public.service_admin_upsert_change_policy_audited(uuid,jsonb,uuid) from public, anon, authenticated;

grant execute on function public.service_admin_service_snapshot(uuid) to service_role;
grant execute on function public.service_admin_update_timing_audited(uuid,text,integer,integer,integer,integer,numeric,numeric,integer,integer,uuid) to service_role;
grant execute on function public.service_admin_replace_duration_configuration_audited(uuid,jsonb,jsonb,uuid) to service_role;
grant execute on function public.service_admin_upsert_change_policy_audited(uuid,jsonb,uuid) to service_role;

-- Do not leave an unaudited service-role bypass available to Edge Functions.
revoke execute on function public.service_admin_update_timing(uuid,text,integer,integer,integer,integer,numeric,numeric,integer,integer) from service_role;
revoke execute on function public.service_admin_replace_duration_configuration(uuid,jsonb,jsonb) from service_role;
revoke execute on function public.service_admin_upsert_change_policy(uuid,jsonb) from service_role;
-- END RC MIGRATION 20260822151000_admin_service_audit_hardening.sql

-- BEGIN RC MIGRATION 20260822152000_admin_rbac_leads.sql
-- Explicit permission boundary for demand-capture PII and lead status changes.

alter table public.admin_user_permissions drop constraint if exists admin_user_permissions_permission_check;
alter table public.admin_user_permissions
  add constraint admin_user_permissions_permission_check
  check (permission in (
    'DASHBOARD_VIEW',
    'AGENDA_VIEW','AGENDA_MANAGE',
    'CUSTOMERS_VIEW','CUSTOMERS_MANAGE',
    'FINANCE_VIEW','FINANCE_MANAGE',
    'PACKAGES_VIEW','PACKAGES_MANAGE',
    'SERVICES_VIEW','SERVICES_MANAGE',
    'INTEGRATIONS_VIEW','INTEGRATIONS_MANAGE',
    'LEADS_VIEW','LEADS_MANAGE',
    'AUDIT_VIEW','TEAM_MANAGE'
  ));

create or replace function public.service_admin_role_default_permission(p_role text, p_permission text)
returns boolean
language sql
immutable
set search_path = public
as $$
  select case upper(p_role)
    when 'OWNER' then true
    when 'ADMIN' then true
    when 'OPERATION' then p_permission in (
      'DASHBOARD_VIEW','AGENDA_VIEW','AGENDA_MANAGE',
      'CUSTOMERS_VIEW','CUSTOMERS_MANAGE','PACKAGES_VIEW'
    )
    when 'FINANCE' then p_permission in (
      'DASHBOARD_VIEW','AGENDA_VIEW','CUSTOMERS_VIEW',
      'FINANCE_VIEW','FINANCE_MANAGE','PACKAGES_VIEW'
    )
    else false
  end;
$$;

create or replace function public.service_admin_get_access_profile(p_admin_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'admin_user_id', a.id,
    'display_name', a.display_name,
    'role', a.role,
    'permissions', (
      select jsonb_object_agg(p.permission, public.service_admin_has_permission(a.id, p.permission))
      from (values
        ('DASHBOARD_VIEW'),('AGENDA_VIEW'),('AGENDA_MANAGE'),
        ('CUSTOMERS_VIEW'),('CUSTOMERS_MANAGE'),
        ('FINANCE_VIEW'),('FINANCE_MANAGE'),
        ('PACKAGES_VIEW'),('PACKAGES_MANAGE'),
        ('SERVICES_VIEW'),('SERVICES_MANAGE'),
        ('INTEGRATIONS_VIEW'),('INTEGRATIONS_MANAGE'),
        ('LEADS_VIEW'),('LEADS_MANAGE'),
        ('AUDIT_VIEW'),('TEAM_MANAGE')
      ) p(permission)
    )
  )
  from public.admin_users a
  where a.id = p_admin_id and a.is_active = true;
$$;

create or replace function public.service_admin_set_permission(
  p_target_admin_id uuid,
  p_permission text,
  p_is_granted boolean,
  p_actor_admin_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_before jsonb;
  v_after jsonb;
begin
  if not public.service_admin_has_permission(p_actor_admin_id, 'TEAM_MANAGE') then
    raise exception using errcode = 'P0001', message = 'ADMIN_PERMISSION_DENIED';
  end if;
  if not exists (select 1 from public.admin_users where id = p_target_admin_id) then
    raise exception using errcode = 'P0001', message = 'ADMIN_USER_NOT_FOUND';
  end if;
  if p_permission not in (
    'DASHBOARD_VIEW','AGENDA_VIEW','AGENDA_MANAGE','CUSTOMERS_VIEW','CUSTOMERS_MANAGE',
    'FINANCE_VIEW','FINANCE_MANAGE','PACKAGES_VIEW','PACKAGES_MANAGE','SERVICES_VIEW','SERVICES_MANAGE',
    'INTEGRATIONS_VIEW','INTEGRATIONS_MANAGE','LEADS_VIEW','LEADS_MANAGE','AUDIT_VIEW','TEAM_MANAGE'
  ) then
    raise exception using errcode = 'P0001', message = 'ADMIN_PERMISSION_INVALID';
  end if;

  select public.service_admin_get_access_profile(p_target_admin_id) into v_before;

  insert into public.admin_user_permissions(admin_user_id, permission, is_granted, updated_by_admin_id, updated_at)
  values (p_target_admin_id, p_permission, p_is_granted, p_actor_admin_id, now())
  on conflict (admin_user_id, permission) do update set
    is_granted = excluded.is_granted,
    updated_by_admin_id = excluded.updated_by_admin_id,
    updated_at = now();

  select public.service_admin_get_access_profile(p_target_admin_id) into v_after;

  insert into public.audit_logs(admin_user_id, entity_type, entity_id, action, before_json, after_json, origin)
  values (p_actor_admin_id, 'ADMIN_USER', p_target_admin_id, 'PERMISSION_CHANGED', v_before, v_after, 'ADMIN');

  return v_after;
end;
$$;
-- END RC MIGRATION 20260822152000_admin_rbac_leads.sql

-- BEGIN RC MIGRATION 20260822153000_audit_logs_append_only.sql
-- Frente 3 pós-auditoria: imutabilidade da trilha de auditoria.
-- Política de retenção da V1: INDEFINITE por padrão, sem expurgo automático.
-- Qualquer expurgo é uma operação excepcional de manutenção, fora dos papéis da aplicação,
-- com cutoff e motivo explícitos e registro prévio em trilha separada append-only.

create table public.audit_retention_policy (
  id smallint primary key check (id = 1),
  retention_mode text not null check (retention_mode in ('INDEFINITE')),
  retention_days integer,
  automatic_purge boolean not null,
  created_at timestamptz not null default now(),
  check (retention_mode <> 'INDEFINITE' or retention_days is null),
  check (retention_mode <> 'INDEFINITE' or automatic_purge = false)
);

insert into public.audit_retention_policy(id, retention_mode, retention_days, automatic_purge)
values (1, 'INDEFINITE', null, false);

create table public.audit_purge_runs (
  id uuid primary key default gen_random_uuid(),
  cutoff_before timestamptz not null,
  reason text not null check (length(btrim(reason)) >= 10),
  requested_by text not null check (length(btrim(requested_by)) >= 3),
  rows_planned bigint not null check (rows_planned >= 0),
  created_at timestamptz not null default now()
);

comment on table public.audit_logs is
  'Append-only application audit trail. Retention is INDEFINITE by default. UPDATE, DELETE and TRUNCATE are forbidden outside the dedicated maintenance purge path.';
comment on table public.audit_purge_runs is
  'Append-only evidence of exceptional audit-log purges. A record is inserted before deletion in the same transaction.';
comment on table public.audit_retention_policy is
  'V1 audit retention policy. INDEFINITE means no automatic purge; any future policy change requires an explicit migration/decision.';

-- Default privileges are not enough for an append-only guarantee. Remove destructive
-- privileges from every application-facing role, including service_role.
revoke update, delete, truncate on table public.audit_logs from public, anon, authenticated, service_role;
revoke insert, update, delete, truncate on table public.audit_purge_runs from public, anon, authenticated, service_role;
revoke insert, update, delete, truncate on table public.audit_retention_policy from public, anon, authenticated, service_role;

create or replace function public.reject_audit_log_mutation()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  -- The only destructive path allowed for audit_logs is the dedicated maintenance
  -- function below. It runs as the database owner and sets a transaction-local guard.
  if tg_table_name = 'audit_logs'
     and tg_op = 'DELETE'
     and current_user = 'postgres'
     and current_setting('app.audit_purge_context', true) = 'DEDICATED_MAINTENANCE_PURGE' then
    return old;
  end if;

  raise exception using errcode = '42501', message = 'AUDIT_TRAIL_APPEND_ONLY';
end;
$$;

create trigger audit_logs_reject_update_delete
before update or delete on public.audit_logs
for each row execute function public.reject_audit_log_mutation();

create trigger audit_logs_reject_truncate
before truncate on public.audit_logs
for each statement execute function public.reject_audit_log_mutation();

create trigger audit_purge_runs_reject_update_delete
before update or delete on public.audit_purge_runs
for each row execute function public.reject_audit_log_mutation();

create trigger audit_purge_runs_reject_truncate
before truncate on public.audit_purge_runs
for each statement execute function public.reject_audit_log_mutation();

create trigger audit_retention_policy_reject_update_delete
before update or delete on public.audit_retention_policy
for each row execute function public.reject_audit_log_mutation();

create trigger audit_retention_policy_reject_truncate
before truncate on public.audit_retention_policy
for each statement execute function public.reject_audit_log_mutation();

create or replace function public.maintenance_purge_audit_logs(
  p_before timestamptz,
  p_reason text,
  p_requested_by text
)
returns bigint
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_count bigint;
begin
  if p_before is null then
    raise exception using errcode = '22004', message = 'AUDIT_PURGE_CUTOFF_REQUIRED';
  end if;
  if p_before >= now() then
    raise exception using errcode = '22023', message = 'AUDIT_PURGE_CUTOFF_MUST_BE_IN_PAST';
  end if;
  if p_reason is null or length(btrim(p_reason)) < 10 then
    raise exception using errcode = '22023', message = 'AUDIT_PURGE_REASON_REQUIRED';
  end if;
  if p_requested_by is null or length(btrim(p_requested_by)) < 3 then
    raise exception using errcode = '22023', message = 'AUDIT_PURGE_REQUESTOR_REQUIRED';
  end if;

  select count(*) into v_count
  from public.audit_logs
  where created_at < p_before;

  -- Evidence is written before deletion. Both operations are in the same transaction:
  -- if deletion fails, the evidence insert rolls back too.
  insert into public.audit_purge_runs(cutoff_before, reason, requested_by, rows_planned)
  values (p_before, btrim(p_reason), btrim(p_requested_by), v_count);

  perform set_config('app.audit_purge_context', 'DEDICATED_MAINTENANCE_PURGE', true);

  delete from public.audit_logs
  where created_at < p_before;

  perform set_config('app.audit_purge_context', '', true);
  return v_count;
exception
  when others then
    perform set_config('app.audit_purge_context', '', true);
    raise;
end;
$$;

-- This is deliberately NOT an application API. Only the database owner/maintenance
-- context may execute it. Application OWNER is an application role, not database owner.
revoke all on function public.maintenance_purge_audit_logs(timestamptz,text,text) from public, anon, authenticated, service_role;
revoke all on function public.reject_audit_log_mutation() from public, anon, authenticated, service_role;
-- END RC MIGRATION 20260822153000_audit_logs_append_only.sql

-- BEGIN RC MIGRATION 20260822154000_distributed_public_rate_limit.sql
-- Frente 4 pós-auditoria: rate limiting distribuído para superfícies públicas.
-- O contador autoritativo fica no PostgreSQL e é compartilhado entre todas as instâncias Edge.
-- Chaves brutas (IP/fingerprint) nunca são persistidas; somente SHA-256.

create table public.public_rate_limit_buckets (
  scope text not null,
  key_hash text not null,
  window_started_at timestamptz not null,
  request_count integer not null check (request_count >= 0),
  updated_at timestamptz not null default now(),
  primary key (scope, key_hash),
  check (scope ~ '^[A-Z0-9_]{3,64}$'),
  check (key_hash ~ '^[0-9a-f]{64}$')
);

create index public_rate_limit_buckets_updated_idx
  on public.public_rate_limit_buckets(updated_at);

comment on table public.public_rate_limit_buckets is
  'Distributed fixed-window counters for public abuse protection. Stores only hashed client keys.';

create or replace function public.service_consume_public_rate_limit_at(
  p_scope text,
  p_client_key text,
  p_limit integer,
  p_window_seconds integer,
  p_now timestamptz
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_scope text := upper(btrim(coalesce(p_scope,'')));
  v_key text := btrim(coalesce(p_client_key,''));
  v_key_hash text;
  v_bucket public.public_rate_limit_buckets%rowtype;
  v_reset_at timestamptz;
begin
  if v_scope !~ '^[A-Z0-9_]{3,64}$' then
    raise exception using errcode = '22023', message = 'RATE_LIMIT_SCOPE_INVALID';
  end if;
  if length(v_key) < 3 or length(v_key) > 1000 then
    raise exception using errcode = '22023', message = 'RATE_LIMIT_KEY_INVALID';
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 10000 then
    raise exception using errcode = '22023', message = 'RATE_LIMIT_VALUE_INVALID';
  end if;
  if p_window_seconds is null or p_window_seconds < 1 or p_window_seconds > 86400 then
    raise exception using errcode = '22023', message = 'RATE_LIMIT_WINDOW_INVALID';
  end if;
  if p_now is null then
    raise exception using errcode = '22004', message = 'RATE_LIMIT_CLOCK_REQUIRED';
  end if;

  v_key_hash := encode(digest(v_key, 'sha256'), 'hex');

  insert into public.public_rate_limit_buckets(scope,key_hash,window_started_at,request_count,updated_at)
  values (v_scope,v_key_hash,p_now,0,p_now)
  on conflict (scope,key_hash) do nothing;

  select * into v_bucket
  from public.public_rate_limit_buckets
  where scope = v_scope and key_hash = v_key_hash
  for update;

  v_reset_at := v_bucket.window_started_at + make_interval(secs => p_window_seconds);

  if p_now >= v_reset_at then
    update public.public_rate_limit_buckets
    set window_started_at = p_now,
        request_count = 1,
        updated_at = p_now
    where scope = v_scope and key_hash = v_key_hash;

    return jsonb_build_object(
      'allowed', true,
      'count', 1,
      'limit', p_limit,
      'reset_at', p_now + make_interval(secs => p_window_seconds)
    );
  end if;

  if v_bucket.request_count >= p_limit then
    raise exception using errcode = 'P0001', message = 'RATE_LIMITED';
  end if;

  update public.public_rate_limit_buckets
  set request_count = request_count + 1,
      updated_at = p_now
  where scope = v_scope and key_hash = v_key_hash;

  return jsonb_build_object(
    'allowed', true,
    'count', v_bucket.request_count + 1,
    'limit', p_limit,
    'reset_at', v_reset_at
  );
end;
$$;

create or replace function public.service_consume_public_rate_limit(
  p_scope text,
  p_client_key text,
  p_limit integer,
  p_window_seconds integer
)
returns jsonb
language sql
volatile
security definer
set search_path = public
as $$
  select public.service_consume_public_rate_limit_at(
    p_scope, p_client_key, p_limit, p_window_seconds, clock_timestamp()
  );
$$;

-- Request metadata used only as a defense-in-depth path for successful direct hold creation.
-- Edge Functions remain the primary public gateway and consume the same distributed counter
-- in a separate transaction, which also counts malformed/invalid attempts.
create or replace function public.public_request_client_key()
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_raw text := current_setting('request.headers', true);
  v_headers jsonb := '{}'::jsonb;
  v_ip text;
  v_ua text;
begin
  if v_raw is not null and btrim(v_raw) <> '' then
    begin
      v_headers := v_raw::jsonb;
    exception when others then
      v_headers := '{}'::jsonb;
    end;
  end if;

  v_ip := nullif(btrim(coalesce(
    v_headers->>'cf-connecting-ip',
    split_part(coalesce(v_headers->>'x-forwarded-for',''), ',', 1),
    v_headers->>'x-real-ip',
    ''
  )), '');
  v_ua := nullif(left(btrim(coalesce(v_headers->>'user-agent','')), 200), '');

  return case
    when v_ip is not null then 'ip:' || v_ip
    when v_ua is not null then 'missing-ip:ua:' || v_ua
    else 'missing-ip:unknown'
  end;
end;
$$;

create or replace function public.public_request_jwt_role()
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_raw text := current_setting('request.jwt.claims', true);
  v_claims jsonb := '{}'::jsonb;
  v_role text;
begin
  if v_raw is not null and btrim(v_raw) <> '' then
    begin
      v_claims := v_raw::jsonb;
    exception when others then
      v_claims := '{}'::jsonb;
    end;
  end if;
  v_role := nullif(v_claims->>'role','');
  return coalesce(v_role, nullif(current_setting('request.jwt.claim.role', true),''), '');
end;
$$;

create or replace function public.enforce_direct_public_hold_rate_limit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if public.public_request_jwt_role() in ('anon','authenticated') then
    perform public.service_consume_public_rate_limit_at(
      'CHECKOUT_HOLD_CREATE',
      public.public_request_client_key(),
      30,
      600,
      clock_timestamp()
    );
  end if;
  return new;
end;
$$;

create trigger checkout_holds_public_rate_limit_trg
before insert on public.checkout_holds
for each row execute function public.enforce_direct_public_hold_rate_limit();

-- Public write/token RPCs are moved behind Edge gateways so the distributed counter
-- commits in its own transaction before the authoritative operation. This prevents
-- invalid-token errors from rolling the counter back and blocks direct bypass.
revoke execute on function public.public_create_checkout_hold(text,uuid,uuid,jsonb,integer,timestamptz) from anon, authenticated;
revoke execute on function public.public_create_checkout_hold_tracked(text,uuid,uuid,jsonb,integer,timestamptz,jsonb) from anon, authenticated;
revoke execute on function public.public_create_checkout_hold_duration(text,uuid,uuid,integer,jsonb,integer,timestamptz) from anon, authenticated;
revoke execute on function public.public_create_checkout_hold_tracked_duration(text,uuid,uuid,integer,jsonb,integer,timestamptz,jsonb) from anon, authenticated;

grant execute on function public.public_create_checkout_hold(text,uuid,uuid,jsonb,integer,timestamptz) to service_role;
grant execute on function public.public_create_checkout_hold_tracked(text,uuid,uuid,jsonb,integer,timestamptz,jsonb) to service_role;
grant execute on function public.public_create_checkout_hold_duration(text,uuid,uuid,integer,jsonb,integer,timestamptz) to service_role;
grant execute on function public.public_create_checkout_hold_tracked_duration(text,uuid,uuid,integer,jsonb,integer,timestamptz,jsonb) to service_role;

revoke execute on function public.public_get_checkout_context(text) from anon, authenticated;
revoke execute on function public.set_checkout_hold_recovery_contact(text,text,boolean) from anon, authenticated;
revoke execute on function public.public_bind_checkout_customer(text,text,text,text,text,boolean) from anon, authenticated;
revoke execute on function public.public_list_checkout_hour_packages(text) from anon, authenticated;
revoke execute on function public.public_select_checkout_hour_package(text,uuid) from anon, authenticated;
revoke execute on function public.public_clear_checkout_hour_package(text) from anon, authenticated;
revoke execute on function public.get_checkout_hold_resume_context(text) from anon, authenticated;

grant execute on function public.public_get_checkout_context(text) to service_role;
grant execute on function public.set_checkout_hold_recovery_contact(text,text,boolean) to service_role;
grant execute on function public.public_bind_checkout_customer(text,text,text,text,text,boolean) to service_role;
grant execute on function public.public_list_checkout_hour_packages(text) to service_role;
grant execute on function public.public_select_checkout_hour_package(text,uuid) to service_role;
grant execute on function public.public_clear_checkout_hour_package(text) to service_role;
grant execute on function public.get_checkout_hold_resume_context(text) to service_role;

-- Only backend service code can consume counters explicitly. The clock-injectable helper
-- remains database-internal for deterministic tests.
revoke all on function public.service_consume_public_rate_limit_at(text,text,integer,integer,timestamptz) from public, anon, authenticated, service_role;
revoke all on function public.service_consume_public_rate_limit(text,text,integer,integer) from public, anon, authenticated;
grant execute on function public.service_consume_public_rate_limit(text,text,integer,integer) to service_role;
revoke all on function public.public_request_client_key() from public, anon, authenticated, service_role;
revoke all on function public.public_request_jwt_role() from public, anon, authenticated, service_role;
revoke all on function public.enforce_direct_public_hold_rate_limit() from public, anon, authenticated, service_role;

revoke all on table public.public_rate_limit_buckets from public, anon, authenticated;
grant select, insert, update on table public.public_rate_limit_buckets to service_role;
-- END RC MIGRATION 20260822154000_distributed_public_rate_limit.sql

-- BEGIN RC MIGRATION 20260822154100_distributed_public_rate_limit_hardening.sql
-- Follow-up hardening for the distributed limiter.
-- SECURITY DEFINER functions own the counter mutation. service_role must not be able to
-- edit buckets directly, otherwise an application credential could reset its own quota.
revoke all on table public.public_rate_limit_buckets from public, anon, authenticated, service_role;

-- This legacy token-scoped promotion wrapper can create an appointment. The current web
-- flow already uses booking-submit -> service_submit_public_checkout, so remove the direct
-- anonymous mutation surface and keep it only for backend compatibility.
revoke execute on function public.public_promote_checkout_hold(text,text,uuid[],jsonb,text) from anon, authenticated;
grant execute on function public.public_promote_checkout_hold(text,text,uuid[],jsonb,text) to service_role;
-- END RC MIGRATION 20260822154100_distributed_public_rate_limit_hardening.sql

-- BEGIN RC MIGRATION 20260822155000_authoritative_pre_reservations.sql
-- Issue #72: authoritative pre-reservations + explicit invoice due basis.
-- No production customer is enabled or seeded here.

-- PRE_RESERVATION participates in the same exclusion constraint used by checkout holds,
-- appointments and external/manual blocks.
alter domain public.allocation_type drop constraint if exists allocation_type_check;
alter domain public.allocation_type add constraint allocation_type_check
  check (value in ('APPOINTMENT','CHECKOUT_HOLD','PRE_RESERVATION','MANUAL_BLOCK','EXTERNAL_BLOCK'));

alter table public.pre_reservations
  add column service_employee_id uuid references public.service_employees(id) on delete restrict,
  add column public_code text,
  add column people_count integer not null default 1 check (people_count >= 1),
  add column extra_selections jsonb not null default '[]'::jsonb,
  add column extras_snapshot jsonb not null default '[]'::jsonb,
  add column duration_blocks integer check (duration_blocks is null or duration_blocks >= 1),
  add column contracted_minutes integer check (contracted_minutes is null or contracted_minutes > 0),
  add column duration_minutes integer check (duration_minutes is null or duration_minutes > 0),
  add column core_start_at timestamptz,
  add column core_end_at timestamptz,
  add column pre_service_minutes integer not null default 0 check (pre_service_minutes >= 0),
  add column post_service_minutes integer not null default 0 check (post_service_minutes >= 0),
  add column schedule_profile_snapshot jsonb not null default '{}'::jsonb,
  add column quote_snapshot jsonb,
  add column resource_ids uuid[] not null default '{}'::uuid[],
  add column billing_mode_snapshot text check (billing_mode_snapshot is null or billing_mode_snapshot in ('CHECKOUT','INVOICE')),
  add column invoice_due_days_snapshot integer check (invoice_due_days_snapshot is null or invoice_due_days_snapshot >= 0),
  add column requires_manual_confirmation_snapshot boolean,
  add column released_at timestamptz,
  add column released_by_admin_id uuid,
  add column release_reason text;

create unique index pre_reservations_public_code_uq
  on public.pre_reservations(public_code)
  where public_code is not null;

alter table public.pre_reservations
  add constraint pre_reservations_core_range_check
    check (core_start_at is null or core_end_at is null or core_end_at > core_start_at),
  add constraint pre_reservations_schedule_envelope_check
    check (
      core_start_at is null
      or core_end_at is null
      or (start_at <= core_start_at and end_at >= core_end_at)
    );

alter table public.appointments
  add column invoice_due_basis text check (invoice_due_basis is null or invoice_due_basis = 'SERVICE_START'),
  add column invoice_due_days_snapshot integer check (invoice_due_days_snapshot is null or invoice_due_days_snapshot >= 0);

create table public.pre_reservation_access_tokens (
  id uuid primary key default gen_random_uuid(),
  pre_reservation_id uuid not null references public.pre_reservations(id) on delete cascade,
  token_hash text not null unique,
  scope text not null default 'VIEW' check (scope = 'VIEW'),
  expires_at timestamptz not null,
  revoked_at timestamptz,
  created_at timestamptz not null default now(),
  last_used_at timestamptz
);

create index pre_reservation_access_tokens_pre_reservation_idx
  on public.pre_reservation_access_tokens(pre_reservation_id)
  where revoked_at is null;

alter table public.resource_allocations
  add column pre_reservation_id uuid references public.pre_reservations(id) on delete restrict;

alter table public.resource_allocations
  drop constraint resource_allocations_owner_check;

alter table public.resource_allocations
  add constraint resource_allocations_owner_check check (
    (allocation_type = 'APPOINTMENT'
      and appointment_id is not null and checkout_hold_id is null and pre_reservation_id is null)
    or
    (allocation_type = 'CHECKOUT_HOLD'
      and checkout_hold_id is not null and appointment_id is null and pre_reservation_id is null)
    or
    (allocation_type = 'PRE_RESERVATION'
      and pre_reservation_id is not null and appointment_id is null and checkout_hold_id is null)
    or
    (allocation_type in ('MANUAL_BLOCK','EXTERNAL_BLOCK')
      and appointment_id is null and checkout_hold_id is null and pre_reservation_id is null)
  );

create index resource_allocations_pre_reservation_idx
  on public.resource_allocations(pre_reservation_id)
  where pre_reservation_id is not null;

-- Service-role callers must use the audited RPC surface instead of direct mutation.
revoke insert, update, delete, truncate on table public.pre_reservations
  from public, anon, authenticated, service_role;
revoke insert, update, delete, truncate on table public.pre_reservation_access_tokens
  from public, anon, authenticated, service_role;

create or replace function public.service_expire_pre_reservations()
returns integer
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_pr public.pre_reservations%rowtype;
  v_after jsonb;
  v_count integer := 0;
  v_released_at timestamptz;
begin
  for v_pr in
    select pr.*
    from public.pre_reservations pr
    where pr.status = 'ACTIVE'
      and pr.expires_at <= now()
    for update skip locked
  loop
    v_released_at := now();

    update public.resource_allocations
    set status = 'EXPIRED', updated_at = v_released_at
    where pre_reservation_id = v_pr.id
      and status = 'HELD';

    update public.pre_reservation_access_tokens
    set revoked_at = coalesce(revoked_at, v_released_at)
    where pre_reservation_id = v_pr.id
      and revoked_at is null;

    update public.pre_reservations
    set status = 'EXPIRED',
        released_at = v_released_at,
        released_by_admin_id = null,
        release_reason = 'EXPIRED',
        updated_at = v_released_at
    where id = v_pr.id
    returning to_jsonb(pre_reservations.*) into v_after;

    insert into public.audit_logs(
      admin_user_id, entity_type, entity_id, action, before_json, after_json, origin
    ) values (
      null, 'PRE_RESERVATION', v_pr.id, 'PRE_RESERVATION_EXPIRED',
      to_jsonb(v_pr), v_after, 'SYSTEM'
    );

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

create or replace function public.service_admin_create_pre_reservation(
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
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_terms public.customer_commercial_terms%rowtype;
  v_service public.services%rowtype;
  v_customer public.customers%rowtype;
  v_employee_id uuid;
  v_timezone text;
  v_local_date date;
  v_slot record;
  v_quote jsonb;
  v_canonical_extras jsonb;
  v_extras_snapshot jsonb;
  v_resource_ids uuid[] := '{}'::uuid[];
  v_pre_reservation_id uuid := gen_random_uuid();
  v_public_code text;
  v_raw_token text;
  v_token_hash text;
  v_expires_at timestamptz;
  v_active_count integer;
  v_contracted_minutes integer;
begin
  if not public.service_admin_has_permission(p_admin_id, 'AGENDA_MANAGE') then
    raise exception using errcode = 'P0001', message = 'ADMIN_PERMISSION_DENIED';
  end if;

  perform public.service_expire_pre_reservations();

  select * into v_terms
  from public.customer_commercial_terms
  where customer_id = p_customer_id
    and is_active = true
  for update;

  if not found or not v_terms.can_prebook then
    raise exception using errcode = 'P0001', message = 'CUSTOMER_NOT_AUTHORIZED_FOR_PREBOOK';
  end if;

  if not exists (
    select 1
    from public.customer_prebook_authorized_services cas
    where cas.customer_id = p_customer_id
      and cas.service_id = p_service_id
  ) then
    raise exception using errcode = 'P0001', message = 'SERVICE_NOT_AUTHORIZED_FOR_PREBOOK';
  end if;

  select count(*)::integer into v_active_count
  from public.pre_reservations pr
  where pr.customer_id = p_customer_id
    and pr.status = 'ACTIVE'
    and pr.expires_at > now();

  if v_active_count >= v_terms.max_active_prebooks then
    raise exception using errcode = 'P0001', message = 'MAX_ACTIVE_PREBOOKS_REACHED';
  end if;

  select * into v_customer from public.customers where id = p_customer_id;
  if not found then
    raise exception using errcode = 'P0001', message = 'CUSTOMER_NOT_FOUND';
  end if;

  select s.* into v_service
  from public.services s
  where s.id = p_service_id and s.is_active;
  if not found then
    raise exception using errcode = 'P0001', message = 'SERVICE_NOT_AVAILABLE';
  end if;

  select se.employee_id into v_employee_id
  from public.service_employees se
  join public.employees e on e.id = se.employee_id and e.is_active
  where se.id = p_service_employee_id
    and se.service_id = p_service_id
    and se.is_active;
  if not found then
    raise exception using errcode = 'P0001', message = 'EMPLOYEE_NOT_AVAILABLE_FOR_SERVICE';
  end if;

  if jsonb_typeof(coalesce(p_extra_selections, '[]'::jsonb)) <> 'array' then
    raise exception using errcode = 'P0001', message = 'INVALID_EXTRA';
  end if;

  select coalesce(jsonb_agg(
    jsonb_build_object('extra_id', x.extra_id, 'quantity', x.quantity)
    order by x.extra_id
  ), '[]'::jsonb)
  into v_canonical_extras
  from jsonb_to_recordset(coalesce(p_extra_selections, '[]'::jsonb)) x(extra_id uuid, quantity integer);

  v_contracted_minutes := public.resolve_service_contracted_minutes(p_service_id, p_duration_blocks);
  select timezone into v_timezone from public.operation_settings where id = 1;
  v_local_date := (p_requested_start_at at time zone v_timezone)::date;

  select s.* into v_slot
  from (
    select * from public.list_available_slots_for_duration(
      p_service_id, p_service_employee_id, p_duration_blocks,
      v_canonical_extras, p_people_count, v_local_date, null
    )
    union all
    select * from public.list_available_slots_for_duration(
      p_service_id, p_service_employee_id, p_duration_blocks,
      v_canonical_extras, p_people_count, v_local_date + 1, null
    )
  ) s
  where s.slot_start_at = p_requested_start_at
  order by s.core_start_at
  limit 1;

  if not found then
    raise exception using errcode = 'P0001', message = 'SLOT_NO_LONGER_AVAILABLE';
  end if;

  v_quote := public.calculate_booking_quote_for_duration(
    p_service_id, p_service_employee_id, p_duration_blocks,
    v_canonical_extras, p_people_count, v_slot.core_start_at, null
  );

  select coalesce(array_agg(r.resource_id order by r.resource_id), '{}'::uuid[])
  into v_resource_ids
  from public.calculate_booking_resource_ranges_for_duration(
    p_service_id, v_canonical_extras, v_slot.core_start_at, p_duration_blocks
  ) r;

  if coalesce(array_length(v_resource_ids, 1), 0) = 0 then
    raise exception using errcode = 'P0001', message = 'SERVICE_HAS_NO_REQUIRED_RESOURCES';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'extra_id', e.id,
    'name', e.name,
    'unit_price', e.price,
    'duration_delta_minutes', e.duration_delta_minutes,
    'quantity', x.quantity,
    'total_price', round(e.price * x.quantity, 2),
    'total_duration_delta', e.duration_delta_minutes * x.quantity
  ) order by e.id), '[]'::jsonb)
  into v_extras_snapshot
  from jsonb_to_recordset(v_canonical_extras) x(extra_id uuid, quantity integer)
  join public.extras e on e.id = x.extra_id;

  loop
    v_public_code := upper(substr(encode(gen_random_bytes(8), 'hex'), 1, 12));
    exit when not exists (
      select 1 from public.pre_reservations pr where pr.public_code = v_public_code
    );
  end loop;

  v_raw_token := encode(gen_random_bytes(32), 'hex');
  v_token_hash := encode(digest(v_raw_token, 'sha256'), 'hex');
  v_expires_at := now() + make_interval(mins => v_terms.prebook_hold_minutes);

  insert into public.pre_reservations(
    id, customer_id, service_id, employee_id, service_employee_id, public_code,
    start_at, end_at, core_start_at, core_end_at,
    pre_service_minutes, post_service_minutes, schedule_profile_snapshot,
    expires_at, status, people_count, extra_selections, extras_snapshot,
    duration_blocks, contracted_minutes, duration_minutes, quote_snapshot, resource_ids,
    billing_mode_snapshot, invoice_due_days_snapshot, requires_manual_confirmation_snapshot,
    created_by_admin_id, notes
  ) values (
    v_pre_reservation_id, p_customer_id, p_service_id, v_employee_id, p_service_employee_id, v_public_code,
    v_slot.slot_start_at, v_slot.slot_end_at, v_slot.core_start_at, v_slot.core_end_at,
    v_slot.pre_service_minutes, v_slot.post_service_minutes, v_quote->'schedule_profile',
    v_expires_at, 'ACTIVE', p_people_count, v_canonical_extras, v_extras_snapshot,
    p_duration_blocks, v_contracted_minutes, v_slot.duration_minutes, v_quote, v_resource_ids,
    v_terms.billing_mode, v_terms.invoice_due_days, v_terms.requires_manual_confirmation,
    p_admin_id, nullif(btrim(coalesce(p_notes, '')), '')
  );

  insert into public.pre_reservation_access_tokens(
    pre_reservation_id, token_hash, scope, expires_at
  ) values (
    v_pre_reservation_id, v_token_hash, 'VIEW', v_expires_at
  );

  begin
    insert into public.resource_allocations(
      resource_id, pre_reservation_id, allocation_type, status, occupied_range,
      reason, created_by_admin_id
    )
    select r.resource_id, v_pre_reservation_id, 'PRE_RESERVATION', 'HELD', r.occupied_range,
           'PRE_RESERVATION', p_admin_id
    from public.calculate_booking_resource_ranges_for_duration(
      p_service_id, v_canonical_extras, v_slot.core_start_at, p_duration_blocks
    ) r;
  exception when exclusion_violation then
    raise exception using errcode = 'P0001', message = 'SLOT_NO_LONGER_AVAILABLE';
  end;

  insert into public.audit_logs(
    admin_user_id, entity_type, entity_id, action, after_json, origin
  ) values (
    p_admin_id, 'PRE_RESERVATION', v_pre_reservation_id, 'PRE_RESERVATION_CREATED',
    jsonb_build_object(
      'customer_id', p_customer_id,
      'service_id', p_service_id,
      'service_employee_id', p_service_employee_id,
      'public_code', v_public_code,
      'status', 'ACTIVE',
      'start_at', v_slot.slot_start_at,
      'end_at', v_slot.slot_end_at,
      'core_start_at', v_slot.core_start_at,
      'core_end_at', v_slot.core_end_at,
      'expires_at', v_expires_at,
      'resource_ids', to_jsonb(v_resource_ids),
      'billing_mode', v_terms.billing_mode,
      'invoice_due_days', v_terms.invoice_due_days,
      'requires_manual_confirmation', v_terms.requires_manual_confirmation
    ),
    'ADMIN'
  );

  return jsonb_build_object(
    'pre_reservation_id', v_pre_reservation_id,
    'public_code', v_public_code,
    'status', 'ACTIVE',
    'expires_at', v_expires_at,
    'start_at', v_slot.slot_start_at,
    'end_at', v_slot.slot_end_at,
    'core_start_at', v_slot.core_start_at,
    'core_end_at', v_slot.core_end_at,
    'billing_mode', v_terms.billing_mode,
    'invoice_due_days', v_terms.invoice_due_days,
    'commercial_value', (v_quote->>'commercial_value')::numeric(12,2),
    'access_token', v_raw_token,
    'authoritative_resource_hold', true
  );
end;
$$;

create or replace function public.service_admin_cancel_pre_reservation(
  p_pre_reservation_id uuid,
  p_admin_id uuid,
  p_reason text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_pr public.pre_reservations%rowtype;
  v_after jsonb;
  v_released_at timestamptz;
begin
  if not public.service_admin_has_permission(p_admin_id, 'AGENDA_MANAGE') then
    raise exception using errcode = 'P0001', message = 'ADMIN_PERMISSION_DENIED';
  end if;

  perform public.service_expire_pre_reservations();

  select * into v_pr
  from public.pre_reservations
  where id = p_pre_reservation_id
  for update;

  if not found then
    raise exception using errcode = 'P0001', message = 'PRE_RESERVATION_NOT_FOUND';
  end if;

  if v_pr.status = 'CANCELLED' then
    return jsonb_build_object(
      'pre_reservation_id', v_pr.id,
      'status', v_pr.status,
      'released_at', v_pr.released_at
    );
  end if;

  if v_pr.status <> 'ACTIVE' then
    raise exception using errcode = 'P0001', message = 'PRE_RESERVATION_NOT_ACTIVE';
  end if;

  v_released_at := now();

  update public.resource_allocations
  set status = 'CANCELLED', updated_at = v_released_at
  where pre_reservation_id = v_pr.id
    and status = 'HELD';

  update public.pre_reservation_access_tokens
  set revoked_at = coalesce(revoked_at, v_released_at)
  where pre_reservation_id = v_pr.id
    and revoked_at is null;

  update public.pre_reservations
  set status = 'CANCELLED',
      cancelled_by_admin_id = p_admin_id,
      cancelled_at = v_released_at,
      released_at = v_released_at,
      released_by_admin_id = p_admin_id,
      release_reason = nullif(btrim(coalesce(p_reason, '')), ''),
      updated_at = v_released_at
  where id = v_pr.id
  returning to_jsonb(pre_reservations.*) into v_after;

  insert into public.audit_logs(
    admin_user_id, entity_type, entity_id, action, before_json, after_json, origin
  ) values (
    p_admin_id, 'PRE_RESERVATION', v_pr.id, 'PRE_RESERVATION_CANCELLED',
    to_jsonb(v_pr), v_after, 'ADMIN'
  );

  return jsonb_build_object(
    'pre_reservation_id', v_pr.id,
    'status', 'CANCELLED',
    'released_at', v_released_at
  );
end;
$$;

create or replace function public.service_admin_confirm_pre_reservation(
  p_pre_reservation_id uuid,
  p_admin_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_pr public.pre_reservations%rowtype;
  v_service public.services%rowtype;
  v_customer public.customers%rowtype;
  v_quote jsonb;
  v_appointment_id uuid := gen_random_uuid();
  v_public_code text;
  v_raw_access_token text;
  v_access_token_hash text;
  v_access_scope text;
  v_final_status public.appointment_status;
  v_financial_status public.financial_status;
  v_allocation_status public.allocation_status;
  v_payment_hold_minutes integer;
  v_hold_expires_at timestamptz;
  v_invoice_due_at timestamptz;
  v_invoice_due_basis text;
  v_expected_allocations integer;
  v_actual_allocations integer;
  v_after jsonb;
begin
  if not public.service_admin_has_permission(p_admin_id, 'AGENDA_MANAGE') then
    raise exception using errcode = 'P0001', message = 'ADMIN_PERMISSION_DENIED';
  end if;

  perform public.service_expire_pre_reservations();

  select * into v_pr
  from public.pre_reservations
  where id = p_pre_reservation_id
  for update;

  if not found then
    raise exception using errcode = 'P0001', message = 'PRE_RESERVATION_NOT_FOUND';
  end if;

  if v_pr.status = 'CONFIRMED' and v_pr.converted_appointment_id is not null then
    return jsonb_build_object(
      'pre_reservation_id', v_pr.id,
      'status', 'CONFIRMED',
      'appointment_id', v_pr.converted_appointment_id,
      'appointment_access_token', null
    );
  end if;

  if v_pr.status <> 'ACTIVE' or v_pr.expires_at <= now() then
    raise exception using errcode = 'P0001', message = 'PRE_RESERVATION_NOT_ACTIVE';
  end if;

  if v_pr.billing_mode_snapshot is null then
    raise exception using errcode = 'P0001', message = 'PRE_RESERVATION_BILLING_SNAPSHOT_MISSING';
  end if;

  if v_pr.billing_mode_snapshot = 'INVOICE'
     and not public.service_admin_has_permission(p_admin_id, 'FINANCE_MANAGE') then
    raise exception using errcode = 'P0001', message = 'ADMIN_PERMISSION_DENIED';
  end if;

  select * into v_service from public.services where id = v_pr.service_id;
  if not found then
    raise exception using errcode = 'P0001', message = 'SERVICE_NOT_FOUND';
  end if;

  select * into v_customer from public.customers where id = v_pr.customer_id;
  if not found then
    raise exception using errcode = 'P0001', message = 'CUSTOMER_NOT_FOUND';
  end if;

  v_expected_allocations := coalesce(array_length(v_pr.resource_ids, 1), 0);
  select count(*)::integer into v_actual_allocations
  from public.resource_allocations ra
  where ra.pre_reservation_id = v_pr.id
    and ra.allocation_type = 'PRE_RESERVATION'
    and ra.status = 'HELD';

  if v_expected_allocations = 0 or v_actual_allocations <> v_expected_allocations then
    raise exception using errcode = 'P0001', message = 'PRE_RESERVATION_ALLOCATION_MISSING';
  end if;

  v_quote := v_pr.quote_snapshot;
  if v_quote is null then
    raise exception using errcode = 'P0001', message = 'PRE_RESERVATION_QUOTE_SNAPSHOT_MISSING';
  end if;

  if v_pr.billing_mode_snapshot = 'INVOICE' then
    if v_pr.invoice_due_days_snapshot is null then
      raise exception using errcode = 'P0001', message = 'INVOICE_DUE_DAYS_REQUIRED';
    end if;
    v_final_status := 'CONFIRMED';
    v_financial_status := 'UNPAID_AUTHORIZED';
    v_allocation_status := 'CONFIRMED';
    v_hold_expires_at := null;
    v_invoice_due_basis := 'SERVICE_START';
    v_invoice_due_at := coalesce(v_pr.core_start_at, v_pr.start_at)
      + make_interval(days => v_pr.invoice_due_days_snapshot);
    v_access_scope := 'VIEW';
  else
    v_final_status := 'AWAITING_PAYMENT';
    v_financial_status := 'PENDING';
    v_allocation_status := 'AWAITING_PAYMENT';
    select coalesce(v_service.payment_hold_minutes, os.payment_hold_minutes)
      into v_payment_hold_minutes
    from public.operation_settings os
    where os.id = 1;
    v_hold_expires_at := now() + make_interval(mins => v_payment_hold_minutes);
    v_invoice_due_basis := null;
    v_invoice_due_at := null;
    v_access_scope := 'PAY';
  end if;

  loop
    v_public_code := upper(substr(encode(gen_random_bytes(8), 'hex'), 1, 12));
    exit when not exists (
      select 1 from public.appointments a where a.public_code = v_public_code
    );
  end loop;

  insert into public.appointments(
    id, public_code, service_id, service_employee_id, primary_customer_id,
    status, financial_status, start_at, end_at, duration_minutes, people_count,
    hold_expires_at, version, origin,
    service_name_snapshot, service_description_snapshot,
    base_duration_snapshot, buffer_before_snapshot, buffer_after_snapshot,
    base_price_snapshot, variable_price_adjustment, extras_total, coupon_discount,
    commercial_value, confirmed_at,
    billing_mode_snapshot, invoice_due_at, invoice_authorized_by_admin_id,
    source_pre_reservation_id, invoice_due_basis, invoice_due_days_snapshot,
    core_start_at, core_end_at, pre_service_minutes, post_service_minutes,
    schedule_profile_snapshot, duration_blocks, contracted_minutes
  ) values (
    v_appointment_id, v_public_code, v_pr.service_id, v_pr.service_employee_id, v_pr.customer_id,
    v_final_status, v_financial_status, v_pr.start_at, v_pr.end_at,
    coalesce(v_pr.duration_minutes, greatest(1, round(extract(epoch from (v_pr.end_at - v_pr.start_at))/60)::integer)),
    v_pr.people_count,
    v_hold_expires_at, 1, 'ADMIN',
    v_service.name, v_service.full_description,
    v_service.base_duration_minutes, v_service.buffer_before_minutes, v_service.buffer_after_minutes,
    coalesce((v_quote->>'base_price')::numeric, v_service.base_price),
    coalesce((v_quote->>'day_time_adjustment')::numeric, 0) + coalesce((v_quote->>'people_adjustment')::numeric, 0),
    coalesce((v_quote->>'extras_total')::numeric, 0),
    coalesce((v_quote->>'coupon_discount')::numeric, 0),
    coalesce((v_quote->>'commercial_value')::numeric, 0),
    case when v_final_status = 'CONFIRMED' then now() else null end,
    v_pr.billing_mode_snapshot, v_invoice_due_at,
    case when v_pr.billing_mode_snapshot = 'INVOICE' then p_admin_id else null end,
    v_pr.id, v_invoice_due_basis,
    case when v_pr.billing_mode_snapshot = 'INVOICE' then v_pr.invoice_due_days_snapshot else null end,
    v_pr.core_start_at, v_pr.core_end_at, v_pr.pre_service_minutes, v_pr.post_service_minutes,
    v_pr.schedule_profile_snapshot, v_pr.duration_blocks, v_pr.contracted_minutes
  );

  insert into public.appointment_participants(
    appointment_id, customer_id, role, name_snapshot, email_snapshot, phone_snapshot, cpf_cnpj_snapshot
  ) values (
    v_appointment_id, v_customer.id, 'BOOKER', v_customer.name,
    v_customer.email, v_customer.phone, v_customer.cpf_cnpj
  );

  insert into public.appointment_extras(
    appointment_id, extra_id, name_snapshot, unit_price_snapshot,
    duration_delta_snapshot, quantity, total_price, total_duration_delta
  )
  select
    v_appointment_id, x.extra_id, x.name, x.unit_price,
    x.duration_delta_minutes, x.quantity, x.total_price, x.total_duration_delta
  from jsonb_to_recordset(coalesce(v_pr.extras_snapshot, '[]'::jsonb)) x(
    extra_id uuid,
    name text,
    unit_price numeric,
    duration_delta_minutes integer,
    quantity integer,
    total_price numeric,
    total_duration_delta integer
  );

  -- Atomic ownership transfer: the exact same allocation rows remain in place.
  -- There is no release/recreate window in which another booking can enter.
  update public.resource_allocations
  set appointment_id = v_appointment_id,
      pre_reservation_id = null,
      allocation_type = 'APPOINTMENT',
      status = v_allocation_status,
      updated_at = now()
  where pre_reservation_id = v_pr.id
    and allocation_type = 'PRE_RESERVATION'
    and status = 'HELD';

  update public.pre_reservation_access_tokens
  set revoked_at = coalesce(revoked_at, now())
  where pre_reservation_id = v_pr.id
    and revoked_at is null;

  update public.pre_reservations
  set status = 'CONFIRMED',
      converted_appointment_id = v_appointment_id,
      confirmed_by_admin_id = p_admin_id,
      confirmed_at = now(),
      updated_at = now()
  where id = v_pr.id
  returning to_jsonb(pre_reservations.*) into v_after;

  v_raw_access_token := encode(gen_random_bytes(32), 'hex');
  v_access_token_hash := encode(digest(v_raw_access_token, 'sha256'), 'hex');

  insert into public.appointment_access_tokens(
    appointment_id, token_hash, scope, expires_at
  ) values (
    v_appointment_id, v_access_token_hash, v_access_scope,
    case when v_access_scope = 'PAY' then v_hold_expires_at else null end
  );

  insert into public.audit_logs(
    admin_user_id, entity_type, entity_id, action, before_json, after_json, origin
  ) values (
    p_admin_id, 'PRE_RESERVATION', v_pr.id, 'PRE_RESERVATION_CONFIRMED',
    to_jsonb(v_pr), v_after || jsonb_build_object(
      'appointment_id', v_appointment_id,
      'billing_mode', v_pr.billing_mode_snapshot,
      'invoice_due_basis', v_invoice_due_basis,
      'invoice_due_days', v_pr.invoice_due_days_snapshot,
      'invoice_due_at', v_invoice_due_at
    ),
    'ADMIN'
  );

  return jsonb_build_object(
    'pre_reservation_id', v_pr.id,
    'status', 'CONFIRMED',
    'appointment_id', v_appointment_id,
    'appointment_status', v_final_status,
    'financial_status', v_financial_status,
    'billing_mode', v_pr.billing_mode_snapshot,
    'invoice_due_basis', v_invoice_due_basis,
    'invoice_due_days', case when v_pr.billing_mode_snapshot = 'INVOICE' then v_pr.invoice_due_days_snapshot else null end,
    'invoice_due_at', v_invoice_due_at,
    'hold_expires_at', v_hold_expires_at,
    'appointment_access_token', v_raw_access_token,
    'allocation_transferred_atomically', true
  );
end;
$$;

create or replace function public.public_get_pre_reservation_context(p_access_token text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_hash text;
  v_token public.pre_reservation_access_tokens%rowtype;
  v_pr public.pre_reservations%rowtype;
  v_service public.services%rowtype;
begin
  perform public.service_expire_pre_reservations();

  if p_access_token is null or length(btrim(p_access_token)) < 32 then
    raise exception using errcode = 'P0001', message = 'PRE_RESERVATION_TOKEN_INVALID';
  end if;

  v_hash := encode(digest(btrim(p_access_token), 'sha256'), 'hex');

  select * into v_token
  from public.pre_reservation_access_tokens
  where token_hash = v_hash
  for update;

  if not found or v_token.revoked_at is not null then
    raise exception using errcode = 'P0001', message = 'PRE_RESERVATION_TOKEN_INVALID';
  end if;

  if v_token.expires_at <= now() then
    raise exception using errcode = 'P0001', message = 'PRE_RESERVATION_TOKEN_EXPIRED';
  end if;

  select * into v_pr
  from public.pre_reservations
  where id = v_token.pre_reservation_id;

  if not found or v_pr.status <> 'ACTIVE' then
    raise exception using errcode = 'P0001', message = 'PRE_RESERVATION_TOKEN_INVALID';
  end if;

  select * into v_service from public.services where id = v_pr.service_id;

  update public.pre_reservation_access_tokens
  set last_used_at = now()
  where id = v_token.id;

  return jsonb_build_object(
    'public_code', v_pr.public_code,
    'status', v_pr.status,
    'service_name', v_service.name,
    'start_at', v_pr.start_at,
    'end_at', v_pr.end_at,
    'core_start_at', v_pr.core_start_at,
    'core_end_at', v_pr.core_end_at,
    'expires_at', v_pr.expires_at,
    'authoritative_resource_hold', exists(
      select 1 from public.resource_allocations ra
      where ra.pre_reservation_id = v_pr.id
        and ra.allocation_type = 'PRE_RESERVATION'
        and ra.status = 'HELD'
    )
  );
end;
$$;

-- Existing standalone invoice authorization is kept, but its due basis is now explicit
-- and DB authorization is enforced, not only Edge authorization.
create or replace function public.service_admin_authorize_invoiced_appointment(
  p_appointment_id uuid,
  p_admin_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_appt public.appointments%rowtype;
  v_terms public.customer_commercial_terms%rowtype;
  v_due_base timestamptz;
  v_due_at timestamptz;
  v_before jsonb;
  v_after jsonb;
begin
  if not public.service_admin_has_permission(p_admin_id, 'FINANCE_MANAGE') then
    raise exception using errcode = 'P0001', message = 'ADMIN_PERMISSION_DENIED';
  end if;

  select * into v_appt
  from public.appointments
  where id = p_appointment_id
  for update;

  if not found then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_NOT_FOUND';
  end if;

  select * into v_terms
  from public.customer_commercial_terms
  where customer_id = v_appt.primary_customer_id
    and is_active = true;

  if not found or v_terms.billing_mode <> 'INVOICE' then
    raise exception using errcode = 'P0001', message = 'CUSTOMER_NOT_AUTHORIZED_FOR_INVOICE';
  end if;

  v_before := to_jsonb(v_appt);
  v_due_base := coalesce(v_appt.core_start_at, v_appt.start_at);
  v_due_at := v_due_base + make_interval(days => v_terms.invoice_due_days);

  update public.appointments
  set billing_mode_snapshot = 'INVOICE',
      invoice_due_basis = 'SERVICE_START',
      invoice_due_days_snapshot = v_terms.invoice_due_days,
      invoice_due_at = v_due_at,
      invoice_authorized_by_admin_id = p_admin_id,
      financial_status = 'UNPAID_AUTHORIZED',
      updated_at = now()
  where id = p_appointment_id
  returning to_jsonb(appointments.*) into v_after;

  insert into public.audit_logs(
    admin_user_id, entity_type, entity_id, action, before_json, after_json, origin
  ) values (
    p_admin_id, 'APPOINTMENT', p_appointment_id, 'AUTHORIZE_INVOICE',
    v_before, v_after, 'ADMIN'
  );

  return jsonb_build_object(
    'appointment_id', p_appointment_id,
    'billing_mode', 'INVOICE',
    'financial_status', 'UNPAID_AUTHORIZED',
    'invoice_due_basis', 'SERVICE_START',
    'invoice_due_days', v_terms.invoice_due_days,
    'invoice_due_at', v_due_at
  );
end;
$$;

-- Read model now makes the authoritative-hold state explicit; UI can only call a
-- pre-reservation protected when this flag is true.
create or replace function public.service_admin_get_customer_commercial_profile(p_customer_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'customer', jsonb_build_object(
      'id', c.id,
      'customer_type', c.customer_type,
      'name', c.name,
      'legal_name', c.legal_name,
      'cpf_cnpj', c.cpf_cnpj,
      'email', c.email,
      'phone', c.phone,
      'notes', c.notes
    ),
    'terms', case when t.customer_id is null then null else jsonb_build_object(
      'can_prebook', t.can_prebook,
      'prebook_hold_minutes', t.prebook_hold_minutes,
      'max_active_prebooks', t.max_active_prebooks,
      'requires_manual_confirmation', t.requires_manual_confirmation,
      'billing_mode', t.billing_mode,
      'invoice_due_days', t.invoice_due_days,
      'invoice_due_basis', case when t.billing_mode = 'INVOICE' then 'SERVICE_START' else null end,
      'is_active', t.is_active
    ) end,
    'authorized_services', coalesce((
      select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'slug', s.slug) order by s.sort_order, s.name)
      from public.customer_prebook_authorized_services cas
      join public.services s on s.id = cas.service_id
      where cas.customer_id = c.id
    ), '[]'::jsonb),
    'active_pre_reservations', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', pr.id,
        'public_code', pr.public_code,
        'service_id', pr.service_id,
        'service_name', s.name,
        'service_employee_id', pr.service_employee_id,
        'start_at', pr.start_at,
        'end_at', pr.end_at,
        'core_start_at', pr.core_start_at,
        'core_end_at', pr.core_end_at,
        'expires_at', pr.expires_at,
        'status', pr.status,
        'billing_mode', pr.billing_mode_snapshot,
        'invoice_due_days', pr.invoice_due_days_snapshot,
        'commercial_value', case when pr.quote_snapshot is null then null else (pr.quote_snapshot->>'commercial_value')::numeric end,
        'authoritative_resource_hold', exists(
          select 1 from public.resource_allocations ra
          where ra.pre_reservation_id = pr.id
            and ra.allocation_type = 'PRE_RESERVATION'
            and ra.status = 'HELD'
        ),
        'converted_appointment_id', pr.converted_appointment_id
      ) order by pr.start_at)
      from public.pre_reservations pr
      join public.services s on s.id = pr.service_id
      where pr.customer_id = c.id
        and pr.status = 'ACTIVE'
        and pr.expires_at > now()
    ), '[]'::jsonb)
  )
  from public.customers c
  left join public.customer_commercial_terms t on t.customer_id = c.id
  where c.id = p_customer_id;
$$;

revoke all on function public.service_expire_pre_reservations() from public, anon, authenticated;
revoke all on function public.service_admin_create_pre_reservation(uuid,uuid,uuid,timestamptz,uuid,integer,jsonb,integer,text)
  from public, anon, authenticated;
revoke all on function public.service_admin_cancel_pre_reservation(uuid,uuid,text)
  from public, anon, authenticated;
revoke all on function public.service_admin_confirm_pre_reservation(uuid,uuid)
  from public, anon, authenticated;
revoke all on function public.public_get_pre_reservation_context(text) from public;
revoke all on function public.service_admin_authorize_invoiced_appointment(uuid,uuid)
  from public, anon, authenticated;

grant execute on function public.service_expire_pre_reservations() to service_role;
grant execute on function public.service_admin_create_pre_reservation(uuid,uuid,uuid,timestamptz,uuid,integer,jsonb,integer,text)
  to service_role;
grant execute on function public.service_admin_cancel_pre_reservation(uuid,uuid,text)
  to service_role;
grant execute on function public.service_admin_confirm_pre_reservation(uuid,uuid)
  to service_role;
grant execute on function public.public_get_pre_reservation_context(text) to anon, authenticated, service_role;
grant execute on function public.service_admin_authorize_invoiced_appointment(uuid,uuid)
  to service_role;
-- END RC MIGRATION 20260822155000_authoritative_pre_reservations.sql

-- BEGIN RC MIGRATION 20260822155100_invoice_due_basis_integrity.sql
-- Issue #72 hardening: make the approved invoice due-date basis explicit and self-validating.
-- Approved rule: service start + invoice_due_days.

alter table public.appointments
  add column invoice_due_base_at timestamptz;

comment on column public.appointments.invoice_due_basis is
  'Authoritative basis identifier for invoiced appointments. V1 approved value: SERVICE_START.';
comment on column public.appointments.invoice_due_base_at is
  'Exact service-start timestamp used as the base for invoice due-date calculation.';
comment on column public.appointments.invoice_due_days_snapshot is
  'Customer invoice_due_days snapshotted when INVOICE is authorized/confirmed.';

create or replace function public.enforce_invoice_due_basis_integrity()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.billing_mode_snapshot = 'INVOICE' then
    if new.invoice_due_basis is distinct from 'SERVICE_START' then
      raise exception using errcode = 'P0001', message = 'INVOICE_DUE_BASIS_REQUIRED';
    end if;
    if new.invoice_due_days_snapshot is null or new.invoice_due_days_snapshot < 0 then
      raise exception using errcode = 'P0001', message = 'INVOICE_DUE_DAYS_REQUIRED';
    end if;

    -- core_start_at is the explicit contracted service start in the current domain;
    -- start_at is the compatibility fallback for appointments created before schedule phases.
    new.invoice_due_base_at := coalesce(new.invoice_due_base_at, new.core_start_at, new.start_at);
    new.invoice_due_at := new.invoice_due_base_at
      + make_interval(days => new.invoice_due_days_snapshot);
  else
    new.invoice_due_basis := null;
    new.invoice_due_base_at := null;
    new.invoice_due_days_snapshot := null;
    new.invoice_due_at := null;
    new.invoice_authorized_by_admin_id := null;
  end if;

  return new;
end;
$$;

create trigger appointments_invoice_due_basis_integrity_trg
before insert or update of billing_mode_snapshot, invoice_due_basis, invoice_due_base_at,
  invoice_due_days_snapshot, invoice_due_at, core_start_at, start_at
on public.appointments
for each row execute function public.enforce_invoice_due_basis_integrity();

-- Backfill only already-explicit INVOICE rows. No customer or due-days rule is invented.
update public.appointments
set invoice_due_basis = 'SERVICE_START',
    invoice_due_days_snapshot = case
      when invoice_due_days_snapshot is not null then invoice_due_days_snapshot
      when invoice_due_at is not null and coalesce(core_start_at, start_at) is not null
        then greatest(0, round(extract(epoch from (invoice_due_at - coalesce(core_start_at, start_at))) / 86400)::integer)
      else null
    end,
    invoice_due_base_at = coalesce(core_start_at, start_at)
where billing_mode_snapshot = 'INVOICE'
  and invoice_due_days_snapshot is not null;

create or replace function public.service_admin_authorize_invoiced_appointment(
  p_appointment_id uuid,
  p_admin_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_appt public.appointments%rowtype;
  v_terms public.customer_commercial_terms%rowtype;
  v_due_base timestamptz;
  v_due_at timestamptz;
  v_before jsonb;
  v_after jsonb;
begin
  if not public.service_admin_has_permission(p_admin_id, 'FINANCE_MANAGE') then
    raise exception using errcode = 'P0001', message = 'ADMIN_PERMISSION_DENIED';
  end if;

  select * into v_appt
  from public.appointments
  where id = p_appointment_id
  for update;

  if not found then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_NOT_FOUND';
  end if;

  select * into v_terms
  from public.customer_commercial_terms
  where customer_id = v_appt.primary_customer_id
    and is_active = true;

  if not found or v_terms.billing_mode <> 'INVOICE' then
    raise exception using errcode = 'P0001', message = 'CUSTOMER_NOT_AUTHORIZED_FOR_INVOICE';
  end if;

  if v_terms.invoice_due_days is null then
    raise exception using errcode = 'P0001', message = 'INVOICE_DUE_DAYS_REQUIRED';
  end if;

  v_before := to_jsonb(v_appt);
  v_due_base := coalesce(v_appt.core_start_at, v_appt.start_at);
  v_due_at := v_due_base + make_interval(days => v_terms.invoice_due_days);

  update public.appointments
  set billing_mode_snapshot = 'INVOICE',
      invoice_due_basis = 'SERVICE_START',
      invoice_due_base_at = v_due_base,
      invoice_due_days_snapshot = v_terms.invoice_due_days,
      invoice_due_at = v_due_at,
      invoice_authorized_by_admin_id = p_admin_id,
      financial_status = 'UNPAID_AUTHORIZED',
      updated_at = now()
  where id = p_appointment_id
  returning to_jsonb(appointments.*) into v_after;

  insert into public.audit_logs(
    admin_user_id, entity_type, entity_id, action, before_json, after_json, origin
  ) values (
    p_admin_id, 'APPOINTMENT', p_appointment_id, 'AUTHORIZE_INVOICE',
    v_before, v_after, 'ADMIN'
  );

  return jsonb_build_object(
    'appointment_id', p_appointment_id,
    'billing_mode', 'INVOICE',
    'financial_status', 'UNPAID_AUTHORIZED',
    'invoice_due_basis', 'SERVICE_START',
    'invoice_due_base_at', v_due_base,
    'invoice_due_days', v_terms.invoice_due_days,
    'invoice_due_at', v_due_at
  );
end;
$$;

revoke all on function public.enforce_invoice_due_basis_integrity() from public, anon, authenticated, service_role;
revoke all on function public.service_admin_authorize_invoiced_appointment(uuid,uuid)
  from public, anon, authenticated;
grant execute on function public.service_admin_authorize_invoiced_appointment(uuid,uuid)
  to service_role;
-- END RC MIGRATION 20260822155100_invoice_due_basis_integrity.sql

-- BEGIN RC MIGRATION 20260822155200_pre_reservation_public_surface.sql
-- Keep the opaque-token resolver behind the rate-limited Edge surface.
revoke all on function public.public_get_pre_reservation_context(text)
  from public, anon, authenticated;
grant execute on function public.public_get_pre_reservation_context(text)
  to service_role;
-- END RC MIGRATION 20260822155200_pre_reservation_public_surface.sql
