-- Progressive duration pricing for block-based services.
-- Pricing tiers are deliberately separate from editorial duration presets:
-- tiers control money; presets guide the customer toward useful durations.

create table public.service_duration_pricing_tiers (
  id uuid primary key default gen_random_uuid(),
  service_id uuid not null references public.services(id) on delete cascade,
  min_blocks integer not null check (min_blocks > 0),
  max_blocks integer check (max_blocks is null or max_blocks >= min_blocks),
  price_per_block numeric(12,2) not null check (price_per_block >= 0),
  is_active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index service_duration_pricing_tiers_service_idx
  on public.service_duration_pricing_tiers(service_id, is_active, min_blocks, max_blocks);

create table public.service_duration_presets (
  id uuid primary key default gen_random_uuid(),
  service_id uuid not null references public.services(id) on delete cascade,
  block_count integer not null check (block_count > 0),
  title text not null check (btrim(title) <> ''),
  description text,
  badge text,
  is_featured boolean not null default false,
  is_active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(service_id, block_count)
);

create index service_duration_presets_service_idx
  on public.service_duration_presets(service_id, is_active, sort_order, block_count);

alter table public.service_duration_pricing_tiers enable row level security;
alter table public.service_duration_presets enable row level security;
revoke all on public.service_duration_pricing_tiers from public, anon, authenticated;
revoke all on public.service_duration_presets from public, anon, authenticated;

create or replace function public.prevent_duration_pricing_overlap()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.is_active and exists (
    select 1
    from public.service_duration_pricing_tiers t
    where t.service_id = new.service_id
      and t.is_active
      and t.id <> new.id
      and int4range(t.min_blocks, coalesce(t.max_blocks, 2147483646) + 1, '[)')
          && int4range(new.min_blocks, coalesce(new.max_blocks, 2147483646) + 1, '[)')
  ) then
    raise exception using errcode = 'P0001', message = 'DURATION_PRICING_TIER_OVERLAP';
  end if;
  new.updated_at := now();
  return new;
end;
$$;

create trigger service_duration_pricing_tiers_no_overlap
before insert or update on public.service_duration_pricing_tiers
for each row execute function public.prevent_duration_pricing_overlap();

create or replace function public.touch_duration_preset_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger service_duration_presets_touch
before update on public.service_duration_presets
for each row execute function public.touch_duration_preset_updated_at();

create or replace function public.resolve_service_duration_pricing(
  p_service_id uuid,
  p_duration_blocks integer
)
returns jsonb
language plpgsql
stable
set search_path = public
as $$
declare
  v_service public.services%rowtype;
  v_tier public.service_duration_pricing_tiers%rowtype;
  v_matches integer;
begin
  select * into v_service
  from public.services
  where id = p_service_id and is_active;

  if not found then
    raise exception using errcode = 'P0001', message = 'SERVICE_NOT_AVAILABLE';
  end if;

  if v_service.duration_mode <> 'BLOCKS' then
    raise exception using errcode = 'P0001', message = 'DURATION_PRICING_NOT_ALLOWED';
  end if;

  perform public.resolve_service_contracted_minutes(p_service_id, p_duration_blocks);

  select count(*) into v_matches
  from public.service_duration_pricing_tiers t
  where t.service_id = p_service_id
    and t.is_active
    and p_duration_blocks >= t.min_blocks
    and (t.max_blocks is null or p_duration_blocks <= t.max_blocks);

  if v_matches > 1 then
    raise exception using errcode = 'P0001', message = 'DURATION_PRICING_TIER_OVERLAP';
  end if;

  select * into v_tier
  from public.service_duration_pricing_tiers t
  where t.service_id = p_service_id
    and t.is_active
    and p_duration_blocks >= t.min_blocks
    and (t.max_blocks is null or p_duration_blocks <= t.max_blocks)
  order by t.min_blocks desc, t.sort_order, t.id
  limit 1;

  if found then
    return jsonb_build_object(
      'source', 'TIER',
      'tier_id', v_tier.id,
      'min_blocks', v_tier.min_blocks,
      'max_blocks', v_tier.max_blocks,
      'unit_price', v_tier.price_per_block,
      'base_price', round(v_tier.price_per_block * p_duration_blocks, 2)
    );
  end if;

  if v_service.price_per_block is null then
    raise exception using errcode = 'P0001', message = 'DURATION_PRICING_NOT_CONFIGURED';
  end if;

  return jsonb_build_object(
    'source', 'SERVICE_FALLBACK',
    'tier_id', null,
    'min_blocks', null,
    'max_blocks', null,
    'unit_price', v_service.price_per_block,
    'base_price', round(v_service.price_per_block * p_duration_blocks, 2)
  );
end;
$$;

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
as $$
declare
  v_service public.services%rowtype;
  v_timezone text;
  v_price numeric := 0;
  v_dynamic_base numeric := 0;
  v_after_day_time numeric := 0;
  v_after_people numeric := 0;
  v_day_time_adjustment numeric := 0;
  v_people_adjustment numeric := 0;
  v_extras_total numeric := 0;
  v_subtotal numeric := 0;
  v_coupon_discount numeric := 0;
  v_commercial_value numeric := 0;
  v_coupon public.coupons%rowtype;
  v_local_ts timestamp without time zone;
  v_local_date date;
  v_local_time time without time zone;
  v_dow smallint;
  v_processed_extras integer := 0;
  v_requested_extras integer := 0;
  v_resource_ids uuid[] := '{}'::uuid[];
  v_contracted_minutes integer;
  v_profile jsonb;
  v_pre integer := 0;
  v_post integer := 0;
  v_pricing_version text;
  v_duration_pricing jsonb;
  v_unit_price numeric := 0;
  r record;
begin
  select * into v_service
  from public.services
  where id = p_service_id and is_active;

  if not found then
    raise exception using errcode = 'P0001', message = 'SERVICE_NOT_AVAILABLE';
  end if;

  if not exists (
    select 1 from public.service_employees se
    where se.id = p_service_employee_id
      and se.service_id = p_service_id
      and se.is_active
  ) then
    raise exception using errcode = 'P0001', message = 'EMPLOYEE_NOT_AVAILABLE_FOR_SERVICE';
  end if;

  v_contracted_minutes := public.resolve_service_contracted_minutes(p_service_id, p_duration_blocks);

  if v_service.duration_mode = 'FIXED' then
    return public.calculate_booking_quote(
      p_service_id,
      p_service_employee_id,
      p_extra_selections,
      p_people_count,
      p_requested_start_at,
      p_coupon_code
    ) || jsonb_build_object(
      'duration_mode', 'FIXED',
      'duration_blocks', null,
      'contracted_minutes', v_contracted_minutes,
      'buffer_before_minutes', v_service.buffer_before_minutes,
      'buffer_after_minutes', v_service.buffer_after_minutes
    );
  end if;

  if p_people_count < v_service.minimum_people or p_people_count > v_service.maximum_people then
    raise exception using errcode = 'P0001', message = 'INVALID_PEOPLE_COUNT';
  end if;

  if jsonb_typeof(coalesce(p_extra_selections, '[]'::jsonb)) <> 'array' then
    raise exception using errcode = 'P0001', message = 'INVALID_EXTRA';
  end if;

  select count(*) into v_requested_extras
  from jsonb_array_elements(coalesce(p_extra_selections, '[]'::jsonb));

  if exists (
    select 1
    from jsonb_to_recordset(coalesce(p_extra_selections, '[]'::jsonb)) x(extra_id uuid, quantity integer)
    group by x.extra_id having count(*) > 1
  ) then
    raise exception using errcode = 'P0001', message = 'INVALID_EXTRA';
  end if;

  v_duration_pricing := public.resolve_service_duration_pricing(p_service_id, p_duration_blocks);
  v_unit_price := (v_duration_pricing->>'unit_price')::numeric;
  v_dynamic_base := (v_duration_pricing->>'base_price')::numeric;
  v_price := v_dynamic_base;

  for r in
    select e.id, e.price, x.quantity, se.max_quantity
    from jsonb_to_recordset(coalesce(p_extra_selections, '[]'::jsonb)) x(extra_id uuid, quantity integer)
    join public.service_extras se on se.service_id = p_service_id and se.extra_id = x.extra_id
    join public.extras e on e.id = x.extra_id and e.is_active
  loop
    if r.quantity is null or r.quantity < 1 or r.quantity > r.max_quantity then
      raise exception using errcode = 'P0001', message = 'INVALID_EXTRA_QUANTITY';
    end if;
    v_processed_extras := v_processed_extras + 1;
    v_extras_total := v_extras_total + (r.price * r.quantity);
  end loop;

  if v_processed_extras <> v_requested_extras then
    raise exception using errcode = 'P0001', message = 'INVALID_EXTRA';
  end if;

  select timezone into v_timezone from public.operation_settings where id = 1;

  if p_requested_start_at is not null then
    v_local_ts := p_requested_start_at at time zone v_timezone;
    v_local_date := v_local_ts::date;
    v_local_time := v_local_ts::time;
    v_dow := extract(dow from v_local_ts)::smallint;

    for r in
      select pr.*
      from public.pricing_rules pr
      where pr.service_id = p_service_id
        and pr.is_active
        and pr.rule_scope = 'DAY_TIME'
        and (pr.valid_from_date is null or v_local_date >= pr.valid_from_date)
        and (pr.valid_until_date is null or v_local_date <= pr.valid_until_date)
        and (pr.days_of_week is null or v_dow = any(pr.days_of_week))
        and (pr.start_local_time is null or v_local_time >= pr.start_local_time)
        and (pr.end_local_time is null or v_local_time < pr.end_local_time)
      order by pr.priority, pr.id
    loop
      if r.action_type = 'REPLACE_PRICE' then
        v_price := r.amount;
      elsif r.action_type = 'ADD_AMOUNT' then
        v_price := v_price + r.amount;
      elsif r.action_type = 'ADD_PERCENT' then
        v_price := v_price * (1 + (r.percentage / 100));
      end if;
    end loop;
  end if;

  v_after_day_time := round(greatest(v_price, 0), 2);
  v_day_time_adjustment := v_after_day_time - v_dynamic_base;
  v_price := v_after_day_time;

  for r in
    select pr.*
    from public.pricing_rules pr
    where pr.service_id = p_service_id
      and pr.is_active
      and pr.rule_scope = 'PEOPLE'
      and p_people_count between pr.min_people and pr.max_people
      and (pr.valid_from_date is null or coalesce(v_local_date, current_date) >= pr.valid_from_date)
      and (pr.valid_until_date is null or coalesce(v_local_date, current_date) <= pr.valid_until_date)
    order by pr.priority, pr.id
  loop
    if r.action_type = 'REPLACE_PRICE' then
      v_price := r.amount;
    elsif r.action_type = 'ADD_AMOUNT' then
      v_price := v_price + r.amount;
    elsif r.action_type = 'ADD_PERCENT' then
      v_price := v_price * (1 + (r.percentage / 100));
    end if;
  end loop;

  v_after_people := round(greatest(v_price, 0), 2);
  v_people_adjustment := v_after_people - v_after_day_time;
  v_extras_total := round(v_extras_total, 2);
  v_subtotal := round(greatest(v_after_people + v_extras_total, 0), 2);

  if p_coupon_code is not null and btrim(p_coupon_code) <> '' then
    select c.* into v_coupon
    from public.coupons c
    where lower(c.code) = lower(btrim(p_coupon_code))
      and c.is_active
      and (c.valid_from is null or coalesce(p_requested_start_at, now()) >= c.valid_from)
      and (c.valid_until is null or coalesce(p_requested_start_at, now()) <= c.valid_until)
      and (
        not exists (select 1 from public.coupon_services cs where cs.coupon_id = c.id)
        or exists (select 1 from public.coupon_services cs where cs.coupon_id = c.id and cs.service_id = p_service_id)
      )
    limit 1;

    if not found then
      raise exception using errcode = 'P0001', message = 'INVALID_COUPON';
    end if;

    if v_coupon.discount_type = 'FIXED' then
      v_coupon_discount := least(v_coupon.discount_value, v_subtotal);
    else
      v_coupon_discount := round(v_subtotal * (v_coupon.discount_value / 100), 2);
    end if;
  end if;

  v_coupon_discount := round(v_coupon_discount, 2);
  v_commercial_value := round(greatest(v_subtotal - v_coupon_discount, 0), 2);

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

  v_profile := public.resolve_extra_schedule_profile(p_service_id, p_extra_selections, p_requested_start_at);
  v_pre := coalesce((v_profile->>'pre_service_minutes')::integer, 0);
  v_post := coalesce((v_profile->>'post_service_minutes')::integer, 0);

  select md5(concat_ws('|',
    v_service.updated_at::text,
    p_duration_blocks::text,
    v_dynamic_base::text,
    coalesce((select max(updated_at)::text from public.service_duration_pricing_tiers where service_id = p_service_id), ''),
    coalesce((select max(updated_at)::text from public.pricing_rules where service_id = p_service_id), ''),
    coalesce((select max(e.updated_at)::text
      from jsonb_to_recordset(coalesce(p_extra_selections, '[]'::jsonb)) x(extra_id uuid, quantity integer)
      join public.extras e on e.id = x.extra_id), ''),
    coalesce(v_coupon.updated_at::text, ''),
    coalesce(v_profile->>'schedule_version', '')
  )) into v_pricing_version;

  return jsonb_build_object(
    'service_id', p_service_id,
    'service_employee_id', p_service_employee_id,
    'duration_mode', 'BLOCKS',
    'duration_blocks', p_duration_blocks,
    'booking_block_minutes', v_service.booking_block_minutes,
    'contracted_minutes', v_contracted_minutes,
    'core_duration_minutes', v_contracted_minutes,
    'pre_service_minutes', v_pre,
    'post_service_minutes', v_post,
    'duration_minutes', v_contracted_minutes + v_pre + v_post,
    'buffer_before_minutes', v_service.buffer_before_minutes,
    'buffer_after_minutes', v_service.buffer_after_minutes,
    'resource_ids', to_jsonb(v_resource_ids),
    'base_price', v_dynamic_base,
    'duration_unit_price', v_unit_price,
    'duration_pricing_source', v_duration_pricing->>'source',
    'duration_pricing_tier_id', v_duration_pricing->'tier_id',
    'day_time_adjustment', round(v_day_time_adjustment, 2),
    'people_adjustment', round(v_people_adjustment, 2),
    'extras_total', v_extras_total,
    'coupon_discount', v_coupon_discount,
    'commercial_value', v_commercial_value,
    'schedule_profile', v_profile,
    'pricing_version', v_pricing_version
  );
end;
$$;

-- Public catalog exposes active pricing tiers and recommendation presets as read-only
-- data. The authoritative quote still comes from calculate_booking_quote_for_duration.
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
        'duration_pricing_tiers', coalesce((
          select jsonb_agg(jsonb_build_object(
            'id', t.id,
            'min_blocks', t.min_blocks,
            'max_blocks', t.max_blocks,
            'price_per_block', t.price_per_block
          ) order by t.sort_order, t.min_blocks, t.id)
          from public.service_duration_pricing_tiers t
          where t.service_id = s.id and t.is_active
        ), '[]'::jsonb),
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

revoke all on function public.resolve_service_duration_pricing(uuid,integer) from public, anon, authenticated;
grant execute on function public.resolve_service_duration_pricing(uuid,integer) to service_role;

comment on table public.service_duration_pricing_tiers is
  'Authoritative block-duration pricing ranges. No overlap is allowed per active service.';
comment on table public.service_duration_presets is
  'Editorial duration shortcuts such as 1h/2h/4h/8h. They do not determine price.';
