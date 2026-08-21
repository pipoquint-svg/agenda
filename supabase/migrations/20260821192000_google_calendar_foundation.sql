create domain public.google_connection_status as text
  check (value in ('ACTIVE','RECONNECT_REQUIRED','REVOKED'));

create domain public.google_sync_health as text
  check (value in ('NEVER_SYNCED','HEALTHY','STALE','ERROR','REBUILDING'));

create domain public.google_watch_status as text
  check (value in ('ACTIVE','REPLACED','EXPIRED','STOPPED'));

create domain public.google_event_qualification as text
  check (value in (
    'BLOCKING',
    'MANAGED',
    'CANCELLED',
    'IGNORED_TRANSPARENT',
    'IGNORED_DECLINED',
    'IGNORED_ALL_DAY',
    'NO_RESOURCE_MAPPING',
    'INVALID_TIME'
  ));

create table public.google_connections (
  id uuid primary key default gen_random_uuid(),
  account_email text not null,
  google_user_id text,
  refresh_token_ciphertext text,
  token_encryption_version integer,
  scopes text[] not null default '{}'::text[],
  status public.google_connection_status not null default 'ACTIVE',
  last_error text,
  connected_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (account_email)
);

create table public.google_calendars (
  id uuid primary key default gen_random_uuid(),
  google_connection_id uuid not null references public.google_connections(id) on delete cascade,
  google_calendar_id text not null,
  name text not null,
  timezone text not null default 'America/Sao_Paulo',
  access_role text,
  is_primary boolean not null default false,
  is_active boolean not null default true,
  block_all_day_events boolean not null default false,
  ignore_transparent_events boolean not null default true,
  ignore_declined_events boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (google_connection_id, google_calendar_id)
);

create table public.google_calendar_resources (
  google_calendar_id uuid not null references public.google_calendars(id) on delete cascade,
  resource_id uuid not null references public.resources(id) on delete restrict,
  created_at timestamptz not null default now(),
  primary key (google_calendar_id, resource_id)
);

create table public.service_employee_calendar_write (
  service_employee_id uuid primary key references public.service_employees(id) on delete cascade,
  google_calendar_id uuid not null references public.google_calendars(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.google_sync_state (
  google_calendar_id uuid primary key references public.google_calendars(id) on delete cascade,
  sync_token text,
  health_status public.google_sync_health not null default 'NEVER_SYNCED',
  last_attempt_at timestamptz,
  last_success_at timestamptz,
  last_full_sync_at timestamptz,
  consecutive_failures integer not null default 0 check (consecutive_failures >= 0),
  last_error text,
  updated_at timestamptz not null default now()
);

create table public.google_watch_channels (
  id uuid primary key default gen_random_uuid(),
  google_calendar_id uuid not null references public.google_calendars(id) on delete cascade,
  channel_id text not null unique,
  google_resource_id text not null,
  channel_token_hash text,
  expiration_at timestamptz,
  status public.google_watch_status not null default 'ACTIVE',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index google_watch_channels_expiry_idx
  on public.google_watch_channels (expiration_at)
  where status = 'ACTIVE';

create table public.google_calendar_events (
  id uuid primary key default gen_random_uuid(),
  google_calendar_id uuid not null references public.google_calendars(id) on delete cascade,
  google_event_id text not null,
  recurring_event_id text,
  original_start_at timestamptz,
  original_start_date date,
  etag text,
  status text not null default 'confirmed',
  summary text,
  is_all_day boolean not null default false,
  start_at timestamptz,
  end_at timestamptz,
  start_date date,
  end_date date,
  transparency text,
  self_response_status text,
  managed_by_agenda boolean not null default false,
  agenda_appointment_id uuid references public.appointments(id) on delete set null,
  bs_source text,
  google_updated_at timestamptz,
  qualification public.google_event_qualification not null default 'INVALID_TIME',
  normalized_payload jsonb not null default '{}'::jsonb,
  payload_hash text,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (google_calendar_id, google_event_id),
  check (
    (is_all_day and start_date is not null and end_date is not null and end_date > start_date)
    or
    (not is_all_day and (status = 'cancelled' or (start_at is not null and end_at is not null and end_at > start_at)))
  )
);

create index google_calendar_events_recurring_idx
  on public.google_calendar_events (google_calendar_id, recurring_event_id, original_start_at, original_start_date)
  where recurring_event_id is not null;

create index google_calendar_events_appointment_idx
  on public.google_calendar_events (agenda_appointment_id)
  where agenda_appointment_id is not null;

alter table public.resource_allocations
  add column google_calendar_event_id uuid references public.google_calendar_events(id) on delete restrict;

create index resource_allocations_google_event_idx
  on public.resource_allocations (google_calendar_event_id)
  where google_calendar_event_id is not null;

create table public.schedule_divergences (
  id uuid primary key default gen_random_uuid(),
  resource_id uuid not null references public.resources(id) on delete restrict,
  appointment_id uuid references public.appointments(id) on delete restrict,
  google_calendar_event_id uuid not null references public.google_calendar_events(id) on delete restrict,
  source text not null default 'GOOGLE',
  desired_range tstzrange not null,
  active_range tstzrange,
  status text not null default 'OPEN' check (status in ('OPEN','RESOLVED','IGNORED_WITH_REASON')),
  reason text not null,
  detected_at timestamptz not null default now(),
  resolved_at timestamptz,
  resolved_by_admin_id uuid,
  resolution_notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index schedule_divergences_open_google_resource_uq
  on public.schedule_divergences (google_calendar_event_id, resource_id)
  where status = 'OPEN';

create index schedule_divergences_open_idx
  on public.schedule_divergences (detected_at)
  where status = 'OPEN';

create or replace function public.qualify_google_calendar_event(p_event_id uuid)
returns public.google_event_qualification
language plpgsql
stable
set search_path = public
as $$
declare
  v_event public.google_calendar_events%rowtype;
  v_calendar public.google_calendars%rowtype;
begin
  select * into v_event
  from public.google_calendar_events
  where id = p_event_id;

  if not found then
    raise exception using errcode = 'P0001', message = 'GOOGLE_EVENT_NOT_FOUND';
  end if;

  select * into v_calendar
  from public.google_calendars
  where id = v_event.google_calendar_id;

  if v_event.managed_by_agenda or v_event.bs_source = 'blacksheep_agenda' then
    return 'MANAGED';
  end if;

  if v_event.status = 'cancelled' then
    return 'CANCELLED';
  end if;

  if v_calendar.ignore_transparent_events
     and coalesce(v_event.transparency, 'opaque') = 'transparent' then
    return 'IGNORED_TRANSPARENT';
  end if;

  if v_calendar.ignore_declined_events
     and lower(coalesce(v_event.self_response_status, '')) = 'declined' then
    return 'IGNORED_DECLINED';
  end if;

  if v_event.is_all_day and not v_calendar.block_all_day_events then
    return 'IGNORED_ALL_DAY';
  end if;

  if not exists (
    select 1
    from public.google_calendar_resources gcr
    where gcr.google_calendar_id = v_event.google_calendar_id
  ) then
    return 'NO_RESOURCE_MAPPING';
  end if;

  if v_event.is_all_day then
    if v_event.start_date is null or v_event.end_date is null or v_event.end_date <= v_event.start_date then
      return 'INVALID_TIME';
    end if;
  else
    if v_event.start_at is null or v_event.end_at is null or v_event.end_at <= v_event.start_at then
      return 'INVALID_TIME';
    end if;
  end if;

  return 'BLOCKING';
end;
$$;

create or replace function public.google_event_desired_range(p_event_id uuid)
returns tstzrange
language plpgsql
stable
set search_path = public
as $$
declare
  v_event public.google_calendar_events%rowtype;
  v_calendar public.google_calendars%rowtype;
begin
  select * into v_event
  from public.google_calendar_events
  where id = p_event_id;

  if not found then
    raise exception using errcode = 'P0001', message = 'GOOGLE_EVENT_NOT_FOUND';
  end if;

  select * into v_calendar
  from public.google_calendars
  where id = v_event.google_calendar_id;

  if v_event.is_all_day then
    return tstzrange(
      v_event.start_date::timestamp at time zone v_calendar.timezone,
      v_event.end_date::timestamp at time zone v_calendar.timezone,
      '[)'
    );
  end if;

  return tstzrange(v_event.start_at, v_event.end_at, '[)');
end;
$$;

create or replace function public.apply_google_calendar_event_state(p_event_id uuid)
returns jsonb
language plpgsql
volatile
set search_path = public
as $$
declare
  v_event public.google_calendar_events%rowtype;
  v_qualification public.google_event_qualification;
  v_range tstzrange;
  v_resource record;
  v_active_range tstzrange;
  v_conflict_count integer := 0;
  v_allocation_count integer := 0;
begin
  select * into v_event
  from public.google_calendar_events
  where id = p_event_id
  for update;

  if not found then
    raise exception using errcode = 'P0001', message = 'GOOGLE_EVENT_NOT_FOUND';
  end if;

  v_qualification := public.qualify_google_calendar_event(p_event_id);

  update public.google_calendar_events
  set qualification = v_qualification,
      last_seen_at = now(),
      updated_at = now()
  where id = p_event_id;

  if v_qualification <> 'BLOCKING' then
    update public.resource_allocations
    set status = 'RELEASED',
        updated_at = now()
    where google_calendar_event_id = p_event_id
      and allocation_type = 'EXTERNAL_BLOCK'
      and status in ('EXTERNAL_ACTIVE','IGNORED_BY_ADMIN');

    update public.schedule_divergences
    set status = 'RESOLVED',
        resolved_at = now(),
        resolution_notes = coalesce(resolution_notes, '') || case when resolution_notes is null or resolution_notes = '' then '' else E'\n' end || 'Remote event no longer qualifies as blocking.',
        updated_at = now()
    where google_calendar_event_id = p_event_id
      and status = 'OPEN';

    return jsonb_build_object(
      'event_id', p_event_id,
      'qualification', v_qualification,
      'allocations', 0,
      'divergences', 0
    );
  end if;

  v_range := public.google_event_desired_range(p_event_id);

  begin
    update public.resource_allocations
    set status = 'RELEASED',
        updated_at = now()
    where google_calendar_event_id = p_event_id
      and allocation_type = 'EXTERNAL_BLOCK'
      and status in ('EXTERNAL_ACTIVE','IGNORED_BY_ADMIN');

    insert into public.resource_allocations (
      resource_id,
      allocation_type,
      status,
      occupied_range,
      external_source,
      external_calendar_id,
      external_event_id,
      external_event_recurring_id,
      external_event_instance_start,
      google_calendar_event_id
    )
    select
      gcr.resource_id,
      'EXTERNAL_BLOCK',
      'EXTERNAL_ACTIVE',
      v_range,
      'GOOGLE',
      gc.google_calendar_id,
      v_event.google_event_id,
      v_event.recurring_event_id,
      v_event.original_start_at,
      p_event_id
    from public.google_calendar_resources gcr
    join public.google_calendars gc on gc.id = gcr.google_calendar_id
    where gcr.google_calendar_id = v_event.google_calendar_id;

    get diagnostics v_allocation_count = row_count;

    update public.schedule_divergences
    set status = 'RESOLVED',
        resolved_at = now(),
        resolution_notes = coalesce(resolution_notes, '') || case when resolution_notes is null or resolution_notes = '' then '' else E'\n' end || 'Desired external allocation applied successfully.',
        updated_at = now()
    where google_calendar_event_id = p_event_id
      and status = 'OPEN';

  exception
    when exclusion_violation then
      v_allocation_count := 0;

      for v_resource in
        select
          gcr.resource_id,
          ra.appointment_id,
          ra.occupied_range
        from public.google_calendar_resources gcr
        left join lateral (
          select ra.appointment_id, ra.occupied_range
          from public.resource_allocations ra
          where ra.resource_id = gcr.resource_id
            and ra.status in ('HELD','AWAITING_PAYMENT','CONFIRMED','BLOCKED','EXTERNAL_ACTIVE')
            and ra.google_calendar_event_id is distinct from p_event_id
            and ra.occupied_range && v_range
          order by lower(ra.occupied_range)
          limit 1
        ) ra on true
        where gcr.google_calendar_id = v_event.google_calendar_id
          and ra.occupied_range is not null
      loop
        select ra.occupied_range into v_active_range
        from public.resource_allocations ra
        where ra.google_calendar_event_id = p_event_id
          and ra.resource_id = v_resource.resource_id
          and ra.status in ('EXTERNAL_ACTIVE','IGNORED_BY_ADMIN')
        order by ra.created_at desc
        limit 1;

        insert into public.schedule_divergences (
          resource_id,
          appointment_id,
          google_calendar_event_id,
          desired_range,
          active_range,
          reason
        ) values (
          v_resource.resource_id,
          v_resource.appointment_id,
          p_event_id,
          v_range,
          v_active_range,
          'GOOGLE_EVENT_CONFLICT'
        )
        on conflict (google_calendar_event_id, resource_id) where status = 'OPEN'
        do update set
          appointment_id = excluded.appointment_id,
          desired_range = excluded.desired_range,
          active_range = excluded.active_range,
          detected_at = now(),
          updated_at = now();

        v_conflict_count := v_conflict_count + 1;
      end loop;
  end;

  return jsonb_build_object(
    'event_id', p_event_id,
    'qualification', v_qualification,
    'desired_range', v_range,
    'allocations', v_allocation_count,
    'divergences', v_conflict_count
  );
end;
$$;

create or replace function public.upsert_google_calendar_event(
  p_google_calendar_id uuid,
  p_google_event_id text,
  p_status text,
  p_summary text default null,
  p_is_all_day boolean default false,
  p_start_at timestamptz default null,
  p_end_at timestamptz default null,
  p_start_date date default null,
  p_end_date date default null,
  p_transparency text default null,
  p_self_response_status text default null,
  p_recurring_event_id text default null,
  p_original_start_at timestamptz default null,
  p_original_start_date date default null,
  p_etag text default null,
  p_google_updated_at timestamptz default null,
  p_managed_by_agenda boolean default false,
  p_agenda_appointment_id uuid default null,
  p_bs_source text default null,
  p_normalized_payload jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
volatile
set search_path = public
as $$
declare
  v_event_id uuid;
  v_result jsonb;
begin
  if p_google_event_id is null or btrim(p_google_event_id) = '' then
    raise exception using errcode = 'P0001', message = 'GOOGLE_EVENT_ID_REQUIRED';
  end if;

  insert into public.google_calendar_events (
    google_calendar_id,
    google_event_id,
    recurring_event_id,
    original_start_at,
    original_start_date,
    etag,
    status,
    summary,
    is_all_day,
    start_at,
    end_at,
    start_date,
    end_date,
    transparency,
    self_response_status,
    managed_by_agenda,
    agenda_appointment_id,
    bs_source,
    google_updated_at,
    normalized_payload,
    payload_hash,
    last_seen_at,
    updated_at
  ) values (
    p_google_calendar_id,
    p_google_event_id,
    p_recurring_event_id,
    p_original_start_at,
    p_original_start_date,
    p_etag,
    p_status,
    p_summary,
    p_is_all_day,
    p_start_at,
    p_end_at,
    p_start_date,
    p_end_date,
    p_transparency,
    p_self_response_status,
    p_managed_by_agenda,
    p_agenda_appointment_id,
    p_bs_source,
    p_google_updated_at,
    coalesce(p_normalized_payload, '{}'::jsonb),
    md5(coalesce(p_normalized_payload, '{}'::jsonb)::text),
    now(),
    now()
  )
  on conflict (google_calendar_id, google_event_id)
  do update set
    recurring_event_id = excluded.recurring_event_id,
    original_start_at = excluded.original_start_at,
    original_start_date = excluded.original_start_date,
    etag = excluded.etag,
    status = excluded.status,
    summary = excluded.summary,
    is_all_day = excluded.is_all_day,
    start_at = excluded.start_at,
    end_at = excluded.end_at,
    start_date = excluded.start_date,
    end_date = excluded.end_date,
    transparency = excluded.transparency,
    self_response_status = excluded.self_response_status,
    managed_by_agenda = excluded.managed_by_agenda,
    agenda_appointment_id = excluded.agenda_appointment_id,
    bs_source = excluded.bs_source,
    google_updated_at = excluded.google_updated_at,
    normalized_payload = excluded.normalized_payload,
    payload_hash = excluded.payload_hash,
    last_seen_at = now(),
    updated_at = now()
  returning id into v_event_id;

  v_result := public.apply_google_calendar_event_state(v_event_id);

  return v_result || jsonb_build_object('google_calendar_event_id', v_event_id);
end;
$$;

create or replace function public.ignore_google_external_block(
  p_allocation_id uuid,
  p_admin_user_id uuid,
  p_reason text
)
returns jsonb
language plpgsql
volatile
set search_path = public
as $$
declare
  v_allocation public.resource_allocations%rowtype;
begin
  if p_reason is null or btrim(p_reason) = '' then
    raise exception using errcode = 'P0001', message = 'IGNORE_REASON_REQUIRED';
  end if;

  select * into v_allocation
  from public.resource_allocations
  where id = p_allocation_id
  for update;

  if not found then
    raise exception using errcode = 'P0001', message = 'EXTERNAL_BLOCK_NOT_FOUND';
  end if;

  if v_allocation.allocation_type <> 'EXTERNAL_BLOCK'
     or v_allocation.status <> 'EXTERNAL_ACTIVE' then
    raise exception using errcode = 'P0001', message = 'EXTERNAL_BLOCK_NOT_IGNORABLE';
  end if;

  update public.resource_allocations
  set status = 'IGNORED_BY_ADMIN',
      ignored_by_admin_id = p_admin_user_id,
      ignored_at = now(),
      ignore_reason = p_reason,
      updated_at = now()
  where id = p_allocation_id;

  insert into public.audit_logs (
    admin_user_id,
    entity_type,
    entity_id,
    action,
    before_json,
    after_json,
    origin
  ) values (
    p_admin_user_id,
    'RESOURCE_ALLOCATION',
    p_allocation_id,
    'GOOGLE_EXTERNAL_BLOCK_IGNORED',
    jsonb_build_object('status', v_allocation.status),
    jsonb_build_object('status', 'IGNORED_BY_ADMIN', 'reason', p_reason),
    'ADMIN'
  );

  return jsonb_build_object(
    'allocation_id', p_allocation_id,
    'status', 'IGNORED_BY_ADMIN'
  );
end;
$$;

create or replace function public.mark_google_sync_success(
  p_google_calendar_id uuid,
  p_sync_token text,
  p_is_full_sync boolean default false
)
returns void
language plpgsql
volatile
set search_path = public
as $$
begin
  insert into public.google_sync_state (
    google_calendar_id,
    sync_token,
    health_status,
    last_attempt_at,
    last_success_at,
    last_full_sync_at,
    consecutive_failures,
    last_error,
    updated_at
  ) values (
    p_google_calendar_id,
    p_sync_token,
    'HEALTHY',
    now(),
    now(),
    case when p_is_full_sync then now() else null end,
    0,
    null,
    now()
  )
  on conflict (google_calendar_id)
  do update set
    sync_token = excluded.sync_token,
    health_status = 'HEALTHY',
    last_attempt_at = now(),
    last_success_at = now(),
    last_full_sync_at = case
      when p_is_full_sync then now()
      else public.google_sync_state.last_full_sync_at
    end,
    consecutive_failures = 0,
    last_error = null,
    updated_at = now();
end;
$$;

create or replace function public.mark_google_sync_failure(
  p_google_calendar_id uuid,
  p_error text,
  p_requires_full_sync boolean default false
)
returns void
language plpgsql
volatile
set search_path = public
as $$
begin
  insert into public.google_sync_state (
    google_calendar_id,
    health_status,
    last_attempt_at,
    consecutive_failures,
    last_error,
    updated_at
  ) values (
    p_google_calendar_id,
    case when p_requires_full_sync then 'STALE' else 'ERROR' end,
    now(),
    1,
    p_error,
    now()
  )
  on conflict (google_calendar_id)
  do update set
    health_status = case when p_requires_full_sync then 'STALE' else 'ERROR' end,
    last_attempt_at = now(),
    consecutive_failures = public.google_sync_state.consecutive_failures + 1,
    last_error = p_error,
    sync_token = case when p_requires_full_sync then null else public.google_sync_state.sync_token end,
    updated_at = now();
end;
$$;

create or replace function public.google_sync_is_fresh(
  p_google_calendar_id uuid,
  p_max_age_seconds integer default 120
)
returns boolean
language sql
stable
set search_path = public
as $$
  select coalesce((
    select gss.health_status = 'HEALTHY'
      and gss.last_success_at is not null
      and gss.last_success_at >= now() - make_interval(secs => p_max_age_seconds)
    from public.google_sync_state gss
    where gss.google_calendar_id = p_google_calendar_id
  ), false);
$$;

comment on table public.google_calendar_events is
  'Remote Google event mirror. resource_allocations remains the only authority for schedule conflicts.';

comment on function public.apply_google_calendar_event_state(uuid) is
  'Reconciles desired Google event state into external allocations atomically; conflicts preserve prior blocking allocations and open divergences.';
