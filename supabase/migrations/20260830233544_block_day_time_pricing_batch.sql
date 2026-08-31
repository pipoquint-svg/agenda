create or replace function public.calculate_booking_quotes_for_duration_batch(
  p_service_id uuid,
  p_service_employee_id uuid,
  p_duration_blocks integer,
  p_extra_selections jsonb default '[]'::jsonb,
  p_people_count integer default 1,
  p_requested_start_ats timestamptz[] default '{}'::timestamptz[],
  p_coupon_code text default null
)
returns table(requested_start_at timestamptz, quote jsonb)
language plpgsql
stable
set search_path = public, extensions
as $function$
declare
  v_service public.services%rowtype;
  v_timezone text;
  v_duration_pricing jsonb;
  v_unit_price numeric := 0;
  v_dynamic_base numeric := 0;
  v_contracted_minutes integer;
  v_extras_total numeric := 0;
  v_processed_extras integer := 0;
  v_requested_extras integer := 0;
  v_resource_ids uuid[] := '{}'::uuid[];
  v_day_rules jsonb := '[]'::jsonb;
  v_people_rules jsonb := '[]'::jsonb;
  v_coupon public.coupons%rowtype;
  v_has_coupon boolean := false;
  v_pricing_version_seed text;
  v_start timestamptz;
  v_local_ts timestamp without time zone;
  v_local_date date;
  v_local_time time without time zone;
  v_dow smallint;
  v_block_local_ts timestamp without time zone;
  v_block_local_date date;
  v_block_local_time time without time zone;
  v_block_dow smallint;
  v_surcharge numeric;
  v_price numeric;
  v_after_day_time numeric;
  v_day_time_adjustment numeric;
  v_after_people numeric;
  v_people_adjustment numeric;
  v_subtotal numeric;
  v_coupon_discount numeric;
  v_commercial_value numeric;
  v_rule jsonb;
  v_block_idx integer;
  r record;
begin
  select * into v_service
  from public.services
  where id = p_service_id and is_active;

  if not found then
    raise exception using errcode='P0001', message='SERVICE_NOT_AVAILABLE';
  end if;

  if v_service.duration_mode <> 'BLOCKS' then
    raise exception using errcode='P0001', message='DURATION_PRICING_NOT_ALLOWED';
  end if;

  if not exists (
    select 1 from public.service_employees se
    where se.id = p_service_employee_id
      and se.service_id = p_service_id
      and se.is_active
  ) then
    raise exception using errcode='P0001', message='EMPLOYEE_NOT_AVAILABLE_FOR_SERVICE';
  end if;

  if p_people_count < v_service.minimum_people or p_people_count > v_service.maximum_people then
    raise exception using errcode='P0001', message='INVALID_PEOPLE_COUNT';
  end if;

  if jsonb_typeof(coalesce(p_extra_selections, '[]'::jsonb)) <> 'array' then
    raise exception using errcode='P0001', message='INVALID_EXTRA';
  end if;

  select count(*) into v_requested_extras
  from jsonb_array_elements(coalesce(p_extra_selections, '[]'::jsonb));

  if exists (
    select 1
    from jsonb_to_recordset(coalesce(p_extra_selections, '[]'::jsonb)) x(extra_id uuid, quantity integer)
    group by x.extra_id
    having count(*) > 1
  ) then
    raise exception using errcode='P0001', message='INVALID_EXTRA';
  end if;

  v_contracted_minutes := public.resolve_service_contracted_minutes(p_service_id, p_duration_blocks);
  if v_contracted_minutes % 30 <> 0 then
    raise exception using errcode='P0001', message='BLOCK_SURCHARGE_REQUIRES_30_MINUTE_MULTIPLE';
  end if;

  v_duration_pricing := public.resolve_service_duration_pricing(p_service_id, p_duration_blocks);
  v_unit_price := (v_duration_pricing->>'unit_price')::numeric;
  v_dynamic_base := (v_duration_pricing->>'base_price')::numeric;

  for r in
    select e.id, e.price, x.quantity, se.max_quantity
    from jsonb_to_recordset(coalesce(p_extra_selections, '[]'::jsonb)) x(extra_id uuid, quantity integer)
    join public.service_extras se
      on se.service_id = p_service_id and se.extra_id = x.extra_id
    join public.extras e
      on e.id = x.extra_id and e.is_active
  loop
    if r.quantity is null or r.quantity < 1 or r.quantity > r.max_quantity then
      raise exception using errcode='P0001', message='INVALID_EXTRA_QUANTITY';
    end if;
    v_processed_extras := v_processed_extras + 1;
    v_extras_total := v_extras_total + (r.price * r.quantity);
  end loop;

  if v_processed_extras <> v_requested_extras then
    raise exception using errcode='P0001', message='INVALID_EXTRA';
  end if;
  v_extras_total := round(v_extras_total, 2);

  select os.timezone into v_timezone
  from public.operation_settings os
  where os.id = 1;

  select coalesce(jsonb_agg(to_jsonb(pr) order by pr.priority, pr.id), '[]'::jsonb)
    into v_day_rules
  from public.pricing_rules pr
  where pr.service_id = p_service_id
    and pr.is_active
    and pr.rule_scope = 'DAY_TIME';

  select coalesce(jsonb_agg(to_jsonb(pr) order by pr.priority, pr.id), '[]'::jsonb)
    into v_people_rules
  from public.pricing_rules pr
  where pr.service_id = p_service_id
    and pr.is_active
    and pr.rule_scope = 'PEOPLE'
    and p_people_count between pr.min_people and pr.max_people;

  if p_coupon_code is not null and btrim(p_coupon_code) <> '' then
    select c.* into v_coupon
    from public.coupons c
    where lower(c.code) = lower(btrim(p_coupon_code))
      and c.is_active
      and (
        not exists (select 1 from public.coupon_services cs where cs.coupon_id = c.id)
        or exists (
          select 1 from public.coupon_services cs
          where cs.coupon_id = c.id and cs.service_id = p_service_id
        )
      )
    limit 1;
    if not found then
      raise exception using errcode='P0001', message='INVALID_COUPON';
    end if;
    v_has_coupon := true;
  end if;

  select coalesce(array_agg(distinct resource_id order by resource_id), '{}'::uuid[])
    into v_resource_ids
  from (
    select sr.resource_id
    from public.service_resources sr
    where sr.service_id = p_service_id and sr.is_required
    union
    select er.resource_id
    from jsonb_to_recordset(coalesce(p_extra_selections, '[]'::jsonb)) x(extra_id uuid, quantity integer)
    join public.extra_resources er on er.extra_id = x.extra_id and er.is_required
  ) q;

  select md5(concat_ws('|',
    'BLOCK_DAY_TIME_PROPORTIONAL_V1',
    v_service.updated_at::text,
    p_duration_blocks::text,
    v_dynamic_base::text,
    coalesce((select max(updated_at)::text from public.service_duration_pricing_tiers where service_id=p_service_id),''),
    coalesce((select max(updated_at)::text from public.pricing_rules where service_id=p_service_id),''),
    coalesce((select max(e.updated_at)::text
      from jsonb_to_recordset(coalesce(p_extra_selections,'[]'::jsonb)) x(extra_id uuid,quantity integer)
      join public.extras e on e.id=x.extra_id),''),
    case when v_has_coupon then coalesce(v_coupon.updated_at::text,'') else '' end
  )) into v_pricing_version_seed;

  foreach v_start in array coalesce(p_requested_start_ats, '{}'::timestamptz[])
  loop
    v_surcharge := 0;
    v_price := v_dynamic_base;
    v_local_ts := null;
    v_local_date := null;
    v_local_time := null;
    v_dow := null;

    if v_start is not null then
      v_local_ts := v_start at time zone v_timezone;
      v_local_date := v_local_ts::date;
      v_local_time := v_local_ts::time;
      v_dow := extract(dow from v_local_ts)::smallint;

      for v_block_idx in 0..((v_contracted_minutes / 30) - 1)
      loop
        v_block_local_ts := (v_start + make_interval(mins => v_block_idx * 30)) at time zone v_timezone;
        v_block_local_date := v_block_local_ts::date;
        v_block_local_time := v_block_local_ts::time;
        v_block_dow := extract(dow from v_block_local_ts)::smallint;

        for v_rule in select value from jsonb_array_elements(v_day_rules)
        loop
          if coalesce(v_rule->>'action_type','') = 'ADD_PERCENT'
             and (v_rule->>'valid_from_date' is null or v_block_local_date >= (v_rule->>'valid_from_date')::date)
             and (v_rule->>'valid_until_date' is null or v_block_local_date <= (v_rule->>'valid_until_date')::date)
             and (
               v_rule->'days_of_week' is null
               or jsonb_typeof(v_rule->'days_of_week') = 'null'
               or exists (
                 select 1 from jsonb_array_elements_text(v_rule->'days_of_week') d
                 where d::smallint = v_block_dow
               )
             )
             and (v_rule->>'start_local_time' is null or v_block_local_time >= (v_rule->>'start_local_time')::time)
             and (v_rule->>'end_local_time' is null or v_block_local_time < (v_rule->>'end_local_time')::time)
          then
            v_surcharge := v_surcharge
              + ((v_dynamic_base / (v_contracted_minutes / 30)::numeric)
                 * ((v_rule->>'percentage')::numeric / 100));
          end if;
        end loop;
      end loop;

      v_surcharge := round(v_surcharge, 2);
      v_price := v_dynamic_base + v_surcharge;

      for v_rule in select value from jsonb_array_elements(v_day_rules)
      loop
        if coalesce(v_rule->>'action_type','') <> 'ADD_PERCENT'
           and (v_rule->>'valid_from_date' is null or v_local_date >= (v_rule->>'valid_from_date')::date)
           and (v_rule->>'valid_until_date' is null or v_local_date <= (v_rule->>'valid_until_date')::date)
           and (
             v_rule->'days_of_week' is null
             or jsonb_typeof(v_rule->'days_of_week') = 'null'
             or exists (
               select 1 from jsonb_array_elements_text(v_rule->'days_of_week') d
               where d::smallint = v_dow
             )
           )
           and (v_rule->>'start_local_time' is null or v_local_time >= (v_rule->>'start_local_time')::time)
           and (v_rule->>'end_local_time' is null or v_local_time < (v_rule->>'end_local_time')::time)
        then
          if v_rule->>'action_type' = 'REPLACE_PRICE' then
            v_price := (v_rule->>'amount')::numeric;
          elsif v_rule->>'action_type' = 'ADD_AMOUNT' then
            v_price := v_price + (v_rule->>'amount')::numeric;
          end if;
        end if;
      end loop;
    end if;

    v_after_day_time := round(greatest(v_price, 0), 2);
    v_day_time_adjustment := v_after_day_time - v_dynamic_base;
    v_price := v_after_day_time;

    for v_rule in select value from jsonb_array_elements(v_people_rules)
    loop
      if (v_rule->>'valid_from_date' is null or coalesce(v_local_date,current_date) >= (v_rule->>'valid_from_date')::date)
         and (v_rule->>'valid_until_date' is null or coalesce(v_local_date,current_date) <= (v_rule->>'valid_until_date')::date)
      then
        if v_rule->>'action_type' = 'REPLACE_PRICE' then
          v_price := (v_rule->>'amount')::numeric;
        elsif v_rule->>'action_type' = 'ADD_AMOUNT' then
          v_price := v_price + (v_rule->>'amount')::numeric;
        elsif v_rule->>'action_type' = 'ADD_PERCENT' then
          v_price := v_price * (1 + ((v_rule->>'percentage')::numeric / 100));
        end if;
      end if;
    end loop;

    v_after_people := round(greatest(v_price,0),2);
    v_people_adjustment := v_after_people - v_after_day_time;
    v_subtotal := round(greatest(v_after_people + v_extras_total, 0), 2);
    v_coupon_discount := 0;

    if v_has_coupon then
      if (v_coupon.valid_from is not null and coalesce(v_start, now()) < v_coupon.valid_from)
         or (v_coupon.valid_until is not null and coalesce(v_start, now()) > v_coupon.valid_until)
      then
        raise exception using errcode='P0001', message='INVALID_COUPON';
      end if;
      if v_coupon.discount_type = 'FIXED' then
        v_coupon_discount := least(v_coupon.discount_value, v_subtotal);
      else
        v_coupon_discount := round(v_subtotal * (v_coupon.discount_value / 100), 2);
      end if;
    end if;

    v_coupon_discount := round(v_coupon_discount,2);
    v_commercial_value := round(greatest(v_subtotal - v_coupon_discount,0),2);

    requested_start_at := v_start;
    quote := jsonb_build_object(
      'service_id', p_service_id,
      'service_employee_id', p_service_employee_id,
      'duration_mode', 'BLOCKS',
      'duration_blocks', p_duration_blocks,
      'booking_block_minutes', v_service.booking_block_minutes,
      'contracted_minutes', v_contracted_minutes,
      'core_duration_minutes', v_contracted_minutes,
      'duration_minutes', v_contracted_minutes,
      'buffer_before_minutes', v_service.buffer_before_minutes,
      'buffer_after_minutes', v_service.buffer_after_minutes,
      'resource_ids', to_jsonb(v_resource_ids),
      'base_price', round(v_dynamic_base,2),
      'base_amount', round(v_dynamic_base,2),
      'duration_unit_price', v_unit_price,
      'duration_pricing_source', v_duration_pricing->>'source',
      'duration_pricing_tier_id', v_duration_pricing->'tier_id',
      'day_time_adjustment', round(v_day_time_adjustment,2),
      'surcharge_amount', round(v_surcharge,2),
      'people_adjustment', round(v_people_adjustment,2),
      'extras_total', v_extras_total,
      'subtotal_after_surcharge', v_subtotal,
      'coupon_discount', v_coupon_discount,
      'discount_amount', v_coupon_discount,
      'commercial_value', v_commercial_value,
      'total_amount', v_commercial_value,
      'pricing_version', v_pricing_version_seed
    );
    return next;
  end loop;
end;
$function$;

create or replace function public.calculate_booking_quote_for_duration(
  p_service_id uuid,
  p_service_employee_id uuid,
  p_duration_blocks integer default null,
  p_extra_selections jsonb default '[]'::jsonb,
  p_people_count integer default 1,
  p_requested_start_at timestamptz default null,
  p_coupon_code text default null
)
returns jsonb
language plpgsql
stable
set search_path = public, extensions
as $function$
declare
  v_service public.services%rowtype;
  v_quote jsonb;
  v_profile jsonb;
  v_pre integer := 0;
  v_post integer := 0;
  v_contracted_minutes integer;
  v_pricing_version text;
begin
  select * into v_service
  from public.services
  where id=p_service_id and is_active;

  if not found then
    raise exception using errcode='P0001',message='SERVICE_NOT_AVAILABLE';
  end if;

  v_contracted_minutes := public.resolve_service_contracted_minutes(p_service_id,p_duration_blocks);

  if v_service.duration_mode='FIXED' then
    return public.calculate_booking_quote(
      p_service_id,p_service_employee_id,p_extra_selections,p_people_count,p_requested_start_at,p_coupon_code
    ) || jsonb_build_object(
      'duration_mode','FIXED',
      'duration_blocks',null,
      'contracted_minutes',v_contracted_minutes,
      'buffer_before_minutes',v_service.buffer_before_minutes,
      'buffer_after_minutes',v_service.buffer_after_minutes
    );
  end if;

  select b.quote into v_quote
  from public.calculate_booking_quotes_for_duration_batch(
    p_service_id,
    p_service_employee_id,
    p_duration_blocks,
    p_extra_selections,
    p_people_count,
    array[p_requested_start_at]::timestamptz[],
    p_coupon_code
  ) b
  limit 1;

  if v_quote is null then
    raise exception using errcode='P0001', message='BOOKING_QUOTE_NOT_AVAILABLE';
  end if;

  v_profile := public.resolve_extra_schedule_profile(p_service_id,p_extra_selections,p_requested_start_at);
  v_pre := coalesce((v_profile->>'pre_service_minutes')::integer,0);
  v_post := coalesce((v_profile->>'post_service_minutes')::integer,0);
  v_pricing_version := md5(coalesce(v_quote->>'pricing_version','') || '|' || coalesce(v_profile->>'schedule_version',''));

  return v_quote || jsonb_build_object(
    'pre_service_minutes',v_pre,
    'post_service_minutes',v_post,
    'duration_minutes',v_contracted_minutes+v_pre+v_post,
    'schedule_profile',v_profile,
    'pricing_version',v_pricing_version
  );
end;
$function$;

do $migration$
declare
  v_oid oid;
  v_def text;
  v_old_decl text := E'  v_quote jsonb;\n';
  v_new_decl text := E'  v_profile jsonb;\n  v_candidates jsonb := ''[]''::jsonb;\n';
  v_old_quote text := E'    v_quote := public.calculate_booking_quote_for_duration(\n      p_service_id,\n      p_service_employee_id,\n      p_duration_blocks,\n      p_extra_selections,\n      p_people_count,\n      v_anchor_start,\n      p_coupon_code\n    );\n    v_pre := coalesce((v_quote->>''pre_service_minutes'')::integer, 0);\n    v_post := coalesce((v_quote->>''post_service_minutes'')::integer, 0);';
  v_new_quote text := E'    v_profile := public.resolve_extra_schedule_profile(p_service_id, p_extra_selections, v_anchor_start);\n    v_pre := coalesce((v_profile->>''pre_service_minutes'')::integer, 0);\n    v_post := coalesce((v_profile->>''post_service_minutes'')::integer, 0);';
  v_old_tail text := E'    slot_start_at := v_appointment_start;\n    slot_end_at := v_appointment_end;\n    core_start_at := v_anchor_start;\n    core_end_at := v_core_end;\n    pre_service_minutes := v_pre;\n    post_service_minutes := v_post;\n    duration_minutes := v_contracted_minutes + v_pre + v_post;\n    commercial_value := (v_quote->>''commercial_value'')::numeric(12,2);\n    return next;\n  end loop;\nend;';
  v_new_tail text := E'    v_candidates := v_candidates || jsonb_build_array(jsonb_build_object(\n      ''slot_start_at'',v_appointment_start,\n      ''slot_end_at'',v_appointment_end,\n      ''core_start_at'',v_anchor_start,\n      ''core_end_at'',v_core_end,\n      ''pre_service_minutes'',v_pre,\n      ''post_service_minutes'',v_post,\n      ''duration_minutes'',v_contracted_minutes + v_pre + v_post\n    ));\n  end loop;\n\n  if jsonb_array_length(v_candidates) = 0 then\n    return;\n  end if;\n\n  return query\n  with candidates as (\n    select\n      ord::bigint as ord,\n      (item->>''slot_start_at'')::timestamptz as slot_start_at,\n      (item->>''slot_end_at'')::timestamptz as slot_end_at,\n      (item->>''core_start_at'')::timestamptz as core_start_at,\n      (item->>''core_end_at'')::timestamptz as core_end_at,\n      (item->>''pre_service_minutes'')::integer as pre_service_minutes,\n      (item->>''post_service_minutes'')::integer as post_service_minutes,\n      (item->>''duration_minutes'')::integer as duration_minutes\n    from jsonb_array_elements(v_candidates) with ordinality x(item,ord)\n  ), quotes as (\n    select b.requested_start_at, b.quote\n    from public.calculate_booking_quotes_for_duration_batch(\n      p_service_id,p_service_employee_id,p_duration_blocks,p_extra_selections,p_people_count,\n      (select array_agg(c.core_start_at order by c.ord) from candidates c),p_coupon_code\n    ) b\n  )\n  select c.slot_start_at,c.slot_end_at,c.core_start_at,c.core_end_at,\n         c.pre_service_minutes,c.post_service_minutes,c.duration_minutes,\n         (q.quote->>''commercial_value'')::numeric(12,2)\n  from candidates c\n  join quotes q on q.requested_start_at = c.core_start_at\n  order by c.ord;\nend;';
begin
  select p.oid into v_oid
  from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public'
    and p.proname='list_available_slots_for_duration_without_google_sync_gate'
    and pg_get_function_identity_arguments(p.oid) =
      'p_service_id uuid, p_service_employee_id uuid, p_duration_blocks integer, p_extra_selections jsonb, p_people_count integer, p_local_date date, p_coupon_code text';

  if v_oid is null then
    raise exception 'duration slot function not found';
  end if;

  v_def := pg_get_functiondef(v_oid);

  if position(v_old_decl in v_def)=0 then raise exception 'expected quote declaration not found'; end if;
  v_def := replace(v_def,v_old_decl,v_new_decl);

  if position(v_old_quote in v_def)=0 then raise exception 'expected in-loop quote call not found'; end if;
  v_def := replace(v_def,v_old_quote,v_new_quote);

  if position(v_old_tail in v_def)=0 then raise exception 'expected slot return tail not found'; end if;
  v_def := replace(v_def,v_old_tail,v_new_tail);

  execute v_def;
end;
$migration$;

comment on function public.calculate_booking_quotes_for_duration_batch(uuid,uuid,integer,jsonb,integer,timestamptz[],text)
is 'Canonical batch pricing core for BLOCKS services. Loads duration pricing and pricing_rules once per batch; ADD_PERCENT DAY_TIME surcharge is proportional by 30-minute contracted blocks. FIXED services are excluded.';