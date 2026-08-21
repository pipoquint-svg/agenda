create domain public.extra_schedule_placement as text
  check (value in ('PREPEND','APPEND'));

alter table public.service_extras
  add column schedule_placement public.extra_schedule_placement not null default 'APPEND',
  add column default_schedule_minutes integer,
  add column schedule_updated_at timestamptz not null default now(),
  add constraint service_extras_default_schedule_minutes_check
    check (default_schedule_minutes is null or default_schedule_minutes >= 0);

create table public.service_extra_schedule_rules (
  id uuid primary key default gen_random_uuid(),
  service_id uuid not null,
  extra_id uuid not null,
  days_of_week smallint[],
  anchor_start_local_time time without time zone,
  anchor_end_local_time time without time zone,
  schedule_placement public.extra_schedule_placement not null,
  schedule_minutes integer not null check (schedule_minutes >= 0),
  priority integer not null default 100,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (service_id, extra_id)
    references public.service_extras(service_id, extra_id)
    on delete cascade,
  check (days_of_week is null or days_of_week <@ array[0,1,2,3,4,5,6]::smallint[]),
  check (
    anchor_start_local_time is null
    or anchor_end_local_time is null
    or anchor_start_local_time < anchor_end_local_time
  )
);

create index service_extra_schedule_rules_lookup_idx
  on public.service_extra_schedule_rules (service_id, extra_id, priority, id)
  where is_active;

alter table public.checkout_holds
  add column core_start_at timestamptz,
  add column core_end_at timestamptz,
  add column pre_service_minutes integer not null default 0 check (pre_service_minutes >= 0),
  add column post_service_minutes integer not null default 0 check (post_service_minutes >= 0),
  add column schedule_profile jsonb not null default '{}'::jsonb;

alter table public.appointments
  add column core_start_at timestamptz,
  add column core_end_at timestamptz,
  add column pre_service_minutes integer not null default 0 check (pre_service_minutes >= 0),
  add column post_service_minutes integer not null default 0 check (post_service_minutes >= 0),
  add column schedule_profile_snapshot jsonb not null default '{}'::jsonb;

update public.checkout_holds
set core_start_at = requested_start_at,
    core_end_at = requested_end_at
where core_start_at is null or core_end_at is null;

update public.appointments
set core_start_at = start_at,
    core_end_at = end_at
where core_start_at is null or core_end_at is null;

alter table public.checkout_holds
  add constraint checkout_holds_core_range_check
    check (core_start_at is null or core_end_at is null or core_end_at > core_start_at),
  add constraint checkout_holds_schedule_envelope_check
    check (
      core_start_at is null
      or core_end_at is null
      or (requested_start_at <= core_start_at and requested_end_at >= core_end_at)
    );

alter table public.appointments
  add constraint appointments_core_range_check
    check (core_start_at is null or core_end_at is null or core_end_at > core_start_at),
  add constraint appointments_schedule_envelope_check
    check (
      core_start_at is null
      or core_end_at is null
      or (start_at <= core_start_at and end_at >= core_end_at)
    );

create or replace function public.ensure_checkout_hold_schedule_defaults()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.core_start_at := coalesce(new.core_start_at, new.requested_start_at);
  new.core_end_at := coalesce(new.core_end_at, new.requested_end_at);
  return new;
end;
$$;

create trigger checkout_holds_schedule_defaults_trg
before insert on public.checkout_holds
for each row execute function public.ensure_checkout_hold_schedule_defaults();

create or replace function public.ensure_appointment_schedule_defaults()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.core_start_at := coalesce(new.core_start_at, new.start_at);
  new.core_end_at := coalesce(new.core_end_at, new.end_at);
  return new;
end;
$$;

create trigger appointments_schedule_defaults_trg
before insert on public.appointments
for each row execute function public.ensure_appointment_schedule_defaults();

create or replace function public.resolve_extra_schedule_profile(
  p_service_id uuid,
  p_extra_selections jsonb default '[]'::jsonb,
  p_anchor_start_at timestamptz default null
)
returns jsonb
language plpgsql
stable
set search_path = public
as $$
declare
  v_timezone text;
  v_local_ts timestamp without time zone;
  v_local_time time without time zone;
  v_dow smallint;
  v_pre integer := 0;
  v_post integer := 0;
  v_details jsonb := '[]'::jsonb;
  v_version text;
begin
  select timezone into v_timezone
  from public.operation_settings
  where id = 1;

  if p_anchor_start_at is not null then
    v_local_ts := p_anchor_start_at at time zone v_timezone;
    v_local_time := v_local_ts::time;
    v_dow := extract(dow from v_local_ts)::smallint;
  end if;

  with selected as (
    select
      x.extra_id,
      x.quantity,
      se.sort_order,
      coalesce(rr.schedule_placement, se.schedule_placement) as placement,
      coalesce(rr.schedule_minutes, se.default_schedule_minutes, e.duration_delta_minutes) as minutes_per_unit,
      greatest(e.updated_at, se.schedule_updated_at, coalesce(rr.updated_at, '-infinity'::timestamptz)) as config_updated_at
    from jsonb_to_recordset(coalesce(p_extra_selections, '[]'::jsonb)) as x(extra_id uuid, quantity integer)
    join public.service_extras se
      on se.service_id = p_service_id
     and se.extra_id = x.extra_id
    join public.extras e
      on e.id = x.extra_id
     and e.is_active
    left join lateral (
      select r.schedule_placement, r.schedule_minutes, r.updated_at
      from public.service_extra_schedule_rules r
      where r.service_id = p_service_id
        and r.extra_id = x.extra_id
        and r.is_active
        and p_anchor_start_at is not null
        and (r.days_of_week is null or v_dow = any(r.days_of_week))
        and (r.anchor_start_local_time is null or v_local_time >= r.anchor_start_local_time)
        and (r.anchor_end_local_time is null or v_local_time < r.anchor_end_local_time)
      order by r.priority asc, r.id asc
      limit 1
    ) rr on true
    where x.quantity is not null and x.quantity > 0
  )
  select
    coalesce(sum(minutes_per_unit * quantity) filter (where placement = 'PREPEND'), 0)::integer,
    coalesce(sum(minutes_per_unit * quantity) filter (where placement = 'APPEND'), 0)::integer,
    coalesce(jsonb_agg(
      jsonb_build_object(
        'extra_id', extra_id,
        'quantity', quantity,
        'placement', placement,
        'minutes_per_unit', minutes_per_unit,
        'total_schedule_minutes', minutes_per_unit * quantity
      ) order by sort_order, extra_id
    ), '[]'::jsonb),
    md5(coalesce(string_agg(
      concat_ws('|', extra_id::text, quantity::text, placement::text, minutes_per_unit::text, config_updated_at::text),
      '||' order by sort_order, extra_id
    ), ''))
  into v_pre, v_post, v_details, v_version
  from selected;

  return jsonb_build_object(
    'pre_service_minutes', v_pre,
    'post_service_minutes', v_post,
    'details', v_details,
    'schedule_version', v_version
  );
end;
$$;

alter function public.calculate_booking_quote(
  uuid, uuid, jsonb, integer, timestamptz, text
) rename to calculate_booking_quote_base;

create or replace function public.calculate_booking_quote(
  p_service_id uuid,
  p_service_employee_id uuid,
  p_extra_selections jsonb default '[]'::jsonb,
  p_people_count integer default 1,
  p_requested_start_at timestamptz default null,
  p_coupon_code text default null
)
returns jsonb
language plpgsql
stable
set search_path = public
as $$
declare
  v_quote jsonb;
  v_profile jsonb;
  v_core_duration integer;
  v_pre integer;
  v_post integer;
  v_schedule_version text;
  v_pricing_version text;
begin
  v_quote := public.calculate_booking_quote_base(
    p_service_id,
    p_service_employee_id,
    p_extra_selections,
    p_people_count,
    p_requested_start_at,
    p_coupon_code
  );

  select base_duration_minutes into v_core_duration
  from public.services
  where id = p_service_id;

  v_profile := public.resolve_extra_schedule_profile(
    p_service_id,
    p_extra_selections,
    p_requested_start_at
  );

  v_pre := coalesce((v_profile->>'pre_service_minutes')::integer, 0);
  v_post := coalesce((v_profile->>'post_service_minutes')::integer, 0);
  v_schedule_version := coalesce(v_profile->>'schedule_version', '');
  v_pricing_version := md5(coalesce(v_quote->>'pricing_version', '') || '|' || v_schedule_version);

  return v_quote || jsonb_build_object(
    'core_duration_minutes', v_core_duration,
    'pre_service_minutes', v_pre,
    'post_service_minutes', v_post,
    'duration_minutes', v_core_duration + v_pre + v_post,
    'schedule_profile', v_profile,
    'pricing_version', v_pricing_version
  );
end;
$$;

create or replace function public.calculate_booking_resource_ranges(
  p_service_id uuid,
  p_extra_selections jsonb,
  p_anchor_start_at timestamptz
)
returns table (
  resource_id uuid,
  occupied_range tstzrange
)
language sql
stable
set search_path = public
as $$
with service_data as (
  select
    s.base_duration_minutes,
    s.buffer_before_minutes,
    s.buffer_after_minutes,
    public.resolve_extra_schedule_profile(p_service_id, p_extra_selections, p_anchor_start_at) as profile
  from public.services s
  where s.id = p_service_id
), bounds as (
  select
    p_anchor_start_at as core_start_at,
    p_anchor_start_at + make_interval(mins => base_duration_minutes) as core_end_at,
    p_anchor_start_at - make_interval(mins => coalesce((profile->>'pre_service_minutes')::integer, 0)) as appointment_start_at,
    p_anchor_start_at + make_interval(mins => base_duration_minutes + coalesce((profile->>'post_service_minutes')::integer, 0)) as appointment_end_at,
    buffer_before_minutes,
    buffer_after_minutes,
    profile
  from service_data
), ranges as (
  select
    sr.resource_id,
    tstzrange(
      b.core_start_at - make_interval(mins => b.buffer_before_minutes),
      b.core_end_at + make_interval(mins => b.buffer_after_minutes),
      '[)'
    ) as r
  from public.service_resources sr
  cross join bounds b
  where sr.service_id = p_service_id
    and sr.is_required

  union all

  select
    er.resource_id,
    case d.placement
      when 'PREPEND' then tstzrange(b.appointment_start_at, b.core_start_at, '[)')
      when 'APPEND' then tstzrange(b.core_end_at, b.appointment_end_at, '[)')
    end as r
  from bounds b
  cross join lateral jsonb_to_recordset(b.profile->'details') as d(
    extra_id uuid,
    quantity integer,
    placement text,
    minutes_per_unit integer,
    total_schedule_minutes integer
  )
  join public.extra_resources er
    on er.extra_id = d.extra_id
   and er.is_required
  where d.total_schedule_minutes > 0
), nonempty as (
  select resource_id, r
  from ranges
  where r is not null and not isempty(r)
)
select
  resource_id,
  tstzrange(min(lower(r)), max(upper(r)), '[)') as occupied_range
from nonempty
group by resource_id;
$$;

create or replace function public.sync_promoted_appointment_schedule()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.promoted_appointment_id is not null
     and (old.promoted_appointment_id is distinct from new.promoted_appointment_id) then
    update public.appointments
    set core_start_at = new.core_start_at,
        core_end_at = new.core_end_at,
        pre_service_minutes = new.pre_service_minutes,
        post_service_minutes = new.post_service_minutes,
        schedule_profile_snapshot = new.schedule_profile,
        updated_at = now()
    where id = new.promoted_appointment_id;
  end if;

  return new;
end;
$$;

create trigger checkout_holds_sync_promoted_schedule_trg
after update of promoted_appointment_id on public.checkout_holds
for each row execute function public.sync_promoted_appointment_schedule();

drop function public.create_checkout_hold(uuid, uuid, jsonb, integer, timestamptz);
drop function public.list_available_slots(uuid, uuid, jsonb, integer, date, text);

create function public.list_available_slots(
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
  core_start_at timestamptz,
  core_end_at timestamptz,
  pre_service_minutes integer,
  post_service_minutes integer,
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
  v_slot_interval integer := 30;
  v_dow smallint;
  v_candidate_local timestamp without time zone;
  v_anchor_start timestamptz;
  v_core_end timestamptz;
  v_appointment_start timestamptz;
  v_appointment_end timestamptz;
  v_quote jsonb;
  v_pre integer;
  v_post integer;
  v_resource record;
  v_resource_local_date date;
  v_resource_dow smallint;
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

  v_dow := extract(dow from p_local_date)::smallint;

  select coalesce(min(ar.slot_interval_minutes), 30)
  into v_slot_interval
  from public.availability_rules ar
  where ar.service_employee_id = p_service_employee_id
    and ar.weekday = v_dow
    and ar.is_active;

  for v_candidate_local in
    select gs
    from generate_series(
      p_local_date::timestamp,
      (p_local_date + 1)::timestamp - interval '1 minute',
      make_interval(mins => v_slot_interval)
    ) as gs
  loop
    v_anchor_start := v_candidate_local at time zone v_timezone;
    v_core_end := v_anchor_start + make_interval(mins => v_service.base_duration_minutes);

    v_quote := public.calculate_booking_quote(
      p_service_id,
      p_service_employee_id,
      p_extra_selections,
      p_people_count,
      v_anchor_start,
      p_coupon_code
    );

    v_pre := coalesce((v_quote->>'pre_service_minutes')::integer, 0);
    v_post := coalesce((v_quote->>'post_service_minutes')::integer, 0);
    v_appointment_start := v_anchor_start - make_interval(mins => v_pre);
    v_appointment_end := v_core_end + make_interval(mins => v_post);

    if v_appointment_start < now() + make_interval(mins => v_service.minimum_booking_notice_minutes) then
      continue;
    end if;

    if v_anchor_start > now() + make_interval(days => v_service.maximum_booking_horizon_days) then
      continue;
    end if;

    select (
      exists (
        select 1
        from public.availability_rules ar
        where ar.service_employee_id = p_service_employee_id
          and ar.weekday = v_dow
          and ar.is_active
          and tstzrange(
            (p_local_date + ar.start_local_time) at time zone v_timezone,
            (p_local_date + ar.end_local_time) at time zone v_timezone,
            '[)'
          ) @> tstzrange(v_anchor_start, v_core_end, '[)')
      )
      or exists (
        select 1
        from public.availability_exceptions ae
        where ae.service_employee_id = p_service_employee_id
          and ae.exception_type = 'OPEN'
          and tstzrange(ae.start_at, ae.end_at, '[)') @> tstzrange(v_anchor_start, v_core_end, '[)')
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
        and tstzrange(ae.start_at, ae.end_at, '[)') && tstzrange(v_anchor_start, v_core_end, '[)')
    ) then
      continue;
    end if;

    v_resource_ok := true;

    for v_resource in
      select *
      from public.calculate_booking_resource_ranges(
        p_service_id,
        p_extra_selections,
        v_anchor_start
      )
    loop
      v_resource_local_date := (lower(v_resource.occupied_range) at time zone v_timezone)::date;
      v_resource_dow := extract(dow from v_resource_local_date)::smallint;

      if exists (
        select 1
        from public.resource_availability_rules rar
        where rar.resource_id = v_resource.resource_id
          and rar.weekday = v_resource_dow
          and rar.is_active
      ) then
        if not (
          exists (
            select 1
            from public.resource_availability_rules rar
            where rar.resource_id = v_resource.resource_id
              and rar.weekday = v_resource_dow
              and rar.is_active
              and tstzrange(
                (v_resource_local_date + rar.start_local_time) at time zone v_timezone,
                (v_resource_local_date + rar.end_local_time) at time zone v_timezone,
                '[)'
              ) @> v_resource.occupied_range
          )
          or exists (
            select 1
            from public.availability_exceptions ae
            where ae.resource_id = v_resource.resource_id
              and ae.exception_type = 'OPEN'
              and tstzrange(ae.start_at, ae.end_at, '[)') @> v_resource.occupied_range
          )
        ) then
          v_resource_ok := false;
          exit;
        end if;
      end if;

      if exists (
        select 1
        from public.availability_exceptions ae
        where ae.resource_id = v_resource.resource_id
          and ae.exception_type = 'BLOCK'
          and tstzrange(ae.start_at, ae.end_at, '[)') && v_resource.occupied_range
      ) then
        v_resource_ok := false;
        exit;
      end if;

      if exists (
        select 1
        from public.resource_allocations ra
        where ra.resource_id = v_resource.resource_id
          and ra.status in ('HELD','AWAITING_PAYMENT','CONFIRMED','BLOCKED','EXTERNAL_ACTIVE')
          and ra.occupied_range && v_resource.occupied_range
      ) then
        v_resource_ok := false;
        exit;
      end if;
    end loop;

    if not v_resource_ok then
      continue;
    end if;

    slot_start_at := v_appointment_start;
    slot_end_at := v_appointment_end;
    core_start_at := v_anchor_start;
    core_end_at := v_core_end;
    pre_service_minutes := v_pre;
    post_service_minutes := v_post;
    duration_minutes := v_service.base_duration_minutes + v_pre + v_post;
    commercial_value := (v_quote->>'commercial_value')::numeric(12,2);
    return next;
  end loop;
end;
$$;

create function public.create_checkout_hold(
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
  v_timezone text;
  v_requested_local_date date;
  v_slot record;
  v_quote jsonb;
  v_resource_ids uuid[] := '{}'::uuid[];
  v_hold_id uuid;
  v_raw_token text;
  v_token_hash text;
  v_selection_hash text;
  v_canonical_extras jsonb;
  v_expires_at timestamptz;
  v_hold_minutes integer;
begin
  perform public.expire_due_checkout_holds();

  select timezone into v_timezone
  from public.operation_settings
  where id = 1;

  select coalesce(
    jsonb_agg(
      jsonb_build_object('extra_id', x.extra_id, 'quantity', x.quantity)
      order by x.extra_id
    ),
    '[]'::jsonb
  )
  into v_canonical_extras
  from jsonb_to_recordset(coalesce(p_extra_selections, '[]'::jsonb)) as x(extra_id uuid, quantity integer);

  v_requested_local_date := (p_requested_start_at at time zone v_timezone)::date;

  select s.* into v_slot
  from (
    select * from public.list_available_slots(
      p_service_id, p_service_employee_id, v_canonical_extras, p_people_count,
      v_requested_local_date, null
    )
    union all
    select * from public.list_available_slots(
      p_service_id, p_service_employee_id, v_canonical_extras, p_people_count,
      v_requested_local_date + 1, null
    )
  ) s
  where s.slot_start_at = p_requested_start_at
  order by s.core_start_at
  limit 1;

  if not found then
    raise exception using errcode = 'P0001', message = 'SLOT_NO_LONGER_AVAILABLE';
  end if;

  v_quote := public.calculate_booking_quote(
    p_service_id,
    p_service_employee_id,
    v_canonical_extras,
    p_people_count,
    v_slot.core_start_at,
    null
  );

  select coalesce(array_agg(r.resource_id order by r.resource_id), '{}'::uuid[])
  into v_resource_ids
  from public.calculate_booking_resource_ranges(
    p_service_id,
    v_canonical_extras,
    v_slot.core_start_at
  ) r;

  if coalesce(array_length(v_resource_ids, 1), 0) = 0 then
    raise exception using errcode = 'P0001', message = 'SERVICE_HAS_NO_REQUIRED_RESOURCES';
  end if;

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
    v_slot.slot_start_at::text,
    v_slot.core_start_at::text,
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
    core_start_at,
    core_end_at,
    pre_service_minutes,
    post_service_minutes,
    schedule_profile,
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
    v_slot.slot_start_at,
    v_slot.slot_end_at,
    v_slot.core_start_at,
    v_slot.core_end_at,
    v_slot.pre_service_minutes,
    v_slot.post_service_minutes,
    v_quote->'schedule_profile',
    'ACTIVE',
    v_expires_at,
    v_canonical_extras,
    (v_quote->>'commercial_value')::numeric(12,2),
    v_quote->>'pricing_version',
    v_slot.duration_minutes,
    v_resource_ids
  ) returning id into v_hold_id;

  begin
    insert into public.resource_allocations (
      resource_id,
      checkout_hold_id,
      allocation_type,
      status,
      occupied_range
    )
    select
      r.resource_id,
      v_hold_id,
      'CHECKOUT_HOLD',
      'HELD',
      r.occupied_range
    from public.calculate_booking_resource_ranges(
      p_service_id,
      v_canonical_extras,
      v_slot.core_start_at
    ) r;
  exception
    when exclusion_violation then
      raise exception using errcode = 'P0001', message = 'SLOT_NO_LONGER_AVAILABLE';
  end;

  return jsonb_build_object(
    'checkout_hold_token', v_raw_token,
    'checkout_hold_id', v_hold_id,
    'status', 'ACTIVE',
    'expires_at', v_expires_at,
    'slot_start_at', v_slot.slot_start_at,
    'slot_end_at', v_slot.slot_end_at,
    'core_start_at', v_slot.core_start_at,
    'core_end_at', v_slot.core_end_at,
    'pre_service_minutes', v_slot.pre_service_minutes,
    'post_service_minutes', v_slot.post_service_minutes,
    'commercial_value', (v_quote->>'commercial_value')::numeric(12,2),
    'duration_minutes', v_slot.duration_minutes,
    'pricing_version', v_quote->>'pricing_version'
  );
end;
$$;

comment on table public.service_extra_schedule_rules is
  'Overrides how much an extra prepends/appends around the immutable core service start, optionally by weekday/time range.';

comment on function public.list_available_slots(uuid, uuid, jsonb, integer, date, text) is
  'Lists customer-visible appointment times while preserving service core anchors and validating phased resource occupancy.';
