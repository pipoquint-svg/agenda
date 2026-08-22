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
