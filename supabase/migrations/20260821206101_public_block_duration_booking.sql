-- Public wrappers for configurable block-duration services.
-- Existing fixed-duration entrypoints stay available for compatibility.

create or replace function public.public_get_booking_page(p_slug text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
select jsonb_build_object(
  'id', bp.id,
  'slug', bp.slug,
  'display_name', bp.display_name,
  'title', bp.title,
  'subtitle', bp.subtitle,
  'brand_key', bp.brand_key,
  'logo_url', bp.logo_url,
  'accent_color', bp.accent_color,
  'services', coalesce((
    select jsonb_agg(
      jsonb_build_object(
        'id', s.id,
        'name', s.name,
        'slug', s.slug,
        'short_description', s.short_description,
        'cover_image_url', s.cover_image_url,
        'base_duration_minutes', s.base_duration_minutes,
        'base_price', s.base_price,
        'duration_mode', s.duration_mode,
        'booking_block_minutes', s.booking_block_minutes,
        'minimum_booking_blocks', s.minimum_booking_blocks,
        'maximum_booking_blocks', s.maximum_booking_blocks,
        'price_per_block', s.price_per_block,
        'buffer_before_minutes', s.buffer_before_minutes,
        'buffer_after_minutes', s.buffer_after_minutes,
        'minimum_people', s.minimum_people,
        'maximum_people', s.maximum_people,
        'requires_terms', s.requires_terms,
        'employees', coalesce((
          select jsonb_agg(
            jsonb_build_object(
              'service_employee_id', se.id,
              'employee_id', e.id,
              'name', e.name
            ) order by e.name, se.id
          )
          from public.service_employees se
          join public.employees e on e.id = se.employee_id and e.is_active
          where se.service_id = s.id and se.is_active
        ), '[]'::jsonb),
        'extras', coalesce((
          select jsonb_agg(
            jsonb_build_object(
              'id', e.id,
              'name', e.name,
              'description', e.description,
              'price', e.price,
              'duration_delta_minutes', e.duration_delta_minutes,
              'is_required', sx.is_required,
              'max_quantity', sx.max_quantity,
              'schedule_placement', sx.schedule_placement,
              'default_schedule_minutes', sx.default_schedule_minutes
            ) order by sx.sort_order, e.name, e.id
          )
          from public.service_extras sx
          join public.extras e on e.id = sx.extra_id and e.is_active
          where sx.service_id = s.id
        ), '[]'::jsonb),
        'fields', coalesce((
          select jsonb_agg(
            jsonb_build_object(
              'id', sf.id,
              'field_key', sf.field_key,
              'label', sf.label,
              'field_type', sf.field_type,
              'help_text', sf.help_text,
              'placeholder', sf.placeholder,
              'is_required', sf.is_required,
              'options', sf.options_json
            ) order by sf.sort_order, sf.id
          )
          from public.service_fields sf
          where sf.service_id = s.id and sf.is_active
        ), '[]'::jsonb)
      ) order by bps.sort_order, s.sort_order, s.name
    )
    from public.booking_page_services bps
    join public.services s on s.id = bps.service_id and s.is_active
    where bps.booking_page_id = bp.id and bps.is_active
  ), '[]'::jsonb)
)
from public.booking_pages bp
where bp.slug = lower(btrim(p_slug)) and bp.is_active;
$$;

create or replace function public.assert_public_booking_duration(
  p_booking_page_slug text,
  p_service_id uuid,
  p_service_employee_id uuid,
  p_duration_blocks integer,
  p_extra_selections jsonb default '[]'::jsonb,
  p_people_count integer default 1
)
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.assert_public_booking_selection(
    p_booking_page_slug,
    p_service_id,
    p_service_employee_id,
    p_extra_selections,
    p_people_count
  );
  perform public.resolve_service_contracted_minutes(p_service_id, p_duration_blocks);
end;
$$;

create or replace function public.public_quote_booking_duration(
  p_booking_page_slug text,
  p_service_id uuid,
  p_service_employee_id uuid,
  p_duration_blocks integer,
  p_extra_selections jsonb default '[]'::jsonb,
  p_people_count integer default 1
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.assert_public_booking_duration(
    p_booking_page_slug, p_service_id, p_service_employee_id,
    p_duration_blocks, p_extra_selections, p_people_count
  );
  return public.calculate_booking_quote_for_duration(
    p_service_id, p_service_employee_id, p_duration_blocks,
    p_extra_selections, p_people_count, null, null
  );
end;
$$;

create or replace function public.public_list_available_slots_duration(
  p_booking_page_slug text,
  p_service_id uuid,
  p_service_employee_id uuid,
  p_duration_blocks integer,
  p_extra_selections jsonb default '[]'::jsonb,
  p_people_count integer default 1,
  p_local_date date default current_date
)
returns table (
  slot_start_at timestamptz,
  slot_end_at timestamptz,
  core_start_at timestamptz,
  core_end_at timestamptz,
  pre_service_minutes integer,
  post_service_minutes integer,
  duration_minutes integer,
  commercial_value numeric(12,2)
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.assert_public_booking_duration(
    p_booking_page_slug, p_service_id, p_service_employee_id,
    p_duration_blocks, p_extra_selections, p_people_count
  );
  return query
  select * from public.list_available_slots_for_duration(
    p_service_id, p_service_employee_id, p_duration_blocks,
    p_extra_selections, p_people_count, p_local_date, null
  );
end;
$$;

create or replace function public.public_create_checkout_hold_duration(
  p_booking_page_slug text,
  p_service_id uuid,
  p_service_employee_id uuid,
  p_duration_blocks integer,
  p_extra_selections jsonb,
  p_people_count integer,
  p_requested_start_at timestamptz
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
begin
  perform public.assert_public_booking_duration(
    p_booking_page_slug, p_service_id, p_service_employee_id,
    p_duration_blocks, p_extra_selections, p_people_count
  );
  return public.create_checkout_hold_for_duration(
    p_service_id, p_service_employee_id, p_duration_blocks,
    p_extra_selections, p_people_count, p_requested_start_at
  );
end;
$$;

create or replace function public.public_create_checkout_hold_tracked_duration(
  p_booking_page_slug text,
  p_service_id uuid,
  p_service_employee_id uuid,
  p_duration_blocks integer,
  p_extra_selections jsonb,
  p_people_count integer,
  p_requested_start_at timestamptz,
  p_attribution_json jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_result jsonb;
  v_hold_id uuid;
begin
  if p_attribution_json is not null and jsonb_typeof(p_attribution_json) <> 'object' then
    raise exception using errcode = 'P0001', message = 'ATTRIBUTION_INVALID';
  end if;

  v_result := public.public_create_checkout_hold_duration(
    p_booking_page_slug, p_service_id, p_service_employee_id,
    p_duration_blocks, p_extra_selections, p_people_count, p_requested_start_at
  );

  v_hold_id := (v_result->>'checkout_hold_id')::uuid;
  update public.checkout_holds
  set attribution_json = public.sanitize_public_attribution(coalesce(p_attribution_json, '{}'::jsonb)),
      updated_at = now()
  where id = v_hold_id;

  return v_result;
end;
$$;

revoke all on function public.assert_public_booking_duration(text,uuid,uuid,integer,jsonb,integer)
  from public, anon, authenticated;
revoke all on function public.public_quote_booking_duration(text,uuid,uuid,integer,jsonb,integer) from public;
revoke all on function public.public_list_available_slots_duration(text,uuid,uuid,integer,jsonb,integer,date) from public;
revoke all on function public.public_create_checkout_hold_duration(text,uuid,uuid,integer,jsonb,integer,timestamptz) from public;
revoke all on function public.public_create_checkout_hold_tracked_duration(text,uuid,uuid,integer,jsonb,integer,timestamptz,jsonb) from public;

grant execute on function public.public_quote_booking_duration(text,uuid,uuid,integer,jsonb,integer) to anon, authenticated;
grant execute on function public.public_list_available_slots_duration(text,uuid,uuid,integer,jsonb,integer,date) to anon, authenticated;
grant execute on function public.public_create_checkout_hold_duration(text,uuid,uuid,integer,jsonb,integer,timestamptz) to anon, authenticated;
grant execute on function public.public_create_checkout_hold_tracked_duration(text,uuid,uuid,integer,jsonb,integer,timestamptz,jsonb) to anon, authenticated;
