create table public.availability_rules (
  id uuid primary key default gen_random_uuid(),
  service_employee_id uuid not null references public.service_employees(id) on delete cascade,
  weekday smallint not null check (weekday between 1 and 7),
  start_local_time time without time zone not null,
  end_local_time time without time zone not null,
  slot_interval_minutes integer not null default 30 check (slot_interval_minutes > 0),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (end_local_time > start_local_time)
);

create index availability_rules_lookup_idx
  on public.availability_rules (service_employee_id, weekday, start_local_time, end_local_time)
  where is_active;

create table public.resource_availability_rules (
  id uuid primary key default gen_random_uuid(),
  resource_id uuid not null references public.resources(id) on delete cascade,
  weekday smallint not null check (weekday between 1 and 7),
  start_local_time time without time zone not null,
  end_local_time time without time zone not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (end_local_time > start_local_time)
);

create index resource_availability_rules_lookup_idx
  on public.resource_availability_rules (resource_id, weekday, start_local_time, end_local_time)
  where is_active;

create table public.availability_exceptions (
  id uuid primary key default gen_random_uuid(),
  service_employee_id uuid references public.service_employees(id) on delete cascade,
  resource_id uuid references public.resources(id) on delete cascade,
  exception_type text not null check (exception_type in ('BLOCK','OPEN')),
  start_at timestamptz not null,
  end_at timestamptz not null,
  reason text,
  created_by_admin_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (end_at > start_at),
  check (
    (service_employee_id is not null and resource_id is null)
    or (service_employee_id is null and resource_id is not null)
  )
);

create index availability_exceptions_service_employee_idx
  on public.availability_exceptions (service_employee_id, start_at, end_at)
  where service_employee_id is not null;

create index availability_exceptions_resource_idx
  on public.availability_exceptions (resource_id, start_at, end_at)
  where resource_id is not null;

alter table public.checkout_holds
  add column extra_selections jsonb not null default '[]'::jsonb,
  add column commercial_value numeric(12,2) not null default 0 check (commercial_value >= 0),
  add column pricing_version text,
  add column duration_minutes integer check (duration_minutes is null or duration_minutes > 0),
  add column resource_ids uuid[] not null default '{}'::uuid[];

create or replace function public.expire_due_checkout_holds()
returns void
language plpgsql
volatile
set search_path = public
as $$
declare
  v_hold record;
begin
  for v_hold in
    select ch.id
    from public.checkout_holds ch
    where ch.status = 'ACTIVE'
      and ch.expires_at <= now()
    for update skip locked
  loop
    update public.checkout_holds
    set status = 'EXPIRED', updated_at = now()
    where id = v_hold.id;

    update public.resource_allocations
    set status = 'EXPIRED', updated_at = now()
    where checkout_hold_id = v_hold.id
      and status = 'HELD';
  end loop;
end;
$$;

create or replace function public.list_available_slots(
  p_service_id uuid,
  p_service_employee_id uuid,
  p_extra_selections jsonb default '[]'::jsonb,
  p_people_count integer default 1,
  p_local_date date default current_date,
  p_coupon_code text default null
)
returns table (
  slot_start_at timestamptz,
  slot_end_at timestamptz,
  duration_minutes integer,
  commercial_value numeric(12,2)
)
language plpgsql
stable
set search_path = public, extensions
as $$
declare
  v_service public.services%rowtype;
  v_timezone text;
  v_base_quote jsonb;
  v_duration integer;
  v_buffer_before integer;
  v_buffer_after integer;
  v_resource_ids uuid[] := '{}'::uuid[];
  v_slot_interval integer := 30;
  v_isodow smallint;
  v_candidate_local timestamp without time zone;
  v_candidate_start timestamptz;
  v_candidate_end timestamptz;
  v_occupied tstzrange;
  v_quote jsonb;
  v_resource_id uuid;
  v_resource_ok boolean;
  v_service_window_ok boolean;
begin
  select s.* into v_service
  from public.services s
  where s.id = p_service_id
    and s.is_active;

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

  select os.timezone into v_timezone
  from public.operation_settings os
  where os.id = 1;

  v_base_quote := public.calculate_booking_quote(
    p_service_id,
    p_service_employee_id,
    p_extra_selections,
    p_people_count,
    null,
    p_coupon_code
  );

  v_duration := (v_base_quote->>'duration_minutes')::integer;
  v_buffer_before := (v_base_quote->>'buffer_before_minutes')::integer;
  v_buffer_after := (v_base_quote->>'buffer_after_minutes')::integer;

  select coalesce(array_agg(value::uuid), '{}'::uuid[])
  into v_resource_ids
  from jsonb_array_elements_text(v_base_quote->'resource_ids');

  v_isodow := extract(isodow from p_local_date)::smallint;

  select coalesce(min(ar.slot_interval_minutes), 30)
  into v_slot_interval
  from public.availability_rules ar
  where ar.service_employee_id = p_service_employee_id
    and ar.weekday = v_isodow
    and ar.is_active;

  for v_candidate_local in
    select gs
    from generate_series(
      p_local_date::timestamp,
      (p_local_date + 1)::timestamp - interval '1 minute',
      make_interval(mins => v_slot_interval)
    ) as gs
  loop
    v_candidate_start := v_candidate_local at time zone v_timezone;
    v_candidate_end := v_candidate_start + make_interval(mins => v_duration);
    v_occupied := tstzrange(
      v_candidate_start - make_interval(mins => v_buffer_before),
      v_candidate_end + make_interval(mins => v_buffer_after),
      '[)'
    );

    if v_candidate_start < now() + make_interval(mins => v_service.minimum_booking_notice_minutes) then
      continue;
    end if;

    if v_candidate_start > now() + make_interval(days => v_service.maximum_booking_horizon_days) then
      continue;
    end if;

    select (
      exists (
        select 1
        from public.availability_rules ar
        where ar.service_employee_id = p_service_employee_id
          and ar.weekday = v_isodow
          and ar.is_active
          and tstzrange(
            (p_local_date + ar.start_local_time) at time zone v_timezone,
            (p_local_date + ar.end_local_time) at time zone v_timezone,
            '[)'
          ) @> tstzrange(v_candidate_start, v_candidate_end, '[)')
      )
      or exists (
        select 1
        from public.availability_exceptions ae
        where ae.service_employee_id = p_service_employee_id
          and ae.exception_type = 'OPEN'
          and tstzrange(ae.start_at, ae.end_at, '[)') @> tstzrange(v_candidate_start, v_candidate_end, '[)')
      )
    ) into v_service_window_ok;

    if not v_service_window_ok then
      continue;
    end if;

    if exists (
      select 1
      from public.availability_exceptions ae
      where ae.service_employee_id = p_service_employee_id
        and ae.exception_type = 'BLOCK'
        and tstzrange(ae.start_at, ae.end_at, '[)') && v_occupied
    ) then
      continue;
    end if;

    v_resource_ok := true;

    foreach v_resource_id in array v_resource_ids
    loop
      if exists (
        select 1
        from public.resource_availability_rules rar
        where rar.resource_id = v_resource_id
          and rar.weekday = v_isodow
          and rar.is_active
      ) then
        if not (
          exists (
            select 1
            from public.resource_availability_rules rar
            where rar.resource_id = v_resource_id
              and rar.weekday = v_isodow
              and rar.is_active
              and tstzrange(
                (p_local_date + rar.start_local_time) at time zone v_timezone,
                (p_local_date + rar.end_local_time) at time zone v_timezone,
                '[)'
              ) @> v_occupied
          )
          or exists (
            select 1
            from public.availability_exceptions ae
            where ae.resource_id = v_resource_id
              and ae.exception_type = 'OPEN'
              and tstzrange(ae.start_at, ae.end_at, '[)') @> v_occupied
          )
        ) then
          v_resource_ok := false;
          exit;
        end if;
      end if;

      if exists (
        select 1
        from public.availability_exceptions ae
        where ae.resource_id = v_resource_id
          and ae.exception_type = 'BLOCK'
          and tstzrange(ae.start_at, ae.end_at, '[)') && v_occupied
      ) then
        v_resource_ok := false;
        exit;
      end if;
    end loop;

    if not v_resource_ok then
      continue;
    end if;

    if exists (
      select 1
      from public.resource_allocations ra
      where ra.resource_id = any(v_resource_ids)
        and ra.status in ('HELD','AWAITING_PAYMENT','CONFIRMED','BLOCKED','EXTERNAL_ACTIVE')
        and ra.occupied_range && v_occupied
    ) then
      continue;
    end if;

    v_quote := public.calculate_booking_quote(
      p_service_id,
      p_service_employee_id,
      p_extra_selections,
      p_people_count,
      v_candidate_start,
      p_coupon_code
    );

    slot_start_at := v_candidate_start;
    slot_end_at := v_candidate_end;
    duration_minutes := v_duration;
    commercial_value := (v_quote->>'commercial_value')::numeric(12,2);
    return next;
  end loop;
end;
$$;

create or replace function public.create_checkout_hold(
  p_service_id uuid,
  p_service_employee_id uuid,
  p_extra_selections jsonb,
  p_people_count integer,
  p_requested_start_at timestamptz
)
returns jsonb
language plpgsql
volatile
set search_path = public, extensions
as $$
declare
  v_quote jsonb;
  v_duration integer;
  v_buffer_before integer;
  v_buffer_after integer;
  v_end_at timestamptz;
  v_occupied tstzrange;
  v_resource_ids uuid[] := '{}'::uuid[];
  v_resource_id uuid;
  v_hold_id uuid;
  v_raw_token text;
  v_token_hash text;
  v_selection_hash text;
  v_canonical_extras jsonb;
  v_expires_at timestamptz;
  v_hold_minutes integer;
begin
  perform public.expire_due_checkout_holds();

  select coalesce(
    jsonb_agg(
      jsonb_build_object('extra_id', x.extra_id, 'quantity', x.quantity)
      order by x.extra_id
    ),
    '[]'::jsonb
  )
  into v_canonical_extras
  from jsonb_to_recordset(coalesce(p_extra_selections, '[]'::jsonb)) as x(extra_id uuid, quantity integer);

  if not exists (
    select 1
    from public.list_available_slots(
      p_service_id,
      p_service_employee_id,
      v_canonical_extras,
      p_people_count,
      (p_requested_start_at at time zone (select timezone from public.operation_settings where id = 1))::date,
      null
    ) s
    where s.slot_start_at = p_requested_start_at
  ) then
    raise exception using errcode = 'P0001', message = 'SLOT_NO_LONGER_AVAILABLE';
  end if;

  v_quote := public.calculate_booking_quote(
    p_service_id,
    p_service_employee_id,
    v_canonical_extras,
    p_people_count,
    p_requested_start_at,
    null
  );

  v_duration := (v_quote->>'duration_minutes')::integer;
  v_buffer_before := (v_quote->>'buffer_before_minutes')::integer;
  v_buffer_after := (v_quote->>'buffer_after_minutes')::integer;
  v_end_at := p_requested_start_at + make_interval(mins => v_duration);
  v_occupied := tstzrange(
    p_requested_start_at - make_interval(mins => v_buffer_before),
    v_end_at + make_interval(mins => v_buffer_after),
    '[)'
  );

  select coalesce(array_agg(value::uuid), '{}'::uuid[])
  into v_resource_ids
  from jsonb_array_elements_text(v_quote->'resource_ids');

  select coalesce(s.checkout_hold_minutes, os.checkout_hold_minutes)
  into v_hold_minutes
  from public.services s
  cross join public.operation_settings os
  where s.id = p_service_id
    and os.id = 1;

  v_expires_at := now() + make_interval(mins => v_hold_minutes);
  v_raw_token := encode(gen_random_bytes(32), 'hex');
  v_token_hash := encode(digest(v_raw_token, 'sha256'), 'hex');
  v_selection_hash := md5(concat_ws('|',
    p_service_id::text,
    p_service_employee_id::text,
    v_canonical_extras::text,
    p_people_count::text,
    p_requested_start_at::text,
    v_quote->>'pricing_version'
  ));

  insert into public.checkout_holds (
    public_token_hash,
    service_id,
    service_employee_id,
    selection_hash,
    people_count,
    requested_start_at,
    requested_end_at,
    status,
    expires_at,
    extra_selections,
    commercial_value,
    pricing_version,
    duration_minutes,
    resource_ids
  ) values (
    v_token_hash,
    p_service_id,
    p_service_employee_id,
    v_selection_hash,
    p_people_count,
    p_requested_start_at,
    v_end_at,
    'ACTIVE',
    v_expires_at,
    v_canonical_extras,
    (v_quote->>'commercial_value')::numeric(12,2),
    v_quote->>'pricing_version',
    v_duration,
    v_resource_ids
  ) returning id into v_hold_id;

  begin
    foreach v_resource_id in array v_resource_ids
    loop
      insert into public.resource_allocations (
        resource_id,
        checkout_hold_id,
        allocation_type,
        status,
        occupied_range
      ) values (
        v_resource_id,
        v_hold_id,
        'CHECKOUT_HOLD',
        'HELD',
        v_occupied
      );
    end loop;
  exception
    when exclusion_violation then
      raise exception using errcode = 'P0001', message = 'SLOT_NO_LONGER_AVAILABLE';
  end;

  return jsonb_build_object(
    'checkout_hold_token', v_raw_token,
    'checkout_hold_id', v_hold_id,
    'status', 'ACTIVE',
    'expires_at', v_expires_at,
    'commercial_value', (v_quote->>'commercial_value')::numeric(12,2),
    'duration_minutes', v_duration,
    'pricing_version', v_quote->>'pricing_version'
  );
end;
$$;
