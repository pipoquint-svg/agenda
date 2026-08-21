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

revoke all on function public.assert_public_booking_selection(text,uuid,uuid,jsonb,integer)
  from public, anon, authenticated;
grant execute on function public.assert_public_booking_selection(text,uuid,uuid,jsonb,integer)
  to service_role;
