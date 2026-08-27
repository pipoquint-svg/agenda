-- BlackSheep invariant: extras are commercial selections only and must never
-- change the reserved schedule. Sabrina services keep the existing schedule
-- profile behavior.

create or replace function public.resolve_extra_schedule_profile(
  p_service_id uuid,
  p_extra_selections jsonb default '[]'::jsonb,
  p_anchor_start_at timestamptz default null::timestamptz
)
returns jsonb
language plpgsql
stable
set search_path to 'public'
as $function$
declare
  v_timezone text;
  v_local_ts timestamp without time zone;
  v_local_time time without time zone;
  v_dow smallint;
  v_operation_scope text;
  v_pre integer := 0;
  v_post integer := 0;
  v_details jsonb := '[]'::jsonb;
  v_version text;
begin
  select timezone into v_timezone
  from public.operation_settings
  where id = 1;

  select operation_scope::text into v_operation_scope
  from public.services
  where id = p_service_id;

  if p_anchor_start_at is not null then
    v_local_ts := p_anchor_start_at at time zone v_timezone;
    v_local_time := v_local_ts::time;
    v_dow := extract(dow from v_local_ts)::smallint;
  end if;

  with selected as (
    select
      x.extra_id,
      x.quantity,
      se.sort_order,
      coalesce(rr.schedule_placement, se.schedule_placement) as placement,
      case
        when v_operation_scope = 'BLACKSHEEP' then 0
        else coalesce(rr.schedule_minutes, se.default_schedule_minutes, e.duration_delta_minutes)
      end as minutes_per_unit,
      greatest(e.updated_at, se.schedule_updated_at, coalesce(rr.updated_at, '-infinity'::timestamptz)) as config_updated_at
    from jsonb_to_recordset(coalesce(p_extra_selections, '[]'::jsonb)) as x(extra_id uuid, quantity integer)
    join public.service_extras se
      on se.service_id = p_service_id
     and se.extra_id = x.extra_id
    join public.extras e
      on e.id = x.extra_id
     and e.is_active
    left join lateral (
      select r.schedule_placement, r.schedule_minutes, r.updated_at
      from public.service_extra_schedule_rules r
      where r.service_id = p_service_id
        and r.extra_id = x.extra_id
        and r.is_active
        and p_anchor_start_at is not null
        and (r.days_of_week is null or v_dow = any(r.days_of_week))
        and (r.anchor_start_local_time is null or v_local_time >= r.anchor_start_local_time)
        and (r.anchor_end_local_time is null or v_local_time < r.anchor_end_local_time)
      order by r.priority asc, r.id asc
      limit 1
    ) rr on true
    where x.quantity is not null and x.quantity > 0
  )
  select
    coalesce(sum(minutes_per_unit * quantity) filter (where placement = 'PREPEND'), 0)::integer,
    coalesce(sum(minutes_per_unit * quantity) filter (where placement = 'APPEND'), 0)::integer,
    coalesce(jsonb_agg(
      jsonb_build_object(
        'extra_id', extra_id,
        'quantity', quantity,
        'placement', placement,
        'minutes_per_unit', minutes_per_unit,
        'total_schedule_minutes', minutes_per_unit * quantity
      ) order by sort_order, extra_id
    ), '[]'::jsonb),
    md5(concat_ws('||',
      coalesce(v_operation_scope, ''),
      coalesce(string_agg(
        concat_ws('|', extra_id::text, quantity::text, placement::text, minutes_per_unit::text, config_updated_at::text),
        '||' order by sort_order, extra_id
      ), '')
    ))
  into v_pre, v_post, v_details, v_version
  from selected;

  return jsonb_build_object(
    'pre_service_minutes', v_pre,
    'post_service_minutes', v_post,
    'details', v_details,
    'schedule_version', v_version
  );
end;
$function$;
