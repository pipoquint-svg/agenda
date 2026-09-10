-- Sabrina public booking page must automatically expose every active service
-- from the active `ensaios` category, while preserving explicit page-service
-- assignments for backwards compatibility and all other booking pages.

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
        'included_people', s.included_people,
        'maximum_people', s.maximum_people,
        'price_per_extra_person', s.price_per_extra_person,
        'people_options', coalesce((
          select jsonb_agg(
            jsonb_build_object(
              'count', g,
              'included', (g <= s.included_people),
              'extra_people_count', greatest(g - s.included_people, 0),
              'extra_people_amount', round(greatest(g - s.included_people, 0) * s.price_per_extra_person, 2)
            ) order by g
          )
          from generate_series(s.minimum_people, s.maximum_people) g
        ), '[]'::jsonb),
        'requires_terms', s.requires_terms,
        'duration_pricing_tiers', coalesce((
          select jsonb_agg(
            jsonb_build_object(
              'id', t.id,
              'min_blocks', t.min_blocks,
              'max_blocks', t.max_blocks,
              'price_per_block', t.price_per_block
            ) order by t.sort_order, t.min_blocks, t.id
          )
          from public.service_duration_pricing_tiers t
          where t.service_id = s.id and t.is_active
        ), '[]'::jsonb),
        'duration_presets', coalesce((
          select jsonb_agg(
            jsonb_build_object(
              'id', p.id,
              'block_count', p.block_count,
              'title', p.title,
              'description', p.description,
              'badge', p.badge,
              'is_featured', p.is_featured
            ) order by p.sort_order, p.block_count, p.id
          )
          from public.service_duration_presets p
          where p.service_id = s.id and p.is_active
        ), '[]'::jsonb),
        'duration_guidance', coalesce((
          select jsonb_agg(
            jsonb_build_object(
              'id', g.id,
              'min_blocks', g.min_blocks,
              'max_blocks', g.max_blocks,
              'title', g.title,
              'description', g.description
            ) order by g.sort_order, g.min_blocks, g.id
          )
          from public.service_duration_guidance_ranges g
          where g.service_id = s.id and g.is_active
        ), '[]'::jsonb),
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
      ) order by
        case when bps.service_id is not null then bps.sort_order else s.sort_order end,
        s.sort_order,
        s.name
    )
    from public.services s
    left join public.categories c
      on c.id = s.category_id
    left join public.booking_page_services bps
      on bps.booking_page_id = bp.id
     and bps.service_id = s.id
     and bps.is_active
    where s.is_active
      and (
        bps.service_id is not null
        or (
          bp.slug = 'sabrina'
          and c.slug = 'ensaios'
          and c.is_active
        )
      )
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
  if jsonb_typeof(coalesce(p_extra_selections, '[]'::jsonb)) <> 'array' then
    raise exception using errcode = 'P0001', message = 'INVALID_EXTRA';
  end if;

  if not exists (
    select 1
    from public.booking_pages bp
    left join public.services page_service
      on page_service.id = p_service_id
    left join public.categories c
      on c.id = page_service.category_id
    left join public.booking_page_services bps
      on bps.booking_page_id = bp.id
     and bps.service_id = p_service_id
     and bps.is_active
    where bp.slug = lower(btrim(p_booking_page_slug))
      and bp.is_active
      and (
        bps.service_id is not null
        or (
          bp.slug = 'sabrina'
          and c.slug = 'ensaios'
          and c.is_active
        )
      )
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

  if exists (
    select 1
    from jsonb_to_recordset(coalesce(p_extra_selections, '[]'::jsonb)) x(extra_id uuid, quantity integer)
    group by x.extra_id
    having count(*) > 1
  ) then
    raise exception using errcode = 'P0001', message = 'INVALID_EXTRA';
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

  if exists (
    select 1
    from public.service_extras se
    join public.extras e on e.id = se.extra_id and e.is_active
    where se.service_id = p_service_id
      and se.is_required
      and not exists (
        select 1
        from jsonb_to_recordset(coalesce(p_extra_selections, '[]'::jsonb)) x(extra_id uuid, quantity integer)
        where x.extra_id = se.extra_id
          and x.quantity between 1 and se.max_quantity
      )
  ) then
    raise exception using errcode = 'P0001', message = 'REQUIRED_EXTRA_MISSING';
  end if;
end;
$$;

create or replace function public.public_create_service_waitlist_entry(
  p_booking_page_slug text,
  p_service_id uuid,
  p_name text,
  p_email text,
  p_whatsapp text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_page_id uuid;
  v_service_name text;
  v_operation_scope text;
  v_duration_mode text;
  v_name text := btrim(coalesce(p_name,''));
  v_email text := lower(btrim(coalesce(p_email,'')));
  v_whatsapp text := btrim(coalesce(p_whatsapp,''));
  v_whatsapp_normalized text := regexp_replace(coalesce(p_whatsapp,''),'[^0-9]','','g');
  v_customer_id uuid;
  v_entry public.service_waitlist_entries%rowtype;
begin
  if length(v_name) < 2 or length(v_name) > 160 then
    raise exception using errcode='P0001',message='WAITLIST_NAME_INVALID';
  end if;
  if length(v_email) > 320 or v_email !~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then
    raise exception using errcode='P0001',message='WAITLIST_EMAIL_INVALID';
  end if;
  if length(v_whatsapp) > 40 or length(v_whatsapp_normalized) < 10 or length(v_whatsapp_normalized) > 15 then
    raise exception using errcode='P0001',message='WAITLIST_WHATSAPP_INVALID';
  end if;

  select bp.id, s.name, s.operation_scope, s.duration_mode
    into v_page_id, v_service_name, v_operation_scope, v_duration_mode
  from public.booking_pages bp
  join public.services s
    on s.id = p_service_id and s.is_active
  left join public.categories c
    on c.id = s.category_id
  left join public.booking_page_services bps
    on bps.booking_page_id = bp.id
   and bps.service_id = s.id
   and bps.is_active
  where bp.slug = lower(btrim(coalesce(p_booking_page_slug,'')))
    and bp.is_active
    and (
      bps.service_id is not null
      or (
        bp.slug = 'sabrina'
        and c.slug = 'ensaios'
        and c.is_active
      )
    );

  if not found then raise exception using errcode='P0001',message='PUBLIC_SERVICE_NOT_AVAILABLE_ON_PAGE'; end if;
  if v_duration_mode <> 'FIXED' then raise exception using errcode='P0001',message='WAITLIST_FIXED_ONLY'; end if;

  select c.id into v_customer_id
  from public.customers c
  where c.anonymized_at is null
    and (
      lower(btrim(coalesce(c.email,''))) = v_email
      or regexp_replace(coalesce(c.phone,''),'[^0-9]','','g') = v_whatsapp_normalized
    )
  order by case when lower(btrim(coalesce(c.email,''))) = v_email then 0 else 1 end, c.created_at, c.id
  limit 1;

  begin
    insert into public.service_waitlist_entries(
      booking_page_id, service_id, name, email, email_normalized, whatsapp, whatsapp_normalized, customer_id
    ) values (
      v_page_id, p_service_id, v_name, v_email, v_email, v_whatsapp, v_whatsapp_normalized, v_customer_id
    ) returning * into v_entry;
  exception when unique_violation then
    raise exception using errcode='P0001',message='WAITLIST_ALREADY_REGISTERED';
  end;

  insert into public.notification_delivery_logs(
    event_key, channel, audience, customer_id, status, attempt_count, idempotency_key, payload_snapshot
  ) values (
    'WAITLIST_SIGNUP_TEAM','EMAIL','EMPLOYEE',v_customer_id,'PENDING',0,
    'waitlist:'||v_entry.id::text||':team',
    jsonb_build_object(
      'waitlist_entry_id',v_entry.id,
      'service_id',p_service_id,
      'service_name',v_service_name,
      'operation_scope',v_operation_scope,
      'name',v_name,
      'email',v_email,
      'whatsapp',v_whatsapp,
      'created_at',v_entry.created_at
    )
  );

  return jsonb_build_object(
    'id',v_entry.id,
    'service_id',p_service_id,
    'service_name',v_service_name,
    'operation_scope',v_operation_scope,
    'customer_id',v_customer_id,
    'created_at',v_entry.created_at,
    'notification_idempotency_key','waitlist:'||v_entry.id::text||':team'
  );
end;
$$;

create or replace function public.public_create_service_waitlist_entry_v2(
  p_booking_page_slug text,
  p_service_id uuid,
  p_name text,
  p_email text,
  p_whatsapp text,
  p_preferred_date date default null::date
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_page_id uuid;
  v_service_name text;
  v_operation_scope text;
  v_duration_mode text;
  v_name text := btrim(coalesce(p_name,''));
  v_email text := lower(btrim(coalesce(p_email,'')));
  v_whatsapp text := btrim(coalesce(p_whatsapp,''));
  v_whatsapp_normalized text := regexp_replace(coalesce(p_whatsapp,''),'[^0-9]','','g');
  v_customer_id uuid;
  v_entry public.service_waitlist_entries%rowtype;
  v_existing_ids uuid[];
  v_changed boolean := false;
  v_notification_key text;
begin
  if length(v_name) < 2 or length(v_name) > 160 then
    raise exception using errcode='P0001',message='WAITLIST_NAME_INVALID';
  end if;
  if length(v_email) > 320 or v_email !~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then
    raise exception using errcode='P0001',message='WAITLIST_EMAIL_INVALID';
  end if;
  if length(v_whatsapp) > 40 or length(v_whatsapp_normalized) < 10 or length(v_whatsapp_normalized) > 15 then
    raise exception using errcode='P0001',message='WAITLIST_WHATSAPP_INVALID';
  end if;

  select bp.id, s.name, s.operation_scope, s.duration_mode
    into v_page_id, v_service_name, v_operation_scope, v_duration_mode
  from public.booking_pages bp
  join public.services s
    on s.id = p_service_id and s.is_active
  left join public.categories c
    on c.id = s.category_id
  left join public.booking_page_services bps
    on bps.booking_page_id = bp.id
   and bps.service_id = s.id
   and bps.is_active
  where bp.slug = lower(btrim(coalesce(p_booking_page_slug,'')))
    and bp.is_active
    and (
      bps.service_id is not null
      or (
        bp.slug = 'sabrina'
        and c.slug = 'ensaios'
        and c.is_active
      )
    );

  if not found then raise exception using errcode='P0001',message='PUBLIC_SERVICE_NOT_AVAILABLE_ON_PAGE'; end if;
  if v_duration_mode <> 'FIXED' then raise exception using errcode='P0001',message='WAITLIST_FIXED_ONLY'; end if;

  select coalesce(array_agg(w.id order by w.created_at,w.id),'{}'::uuid[])
    into v_existing_ids
  from public.service_waitlist_entries w
  where w.service_id = p_service_id
    and (w.email_normalized = v_email or w.whatsapp_normalized = v_whatsapp_normalized);

  if cardinality(v_existing_ids) > 1 then
    raise exception using errcode='P0001',message='WAITLIST_IDENTITY_CONFLICT';
  end if;

  if cardinality(v_existing_ids) = 1 then
    select * into v_entry
    from public.service_waitlist_entries
    where id = v_existing_ids[1]
    for update;

    if p_preferred_date is not null and not (p_preferred_date = any(coalesce(v_entry.preferred_dates,'{}'::date[]))) then
      update public.service_waitlist_entries
      set preferred_dates = (
        select array_agg(d order by d)
        from (
          select distinct unnest(coalesce(v_entry.preferred_dates,'{}'::date[]) || array[p_preferred_date]) as d
        ) q
      )
      where id = v_entry.id
      returning * into v_entry;
      v_changed := true;
    end if;
  else
    select c.id into v_customer_id
    from public.customers c
    where c.anonymized_at is null
      and (
        lower(btrim(coalesce(c.email,''))) = v_email
        or regexp_replace(coalesce(c.phone,''),'[^0-9]','','g') = v_whatsapp_normalized
      )
    order by case when lower(btrim(coalesce(c.email,''))) = v_email then 0 else 1 end, c.created_at, c.id
    limit 1;

    insert into public.service_waitlist_entries(
      booking_page_id, service_id, name, email, email_normalized, whatsapp, whatsapp_normalized, customer_id, preferred_dates
    ) values (
      v_page_id,p_service_id,v_name,v_email,v_email,v_whatsapp,v_whatsapp_normalized,v_customer_id,
      case when p_preferred_date is null then '{}'::date[] else array[p_preferred_date] end
    ) returning * into v_entry;
    v_changed := true;
  end if;

  v_notification_key := 'waitlist:'||v_entry.id::text||':team:'||coalesce(to_char(p_preferred_date,'YYYY-MM-DD'),'general');

  if v_changed then
    insert into public.notification_delivery_logs(
      event_key, channel, audience, customer_id, status, attempt_count, idempotency_key, payload_snapshot
    ) values (
      'WAITLIST_SIGNUP_TEAM','EMAIL','EMPLOYEE',v_entry.customer_id,'PENDING',0,
      v_notification_key,
      jsonb_build_object(
        'waitlist_entry_id',v_entry.id,
        'service_id',p_service_id,
        'service_name',v_service_name,
        'operation_scope',v_operation_scope,
        'name',v_entry.name,
        'email',v_entry.email,
        'whatsapp',v_entry.whatsapp,
        'preferred_dates',v_entry.preferred_dates,
        'created_at',v_entry.created_at
      )
    ) on conflict (idempotency_key) do nothing;
  end if;

  return jsonb_build_object(
    'id',v_entry.id,
    'service_id',p_service_id,
    'service_name',v_service_name,
    'operation_scope',v_operation_scope,
    'customer_id',v_entry.customer_id,
    'preferred_dates',to_jsonb(v_entry.preferred_dates),
    'preferred_date_added',v_changed,
    'created_at',v_entry.created_at,
    'notification_idempotency_key',v_notification_key
  );
end;
$$;
