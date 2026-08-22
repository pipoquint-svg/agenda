-- Administrative service settings. These RPCs are service-role only and are
-- intended to be called after the Edge Function authenticates an admin user.

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

create or replace function public.service_admin_update_timing(
  p_service_id uuid,
  p_duration_mode text,
  p_base_duration_minutes integer,
  p_booking_block_minutes integer,
  p_minimum_booking_blocks integer,
  p_maximum_booking_blocks integer,
  p_base_price numeric,
  p_price_per_block numeric,
  p_buffer_before_minutes integer,
  p_buffer_after_minutes integer
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_service public.services%rowtype;
begin
  select * into v_service from public.services where id = p_service_id for update;
  if not found then
    raise exception using errcode = 'P0001', message = 'SERVICE_NOT_FOUND';
  end if;

  if p_duration_mode not in ('FIXED','BLOCKS') then
    raise exception using errcode = 'P0001', message = 'INVALID_DURATION_MODE';
  end if;
  if coalesce(p_base_duration_minutes, 0) <= 0 then
    raise exception using errcode = 'P0001', message = 'INVALID_BASE_DURATION';
  end if;
  if coalesce(p_buffer_before_minutes, -1) < 0 or coalesce(p_buffer_after_minutes, -1) < 0 then
    raise exception using errcode = 'P0001', message = 'INVALID_BUFFER';
  end if;
  if coalesce(p_base_price, -1) < 0 then
    raise exception using errcode = 'P0001', message = 'INVALID_BASE_PRICE';
  end if;

  if p_duration_mode = 'BLOCKS' then
    if coalesce(p_booking_block_minutes, 0) <= 0
      or coalesce(p_minimum_booking_blocks, 0) <= 0
      or coalesce(p_maximum_booking_blocks, 0) < p_minimum_booking_blocks
      or coalesce(p_price_per_block, -1) < 0 then
      raise exception using errcode = 'P0001', message = 'INVALID_BLOCK_DURATION_CONFIG';
    end if;
  end if;

  update public.services
  set duration_mode = p_duration_mode,
      base_duration_minutes = p_base_duration_minutes,
      booking_block_minutes = case when p_duration_mode = 'BLOCKS' then p_booking_block_minutes else null end,
      minimum_booking_blocks = case when p_duration_mode = 'BLOCKS' then p_minimum_booking_blocks else null end,
      maximum_booking_blocks = case when p_duration_mode = 'BLOCKS' then p_maximum_booking_blocks else null end,
      price_per_block = case when p_duration_mode = 'BLOCKS' then p_price_per_block else null end,
      base_price = p_base_price,
      buffer_before_minutes = p_buffer_before_minutes,
      buffer_after_minutes = p_buffer_after_minutes,
      updated_at = now()
  where id = p_service_id;

  return jsonb_build_object(
    'service_id', p_service_id,
    'duration_mode', p_duration_mode,
    'base_duration_minutes', p_base_duration_minutes,
    'booking_block_minutes', case when p_duration_mode = 'BLOCKS' then p_booking_block_minutes else null end,
    'minimum_booking_blocks', case when p_duration_mode = 'BLOCKS' then p_minimum_booking_blocks else null end,
    'maximum_booking_blocks', case when p_duration_mode = 'BLOCKS' then p_maximum_booking_blocks else null end,
    'price_per_block', case when p_duration_mode = 'BLOCKS' then p_price_per_block else null end,
    'base_price', p_base_price,
    'buffer_before_minutes', p_buffer_before_minutes,
    'buffer_after_minutes', p_buffer_after_minutes
  );
end;
$$;

create or replace function public.service_admin_replace_duration_configuration(
  p_service_id uuid,
  p_pricing_tiers jsonb default '[]'::jsonb,
  p_duration_presets jsonb default '[]'::jsonb
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_service public.services%rowtype;
  v_tier jsonb;
  v_preset jsonb;
  v_count integer := 0;
begin
  select * into v_service from public.services where id = p_service_id for update;
  if not found then
    raise exception using errcode = 'P0001', message = 'SERVICE_NOT_FOUND';
  end if;
  if v_service.duration_mode <> 'BLOCKS' then
    raise exception using errcode = 'P0001', message = 'DURATION_CONFIGURATION_REQUIRES_BLOCKS';
  end if;
  if jsonb_typeof(coalesce(p_pricing_tiers, '[]'::jsonb)) <> 'array'
     or jsonb_typeof(coalesce(p_duration_presets, '[]'::jsonb)) <> 'array' then
    raise exception using errcode = 'P0001', message = 'INVALID_DURATION_CONFIGURATION';
  end if;

  delete from public.service_duration_pricing_tiers where service_id = p_service_id;

  for v_tier in select value from jsonb_array_elements(coalesce(p_pricing_tiers, '[]'::jsonb)) loop
    if coalesce((v_tier->>'min_blocks')::integer, 0) <= 0
      or (v_tier ? 'max_blocks' and v_tier->>'max_blocks' is not null
          and (v_tier->>'max_blocks')::integer < (v_tier->>'min_blocks')::integer)
      or coalesce((v_tier->>'price_per_block')::numeric, -1) < 0 then
      raise exception using errcode = 'P0001', message = 'INVALID_DURATION_PRICING_TIER';
    end if;

    insert into public.service_duration_pricing_tiers(
      service_id, min_blocks, max_blocks, price_per_block, is_active, sort_order
    ) values (
      p_service_id,
      (v_tier->>'min_blocks')::integer,
      case when v_tier->>'max_blocks' is null then null else (v_tier->>'max_blocks')::integer end,
      (v_tier->>'price_per_block')::numeric,
      coalesce((v_tier->>'is_active')::boolean, true),
      coalesce((v_tier->>'sort_order')::integer, v_count * 10)
    );
    v_count := v_count + 1;
  end loop;

  delete from public.service_duration_presets where service_id = p_service_id;
  v_count := 0;

  for v_preset in select value from jsonb_array_elements(coalesce(p_duration_presets, '[]'::jsonb)) loop
    if coalesce((v_preset->>'block_count')::integer, 0) <= 0
      or nullif(btrim(v_preset->>'title'), '') is null then
      raise exception using errcode = 'P0001', message = 'INVALID_DURATION_PRESET';
    end if;
    if (v_preset->>'block_count')::integer < v_service.minimum_booking_blocks
      or (v_preset->>'block_count')::integer > v_service.maximum_booking_blocks then
      raise exception using errcode = 'P0001', message = 'DURATION_PRESET_OUT_OF_RANGE';
    end if;

    insert into public.service_duration_presets(
      service_id, block_count, title, description, badge, is_featured, is_active, sort_order
    ) values (
      p_service_id,
      (v_preset->>'block_count')::integer,
      btrim(v_preset->>'title'),
      nullif(btrim(v_preset->>'description'), ''),
      nullif(btrim(v_preset->>'badge'), ''),
      coalesce((v_preset->>'is_featured')::boolean, false),
      coalesce((v_preset->>'is_active')::boolean, true),
      coalesce((v_preset->>'sort_order')::integer, v_count * 10)
    );
    v_count := v_count + 1;
  end loop;

  return jsonb_build_object(
    'service_id', p_service_id,
    'pricing_tiers', coalesce((
      select jsonb_agg(to_jsonb(t) - 'service_id' - 'created_at' - 'updated_at' order by t.sort_order, t.min_blocks, t.id)
      from public.service_duration_pricing_tiers t where t.service_id = p_service_id
    ), '[]'::jsonb),
    'duration_presets', coalesce((
      select jsonb_agg(to_jsonb(p) - 'service_id' - 'created_at' - 'updated_at' order by p.sort_order, p.block_count, p.id)
      from public.service_duration_presets p where p.service_id = p_service_id
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.service_admin_list_service_settings() from public, anon, authenticated;
revoke all on function public.service_admin_update_timing(uuid,text,integer,integer,integer,integer,numeric,numeric,integer,integer) from public, anon, authenticated;
revoke all on function public.service_admin_replace_duration_configuration(uuid,jsonb,jsonb) from public, anon, authenticated;

grant execute on function public.service_admin_list_service_settings() to service_role;
grant execute on function public.service_admin_update_timing(uuid,text,integer,integer,integer,integer,numeric,numeric,integer,integer) to service_role;
grant execute on function public.service_admin_replace_duration_configuration(uuid,jsonb,jsonb) to service_role;
