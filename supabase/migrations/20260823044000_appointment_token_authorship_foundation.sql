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
