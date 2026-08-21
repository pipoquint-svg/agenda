-- Public booking pages and secure anonymous wrappers.
-- Core scheduling functions remain authoritative but are no longer directly exposed
-- to anon/authenticated callers.

create table public.booking_pages (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique,
  display_name text not null,
  title text not null,
  subtitle text,
  brand_key text not null,
  logo_url text,
  accent_color text,
  is_active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (slug = lower(slug)),
  check (slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'),
  check (accent_color is null or accent_color ~ '^#[0-9A-Fa-f]{6}$')
);

create table public.booking_page_services (
  booking_page_id uuid not null references public.booking_pages(id) on delete cascade,
  service_id uuid not null references public.services(id) on delete cascade,
  sort_order integer not null default 0,
  is_active boolean not null default true,
  primary key (booking_page_id, service_id)
);

create index booking_page_services_page_idx
  on public.booking_page_services (booking_page_id, is_active, sort_order);

alter table public.booking_pages enable row level security;
alter table public.booking_page_services enable row level security;

revoke all on public.booking_pages from anon, authenticated;
revoke all on public.booking_page_services from anon, authenticated;
grant all on public.booking_pages to service_role;
grant all on public.booking_page_services to service_role;

-- Known public surfaces. Services are assigned administratively later; no service
-- is guessed or auto-attached to the wrong brand.
insert into public.booking_pages (slug, display_name, title, subtitle, brand_key, sort_order)
values
  ('sabrina', 'Sabrina Pierri', 'Agende seu ensaio', 'Escolha o serviço e encontre o melhor horário para você.', 'SABRINA', 10),
  ('blacksheep', 'BlackSheep Estúdio Criativo', 'Reserve o estúdio', 'Monte sua locação e consulte horários realmente disponíveis.', 'BLACKSHEEP', 20)
on conflict (slug) do nothing;

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
    where bps.booking_page_id = bp.id
      and bps.is_active
  ), '[]'::jsonb)
)
from public.booking_pages bp
where bp.slug = lower(btrim(p_slug))
  and bp.is_active;
$$;

create or replace function public.assert_public_booking_selection(
  p_booking_page_slug text,
  p_service_id uuid,
  p_service_employee_id uuid,
  p_extra_selections jsonb default '[]'::jsonb,
  p_people_count integer default 1
)
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_service public.services%rowtype;
  v_extra record;
begin
  if not exists (
    select 1
    from public.booking_pages bp
    join public.booking_page_services bps
      on bps.booking_page_id = bp.id and bps.is_active
    where bp.slug = lower(btrim(p_booking_page_slug))
      and bp.is_active
      and bps.service_id = p_service_id
  ) then
    raise exception using errcode = 'P0001', message = 'PUBLIC_SERVICE_NOT_AVAILABLE_ON_PAGE';
  end if;

  select * into v_service
  from public.services
  where id = p_service_id and is_active;

  if not found then
    raise exception using errcode = 'P0001', message = 'SERVICE_NOT_AVAILABLE';
  end if;

  if p_people_count < v_service.minimum_people or p_people_count > v_service.maximum_people then
    raise exception using errcode = 'P0001', message = 'INVALID_PEOPLE_COUNT';
  end if;

  if not exists (
    select 1
    from public.service_employees se
    join public.employees e on e.id = se.employee_id and e.is_active
    where se.id = p_service_employee_id
      and se.service_id = p_service_id
      and se.is_active
  ) then
    raise exception using errcode = 'P0001', message = 'EMPLOYEE_NOT_AVAILABLE_FOR_SERVICE';
  end if;

  for v_extra in
    select x.extra_id, x.quantity
    from jsonb_to_recordset(coalesce(p_extra_selections, '[]'::jsonb)) x(extra_id uuid, quantity integer)
  loop
    if not exists (
      select 1
      from public.service_extras se
      join public.extras e on e.id = se.extra_id and e.is_active
      where se.service_id = p_service_id
        and se.extra_id = v_extra.extra_id
        and v_extra.quantity between 1 and se.max_quantity
    ) then
      raise exception using errcode = 'P0001', message = 'INVALID_EXTRA';
    end if;
  end loop;
end;
$$;

create or replace function public.public_quote_booking(
  p_booking_page_slug text,
  p_service_id uuid,
  p_service_employee_id uuid,
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
  perform public.assert_public_booking_selection(
    p_booking_page_slug,
    p_service_id,
    p_service_employee_id,
    p_extra_selections,
    p_people_count
  );

  return public.calculate_booking_quote(
    p_service_id,
    p_service_employee_id,
    p_extra_selections,
    p_people_count,
    null,
    null
  );
end;
$$;

create or replace function public.public_list_available_slots(
  p_booking_page_slug text,
  p_service_id uuid,
  p_service_employee_id uuid,
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
  perform public.assert_public_booking_selection(
    p_booking_page_slug,
    p_service_id,
    p_service_employee_id,
    p_extra_selections,
    p_people_count
  );

  return query
  select *
  from public.list_available_slots(
    p_service_id,
    p_service_employee_id,
    p_extra_selections,
    p_people_count,
    p_local_date,
    null
  );
end;
$$;

create or replace function public.public_create_checkout_hold(
  p_booking_page_slug text,
  p_service_id uuid,
  p_service_employee_id uuid,
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
  perform public.assert_public_booking_selection(
    p_booking_page_slug,
    p_service_id,
    p_service_employee_id,
    p_extra_selections,
    p_people_count
  );

  return public.create_checkout_hold(
    p_service_id,
    p_service_employee_id,
    p_extra_selections,
    p_people_count,
    p_requested_start_at
  );
end;
$$;

-- Do not expose core mutation/query primitives directly to public web users.
revoke all on function public.calculate_booking_quote(uuid,uuid,jsonb,integer,timestamptz,text)
  from anon, authenticated;
revoke all on function public.list_available_slots(uuid,uuid,jsonb,integer,date,text)
  from anon, authenticated;
revoke all on function public.create_checkout_hold(uuid,uuid,jsonb,integer,timestamptz)
  from anon, authenticated;
revoke all on function public.assert_public_booking_selection(text,uuid,uuid,jsonb,integer)
  from public, anon, authenticated;

revoke all on function public.public_get_booking_page(text) from public;
revoke all on function public.public_quote_booking(text,uuid,uuid,jsonb,integer) from public;
revoke all on function public.public_list_available_slots(text,uuid,uuid,jsonb,integer,date) from public;
revoke all on function public.public_create_checkout_hold(text,uuid,uuid,jsonb,integer,timestamptz) from public;

grant execute on function public.public_get_booking_page(text) to anon, authenticated;
grant execute on function public.public_quote_booking(text,uuid,uuid,jsonb,integer) to anon, authenticated;
grant execute on function public.public_list_available_slots(text,uuid,uuid,jsonb,integer,date) to anon, authenticated;
grant execute on function public.public_create_checkout_hold(text,uuid,uuid,jsonb,integer,timestamptz) to anon, authenticated;

comment on function public.public_create_checkout_hold(text,uuid,uuid,jsonb,integer,timestamptz) is
  'Anonymous-safe booking entrypoint. Validates page/service/employee/extras before invoking the authoritative checkout hold transaction.';
