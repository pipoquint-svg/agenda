-- Editorial guidance for variable-duration services.
-- This table carries no pricing logic: it only helps the UI explain what can
-- typically be produced within a selected duration range.

create table if not exists public.service_duration_guidance_ranges (
  id uuid primary key default gen_random_uuid(),
  service_id uuid not null references public.services(id) on delete cascade,
  min_blocks integer not null check (min_blocks > 0),
  max_blocks integer check (max_blocks is null or max_blocks >= min_blocks),
  title text not null check (btrim(title) <> ''),
  description text not null check (btrim(description) <> ''),
  is_active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists service_duration_guidance_ranges_service_idx
  on public.service_duration_guidance_ranges(service_id, is_active, min_blocks, max_blocks, sort_order);

alter table public.service_duration_guidance_ranges enable row level security;
revoke all on public.service_duration_guidance_ranges from public, anon, authenticated;

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
  'require_tax_id', bp.require_tax_id,
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
        'duration_presets', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', p.id,
            'block_count', p.block_count,
            'title', p.title,
            'description', p.description,
            'badge', p.badge,
            'is_featured', p.is_featured
          ) order by p.sort_order, p.block_count, p.id)
          from public.service_duration_presets p
          where p.service_id = s.id and p.is_active
        ), '[]'::jsonb),
        'duration_guidance', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', g.id,
            'min_blocks', g.min_blocks,
            'max_blocks', g.max_blocks,
            'title', g.title,
            'description', g.description
          ) order by g.sort_order, g.min_blocks, g.id)
          from public.service_duration_guidance_ranges g
          where g.service_id = s.id and g.is_active
        ), '[]'::jsonb),
        'employees', coalesce((
          select jsonb_agg(jsonb_build_object(
            'service_employee_id', se.id,
            'employee_id', e.id,
            'name', e.name
          ) order by e.name, se.id)
          from public.service_employees se
          join public.employees e on e.id = se.employee_id and e.is_active
          where se.service_id = s.id and se.is_active
        ), '[]'::jsonb),
        'extras', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', e.id,
            'name', e.name,
            'description', e.description,
            'price', e.price,
            'duration_delta_minutes', e.duration_delta_minutes,
            'is_required', sx.is_required,
            'max_quantity', sx.max_quantity,
            'schedule_placement', sx.schedule_placement,
            'default_schedule_minutes', sx.default_schedule_minutes
          ) order by sx.sort_order, e.name, e.id)
          from public.service_extras sx
          join public.extras e on e.id = sx.extra_id and e.is_active
          where sx.service_id = s.id
        ), '[]'::jsonb),
        'fields', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', sf.id,
            'field_key', sf.field_key,
            'label', sf.label,
            'field_type', sf.field_type,
            'help_text', sf.help_text,
            'placeholder', sf.placeholder,
            'is_required', sf.is_required,
            'options', sf.options_json
          ) order by sf.sort_order, sf.id)
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

revoke all on function public.public_get_booking_page(text) from public;
grant execute on function public.public_get_booking_page(text) to anon, authenticated;
