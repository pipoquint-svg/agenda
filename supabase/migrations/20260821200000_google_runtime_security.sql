create table public.admin_users (
  id uuid primary key default gen_random_uuid(),
  auth_user_id uuid not null unique references auth.users(id) on delete cascade,
  display_name text,
  role text not null default 'ADMIN' check (role in ('OWNER','ADMIN')),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.admin_users enable row level security;

create policy admin_users_self_select
  on public.admin_users
  for select
  to authenticated
  using (auth.uid() = auth_user_id);

create table public.google_oauth_states (
  state_hash text primary key,
  requested_by_admin_user_id uuid not null references public.admin_users(id) on delete cascade,
  success_url text,
  expires_at timestamptz not null,
  consumed_at timestamptz,
  created_at timestamptz not null default now(),
  check (expires_at > created_at)
);

create index google_oauth_states_expiry_idx
  on public.google_oauth_states (expires_at)
  where consumed_at is null;

create or replace function public.consume_google_oauth_state(p_state_hash text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_state public.google_oauth_states%rowtype;
begin
  select * into v_state
  from public.google_oauth_states
  where state_hash = p_state_hash
  for update;

  if not found then
    raise exception using errcode = 'P0001', message = 'GOOGLE_OAUTH_STATE_INVALID';
  end if;

  if v_state.consumed_at is not null then
    raise exception using errcode = 'P0001', message = 'GOOGLE_OAUTH_STATE_ALREADY_USED';
  end if;

  if v_state.expires_at <= now() then
    raise exception using errcode = 'P0001', message = 'GOOGLE_OAUTH_STATE_EXPIRED';
  end if;

  update public.google_oauth_states
  set consumed_at = now()
  where state_hash = p_state_hash;

  return jsonb_build_object(
    'admin_user_id', v_state.requested_by_admin_user_id,
    'success_url', v_state.success_url
  );
end;
$$;

revoke all on function public.consume_google_oauth_state(text) from public, anon, authenticated;
grant execute on function public.consume_google_oauth_state(text) to service_role;

create or replace function public.prepare_google_full_sync(p_google_calendar_id uuid)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1 from public.google_calendars gc
    where gc.id = p_google_calendar_id and gc.is_active
  ) then
    raise exception using errcode = 'P0001', message = 'GOOGLE_CALENDAR_NOT_FOUND';
  end if;

  insert into public.google_sync_state (
    google_calendar_id, sync_token, health_status, last_attempt_at,
    consecutive_failures, last_error, updated_at
  ) values (
    p_google_calendar_id, null, 'REBUILDING', now(), 0, null, now()
  )
  on conflict (google_calendar_id)
  do update set
    sync_token = null,
    health_status = 'REBUILDING',
    last_attempt_at = now(),
    last_error = null,
    updated_at = now();

  update public.google_calendar_events
  set status = 'cancelled',
      qualification = 'CANCELLED',
      updated_at = now()
  where google_calendar_id = p_google_calendar_id
    and not managed_by_agenda;

  update public.resource_allocations ra
  set status = 'RELEASED',
      updated_at = now()
  where ra.google_calendar_event_id in (
    select gce.id
    from public.google_calendar_events gce
    where gce.google_calendar_id = p_google_calendar_id
      and not gce.managed_by_agenda
  )
    and ra.allocation_type = 'EXTERNAL_BLOCK'
    and ra.status in ('EXTERNAL_ACTIVE','IGNORED_BY_ADMIN');

  update public.schedule_divergences sd
  set status = 'RESOLVED',
      resolved_at = now(),
      resolution_notes = concat_ws(E'\n', nullif(sd.resolution_notes, ''), 'Full Google sync rebuild started.'),
      updated_at = now()
  where sd.google_calendar_event_id in (
    select gce.id
    from public.google_calendar_events gce
    where gce.google_calendar_id = p_google_calendar_id
  )
    and sd.status = 'OPEN';
end;
$$;

revoke all on function public.prepare_google_full_sync(uuid) from public, anon, authenticated;
grant execute on function public.prepare_google_full_sync(uuid) to service_role;

create or replace function public.enqueue_google_calendar_sync(
  p_google_calendar_id uuid,
  p_idempotency_key text,
  p_payload_json jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_job_id uuid;
begin
  if not exists (
    select 1 from public.google_calendars
    where id = p_google_calendar_id and is_active
  ) then
    raise exception using errcode = 'P0001', message = 'GOOGLE_CALENDAR_NOT_FOUND';
  end if;

  insert into public.integration_jobs (
    job_type, entity_type, entity_id, entity_version,
    payload_json, status, run_after, idempotency_key
  ) values (
    'GOOGLE_CALENDAR_SYNC', 'GOOGLE_CALENDAR', p_google_calendar_id, null,
    coalesce(p_payload_json, '{}'::jsonb), 'PENDING', now(), p_idempotency_key
  )
  on conflict (idempotency_key) do update
    set updated_at = public.integration_jobs.updated_at
  returning id into v_job_id;

  return v_job_id;
end;
$$;

revoke all on function public.enqueue_google_calendar_sync(uuid,text,jsonb) from public, anon, authenticated;
grant execute on function public.enqueue_google_calendar_sync(uuid,text,jsonb) to service_role;

comment on function public.prepare_google_full_sync(uuid) is
  'Fail-closed Google full-sync preparation: marks the calendar rebuilding and releases only external Google allocations before replaying remote state.';
