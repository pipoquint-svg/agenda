create unique index extras_name_normalized_uq
  on public.extras (lower(btrim(name)));

create or replace function public.set_extra_service_assignments(
  p_extra_id uuid,
  p_service_ids uuid[],
  p_admin_user_id uuid default null
)
returns jsonb
language plpgsql
volatile
set search_path = public
as $$
declare
  v_requested uuid[] := '{}'::uuid[];
  v_before jsonb;
  v_after jsonb;
  v_unknown_count integer;
begin
  if not exists (
    select 1
    from public.extras e
    where e.id = p_extra_id
  ) then
    raise exception using errcode = 'P0001', message = 'EXTRA_NOT_FOUND';
  end if;

  select coalesce(array_agg(distinct x order by x), '{}'::uuid[])
  into v_requested
  from unnest(coalesce(p_service_ids, '{}'::uuid[])) as x;

  select count(*)::integer
  into v_unknown_count
  from unnest(v_requested) requested(service_id)
  left join public.services s on s.id = requested.service_id
  where s.id is null;

  if v_unknown_count > 0 then
    raise exception using errcode = 'P0001', message = 'SERVICE_NOT_FOUND';
  end if;

  perform 1
  from public.extras e
  where e.id = p_extra_id
  for update;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'service_id', se.service_id,
        'sort_order', se.sort_order,
        'is_required', se.is_required,
        'max_quantity', se.max_quantity,
        'schedule_placement', se.schedule_placement,
        'default_schedule_minutes', se.default_schedule_minutes
      ) order by se.service_id
    ),
    '[]'::jsonb
  )
  into v_before
  from public.service_extras se
  where se.extra_id = p_extra_id;

  delete from public.service_extras se
  where se.extra_id = p_extra_id
    and not (se.service_id = any(v_requested));

  insert into public.service_extras (
    service_id,
    extra_id
  )
  select
    requested.service_id,
    p_extra_id
  from unnest(v_requested) requested(service_id)
  where not exists (
    select 1
    from public.service_extras se
    where se.service_id = requested.service_id
      and se.extra_id = p_extra_id
  );

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'service_id', se.service_id,
        'service_name', s.name,
        'sort_order', se.sort_order,
        'is_required', se.is_required,
        'max_quantity', se.max_quantity,
        'schedule_placement', se.schedule_placement,
        'default_schedule_minutes', se.default_schedule_minutes
      ) order by s.name, se.service_id
    ),
    '[]'::jsonb
  )
  into v_after
  from public.service_extras se
  join public.services s on s.id = se.service_id
  where se.extra_id = p_extra_id;

  insert into public.audit_logs (
    admin_user_id,
    entity_type,
    entity_id,
    action,
    before_json,
    after_json,
    origin
  ) values (
    p_admin_user_id,
    'EXTRA',
    p_extra_id,
    'SERVICE_ASSIGNMENTS_CHANGED',
    jsonb_build_object('services', v_before),
    jsonb_build_object('services', v_after),
    case when p_admin_user_id is null then 'SYSTEM' else 'ADMIN' end
  );

  return jsonb_build_object(
    'extra_id', p_extra_id,
    'assigned_services', v_after,
    'assigned_count', jsonb_array_length(v_after)
  );
end;
$$;

create or replace view public.extra_catalog_admin as
select
  e.id,
  e.name,
  e.description,
  e.price,
  e.duration_delta_minutes,
  e.is_active,
  e.created_at,
  e.updated_at,
  count(se.service_id)::integer as assigned_service_count,
  coalesce(
    jsonb_agg(
      jsonb_build_object(
        'service_id', s.id,
        'service_name', s.name,
        'service_slug', s.slug,
        'sort_order', se.sort_order,
        'is_required', se.is_required,
        'max_quantity', se.max_quantity,
        'schedule_placement', se.schedule_placement,
        'default_schedule_minutes', se.default_schedule_minutes
      ) order by s.name, s.id
    ) filter (where s.id is not null),
    '[]'::jsonb
  ) as assigned_services
from public.extras e
left join public.service_extras se on se.extra_id = e.id
left join public.services s on s.id = se.service_id
group by e.id;

comment on table public.extras is
  'Global reusable extra catalog. An extra is created once and offered in services through service_extras.';

comment on table public.service_extras is
  'Assignment/configuration of a global extra inside one service. Removing an assignment does not delete the global extra or historical appointment snapshots.';

comment on function public.set_extra_service_assignments(uuid, uuid[], uuid) is
  'Atomically replaces the set of services that offer one global extra while preserving configuration for assignments that remain selected.';
