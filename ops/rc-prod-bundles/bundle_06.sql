
-- BEGIN RC MIGRATION 20260823044000_appointment_token_authorship_foundation.sql
-- Appointment token authorship / link-protection foundation.
-- Human decisions from issue #83:
--   * action-token expiry = appointment.start_at
--   * financial verification datum = registered email
--   * network evidence retention = 5 years
--   * block after 3 invalid verification attempts per appointment and per origin
-- This migration adds non-breaking primitives. Existing VIEW/MANAGE/PAY flows remain valid.

alter table public.appointment_access_tokens
  add column if not exists delivery_channel text,
  add column if not exists destination_masked text,
  add column if not exists consumed_at timestamptz,
  add column if not exists consumed_action text,
  add column if not exists issued_request_id text;

alter table public.appointment_access_tokens
  drop constraint if exists appointment_access_tokens_scope_check;
alter table public.appointment_access_tokens
  add constraint appointment_access_tokens_scope_check
  check (scope in ('VIEW','MANAGE','PAY','CANCEL','RESCHEDULE','EDIT_DETAILS','EDIT_EXTRAS'));

alter table public.appointment_access_tokens
  drop constraint if exists appointment_access_tokens_delivery_channel_check;
alter table public.appointment_access_tokens
  add constraint appointment_access_tokens_delivery_channel_check
  check (delivery_channel is null or delivery_channel in ('WHATSAPP','EMAIL','BOTH','INTERNAL'));

create table if not exists public.appointment_token_events (
  id uuid primary key default gen_random_uuid(),
  appointment_access_token_id uuid not null references public.appointment_access_tokens(id) on delete restrict,
  appointment_id uuid not null references public.appointments(id) on delete restrict,
  event_type text not null check (event_type in (
    'ISSUED','DELIVERY_RECORDED','ACCESS','VERIFIED','VERIFY_FAILED',
    'ACTION_EXECUTED','CONSUMED','REVOKED','EXPIRED'
  )),
  channel text check (channel is null or channel in ('WHATSAPP','EMAIL','BOTH','INTERNAL')),
  destination_masked text,
  request_id text,
  metadata_json jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null default now(),
  constraint appointment_token_events_metadata_object
    check (jsonb_typeof(metadata_json) = 'object')
);

create index if not exists appointment_token_events_appointment_idx
  on public.appointment_token_events(appointment_id, occurred_at, id);
create index if not exists appointment_token_events_token_idx
  on public.appointment_token_events(appointment_access_token_id, occurred_at, id);

create table if not exists public.appointment_token_network_evidence (
  id uuid primary key default gen_random_uuid(),
  token_event_id uuid not null unique references public.appointment_token_events(id) on delete restrict,
  ip_address inet,
  user_agent text,
  occurred_at timestamptz not null default now(),
  retain_until timestamptz not null,
  constraint appointment_token_network_retention_valid
    check (retain_until >= occurred_at + interval '5 years' - interval '1 minute')
);

create index if not exists appointment_token_network_retain_idx
  on public.appointment_token_network_evidence(retain_until);

create table if not exists public.appointment_token_network_purge_runs (
  id uuid primary key default gen_random_uuid(),
  cutoff_before timestamptz not null,
  reason text not null,
  requested_by text not null,
  rows_planned bigint not null,
  created_at timestamptz not null default now()
);

alter table public.appointment_token_events enable row level security;
alter table public.appointment_token_network_evidence enable row level security;
alter table public.appointment_token_network_purge_runs enable row level security;

revoke all on public.appointment_token_events from public, anon, authenticated, service_role;
revoke all on public.appointment_token_network_evidence from public, anon, authenticated, service_role;
revoke all on public.appointment_token_network_purge_runs from public, anon, authenticated, service_role;

grant select, insert on public.appointment_token_events to service_role;
grant select, insert on public.appointment_token_network_evidence to service_role;
grant select on public.appointment_token_network_purge_runs to service_role;

create or replace function public.reject_appointment_token_event_mutation()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  raise exception using errcode = '42501', message = 'APPOINTMENT_TOKEN_EVIDENCE_APPEND_ONLY';
end;
$$;

create or replace function public.reject_appointment_token_network_mutation()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if tg_table_name = 'appointment_token_network_evidence'
     and tg_op = 'DELETE'
     and current_user = 'postgres'
     and current_setting('app.token_network_purge_context', true) = 'DEDICATED_TOKEN_NETWORK_PURGE' then
    return old;
  end if;
  raise exception using errcode = '42501', message = 'APPOINTMENT_TOKEN_EVIDENCE_APPEND_ONLY';
end;
$$;

create or replace function public.reject_appointment_token_purge_run_mutation()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  raise exception using errcode = '42501', message = 'APPOINTMENT_TOKEN_EVIDENCE_APPEND_ONLY';
end;
$$;

drop trigger if exists appointment_token_events_append_only on public.appointment_token_events;
create trigger appointment_token_events_append_only
before update or delete or truncate on public.appointment_token_events
for each statement execute function public.reject_appointment_token_event_mutation();

drop trigger if exists appointment_token_network_append_only on public.appointment_token_network_evidence;
create trigger appointment_token_network_append_only
before update or delete or truncate on public.appointment_token_network_evidence
for each statement execute function public.reject_appointment_token_network_mutation();

drop trigger if exists appointment_token_network_purge_runs_append_only on public.appointment_token_network_purge_runs;
create trigger appointment_token_network_purge_runs_append_only
before update or delete or truncate on public.appointment_token_network_purge_runs
for each statement execute function public.reject_appointment_token_purge_run_mutation();

-- Statement triggers above cannot return individual OLD rows for the guarded maintenance delete.
-- Replace network evidence delete guard with a row trigger for the dedicated purge path.
drop trigger if exists appointment_token_network_append_only on public.appointment_token_network_evidence;
create trigger appointment_token_network_append_only
before update or delete on public.appointment_token_network_evidence
for each row execute function public.reject_appointment_token_network_mutation();
drop trigger if exists appointment_token_network_truncate_guard on public.appointment_token_network_evidence;
create trigger appointment_token_network_truncate_guard
before truncate on public.appointment_token_network_evidence
for each statement execute function public.reject_appointment_token_purge_run_mutation();

create or replace function public.service_record_appointment_token_event(
  p_token_id uuid,
  p_event_type text,
  p_channel text default null,
  p_destination_masked text default null,
  p_ip_address inet default null,
  p_user_agent text default null,
  p_request_id text default null,
  p_metadata jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_token public.appointment_access_tokens%rowtype;
  v_event_id uuid;
  v_destination text := nullif(left(btrim(coalesce(p_destination_masked,'')), 160), '');
  v_agent text := nullif(left(coalesce(p_user_agent,''), 1000), '');
begin
  if p_event_type not in ('ISSUED','DELIVERY_RECORDED','ACCESS','VERIFIED','VERIFY_FAILED','ACTION_EXECUTED','CONSUMED','REVOKED','EXPIRED') then
    raise exception using errcode = '22023', message = 'TOKEN_EVENT_TYPE_INVALID';
  end if;
  if p_channel is not null and p_channel not in ('WHATSAPP','EMAIL','BOTH','INTERNAL') then
    raise exception using errcode = '22023', message = 'TOKEN_EVENT_CHANNEL_INVALID';
  end if;
  if p_metadata is null or jsonb_typeof(p_metadata) <> 'object' then
    raise exception using errcode = '22023', message = 'TOKEN_EVENT_METADATA_INVALID';
  end if;

  select * into v_token from public.appointment_access_tokens where id = p_token_id;
  if not found then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_TOKEN_INVALID';
  end if;

  insert into public.appointment_token_events(
    appointment_access_token_id, appointment_id, event_type, channel,
    destination_masked, request_id, metadata_json
  ) values (
    v_token.id, v_token.appointment_id, p_event_type, p_channel,
    v_destination, nullif(left(coalesce(p_request_id,''), 200), ''), p_metadata
  ) returning id into v_event_id;

  if p_ip_address is not null or v_agent is not null then
    insert into public.appointment_token_network_evidence(
      token_event_id, ip_address, user_agent, occurred_at, retain_until
    ) values (
      v_event_id, p_ip_address, v_agent, now(), now() + interval '5 years'
    );
  end if;

  return v_event_id;
end;
$$;

create or replace function public.service_issue_appointment_action_token(
  p_appointment_id uuid,
  p_scope text,
  p_channel text,
  p_destination_masked text,
  p_request_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_start_at timestamptz;
  v_token_id uuid;
  v_raw_token text;
  v_hash text;
  v_expires_at timestamptz;
begin
  if p_scope not in ('CANCEL','RESCHEDULE','EDIT_DETAILS','EDIT_EXTRAS') then
    raise exception using errcode = '22023', message = 'ACTION_TOKEN_SCOPE_INVALID';
  end if;
  if p_channel not in ('WHATSAPP','EMAIL','BOTH','INTERNAL') then
    raise exception using errcode = '22023', message = 'TOKEN_EVENT_CHANNEL_INVALID';
  end if;
  if nullif(btrim(coalesce(p_destination_masked,'')), '') is null then
    raise exception using errcode = '22023', message = 'TOKEN_DESTINATION_MASK_REQUIRED';
  end if;

  select start_at into v_start_at
  from public.appointments
  where id = p_appointment_id;
  if not found then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_NOT_FOUND';
  end if;
  if v_start_at <= now() then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_TOKEN_EXPIRED';
  end if;

  v_raw_token := encode(gen_random_bytes(32), 'hex');
  v_hash := encode(digest(v_raw_token, 'sha256'), 'hex');
  v_expires_at := v_start_at;

  insert into public.appointment_access_tokens(
    appointment_id, token_hash, scope, expires_at,
    delivery_channel, destination_masked, issued_request_id
  ) values (
    p_appointment_id, v_hash, p_scope, v_expires_at,
    p_channel, left(btrim(p_destination_masked),160), nullif(left(coalesce(p_request_id,''),200),'')
  ) returning id into v_token_id;

  perform public.service_record_appointment_token_event(
    v_token_id, 'ISSUED', p_channel, p_destination_masked,
    null, null, p_request_id,
    jsonb_build_object('scope', p_scope, 'expires_at', v_expires_at)
  );

  return jsonb_build_object(
    'token_id', v_token_id,
    'access_token', v_raw_token,
    'scope', p_scope,
    'expires_at', v_expires_at
  );
end;
$$;

create or replace function public.service_record_appointment_token_delivery(
  p_token_id uuid,
  p_channel text,
  p_destination_masked text,
  p_request_id text default null,
  p_provider_message_id text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
begin
  return public.service_record_appointment_token_event(
    p_token_id, 'DELIVERY_RECORDED', p_channel, p_destination_masked,
    null, null, p_request_id,
    jsonb_strip_nulls(jsonb_build_object('provider_message_id', nullif(left(coalesce(p_provider_message_id,''),200),'')))
  );
end;
$$;

create or replace function public.service_resolve_appointment_action_token(
  p_access_token text,
  p_required_scope text,
  p_ip_address inet default null,
  p_user_agent text default null,
  p_request_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_hash text;
  v_token public.appointment_access_tokens%rowtype;
  v_event_id uuid;
  v_start_at timestamptz;
begin
  if p_required_scope not in ('CANCEL','RESCHEDULE','EDIT_DETAILS','EDIT_EXTRAS') then
    raise exception using errcode = '22023', message = 'ACTION_TOKEN_SCOPE_INVALID';
  end if;
  if p_access_token is null or length(btrim(p_access_token)) < 32 then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_TOKEN_INVALID';
  end if;

  v_hash := encode(digest(btrim(p_access_token), 'sha256'), 'hex');
  select * into v_token
  from public.appointment_access_tokens
  where token_hash = v_hash
  for update;

  if not found
     or v_token.scope <> p_required_scope
     or v_token.revoked_at is not null
     or v_token.consumed_at is not null
     or v_token.expires_at is null
     or v_token.expires_at <= now() then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_TOKEN_INVALID';
  end if;

  select start_at into v_start_at from public.appointments where id = v_token.appointment_id;
  if not found or v_start_at <= now() or v_token.expires_at <> v_start_at then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_TOKEN_INVALID';
  end if;

  update public.appointment_access_tokens
  set last_used_at = now()
  where id = v_token.id;

  v_event_id := public.service_record_appointment_token_event(
    v_token.id, 'ACCESS', v_token.delivery_channel, v_token.destination_masked,
    p_ip_address, p_user_agent, p_request_id,
    jsonb_build_object('scope', v_token.scope)
  );

  return jsonb_build_object(
    'appointment_id', v_token.appointment_id,
    'token_id', v_token.id,
    'scope', v_token.scope,
    'expires_at', v_token.expires_at,
    'event_id', v_event_id
  );
end;
$$;

create or replace function public.service_verify_appointment_action_email(
  p_token_id uuid,
  p_email text,
  p_ip_address inet default null,
  p_user_agent text default null,
  p_request_id text default null
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_token public.appointment_access_tokens%rowtype;
  v_email text;
  v_ok boolean;
  v_origin_key text;
begin
  select * into v_token
  from public.appointment_access_tokens
  where id = p_token_id
  for update;
  if not found or v_token.revoked_at is not null or v_token.consumed_at is not null or v_token.expires_at <= now() then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_TOKEN_INVALID';
  end if;
  if v_token.scope <> 'CANCEL' then
    raise exception using errcode = 'P0001', message = 'TOKEN_SCOPE_DENIED';
  end if;

  select lower(btrim(c.email)) into v_email
  from public.appointments a
  join public.customers c on c.id = a.primary_customer_id
  where a.id = v_token.appointment_id;

  v_ok := v_email is not null and lower(btrim(coalesce(p_email,''))) = v_email;
  if v_ok then
    perform public.service_record_appointment_token_event(
      v_token.id, 'VERIFIED', v_token.delivery_channel, v_token.destination_masked,
      p_ip_address, p_user_agent, p_request_id,
      jsonb_build_object('verification_method','REGISTERED_EMAIL')
    );
    return true;
  end if;

  v_origin_key := coalesce(host(p_ip_address), 'missing-origin');
  perform public.service_consume_public_rate_limit(
    'TOKEN_VERIFY_APPOINTMENT', 'appointment:' || v_token.appointment_id::text, 3, 86400
  );
  perform public.service_consume_public_rate_limit(
    'TOKEN_VERIFY_ORIGIN', 'origin:' || v_origin_key, 3, 86400
  );

  perform public.service_record_appointment_token_event(
    v_token.id, 'VERIFY_FAILED', v_token.delivery_channel, v_token.destination_masked,
    p_ip_address, p_user_agent, p_request_id,
    jsonb_build_object('verification_method','REGISTERED_EMAIL')
  );
  return false;
end;
$$;

create or replace function public.service_consume_appointment_action_token(
  p_token_id uuid,
  p_action text,
  p_ip_address inet default null,
  p_user_agent text default null,
  p_request_id text default null,
  p_metadata jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_token public.appointment_access_tokens%rowtype;
begin
  if p_metadata is null or jsonb_typeof(p_metadata) <> 'object' then
    raise exception using errcode = '22023', message = 'TOKEN_EVENT_METADATA_INVALID';
  end if;
  select * into v_token from public.appointment_access_tokens where id = p_token_id for update;
  if not found or v_token.revoked_at is not null or v_token.consumed_at is not null or v_token.expires_at <= now() then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_TOKEN_INVALID';
  end if;
  if v_token.scope not in ('CANCEL','RESCHEDULE','EDIT_DETAILS','EDIT_EXTRAS') then
    raise exception using errcode = 'P0001', message = 'TOKEN_SCOPE_DENIED';
  end if;

  perform public.service_record_appointment_token_event(
    v_token.id, 'ACTION_EXECUTED', v_token.delivery_channel, v_token.destination_masked,
    p_ip_address, p_user_agent, p_request_id,
    p_metadata || jsonb_build_object('action', left(btrim(coalesce(p_action,'')),100))
  );

  update public.appointment_access_tokens
  set consumed_at = now(), consumed_action = left(btrim(coalesce(p_action,'')),100), last_used_at = now()
  where id = v_token.id;

  perform public.service_record_appointment_token_event(
    v_token.id, 'CONSUMED', v_token.delivery_channel, v_token.destination_masked,
    p_ip_address, p_user_agent, p_request_id,
    jsonb_build_object('action', left(btrim(coalesce(p_action,'')),100))
  );
end;
$$;

create or replace function public.service_revoke_appointment_action_tokens(
  p_appointment_id uuid,
  p_reason text,
  p_request_id text default null
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_token record;
  v_count integer := 0;
begin
  for v_token in
    select id, delivery_channel, destination_masked
    from public.appointment_access_tokens
    where appointment_id = p_appointment_id
      and scope in ('CANCEL','RESCHEDULE','EDIT_DETAILS','EDIT_EXTRAS')
      and revoked_at is null
      and consumed_at is null
    for update
  loop
    update public.appointment_access_tokens set revoked_at = now() where id = v_token.id;
    perform public.service_record_appointment_token_event(
      v_token.id, 'REVOKED', v_token.delivery_channel, v_token.destination_masked,
      null, null, p_request_id,
      jsonb_build_object('reason', left(btrim(coalesce(p_reason,'STATE_CHANGED')),200))
    );
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

create or replace function public.maintenance_purge_appointment_token_network_evidence(
  p_before timestamptz,
  p_reason text,
  p_requested_by text
)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count bigint;
begin
  if p_before is null or p_before > now() then
    raise exception using errcode = '22023', message = 'TOKEN_NETWORK_PURGE_CUTOFF_INVALID';
  end if;
  if p_reason is null or length(btrim(p_reason)) < 10 then
    raise exception using errcode = '22023', message = 'TOKEN_NETWORK_PURGE_REASON_REQUIRED';
  end if;
  if p_requested_by is null or length(btrim(p_requested_by)) < 3 then
    raise exception using errcode = '22023', message = 'TOKEN_NETWORK_PURGE_REQUESTOR_REQUIRED';
  end if;

  select count(*) into v_count
  from public.appointment_token_network_evidence
  where retain_until < p_before;

  insert into public.appointment_token_network_purge_runs(cutoff_before,reason,requested_by,rows_planned)
  values (p_before,btrim(p_reason),btrim(p_requested_by),v_count);

  perform set_config('app.token_network_purge_context','DEDICATED_TOKEN_NETWORK_PURGE',true);
  delete from public.appointment_token_network_evidence where retain_until < p_before;
  perform set_config('app.token_network_purge_context','',true);
  return v_count;
exception when others then
  perform set_config('app.token_network_purge_context','',true);
  raise;
end;
$$;

-- Application roles never call the DB primitives directly. Edge/internal services use service_role.
revoke execute on function public.service_record_appointment_token_event(uuid,text,text,text,inet,text,text,jsonb) from public, anon, authenticated;
revoke execute on function public.service_issue_appointment_action_token(uuid,text,text,text,text) from public, anon, authenticated;
revoke execute on function public.service_record_appointment_token_delivery(uuid,text,text,text,text) from public, anon, authenticated;
revoke execute on function public.service_resolve_appointment_action_token(text,text,inet,text,text) from public, anon, authenticated;
revoke execute on function public.service_verify_appointment_action_email(uuid,text,inet,text,text) from public, anon, authenticated;
revoke execute on function public.service_consume_appointment_action_token(uuid,text,inet,text,text,jsonb) from public, anon, authenticated;
revoke execute on function public.service_revoke_appointment_action_tokens(uuid,text,text) from public, anon, authenticated;
revoke execute on function public.maintenance_purge_appointment_token_network_evidence(timestamptz,text,text) from public, anon, authenticated, service_role;

grant execute on function public.service_record_appointment_token_event(uuid,text,text,text,inet,text,text,jsonb) to service_role;
grant execute on function public.service_issue_appointment_action_token(uuid,text,text,text,text) to service_role;
grant execute on function public.service_record_appointment_token_delivery(uuid,text,text,text,text) to service_role;
grant execute on function public.service_resolve_appointment_action_token(text,text,inet,text,text) to service_role;
grant execute on function public.service_verify_appointment_action_email(uuid,text,inet,text,text) to service_role;
grant execute on function public.service_consume_appointment_action_token(uuid,text,inet,text,text,jsonb) to service_role;
grant execute on function public.service_revoke_appointment_action_tokens(uuid,text,text) to service_role;
-- END RC MIGRATION 20260823044000_appointment_token_authorship_foundation.sql

-- BEGIN RC MIGRATION 20260823044100_token_verification_lockout_fix.sql
-- Once three invalid verification attempts have been recorded, both the appointment
-- and the origin remain blocked for the rest of the 24h window, even if a later
-- attempt supplies the correct email. This matches the resolved decision in #83.

create or replace function public.service_verify_appointment_action_email(
  p_token_id uuid,
  p_email text,
  p_ip_address inet default null,
  p_user_agent text default null,
  p_request_id text default null
)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_token public.appointment_access_tokens%rowtype;
  v_email text;
  v_ok boolean;
  v_origin_key text;
  v_appointment_key text;
  v_origin_hash text;
  v_appointment_hash text;
  v_now timestamptz := clock_timestamp();
begin
  select * into v_token
  from public.appointment_access_tokens
  where id = p_token_id
  for update;

  if not found
     or v_token.revoked_at is not null
     or v_token.consumed_at is not null
     or v_token.expires_at is null
     or v_token.expires_at <= v_now then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_TOKEN_INVALID';
  end if;
  if v_token.scope <> 'CANCEL' then
    raise exception using errcode = 'P0001', message = 'TOKEN_SCOPE_DENIED';
  end if;

  v_origin_key := 'origin:' || coalesce(host(p_ip_address), 'missing-origin');
  v_appointment_key := 'appointment:' || v_token.appointment_id::text;
  v_origin_hash := encode(digest(v_origin_key, 'sha256'), 'hex');
  v_appointment_hash := encode(digest(v_appointment_key, 'sha256'), 'hex');

  -- Assert lockout before evaluating the supplied email. A correct value after
  -- three invalid attempts must not bypass the protection.
  if exists (
    select 1
    from public.public_rate_limit_buckets b
    where b.scope = 'TOKEN_VERIFY_APPOINTMENT'
      and b.key_hash = v_appointment_hash
      and b.window_started_at + interval '1 day' > v_now
      and b.request_count >= 3
  ) or exists (
    select 1
    from public.public_rate_limit_buckets b
    where b.scope = 'TOKEN_VERIFY_ORIGIN'
      and b.key_hash = v_origin_hash
      and b.window_started_at + interval '1 day' > v_now
      and b.request_count >= 3
  ) then
    raise exception using errcode = 'P0001', message = 'RATE_LIMITED';
  end if;

  select lower(btrim(c.email)) into v_email
  from public.appointments a
  join public.customers c on c.id = a.primary_customer_id
  where a.id = v_token.appointment_id;

  v_ok := v_email is not null and lower(btrim(coalesce(p_email,''))) = v_email;
  if v_ok then
    perform public.service_record_appointment_token_event(
      v_token.id, 'VERIFIED', v_token.delivery_channel, v_token.destination_masked,
      p_ip_address, p_user_agent, p_request_id,
      jsonb_build_object('verification_method','REGISTERED_EMAIL')
    );
    return true;
  end if;

  perform public.service_consume_public_rate_limit(
    'TOKEN_VERIFY_APPOINTMENT', v_appointment_key, 3, 86400
  );
  perform public.service_consume_public_rate_limit(
    'TOKEN_VERIFY_ORIGIN', v_origin_key, 3, 86400
  );

  perform public.service_record_appointment_token_event(
    v_token.id, 'VERIFY_FAILED', v_token.delivery_channel, v_token.destination_masked,
    p_ip_address, p_user_agent, p_request_id,
    jsonb_build_object('verification_method','REGISTERED_EMAIL')
  );
  return false;
end;
$$;

revoke execute on function public.service_verify_appointment_action_email(uuid,text,inet,text,text)
  from public, anon, authenticated;
grant execute on function public.service_verify_appointment_action_email(uuid,text,inet,text,text)
  to service_role;
-- END RC MIGRATION 20260823044100_token_verification_lockout_fix.sql

-- BEGIN RC MIGRATION 20260823044200_version_hosted_rls_guard.sql
-- Version the hosted automatic RLS guard so clean rebuilds and the sandbox agree.
-- This helper already existed in the hosted project; bringing it into migrations
-- removes environment drift and ensures future public-schema tables start with RLS.

create or replace function public.rls_auto_enable()
returns event_trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  cmd record;
begin
  for cmd in
    select *
    from pg_event_trigger_ddl_commands()
    where command_tag in ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      and object_type in ('table','partitioned table')
  loop
    if cmd.schema_name is not null
       and cmd.schema_name = 'public'
       and cmd.schema_name not in ('pg_catalog','information_schema')
       and cmd.schema_name not like 'pg_toast%'
       and cmd.schema_name not like 'pg_temp%' then
      begin
        execute format('alter table if exists %s enable row level security', cmd.object_identity);
        raise log 'rls_auto_enable: enabled RLS on %', cmd.object_identity;
      exception
        when others then
          raise log 'rls_auto_enable: failed to enable RLS on %', cmd.object_identity;
      end;
    end if;
  end loop;
end;
$$;

revoke execute on function public.rls_auto_enable() from public, anon, authenticated;

-- CREATE EVENT TRIGGER has no IF NOT EXISTS. Recreate only when absent.
do $$
begin
  if not exists (select 1 from pg_event_trigger where evtname = 'ensure_rls') then
    create event trigger ensure_rls
      on ddl_command_end
      when tag in ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      execute function public.rls_auto_enable();
  end if;
end;
$$;
-- END RC MIGRATION 20260823044200_version_hosted_rls_guard.sql

-- BEGIN RC MIGRATION 20260823044300_change_workflow_audit_origin.sql
-- Client-originated change workflows were persisting audit origin as ADMIN in the
-- final cancel/apply steps even when the policy action explicitly said CLIENT.
-- Rewrite only that final audit argument, preserving the already-tested workflow body.

do $do$
declare
  v_def text;
  v_new text;
  v_old text := $$),'ADMIN');$$;
  v_replacement text := $$),case when p_change_origin='CLIENT' then 'CLIENT' else 'ADMIN' end);$$;
begin
  v_def := pg_get_functiondef('public.service_admin_cancel_appointment(uuid,text,text,timestamptz,text,uuid)'::regprocedure);
  if strpos(v_def, v_old) = 0 then
    raise exception 'CANCEL_AUDIT_ORIGIN_PATTERN_NOT_FOUND';
  end if;
  v_new := replace(v_def, v_old, v_replacement);
  if v_new = v_def then
    raise exception 'CANCEL_AUDIT_ORIGIN_NOT_REWRITTEN';
  end if;
  execute v_new;
end;
$do$;

do $do$
declare
  v_def text;
  v_new text;
  v_old text := $$),'ADMIN');$$;
  v_replacement text := $$),case when v_action.change_origin='CLIENT' then 'CLIENT' else 'ADMIN' end);$$;
begin
  v_def := pg_get_functiondef('public.service_admin_apply_reschedule(uuid,uuid)'::regprocedure);
  if strpos(v_def, v_old) = 0 then
    raise exception 'RESCHEDULE_AUDIT_ORIGIN_PATTERN_NOT_FOUND';
  end if;
  v_new := replace(v_def, v_old, v_replacement);
  if v_new = v_def then
    raise exception 'RESCHEDULE_AUDIT_ORIGIN_NOT_REWRITTEN';
  end if;
  execute v_new;
end;
$do$;
-- END RC MIGRATION 20260823044300_change_workflow_audit_origin.sql

-- BEGIN RC MIGRATION 20260823044400_revoke_action_tokens_on_appointment_change.sql
-- Action links are valid only for the appointment state/start time they were issued for.
-- Any status or start_at change revokes unconsumed action-specific tokens. Generic
-- VIEW/MANAGE/PAY tokens retain their existing behavior.

create or replace function public.revoke_action_tokens_after_appointment_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if old.status is distinct from new.status or old.start_at is distinct from new.start_at then
    perform public.service_revoke_appointment_action_tokens(
      new.id,
      case
        when old.status is distinct from new.status and old.start_at is distinct from new.start_at then 'APPOINTMENT_STATUS_AND_START_CHANGED'
        when old.status is distinct from new.status then 'APPOINTMENT_STATUS_CHANGED'
        else 'APPOINTMENT_START_CHANGED'
      end,
      null
    );
  end if;
  return new;
end;
$$;

revoke execute on function public.revoke_action_tokens_after_appointment_change()
  from public, anon, authenticated;

drop trigger if exists appointments_revoke_action_tokens on public.appointments;
create trigger appointments_revoke_action_tokens
after update of status, start_at on public.appointments
for each row
when (old.status is distinct from new.status or old.start_at is distinct from new.start_at)
execute function public.revoke_action_tokens_after_appointment_change();
-- END RC MIGRATION 20260823044400_revoke_action_tokens_on_appointment_change.sql

-- BEGIN RC MIGRATION 20260823080000_kommo_crm_v1_foundation.sql
-- V1 communication architecture:
-- Agenda is the booking authority; Kommo is the external CRM/communication mirror.
-- Only services explicitly classified as BLACKSHEEP are eligible for Kommo sync.
-- Sabrina services do not sync to Kommo and do not receive Agenda confirmation e-mail.
-- Provider credentials are intentionally NOT stored in the database.

create table public.kommo_integration_settings (
  id smallint primary key default 1 check (id = 1),
  enabled boolean not null default false,
  operation_scope text not null default 'BLACKSHEEP' check (operation_scope = 'BLACKSHEEP'),
  account_subdomain text,
  pipeline_id bigint,
  stage_awaiting_payment_id bigint,
  stage_confirmed_id bigint,
  stage_rescheduled_id bigint,
  stage_cancelled_id bigint,
  stage_completed_id bigint,
  stage_no_show_id bigint,
  stage_expired_id bigint,
  booking_mailbox text not null default 'agenda@blacksheepestudiocriativo.com.br',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (account_subdomain is null or account_subdomain ~ '^[a-z0-9][a-z0-9-]{1,62}$'),
  check (pipeline_id is null or pipeline_id > 0),
  check (stage_awaiting_payment_id is null or stage_awaiting_payment_id > 0),
  check (stage_confirmed_id is null or stage_confirmed_id > 0),
  check (stage_rescheduled_id is null or stage_rescheduled_id > 0),
  check (stage_cancelled_id is null or stage_cancelled_id > 0),
  check (stage_completed_id is null or stage_completed_id > 0),
  check (stage_no_show_id is null or stage_no_show_id > 0),
  check (stage_expired_id is null or stage_expired_id > 0)
);

insert into public.kommo_integration_settings (id)
values (1)
on conflict (id) do nothing;

create table public.kommo_customer_links (
  customer_id uuid primary key references public.customers(id) on delete cascade,
  kommo_contact_id bigint not null unique check (kommo_contact_id > 0),
  last_synced_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.kommo_appointment_links (
  appointment_id uuid primary key references public.appointments(id) on delete cascade,
  kommo_lead_id bigint not null unique check (kommo_lead_id > 0),
  kommo_contact_id bigint check (kommo_contact_id is null or kommo_contact_id > 0),
  last_synced_version integer check (last_synced_version is null or last_synced_version >= 1),
  last_synced_status text,
  last_synced_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index kommo_appointment_links_contact_idx
  on public.kommo_appointment_links (kommo_contact_id)
  where kommo_contact_id is not null;

alter table public.kommo_integration_settings enable row level security;
alter table public.kommo_customer_links enable row level security;
alter table public.kommo_appointment_links enable row level security;

revoke all on table public.kommo_integration_settings from public, anon, authenticated;
revoke all on table public.kommo_customer_links from public, anon, authenticated;
revoke all on table public.kommo_appointment_links from public, anon, authenticated;
grant select, insert, update, delete on table public.kommo_integration_settings to service_role;
grant select, insert, update, delete on table public.kommo_customer_links to service_role;
grant select, insert, update, delete on table public.kommo_appointment_links to service_role;

create or replace function public.get_kommo_appointment_desired_state(p_appointment_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_appointment public.appointments%rowtype;
  v_service public.services%rowtype;
  v_customer public.customers%rowtype;
  v_settings public.kommo_integration_settings%rowtype;
  v_stage_key text;
begin
  select * into v_appointment
  from public.appointments
  where id = p_appointment_id;

  if not found then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_NOT_FOUND';
  end if;

  select * into v_service
  from public.services
  where id = v_appointment.service_id;

  select * into v_settings
  from public.kommo_integration_settings
  where id = 1;

  if not found or not v_settings.enabled or v_service.operation_scope is distinct from 'BLACKSHEEP' then
    return jsonb_build_object(
      'appointment_id', v_appointment.id,
      'version', v_appointment.version,
      'eligible', false,
      'reason', case
        when v_service.operation_scope is distinct from 'BLACKSHEEP' then 'OPERATION_SCOPE_NOT_BLACKSHEEP'
        else 'KOMMO_DISABLED'
      end
    );
  end if;

  if v_appointment.primary_customer_id is not null then
    select * into v_customer
    from public.customers
    where id = v_appointment.primary_customer_id;
  end if;

  v_stage_key := case v_appointment.status
    when 'AWAITING_PAYMENT' then 'AWAITING_PAYMENT'
    when 'CONFIRMED' then 'CONFIRMED'
    when 'COMPLETED' then 'COMPLETED'
    when 'CANCELLED' then 'CANCELLED'
    when 'NO_SHOW' then 'NO_SHOW'
    when 'EXPIRED' then 'EXPIRED'
    else 'CREATED'
  end;

  return jsonb_build_object(
    'appointment_id', v_appointment.id,
    'public_code', v_appointment.public_code,
    'version', v_appointment.version,
    'eligible', true,
    'operation_scope', v_service.operation_scope,
    'appointment_status', v_appointment.status,
    'financial_status', v_appointment.financial_status,
    'stage_key', v_stage_key,
    'service', jsonb_build_object(
      'id', v_service.id,
      'name', coalesce(nullif(v_appointment.service_name_snapshot, ''), v_service.name)
    ),
    'schedule', jsonb_build_object(
      'start_at', v_appointment.start_at,
      'end_at', v_appointment.end_at
    ),
    'commercial_value', v_appointment.commercial_value,
    'customer', case when v_customer.id is null then null else jsonb_build_object(
      'id', v_customer.id,
      'name', v_customer.name,
      'email', v_customer.email,
      'phone', v_customer.phone
    ) end
  );
end;
$$;

revoke all on function public.get_kommo_appointment_desired_state(uuid) from public, anon, authenticated;
grant execute on function public.get_kommo_appointment_desired_state(uuid) to service_role;

create or replace function public.enqueue_kommo_appointment_sync(
  p_appointment_id uuid,
  p_event_kind text default 'UPDATED'
)
returns uuid
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_appointment public.appointments%rowtype;
  v_scope text;
  v_enabled boolean;
  v_job_id uuid;
  v_event text := upper(btrim(coalesce(p_event_kind, 'UPDATED')));
begin
  if v_event not in ('CREATED','UPDATED','RESCHEDULED','STATUS_CHANGED','FINANCIAL_CHANGED') then
    raise exception using errcode = 'P0001', message = 'KOMMO_EVENT_KIND_INVALID';
  end if;

  select * into v_appointment
  from public.appointments
  where id = p_appointment_id;

  if not found then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_NOT_FOUND';
  end if;

  select operation_scope into v_scope
  from public.services
  where id = v_appointment.service_id;

  select enabled into v_enabled
  from public.kommo_integration_settings
  where id = 1;

  if not coalesce(v_enabled, false) or v_scope is distinct from 'BLACKSHEEP' then
    return null;
  end if;

  insert into public.integration_jobs (
    job_type, entity_type, entity_id, entity_version,
    payload_json, status, run_after, idempotency_key
  ) values (
    'KOMMO_APPOINTMENT_SYNC',
    'APPOINTMENT',
    v_appointment.id,
    v_appointment.version,
    jsonb_build_object('event_kind', v_event),
    'PENDING',
    now(),
    'kommo-appointment:' || v_appointment.id::text || ':v' || v_appointment.version::text
  )
  on conflict (idempotency_key) do update
    set updated_at = public.integration_jobs.updated_at
  returning id into v_job_id;

  return v_job_id;
end;
$$;

revoke all on function public.enqueue_kommo_appointment_sync(uuid,text) from public, anon, authenticated;
grant execute on function public.enqueue_kommo_appointment_sync(uuid,text) to service_role;

create or replace function public.trg_enqueue_kommo_appointment_sync()
returns trigger
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_scope text;
  v_enabled boolean;
  v_event text;
begin
  select enabled into v_enabled from public.kommo_integration_settings where id = 1;
  if not coalesce(v_enabled, false) then
    return new;
  end if;

  select operation_scope into v_scope from public.services where id = new.service_id;
  if v_scope is distinct from 'BLACKSHEEP' then
    return new;
  end if;

  if tg_op = 'INSERT' then
    v_event := 'CREATED';
  elsif old.start_at is distinct from new.start_at or old.end_at is distinct from new.end_at then
    v_event := 'RESCHEDULED';
  elsif old.status is distinct from new.status then
    v_event := 'STATUS_CHANGED';
  elsif old.financial_status is distinct from new.financial_status then
    v_event := 'FINANCIAL_CHANGED';
  else
    v_event := 'UPDATED';
  end if;

  perform public.enqueue_kommo_appointment_sync(new.id, v_event);
  return new;
end;
$$;

revoke all on function public.trg_enqueue_kommo_appointment_sync() from public, anon, authenticated;

drop trigger if exists appointments_enqueue_kommo_sync on public.appointments;
create trigger appointments_enqueue_kommo_sync
after insert or update of status, financial_status, start_at, end_at, primary_customer_id, service_id, service_employee_id, commercial_value, version
on public.appointments
for each row execute function public.trg_enqueue_kommo_appointment_sync();

-- Direct WhatsApp recovery is retired from active V1 scope. Preserve historical
-- columns/tables for audit compatibility, but disable all public creation/resume paths
-- and stop enqueueing provider jobs.
update public.message_templates
set is_active = false,
    updated_at = now()
where template_key = 'checkout_hold_expired_recovery';

update public.checkout_holds
set recovery_enabled = false,
    recovery_phone = null,
    updated_at = now()
where recovery_enabled or recovery_phone is not null;

revoke all on function public.set_checkout_hold_recovery_contact(text,text,boolean) from public, anon, authenticated;
revoke all on function public.get_checkout_hold_resume_context(text) from public, anon, authenticated;
grant execute on function public.set_checkout_hold_recovery_contact(text,text,boolean) to service_role;
grant execute on function public.get_checkout_hold_resume_context(text) to service_role;

create or replace function public.expire_due_checkout_holds()
returns void
language plpgsql
volatile
set search_path = public
as $$
declare
  v_hold public.checkout_holds%rowtype;
begin
  for v_hold in
    select ch.*
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

    update public.checkout_hour_package_reservations
    set status = 'RELEASED',
        released_at = now(),
        release_reason = 'CHECKOUT_HOLD_EXPIRED',
        updated_at = now()
    where checkout_hold_id = v_hold.id
      and status = 'HELD';
  end loop;
end;
$$;

comment on table public.kommo_integration_settings is
  'BlackSheep-only external CRM configuration. Long-lived Kommo token is an Edge secret, never a database value. Integration is disabled until provider sandbox/account spike passes.';
comment on function public.get_kommo_appointment_desired_state(uuid) is
  'Canonical Agenda-to-Kommo projection. Agenda remains authoritative; Sabrina scope is never eligible.';
comment on function public.enqueue_kommo_appointment_sync(uuid,text) is
  'Idempotent outbox enqueue for one BlackSheep reservation. One Agenda appointment maps to one Kommo lead.';
-- END RC MIGRATION 20260823080000_kommo_crm_v1_foundation.sql

-- BEGIN RC MIGRATION 20260823091000_expired_hold_availability.sql
-- A checkout hold stops blocking public availability exactly at expires_at.
-- Physical cleanup remains authoritative before a new hold insert; this read-side rule
-- prevents stale HELD allocations from creating false unavailable slots in the UI.

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
  core_start_at timestamptz,
  core_end_at timestamptz,
  pre_service_minutes integer,
  post_service_minutes integer,
  duration_minutes integer,
  commercial_value numeric
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
          and (
            ra.status <> 'HELD'
            or ra.allocation_type <> 'CHECKOUT_HOLD'
            or exists (
              select 1
              from public.checkout_holds ch
              where ch.id = ra.checkout_hold_id
                and ch.status = 'ACTIVE'
                and ch.expires_at > now()
            )
          )
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

comment on function public.list_available_slots(uuid,uuid,jsonb,integer,date,text) is
  'Lists candidate slots. Expired checkout-hold allocations are ignored at read time; create_checkout_hold still performs authoritative expiry cleanup and exclusion-constraint enforcement.';
-- END RC MIGRATION 20260823091000_expired_hold_availability.sql

-- BEGIN RC MIGRATION 20260823092000_appointment_authorship_admin_evidence.sql
-- Complete the admin-side authorship chain required by Agenda issue #83.
-- Business audit_logs remain the domain audit ledger. This table stores the
-- request/actor evidence that audit_logs historically could not represent.

create table public.appointment_authorship_events (
  id uuid primary key default gen_random_uuid(),
  appointment_id uuid not null references public.appointments(id) on delete restrict,
  origin text not null check (origin in ('CLIENT_TOKEN','ADMIN_UI','SYSTEM_JOB','PROVIDER_WEBHOOK')),
  action text not null,
  admin_user_id uuid references public.admin_users(id) on delete set null,
  actor_role text,
  actor_permissions text[] not null default '{}'::text[],
  appointment_access_token_id uuid references public.appointment_access_tokens(id) on delete restrict,
  provider text,
  provider_event_id text,
  before_json jsonb,
  after_json jsonb,
  reason text,
  ip_address inet,
  user_agent text,
  request_id text,
  session_id text,
  occurred_at timestamptz not null default clock_timestamp(),
  network_retain_until timestamptz not null default (clock_timestamp() + interval '5 years')
);

create index appointment_authorship_events_appointment_time_idx
  on public.appointment_authorship_events(appointment_id, occurred_at, id);

alter table public.appointment_authorship_events enable row level security;
revoke all on table public.appointment_authorship_events from public, anon, authenticated, service_role;

create or replace function public.reject_appointment_authorship_mutation()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  raise exception using errcode = '42501', message = 'APPOINTMENT_AUTHORSHIP_APPEND_ONLY';
end;
$$;

create trigger appointment_authorship_events_append_only
before update or delete or truncate on public.appointment_authorship_events
for each statement execute function public.reject_appointment_authorship_mutation();

create or replace function public.service_admin_effective_permission_list(p_admin_id uuid)
returns text[]
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(array_agg(p.permission order by p.permission), '{}'::text[])
  from (values
    ('DASHBOARD_VIEW'),('AGENDA_VIEW'),('AGENDA_MANAGE'),
    ('CUSTOMERS_VIEW'),('CUSTOMERS_MANAGE'),
    ('FINANCE_VIEW'),('FINANCE_MANAGE'),
    ('PACKAGES_VIEW'),('PACKAGES_MANAGE'),
    ('SERVICES_VIEW'),('SERVICES_MANAGE'),
    ('INTEGRATIONS_VIEW'),('INTEGRATIONS_MANAGE'),
    ('AUDIT_VIEW'),('TEAM_MANAGE')
  ) p(permission)
  where public.service_admin_has_permission(p_admin_id, p.permission);
$$;

create or replace function public.service_appointment_authorship_snapshot(p_appointment_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'id', a.id,
    'public_code', a.public_code,
    'service_id', a.service_id,
    'service_employee_id', a.service_employee_id,
    'status', a.status,
    'financial_status', a.financial_status,
    'start_at', a.start_at,
    'end_at', a.end_at,
    'duration_minutes', a.duration_minutes,
    'duration_blocks', a.duration_blocks,
    'contracted_minutes', a.contracted_minutes,
    'people_count', a.people_count,
    'commercial_value', a.commercial_value,
    'confirmed_at', a.confirmed_at,
    'completed_at', a.completed_at,
    'cancelled_at', a.cancelled_at,
    'cancel_reason', a.cancel_reason,
    'no_show_at', a.no_show_at,
    'attendance_status', a.attendance_status,
    'core_start_at', a.core_start_at,
    'core_end_at', a.core_end_at,
    'version', a.version,
    'updated_at', a.updated_at
  )
  from public.appointments a
  where a.id = p_appointment_id;
$$;

create or replace function public.service_record_appointment_authorship_event(
  p_appointment_id uuid,
  p_origin text,
  p_action text,
  p_admin_id uuid default null,
  p_token_id uuid default null,
  p_before_json jsonb default null,
  p_after_json jsonb default null,
  p_reason text default null,
  p_ip inet default null,
  p_user_agent text default null,
  p_request_id text default null,
  p_session_id text default null,
  p_provider text default null,
  p_provider_event_id text default null
)
returns uuid
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_origin text := upper(btrim(coalesce(p_origin,'')));
  v_action text := upper(btrim(coalesce(p_action,'')));
  v_role text;
  v_permissions text[] := '{}'::text[];
  v_id uuid;
begin
  if v_origin not in ('CLIENT_TOKEN','ADMIN_UI','SYSTEM_JOB','PROVIDER_WEBHOOK') then
    raise exception using errcode = 'P0001', message = 'AUTHORSHIP_ORIGIN_INVALID';
  end if;
  if v_action = '' then
    raise exception using errcode = 'P0001', message = 'AUTHORSHIP_ACTION_REQUIRED';
  end if;
  if not exists (select 1 from public.appointments where id = p_appointment_id) then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_NOT_FOUND';
  end if;

  if v_origin = 'ADMIN_UI' then
    if p_admin_id is null or p_ip is null or nullif(btrim(coalesce(p_user_agent,'')),'') is null
       or nullif(btrim(coalesce(p_request_id,'')),'') is null then
      raise exception using errcode = 'P0001', message = 'AUTHORSHIP_ADMIN_EVIDENCE_REQUIRED';
    end if;
    select role into v_role from public.admin_users where id = p_admin_id and is_active = true;
    if v_role is null then
      raise exception using errcode = 'P0001', message = 'ADMIN_ACCESS_DENIED';
    end if;
    v_permissions := public.service_admin_effective_permission_list(p_admin_id);
  elsif v_origin = 'CLIENT_TOKEN' and p_token_id is null then
    raise exception using errcode = 'P0001', message = 'AUTHORSHIP_TOKEN_REQUIRED';
  elsif v_origin = 'PROVIDER_WEBHOOK' and nullif(btrim(coalesce(p_provider,'')),'') is null then
    raise exception using errcode = 'P0001', message = 'AUTHORSHIP_PROVIDER_REQUIRED';
  end if;

  insert into public.appointment_authorship_events(
    appointment_id, origin, action, admin_user_id, actor_role, actor_permissions,
    appointment_access_token_id, provider, provider_event_id,
    before_json, after_json, reason, ip_address, user_agent, request_id, session_id
  ) values (
    p_appointment_id, v_origin, v_action, p_admin_id, v_role, v_permissions,
    p_token_id, nullif(btrim(coalesce(p_provider,'')),''), nullif(btrim(coalesce(p_provider_event_id,'')),''),
    p_before_json, p_after_json, nullif(btrim(coalesce(p_reason,'')),''), p_ip,
    nullif(btrim(coalesce(p_user_agent,'')),''), nullif(btrim(coalesce(p_request_id,'')),''),
    nullif(btrim(coalesce(p_session_id,'')),'')
  ) returning id into v_id;

  return v_id;
end;
$$;

create or replace function public.service_admin_cancel_appointment_evidenced(
  p_appointment_id uuid,
  p_settlement_choice text,
  p_reason text,
  p_requested_at timestamptz,
  p_change_origin text,
  p_admin_id uuid,
  p_ip inet,
  p_user_agent text,
  p_request_id text,
  p_session_id text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_before jsonb;
  v_after jsonb;
  v_result jsonb;
begin
  if not public.service_admin_has_permission(p_admin_id, 'AGENDA_MANAGE') then
    raise exception using errcode = 'P0001', message = 'ADMIN_PERMISSION_DENIED';
  end if;
  if p_ip is null or nullif(btrim(coalesce(p_user_agent,'')),'') is null or nullif(btrim(coalesce(p_request_id,'')),'') is null then
    raise exception using errcode = 'P0001', message = 'AUTHORSHIP_ADMIN_EVIDENCE_REQUIRED';
  end if;

  v_before := public.service_appointment_authorship_snapshot(p_appointment_id);
  if v_before is null then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_NOT_FOUND';
  end if;

  v_result := public.service_admin_cancel_appointment(
    p_appointment_id, p_settlement_choice, p_reason, p_requested_at, p_change_origin, p_admin_id
  );
  v_after := public.service_appointment_authorship_snapshot(p_appointment_id);

  if v_before is distinct from v_after then
    perform public.service_record_appointment_authorship_event(
      p_appointment_id, 'ADMIN_UI', 'APPOINTMENT_CANCELLED', p_admin_id, null,
      v_before, v_after, p_reason, p_ip, p_user_agent, p_request_id, p_session_id, null, null
    );
  end if;
  return v_result;
end;
$$;

create or replace function public.service_admin_apply_reschedule_evidenced(
  p_policy_action_id uuid,
  p_admin_id uuid,
  p_ip inet,
  p_user_agent text,
  p_request_id text,
  p_session_id text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_appointment_id uuid;
  v_before jsonb;
  v_after jsonb;
  v_result jsonb;
begin
  if not public.service_admin_has_permission(p_admin_id, 'AGENDA_MANAGE') then
    raise exception using errcode = 'P0001', message = 'ADMIN_PERMISSION_DENIED';
  end if;
  if p_ip is null or nullif(btrim(coalesce(p_user_agent,'')),'') is null or nullif(btrim(coalesce(p_request_id,'')),'') is null then
    raise exception using errcode = 'P0001', message = 'AUTHORSHIP_ADMIN_EVIDENCE_REQUIRED';
  end if;

  select appointment_id into v_appointment_id
  from public.appointment_policy_actions where id = p_policy_action_id;
  if v_appointment_id is null then
    raise exception using errcode = 'P0001', message = 'POLICY_ACTION_NOT_FOUND';
  end if;

  v_before := public.service_appointment_authorship_snapshot(v_appointment_id);
  v_result := public.service_admin_apply_reschedule(p_policy_action_id, p_admin_id);
  v_after := public.service_appointment_authorship_snapshot(v_appointment_id);

  if v_before is distinct from v_after then
    perform public.service_record_appointment_authorship_event(
      v_appointment_id, 'ADMIN_UI', 'APPOINTMENT_RESCHEDULED', p_admin_id, null,
      v_before, v_after, null, p_ip, p_user_agent, p_request_id, p_session_id, null, null
    );
  end if;
  return v_result;
end;
$$;

create or replace function public.service_admin_get_appointment_token_security_state(
  p_appointment_id uuid,
  p_admin_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  v_appointment_hash text;
  v_appointment_count integer := 0;
  v_locked_origins integer := 0;
  v_active_tokens integer := 0;
begin
  if not public.service_admin_has_permission(p_admin_id, 'AUDIT_VIEW') then
    raise exception using errcode = 'P0001', message = 'ADMIN_PERMISSION_DENIED';
  end if;
  if not exists (select 1 from public.appointments where id = p_appointment_id) then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_NOT_FOUND';
  end if;

  v_appointment_hash := encode(digest('appointment:'||p_appointment_id::text,'sha256'),'hex');
  select coalesce(max(request_count),0) into v_appointment_count
  from public.public_rate_limit_buckets
  where scope='TOKEN_VERIFY_APPOINTMENT' and key_hash=v_appointment_hash
    and window_started_at + interval '1 day' > clock_timestamp();

  with failed_ips as (
    select distinct host(ne.ip_address) ip
    from public.appointment_access_tokens t
    join public.appointment_token_events e on e.appointment_access_token_id=t.id and e.event_type='VERIFY_FAILED'
    join public.appointment_token_network_evidence ne on ne.token_event_id=e.id
    where t.appointment_id=p_appointment_id and ne.ip_address is not null
  )
  select count(*)::integer into v_locked_origins
  from failed_ips f
  join public.public_rate_limit_buckets b
    on b.scope='TOKEN_VERIFY_ORIGIN'
   and b.key_hash=encode(digest('origin:'||f.ip,'sha256'),'hex')
   and b.window_started_at + interval '1 day' > clock_timestamp()
   and b.request_count >= 3;

  select count(*)::integer into v_active_tokens
  from public.appointment_access_tokens t
  where t.appointment_id=p_appointment_id
    and t.revoked_at is null and t.consumed_at is null
    and t.expires_at > clock_timestamp();

  return jsonb_build_object(
    'appointment_locked', v_appointment_count >= 3,
    'appointment_attempt_count', v_appointment_count,
    'locked_origin_count', v_locked_origins,
    'locked', (v_appointment_count >= 3 or v_locked_origins > 0),
    'active_token_count', v_active_tokens
  );
end;
$$;

create or replace function public.service_admin_unlock_appointment_token_verification(
  p_appointment_id uuid,
  p_admin_id uuid,
  p_reason text,
  p_ip inet,
  p_user_agent text,
  p_request_id text,
  p_session_id text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_reason text := nullif(btrim(coalesce(p_reason,'')),'');
  v_appointment_hash text;
  v_before jsonb;
  v_after jsonb;
  v_origin record;
begin
  if not public.service_admin_has_permission(p_admin_id, 'AGENDA_MANAGE')
     or not public.service_admin_has_permission(p_admin_id, 'AUDIT_VIEW') then
    raise exception using errcode = 'P0001', message = 'ADMIN_PERMISSION_DENIED';
  end if;
  if v_reason is null then
    raise exception using errcode = 'P0001', message = 'UNLOCK_REASON_REQUIRED';
  end if;
  if p_ip is null or nullif(btrim(coalesce(p_user_agent,'')),'') is null or nullif(btrim(coalesce(p_request_id,'')),'') is null then
    raise exception using errcode = 'P0001', message = 'AUTHORSHIP_ADMIN_EVIDENCE_REQUIRED';
  end if;

  v_before := public.service_admin_get_appointment_token_security_state(p_appointment_id, p_admin_id);
  v_appointment_hash := encode(digest('appointment:'||p_appointment_id::text,'sha256'),'hex');

  delete from public.public_rate_limit_buckets
  where scope='TOKEN_VERIFY_APPOINTMENT' and key_hash=v_appointment_hash;

  for v_origin in
    select distinct host(ne.ip_address) ip
    from public.appointment_access_tokens t
    join public.appointment_token_events e on e.appointment_access_token_id=t.id and e.event_type='VERIFY_FAILED'
    join public.appointment_token_network_evidence ne on ne.token_event_id=e.id
    where t.appointment_id=p_appointment_id and ne.ip_address is not null
  loop
    delete from public.public_rate_limit_buckets
    where scope='TOKEN_VERIFY_ORIGIN'
      and key_hash=encode(digest('origin:'||v_origin.ip,'sha256'),'hex');
  end loop;

  v_after := public.service_admin_get_appointment_token_security_state(p_appointment_id, p_admin_id);
  perform public.service_record_appointment_authorship_event(
    p_appointment_id, 'ADMIN_UI', 'TOKEN_VERIFICATION_UNLOCKED', p_admin_id, null,
    v_before, v_after, v_reason, p_ip, p_user_agent, p_request_id, p_session_id, null, null
  );
  return v_after;
end;
$$;

create or replace function public.service_admin_get_appointment_timeline(
  p_appointment_id uuid,
  p_admin_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_security jsonb;
  v_events jsonb;
begin
  if not public.service_admin_has_permission(p_admin_id, 'AUDIT_VIEW') then
    raise exception using errcode = 'P0001', message = 'ADMIN_PERMISSION_DENIED';
  end if;
  if not exists (select 1 from public.appointments where id=p_appointment_id) then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_NOT_FOUND';
  end if;

  v_security := public.service_admin_get_appointment_token_security_state(p_appointment_id, p_admin_id);

  with timeline as (
    select
      al.created_at occurred_at,
      'BUSINESS_AUDIT' source,
      al.id source_id,
      case
        when upper(coalesce(al.origin,'')) in ('ADMIN','OPERATION','ADMIN_UI') then 'ADMIN_UI'
        when upper(coalesce(al.origin,'')) in ('CLIENT','CLIENT_TOKEN') then 'CLIENT_TOKEN'
        when upper(coalesce(al.origin,'')) in ('MERCADO_PAGO','GOOGLE','PROVIDER','PROVIDER_WEBHOOK') then 'PROVIDER_WEBHOOK'
        else 'SYSTEM_JOB'
      end origin,
      al.action,
      al.admin_user_id,
      au.display_name actor_name,
      au.role actor_role,
      null::text[] actor_permissions,
      al.before_json,
      al.after_json,
      null::text reason,
      null::text ip_address,
      null::text user_agent,
      al.request_id::text request_id,
      null::text token_scope,
      null::text destination_masked,
      null::text provider,
      concat('Ação registrada: ', replace(al.action,'_',' ')) summary
    from public.audit_logs al
    left join public.admin_users au on au.id=al.admin_user_id
    where al.entity_id=p_appointment_id
       or al.entity_id in (select id from public.appointment_policy_actions where appointment_id=p_appointment_id)

    union all

    select
      ae.occurred_at,
      'AUTHORSHIP' source,
      ae.id source_id,
      ae.origin,
      ae.action,
      ae.admin_user_id,
      au.display_name actor_name,
      ae.actor_role,
      ae.actor_permissions,
      ae.before_json,
      ae.after_json,
      ae.reason,
      host(ae.ip_address) ip_address,
      ae.user_agent,
      ae.request_id,
      t.scope token_scope,
      t.destination_masked,
      ae.provider,
      case ae.action
        when 'APPOINTMENT_CANCELLED' then 'Reserva cancelada pela administração'
        when 'APPOINTMENT_RESCHEDULED' then 'Reserva remarcada pela administração'
        when 'TOKEN_VERIFICATION_UNLOCKED' then 'Bloqueio de verificação do link liberado pela administração'
        else concat('Evidência de autoria: ', replace(ae.action,'_',' '))
      end summary
    from public.appointment_authorship_events ae
    left join public.admin_users au on au.id=ae.admin_user_id
    left join public.appointment_access_tokens t on t.id=ae.appointment_access_token_id
    where ae.appointment_id=p_appointment_id

    union all

    select
      e.occurred_at,
      'TOKEN_EVIDENCE' source,
      e.id source_id,
      'CLIENT_TOKEN' origin,
      e.event_type action,
      null::uuid admin_user_id,
      null::text actor_name,
      null::text actor_role,
      null::text[] actor_permissions,
      null::jsonb before_json,
      e.metadata_json after_json,
      null::text reason,
      host(ne.ip_address) ip_address,
      ne.user_agent,
      e.request_id,
      t.scope token_scope,
      e.destination_masked,
      null::text provider,
      case e.event_type
        when 'ISSUED' then 'Link pessoal emitido'
        when 'ACCESS' then 'Link pessoal acessado'
        when 'VERIFY_FAILED' then 'Verificação adicional recusada'
        when 'VERIFIED' then 'E-mail cadastrado verificado'
        when 'ACTION_EXECUTED' then 'Ação do link executada'
        when 'CONSUMED' then 'Link consumido após uso'
        when 'REVOKED' then 'Link revogado após mudança da reserva'
        else concat('Evento do link: ', replace(e.event_type,'_',' '))
      end summary
    from public.appointment_access_tokens t
    join public.appointment_token_events e on e.appointment_access_token_id=t.id
    left join lateral (
      select n.ip_address,n.user_agent
      from public.appointment_token_network_evidence n
      where n.token_event_id=e.id
      order by n.occurred_at desc limit 1
    ) ne on true
    where t.appointment_id=p_appointment_id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'occurred_at', occurred_at,
    'source', source,
    'id', source_id,
    'origin', origin,
    'action', action,
    'admin_user_id', admin_user_id,
    'actor_name', actor_name,
    'actor_role', actor_role,
    'actor_permissions', actor_permissions,
    'before', before_json,
    'after', after_json,
    'reason', reason,
    'ip_address', ip_address,
    'user_agent', user_agent,
    'request_id', request_id,
    'token_scope', token_scope,
    'destination_masked', destination_masked,
    'provider', provider,
    'summary', summary
  ) order by occurred_at, source, source_id), '[]'::jsonb) into v_events
  from timeline;

  return jsonb_build_object('appointment_id',p_appointment_id,'security',v_security,'events',v_events);
end;
$$;

revoke all on function public.service_admin_effective_permission_list(uuid) from public, anon, authenticated;
revoke all on function public.service_appointment_authorship_snapshot(uuid) from public, anon, authenticated;
revoke all on function public.service_record_appointment_authorship_event(uuid,text,text,uuid,uuid,jsonb,jsonb,text,inet,text,text,text,text,text) from public, anon, authenticated;
revoke all on function public.service_admin_cancel_appointment_evidenced(uuid,text,text,timestamptz,text,uuid,inet,text,text,text) from public, anon, authenticated;
revoke all on function public.service_admin_apply_reschedule_evidenced(uuid,uuid,inet,text,text,text) from public, anon, authenticated;
revoke all on function public.service_admin_get_appointment_token_security_state(uuid,uuid) from public, anon, authenticated;
revoke all on function public.service_admin_unlock_appointment_token_verification(uuid,uuid,text,inet,text,text,text) from public, anon, authenticated;
revoke all on function public.service_admin_get_appointment_timeline(uuid,uuid) from public, anon, authenticated;

grant execute on function public.service_admin_effective_permission_list(uuid) to service_role;
grant execute on function public.service_appointment_authorship_snapshot(uuid) to service_role;
grant execute on function public.service_record_appointment_authorship_event(uuid,text,text,uuid,uuid,jsonb,jsonb,text,inet,text,text,text,text,text) to service_role;
grant execute on function public.service_admin_cancel_appointment_evidenced(uuid,text,text,timestamptz,text,uuid,inet,text,text,text) to service_role;
grant execute on function public.service_admin_apply_reschedule_evidenced(uuid,uuid,inet,text,text,text) to service_role;
grant execute on function public.service_admin_get_appointment_token_security_state(uuid,uuid) to service_role;
grant execute on function public.service_admin_unlock_appointment_token_verification(uuid,uuid,text,inet,text,text,text) to service_role;
grant execute on function public.service_admin_get_appointment_timeline(uuid,uuid) to service_role;
-- END RC MIGRATION 20260823092000_appointment_authorship_admin_evidence.sql

-- BEGIN RC MIGRATION 20260823093000_client_token_cancel_action.sql
-- Public client cancellation must be executed by the same request that proves
-- possession of the action token and knowledge of the registered email.
-- The token is consumed before the appointment mutation, in the same database
-- transaction, so any downstream cancellation failure rolls consumption back.

create or replace function public.service_client_cancel_appointment_evidenced(
  p_token_id uuid,
  p_reason text,
  p_requested_at timestamptz,
  p_ip inet,
  p_user_agent text,
  p_request_id text,
  p_session_id text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_token public.appointment_access_tokens%rowtype;
  v_appointment public.appointments%rowtype;
  v_before jsonb;
  v_after jsonb;
  v_result jsonb;
  v_verified boolean := false;
  v_request_id text := nullif(left(btrim(coalesce(p_request_id,'')), 200), '');
begin
  if p_token_id is null then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_TOKEN_INVALID';
  end if;
  if p_requested_at is null then
    raise exception using errcode = 'P0001', message = 'CANCELLATION_REQUESTED_AT_REQUIRED';
  end if;
  if p_ip is null or nullif(btrim(coalesce(p_user_agent,'')), '') is null or v_request_id is null then
    raise exception using errcode = 'P0001', message = 'AUTHORSHIP_CLIENT_EVIDENCE_REQUIRED';
  end if;

  select * into v_token
  from public.appointment_access_tokens
  where id = p_token_id
  for update;

  if not found
     or v_token.scope <> 'CANCEL'
     or v_token.revoked_at is not null
     or v_token.consumed_at is not null
     or v_token.expires_at is null
     or v_token.expires_at <= clock_timestamp() then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_TOKEN_INVALID';
  end if;

  select * into v_appointment
  from public.appointments
  where id = v_token.appointment_id
    and deleted_at is null
  for update;

  if not found
     or v_appointment.start_at <= clock_timestamp()
     or v_token.expires_at <> v_appointment.start_at then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_TOKEN_INVALID';
  end if;

  select exists(
    select 1
    from public.appointment_token_events e
    where e.appointment_access_token_id = v_token.id
      and e.event_type = 'VERIFIED'
      and e.request_id = v_request_id
  ) into v_verified;

  if not v_verified then
    raise exception using errcode = 'P0001', message = 'CANCEL_EMAIL_VERIFICATION_REQUIRED';
  end if;

  v_before := public.service_appointment_authorship_snapshot(v_appointment.id);

  perform public.service_consume_appointment_action_token(
    v_token.id,
    'CANCEL_CONFIRMED',
    p_ip,
    p_user_agent,
    v_request_id,
    jsonb_build_object(
      'financial_action', true,
      'verification_method', 'REGISTERED_EMAIL',
      'settlement', 'REFUND_DEFAULT'
    )
  );

  v_result := public.service_admin_cancel_appointment(
    v_appointment.id,
    null,
    nullif(left(btrim(coalesce(p_reason,'')), 500), ''),
    p_requested_at,
    'CLIENT',
    null
  );

  v_after := public.service_appointment_authorship_snapshot(v_appointment.id);
  if v_before is distinct from v_after then
    perform public.service_record_appointment_authorship_event(
      v_appointment.id,
      'CLIENT_TOKEN',
      'APPOINTMENT_CANCELLED',
      null,
      v_token.id,
      v_before,
      v_after,
      nullif(left(btrim(coalesce(p_reason,'')), 500), ''),
      p_ip,
      p_user_agent,
      v_request_id,
      p_session_id,
      null,
      null
    );
  end if;

  return v_result || jsonb_build_object('token_consumed', true);
end;
$$;

revoke all on function public.service_client_cancel_appointment_evidenced(uuid,text,timestamptz,inet,text,text,text)
  from public, anon, authenticated;
grant execute on function public.service_client_cancel_appointment_evidenced(uuid,text,timestamptz,inet,text,text,text)
  to service_role;
-- END RC MIGRATION 20260823093000_client_token_cancel_action.sql

-- BEGIN RC MIGRATION 20260823094000_client_token_reschedule_action.sql
-- Public client rescheduling keeps slot discovery/hold creation separate from the
-- final appointment mutation. Financially consequential changes require the
-- registered-email verification to belong to the same executing request.

create or replace function public.service_client_reschedule_requirements(
  p_token_id uuid,
  p_policy_action_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_token public.appointment_access_tokens%rowtype;
  v_action public.appointment_policy_actions%rowtype;
  v_settlement public.appointment_change_settlements%rowtype;
  v_appointment public.appointments%rowtype;
  v_hold public.checkout_holds%rowtype;
  v_current_funds numeric(12,2);
  v_after_penalty numeric(12,2);
  v_outstanding numeric(12,2);
  v_financial boolean;
begin
  select * into v_token from public.appointment_access_tokens where id=p_token_id;
  if not found
     or v_token.scope <> 'RESCHEDULE'
     or v_token.revoked_at is not null
     or v_token.consumed_at is not null
     or v_token.expires_at is null
     or v_token.expires_at <= clock_timestamp() then
    raise exception using errcode='P0001',message='APPOINTMENT_TOKEN_INVALID';
  end if;

  select * into v_appointment from public.appointments
  where id=v_token.appointment_id and deleted_at is null;
  if not found
     or v_appointment.status <> 'CONFIRMED'
     or v_appointment.start_at <= clock_timestamp()
     or v_token.expires_at <> v_appointment.start_at then
    raise exception using errcode='P0001',message='APPOINTMENT_TOKEN_INVALID';
  end if;

  select * into v_action from public.appointment_policy_actions where id=p_policy_action_id;
  if not found
     or v_action.appointment_id <> v_appointment.id
     or v_action.action_type <> 'RESCHEDULE'
     or v_action.change_origin <> 'CLIENT'
     or v_action.status not in ('PREVIEW','AWAITING_DIFFERENCE_PAYMENT') then
    raise exception using errcode='P0001',message='CLIENT_RESCHEDULE_ACTION_INVALID';
  end if;

  select * into v_settlement from public.appointment_change_settlements
  where policy_action_id=v_action.id;
  if not found then raise exception using errcode='P0001',message='CHANGE_SETTLEMENT_NOT_FOUND'; end if;

  select * into v_hold from public.checkout_holds where id=v_action.reschedule_checkout_hold_id;
  if not found or v_hold.status<>'ACTIVE' or v_hold.expires_at<=clock_timestamp() then
    raise exception using errcode='P0001',message='RESCHEDULE_HOLD_EXPIRED';
  end if;

  v_current_funds:=public.appointment_customer_funds_amount(v_appointment.id);
  v_after_penalty:=round(greatest(v_current_funds-coalesce(v_settlement.penalty_retained,0),0),2);
  v_outstanding:=round(greatest(coalesce(v_settlement.new_contract_value,0)-v_after_penalty,0),2);
  v_financial:=
    coalesce(v_settlement.penalty_retained,0)>0.005
    or abs(coalesce(v_settlement.new_contract_value,0)-coalesce(v_settlement.contract_value,0))>0.005
    or coalesce(v_settlement.difference_due,0)>0.005;

  return jsonb_build_object(
    'appointment_id',v_appointment.id,
    'policy_action_id',v_action.id,
    'hold_expires_at',v_hold.expires_at,
    'new_start_at',v_hold.requested_start_at,
    'new_end_at',v_hold.requested_end_at,
    'contract_value',v_settlement.contract_value,
    'new_contract_value',v_settlement.new_contract_value,
    'penalty_amount',v_settlement.penalty_retained,
    'outstanding_difference',v_outstanding,
    'requires_payment',v_outstanding>0.005,
    'requires_email_verification',v_financial
  );
end;
$$;

create or replace function public.service_client_apply_reschedule_evidenced(
  p_token_id uuid,
  p_policy_action_id uuid,
  p_ip inet,
  p_user_agent text,
  p_request_id text,
  p_session_id text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_token public.appointment_access_tokens%rowtype;
  v_action public.appointment_policy_actions%rowtype;
  v_requirements jsonb;
  v_requires_email boolean;
  v_verified boolean := false;
  v_before jsonb;
  v_after jsonb;
  v_result jsonb;
  v_request_id text:=nullif(left(btrim(coalesce(p_request_id,'')),200),'');
begin
  if p_token_id is null or p_policy_action_id is null then
    raise exception using errcode='P0001',message='CLIENT_RESCHEDULE_ACTION_INVALID';
  end if;
  if p_ip is null or nullif(btrim(coalesce(p_user_agent,'')),'') is null or v_request_id is null then
    raise exception using errcode='P0001',message='AUTHORSHIP_CLIENT_EVIDENCE_REQUIRED';
  end if;

  select * into v_token from public.appointment_access_tokens where id=p_token_id for update;
  if not found
     or v_token.scope<>'RESCHEDULE'
     or v_token.revoked_at is not null
     or v_token.consumed_at is not null
     or v_token.expires_at is null
     or v_token.expires_at<=clock_timestamp() then
    raise exception using errcode='P0001',message='APPOINTMENT_TOKEN_INVALID';
  end if;

  select * into v_action from public.appointment_policy_actions where id=p_policy_action_id for update;
  if not found or v_action.appointment_id<>v_token.appointment_id then
    raise exception using errcode='P0001',message='CLIENT_RESCHEDULE_ACTION_INVALID';
  end if;

  v_requirements:=public.service_client_reschedule_requirements(v_token.id,v_action.id);
  v_requires_email:=coalesce((v_requirements->>'requires_email_verification')::boolean,false);

  if v_requires_email then
    select exists(
      select 1 from public.appointment_token_events e
      where e.appointment_access_token_id=v_token.id
        and e.event_type='VERIFIED'
        and e.request_id=v_request_id
    ) into v_verified;
    if not v_verified then
      raise exception using errcode='P0001',message='RESCHEDULE_EMAIL_VERIFICATION_REQUIRED';
    end if;
  end if;

  v_before:=public.service_appointment_authorship_snapshot(v_token.appointment_id);

  perform public.service_consume_appointment_action_token(
    v_token.id,
    'RESCHEDULE_CONFIRMED',
    p_ip,
    p_user_agent,
    v_request_id,
    jsonb_build_object(
      'financial_action',v_requires_email,
      'verification_method',case when v_requires_email then 'REGISTERED_EMAIL' else 'TOKEN_ONLY' end,
      'policy_action_id',v_action.id
    )
  );

  -- If a difference is still unpaid or the hold expired, this raises and the
  -- surrounding transaction restores the token to unconsumed state.
  v_result:=public.service_admin_apply_reschedule(v_action.id,null);

  v_after:=public.service_appointment_authorship_snapshot(v_token.appointment_id);
  if v_before is distinct from v_after then
    perform public.service_record_appointment_authorship_event(
      v_token.appointment_id,
      'CLIENT_TOKEN',
      'APPOINTMENT_RESCHEDULED',
      null,
      v_token.id,
      v_before,
      v_after,
      null,
      p_ip,
      p_user_agent,
      v_request_id,
      p_session_id,
      null,
      null
    );
  end if;

  return v_result || jsonb_build_object(
    'token_consumed',true,
    'required_email_verification',v_requires_email
  );
end;
$$;

revoke all on function public.service_client_reschedule_requirements(uuid,uuid) from public,anon,authenticated;
grant execute on function public.service_client_reschedule_requirements(uuid,uuid) to service_role;
revoke all on function public.service_client_apply_reschedule_evidenced(uuid,uuid,inet,text,text,text) from public,anon,authenticated;
grant execute on function public.service_client_apply_reschedule_evidenced(uuid,uuid,inet,text,text,text) to service_role;
-- END RC MIGRATION 20260823094000_client_token_reschedule_action.sql

-- BEGIN RC MIGRATION 20260823094100_token_verification_action_scopes.sql
-- Registered-email verification is shared by the two customer actions that can
-- change the reservation state or financial settlement. Keep the same distributed
-- lockout/evidence behavior while allowing RESCHEDULE tokens in addition to CANCEL.

create or replace function public.service_verify_appointment_action_email(
  p_token_id uuid,
  p_email text,
  p_ip_address inet default null,
  p_user_agent text default null,
  p_request_id text default null
)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_token public.appointment_access_tokens%rowtype;
  v_email text;
  v_ok boolean;
  v_origin_key text;
  v_appointment_key text;
  v_origin_hash text;
  v_appointment_hash text;
  v_now timestamptz := clock_timestamp();
begin
  select * into v_token
  from public.appointment_access_tokens
  where id = p_token_id
  for update;

  if not found
     or v_token.revoked_at is not null
     or v_token.consumed_at is not null
     or v_token.expires_at is null
     or v_token.expires_at <= v_now then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_TOKEN_INVALID';
  end if;

  if v_token.scope not in ('CANCEL', 'RESCHEDULE') then
    raise exception using errcode = 'P0001', message = 'TOKEN_SCOPE_DENIED';
  end if;

  v_origin_key := 'origin:' || coalesce(host(p_ip_address), 'missing-origin');
  v_appointment_key := 'appointment:' || v_token.appointment_id::text;
  v_origin_hash := encode(digest(v_origin_key, 'sha256'), 'hex');
  v_appointment_hash := encode(digest(v_appointment_key, 'sha256'), 'hex');

  if exists (
    select 1
    from public.public_rate_limit_buckets b
    where b.scope = 'TOKEN_VERIFY_APPOINTMENT'
      and b.key_hash = v_appointment_hash
      and b.window_started_at + interval '1 day' > v_now
      and b.request_count >= 3
  ) or exists (
    select 1
    from public.public_rate_limit_buckets b
    where b.scope = 'TOKEN_VERIFY_ORIGIN'
      and b.key_hash = v_origin_hash
      and b.window_started_at + interval '1 day' > v_now
      and b.request_count >= 3
  ) then
    raise exception using errcode = 'P0001', message = 'RATE_LIMITED';
  end if;

  select lower(btrim(c.email)) into v_email
  from public.appointments a
  join public.customers c on c.id = a.primary_customer_id
  where a.id = v_token.appointment_id;

  v_ok := v_email is not null and lower(btrim(coalesce(p_email,''))) = v_email;
  if v_ok then
    perform public.service_record_appointment_token_event(
      v_token.id, 'VERIFIED', v_token.delivery_channel, v_token.destination_masked,
      p_ip_address, p_user_agent, p_request_id,
      jsonb_build_object('verification_method','REGISTERED_EMAIL','scope',v_token.scope)
    );
    return true;
  end if;

  perform public.service_consume_public_rate_limit(
    'TOKEN_VERIFY_APPOINTMENT', v_appointment_key, 3, 86400
  );
  perform public.service_consume_public_rate_limit(
    'TOKEN_VERIFY_ORIGIN', v_origin_key, 3, 86400
  );

  perform public.service_record_appointment_token_event(
    v_token.id, 'VERIFY_FAILED', v_token.delivery_channel, v_token.destination_masked,
    p_ip_address, p_user_agent, p_request_id,
    jsonb_build_object('verification_method','REGISTERED_EMAIL','scope',v_token.scope)
  );
  return false;
end;
$$;

revoke execute on function public.service_verify_appointment_action_email(uuid,text,inet,text,text)
  from public, anon, authenticated;
grant execute on function public.service_verify_appointment_action_email(uuid,text,inet,text,text)
  to service_role;

comment on function public.service_verify_appointment_action_email(uuid,text,inet,text,text) is
  'Verifies the registered customer email for CANCEL or RESCHEDULE action tokens using shared 24h appointment/origin lockout and append-only evidence.';
-- END RC MIGRATION 20260823094100_token_verification_action_scopes.sql

-- BEGIN RC MIGRATION 20260823095000_action_token_public_summary.sql
-- Safe public summary for tokenized appointment actions.
-- The summary deliberately excludes customer/contact/payment details and is only
-- callable by the server-side service role after the action token was resolved.

create or replace function public.service_appointment_action_public_summary(
  p_token_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_token public.appointment_access_tokens%rowtype;
  v_appointment public.appointments%rowtype;
  v_service public.services%rowtype;
  v_resource_name text;
  v_status_label text;
begin
  select * into v_token
  from public.appointment_access_tokens
  where id = p_token_id;

  if not found
     or v_token.scope not in ('CANCEL','RESCHEDULE')
     or v_token.revoked_at is not null
     or v_token.consumed_at is not null
     or v_token.expires_at is null
     or v_token.expires_at <= now() then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_TOKEN_INVALID';
  end if;

  select * into v_appointment
  from public.appointments
  where id = v_token.appointment_id
    and deleted_at is null;

  if not found
     or v_appointment.start_at <= now()
     or v_token.expires_at <> v_appointment.start_at then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_TOKEN_INVALID';
  end if;

  select * into v_service
  from public.services
  where id = v_appointment.service_id;

  if not found then
    raise exception using errcode = 'P0001', message = 'SERVICE_NOT_FOUND';
  end if;

  v_resource_name := case
    when v_service.operation_scope = 'BLACKSHEEP' then 'BlackSheep Estúdio Criativo'
    else null
  end;

  v_status_label := case v_appointment.status::text
    when 'CONFIRMED' then 'Confirmada'
    when 'AWAITING_PAYMENT' then 'Aguardando pagamento'
    when 'CANCELLED' then 'Cancelada'
    when 'COMPLETED' then 'Concluída'
    when 'NO_SHOW' then 'Não compareceu'
    else 'Em andamento'
  end;

  return jsonb_strip_nulls(jsonb_build_object(
    'public_code', v_appointment.public_code,
    'service_name', coalesce(v_appointment.service_name_snapshot, v_service.name),
    'resource_name', v_resource_name,
    'operation_scope', v_service.operation_scope,
    'start_at', v_appointment.start_at,
    'end_at', v_appointment.end_at,
    'status_label', v_status_label
  ));
end;
$$;

revoke all on function public.service_appointment_action_public_summary(uuid)
from public, anon, authenticated;
grant execute on function public.service_appointment_action_public_summary(uuid) to service_role;

comment on function public.service_appointment_action_public_summary(uuid) is
  'Returns the minimal non-PII appointment summary needed by the tokenized cancel/reschedule UI. Requires a currently valid CANCEL or RESCHEDULE token id and exposes no customer/contact/payment data.';
-- END RC MIGRATION 20260823095000_action_token_public_summary.sql

-- BEGIN RC MIGRATION 20260823096000_revoke_authorship_trigger_execute.sql
-- Trigger-only function: PostgreSQL triggers execute it as the function owner.
-- It is not part of the public/admin RPC surface and must never be callable
-- directly through PostgREST by anon, authenticated or service_role.

revoke execute on function public.reject_appointment_authorship_mutation()
from public, anon, authenticated, service_role;

comment on function public.reject_appointment_authorship_mutation() is
  'Internal trigger-only append-only guard. Direct EXECUTE is intentionally revoked from API roles.';
-- END RC MIGRATION 20260823096000_revoke_authorship_trigger_execute.sql

-- BEGIN RC MIGRATION 20260823165000_kommo_blacksheep_pipeline_mapping.sql
alter table public.kommo_integration_settings
  add column if not exists stage_initial_contact_id bigint;

alter table public.kommo_integration_settings
  drop constraint if exists kommo_integration_settings_stage_initial_contact_id_check;

alter table public.kommo_integration_settings
  add constraint kommo_integration_settings_stage_initial_contact_id_check
  check (stage_initial_contact_id is null or stage_initial_contact_id > 0);

update public.kommo_integration_settings
set account_subdomain = 'pierriquintproducoes',
    pipeline_id = 11507124,
    stage_initial_contact_id = 88360028,
    stage_awaiting_payment_id = 88360032,
    stage_confirmed_id = 88360036,
    stage_rescheduled_id = 95038752,
    stage_completed_id = 95038756,
    stage_cancelled_id = 96091804,
    stage_no_show_id = 96091808,
    stage_expired_id = 110702983,
    updated_at = now()
where id = 1;

comment on column public.kommo_integration_settings.stage_initial_contact_id is
  'BlackSheep pre-booking CRM stage. Customer identity is resolved globally in Kommo Contacts by exact normalized phone. This stage is used only to optionally reuse one unclaimed pre-booking lead; one contact may have multiple reservation leads.';
-- END RC MIGRATION 20260823165000_kommo_blacksheep_pipeline_mapping.sql

-- BEGIN RC MIGRATION 20260823172000_kommo_card_projection.sql
-- Kommo card projection for BlackSheep reservations.
-- Agenda remains authoritative. Kommo mirrors operational/card data only.
-- Shared Kommo lead card semantics:
--   Data            <- appointment.start_at (America/Sao_Paulo in Edge adapter)
--   Venda           <- appointment.commercial_value (Kommo built-in lead price)
--   Saldo           <- get_appointment_financial_summary().contract_balance
--   Extras locação  <- appointment_extras snapshots

create or replace function public.get_kommo_appointment_desired_state(p_appointment_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_appointment public.appointments%rowtype;
  v_service public.services%rowtype;
  v_customer public.customers%rowtype;
  v_settings public.kommo_integration_settings%rowtype;
  v_stage_key text;
  v_financial jsonb;
  v_extras jsonb;
begin
  select * into v_appointment
  from public.appointments
  where id = p_appointment_id;

  if not found then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_NOT_FOUND';
  end if;

  select * into v_service
  from public.services
  where id = v_appointment.service_id;

  select * into v_settings
  from public.kommo_integration_settings
  where id = 1;

  if not found or not v_settings.enabled or v_service.operation_scope is distinct from 'BLACKSHEEP' then
    return jsonb_build_object(
      'appointment_id', v_appointment.id,
      'version', v_appointment.version,
      'eligible', false,
      'reason', case
        when v_service.operation_scope is distinct from 'BLACKSHEEP' then 'OPERATION_SCOPE_NOT_BLACKSHEEP'
        else 'KOMMO_DISABLED'
      end
    );
  end if;

  if v_appointment.primary_customer_id is not null then
    select * into v_customer
    from public.customers
    where id = v_appointment.primary_customer_id;
  end if;

  v_stage_key := case v_appointment.status
    when 'AWAITING_PAYMENT' then 'AWAITING_PAYMENT'
    when 'CONFIRMED' then 'CONFIRMED'
    when 'COMPLETED' then 'COMPLETED'
    when 'CANCELLED' then 'CANCELLED'
    when 'NO_SHOW' then 'NO_SHOW'
    when 'EXPIRED' then 'EXPIRED'
    else 'CREATED'
  end;

  v_financial := public.get_appointment_financial_summary(v_appointment.id);

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', ae.id,
        'extra_id', ae.extra_id,
        'name', ae.name_snapshot,
        'quantity', ae.quantity,
        'unit_price', ae.unit_price_snapshot,
        'total_price', ae.total_price
      ) order by ae.created_at, ae.id
    ),
    '[]'::jsonb
  ) into v_extras
  from public.appointment_extras ae
  where ae.appointment_id = v_appointment.id;

  return jsonb_build_object(
    'appointment_id', v_appointment.id,
    'public_code', v_appointment.public_code,
    'version', v_appointment.version,
    'eligible', true,
    'operation_scope', v_service.operation_scope,
    'appointment_status', v_appointment.status,
    'financial_status', v_appointment.financial_status,
    'stage_key', v_stage_key,
    'service', jsonb_build_object(
      'id', v_service.id,
      'name', coalesce(nullif(v_appointment.service_name_snapshot, ''), v_service.name)
    ),
    'schedule', jsonb_build_object(
      'start_at', v_appointment.start_at,
      'end_at', v_appointment.end_at
    ),
    'commercial_value', v_appointment.commercial_value,
    'financial', v_financial,
    'extras', v_extras,
    'customer', case when v_customer.id is null then null else jsonb_build_object(
      'id', v_customer.id,
      'name', v_customer.name,
      'email', v_customer.email,
      'phone', v_customer.phone
    ) end
  );
end;
$$;

revoke all on function public.get_kommo_appointment_desired_state(uuid) from public, anon, authenticated;
grant execute on function public.get_kommo_appointment_desired_state(uuid) to service_role;

-- Appointment version is intentionally not the sole idempotency dimension. Financial
-- coverage and extras can change while the appointment version remains unchanged.
-- Fingerprinting the canonical projection lets those same-version changes enqueue safely.
create or replace function public.enqueue_kommo_appointment_sync(
  p_appointment_id uuid,
  p_event_kind text default 'UPDATED'
)
returns uuid
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_appointment public.appointments%rowtype;
  v_scope text;
  v_enabled boolean;
  v_job_id uuid;
  v_event text := upper(btrim(coalesce(p_event_kind, 'UPDATED')));
  v_projection jsonb;
  v_fingerprint text;
begin
  if v_event not in ('CREATED','UPDATED','RESCHEDULED','STATUS_CHANGED','FINANCIAL_CHANGED','EXTRAS_CHANGED') then
    raise exception using errcode = 'P0001', message = 'KOMMO_EVENT_KIND_INVALID';
  end if;

  select * into v_appointment
  from public.appointments
  where id = p_appointment_id;

  if not found then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_NOT_FOUND';
  end if;

  select operation_scope into v_scope
  from public.services
  where id = v_appointment.service_id;

  select enabled into v_enabled
  from public.kommo_integration_settings
  where id = 1;

  if not coalesce(v_enabled, false) or v_scope is distinct from 'BLACKSHEEP' then
    return null;
  end if;

  v_projection := public.get_kommo_appointment_desired_state(v_appointment.id);
  if coalesce((v_projection->>'eligible')::boolean, false) is not true then
    return null;
  end if;

  v_fingerprint := md5(v_projection::text || ':' || v_event);

  insert into public.integration_jobs (
    job_type, entity_type, entity_id, entity_version,
    payload_json, status, run_after, idempotency_key
  ) values (
    'KOMMO_APPOINTMENT_SYNC',
    'APPOINTMENT',
    v_appointment.id,
    v_appointment.version,
    jsonb_build_object('event_kind', v_event, 'projection_fingerprint', v_fingerprint),
    'PENDING',
    now(),
    'kommo-appointment:' || v_appointment.id::text || ':v' || v_appointment.version::text || ':' || lower(v_event) || ':' || v_fingerprint
  )
  on conflict (idempotency_key) do update
    set updated_at = public.integration_jobs.updated_at
  returning id into v_job_id;

  return v_job_id;
end;
$$;

revoke all on function public.enqueue_kommo_appointment_sync(uuid,text) from public, anon, authenticated;
grant execute on function public.enqueue_kommo_appointment_sync(uuid,text) to service_role;

-- Payment rows can change Saldo without changing appointment.version. Mirror every
-- authoritative contract-payment mutation through the same outbox function.
create or replace function public.trg_enqueue_kommo_payment_sync()
returns trigger
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_appointment_id uuid;
begin
  v_appointment_id := case when tg_op = 'DELETE' then old.appointment_id else new.appointment_id end;
  if v_appointment_id is not null then
    perform public.enqueue_kommo_appointment_sync(v_appointment_id, 'FINANCIAL_CHANGED');
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

revoke all on function public.trg_enqueue_kommo_payment_sync() from public, anon, authenticated, service_role;

drop trigger if exists payment_transactions_enqueue_kommo_sync on public.payment_transactions;
create trigger payment_transactions_enqueue_kommo_sync
after insert or delete or update of status, contract_amount_settled, payment_discount_amount, cash_amount, transaction_type, payment_purpose, parent_transaction_id
on public.payment_transactions
for each row execute function public.trg_enqueue_kommo_payment_sync();

-- Extras are appointment-owned snapshots. Any add/edit/remove must update the existing
-- lead card rather than create a new lead.
create or replace function public.trg_enqueue_kommo_extra_sync()
returns trigger
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_appointment_id uuid;
begin
  v_appointment_id := case when tg_op = 'DELETE' then old.appointment_id else new.appointment_id end;
  if v_appointment_id is not null then
    perform public.enqueue_kommo_appointment_sync(v_appointment_id, 'EXTRAS_CHANGED');
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

revoke all on function public.trg_enqueue_kommo_extra_sync() from public, anon, authenticated, service_role;

drop trigger if exists appointment_extras_enqueue_kommo_sync on public.appointment_extras;
create trigger appointment_extras_enqueue_kommo_sync
after insert or delete or update of extra_id, name_snapshot, unit_price_snapshot, quantity, total_price
on public.appointment_extras
for each row execute function public.trg_enqueue_kommo_extra_sync();

comment on function public.get_kommo_appointment_desired_state(uuid) is
  'Canonical Agenda-to-Kommo projection including reservation date, authoritative finance balance and contracted extras. Agenda remains authoritative.';
comment on function public.enqueue_kommo_appointment_sync(uuid,text) is
  'Idempotent Kommo outbox enqueue keyed by canonical projection fingerprint so same-version finance/extra changes are mirrored safely.';
comment on function public.trg_enqueue_kommo_payment_sync() is
  'Internal trigger only: refresh Kommo Saldo after payment/refund mutations.';
comment on function public.trg_enqueue_kommo_extra_sync() is
  'Internal trigger only: refresh Kommo Extras locação after appointment-extra mutations.';
-- END RC MIGRATION 20260823172000_kommo_card_projection.sql

-- BEGIN RC MIGRATION 20260823204500_integration_production_security_hardening.sql
-- Production hardening discovered during the integration audit on 2026-08-23.
-- Direct browser/database access is deny-by-default. Public booking reads remain exposed
-- only through the intentionally public SECURITY DEFINER RPC contracts.

revoke all privileges on all tables in schema public from anon, authenticated;
revoke all privileges on all sequences in schema public from anon, authenticated;

-- Preserve the five intentional public booking RPCs. Their definitions already pin
-- search_path=public and untrusted roles cannot CREATE in public, preventing object shadowing.
grant execute on function public.public_get_booking_page(text) to anon, authenticated;
grant execute on function public.public_list_available_slots(text, uuid, uuid, jsonb, integer, date) to anon, authenticated;
grant execute on function public.public_list_available_slots_duration(text, uuid, uuid, integer, jsonb, integer, date) to anon, authenticated;
grant execute on function public.public_quote_booking(text, uuid, uuid, jsonb, integer) to anon, authenticated;
grant execute on function public.public_quote_booking_duration(text, uuid, uuid, integer, jsonb, integer) to anon, authenticated;

-- Future objects must be granted deliberately instead of inheriting broad browser rights.
alter default privileges in schema public revoke all privileges on tables from anon, authenticated;
alter default privileges in schema public revoke all privileges on sequences from anon, authenticated;
alter default privileges in schema public revoke execute on functions from anon, authenticated;

-- Cover foreign keys reported by the Supabase performance advisor. These are additive
-- indexes only; no existing integrity/uniqueness index is removed.
create index if not exists admin_user_permissions_updated_by_idx
  on public.admin_user_permissions(updated_by_admin_id);
create index if not exists authorship_events_admin_user_idx
  on public.appointment_authorship_events(admin_user_id);
create index if not exists authorship_events_access_token_idx
  on public.appointment_authorship_events(appointment_access_token_id);
create index if not exists final_settlements_admin_user_idx
  on public.appointment_final_settlements(admin_user_id);
create index if not exists policy_actions_refund_tx_idx
  on public.appointment_policy_actions(refund_transaction_id);
create index if not exists booking_page_services_service_idx
  on public.booking_page_services(service_id);
create index if not exists coupon_services_service_idx
  on public.coupon_services(service_id);
create index if not exists coupons_customer_idx
  on public.coupons(customer_id);
create index if not exists coupons_source_appointment_idx
  on public.coupons(source_appointment_id);
create index if not exists balance_movements_admin_user_idx
  on public.customer_balance_movements(admin_user_id);
create index if not exists balance_refund_requests_admin_idx
  on public.customer_balance_refund_requests(admin_user_id);
create index if not exists prebook_authorized_services_service_idx
  on public.customer_prebook_authorized_services(service_id);
create index if not exists extra_resources_resource_idx
  on public.extra_resources(resource_id);
create index if not exists google_calendar_resources_resource_idx
  on public.google_calendar_resources(resource_id);
create index if not exists google_oauth_states_admin_idx
  on public.google_oauth_states(requested_by_admin_user_id);
create index if not exists google_watch_channels_calendar_idx
  on public.google_watch_channels(google_calendar_id);
create index if not exists hour_package_services_service_idx
  on public.hour_package_services(service_id);
create index if not exists legacy_amelia_first_batch_idx
  on public.legacy_amelia_bookings(first_import_batch_id);
create index if not exists legacy_amelia_last_batch_idx
  on public.legacy_amelia_bookings(last_import_batch_id);
create index if not exists legacy_amelia_matched_customer_idx
  on public.legacy_amelia_bookings(matched_customer_id);
create index if not exists legacy_amelia_batches_admin_idx
  on public.legacy_amelia_import_batches(created_by_admin_user_id);
create index if not exists operation_settings_occupancy_resource_idx
  on public.operation_settings(dashboard_occupancy_resource_id);
create index if not exists employee_calendar_write_calendar_idx
  on public.service_employee_calendar_write(google_calendar_id);
-- END RC MIGRATION 20260823204500_integration_production_security_hardening.sql
