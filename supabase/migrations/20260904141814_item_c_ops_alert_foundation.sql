-- Item C: sanitized operational alert evidence and deduplication state.

create table public.ops_edge_failure_events (
  id bigint generated always as identity primary key,
  function_name text not null check (function_name in (
    'booking-hold',
    'booking-checkout',
    'booking-submit',
    'mercado-pago-payment'
  )),
  error_code text not null check (error_code ~ '^[A-Z][A-Z0-9_]{1,79}$'),
  http_status integer not null check (http_status between 400 and 599),
  occurred_at timestamptz not null default now()
);

create index ops_edge_failure_events_occurred_idx
  on public.ops_edge_failure_events (occurred_at desc);

create table public.ops_alert_states (
  fingerprint text primary key check (fingerprint ~ '^[A-Z0-9_:]{3,240}$'),
  category text not null check (category in (
    'PAYMENT_STUCK',
    'EDGE_FAILURE',
    'INTEGRATION_FAILURES',
    'SCHEDULE_DIVERGENCE',
    'EMAIL_FAILURE'
  )),
  source text not null check (source ~ '^[A-Z][A-Z0-9_]{1,79}$'),
  code text not null check (code ~ '^[A-Z][A-Z0-9_]{1,79}$'),
  occurrence_count integer not null check (occurrence_count > 0),
  first_detected_at timestamptz not null,
  last_seen_at timestamptz not null,
  last_notified_at timestamptz,
  notification_count integer not null default 0 check (notification_count >= 0),
  resolved_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index ops_alert_states_active_idx
  on public.ops_alert_states (last_seen_at desc)
  where resolved_at is null;

alter table public.ops_edge_failure_events enable row level security;
alter table public.ops_alert_states enable row level security;

revoke all on public.ops_edge_failure_events from public, anon, authenticated, service_role;
revoke all on public.ops_alert_states from public, anon, authenticated, service_role;
revoke all on sequence public.ops_edge_failure_events_id_seq from public, anon, authenticated, service_role;

grant select on public.ops_edge_failure_events to service_role;
grant select, insert, update on public.ops_alert_states to service_role;

create or replace function public.service_record_ops_edge_failure(
  p_function_name text,
  p_error_code text,
  p_http_status integer
)
returns bigint
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id bigint;
begin
  if p_function_name is null or p_function_name not in (
    'booking-hold',
    'booking-checkout',
    'booking-submit',
    'mercado-pago-payment'
  ) then
    raise exception using errcode = 'P0001', message = 'OPS_EDGE_FUNCTION_DENIED';
  end if;

  if p_error_code is null or p_error_code !~ '^[A-Z][A-Z0-9_]{1,79}$' then
    raise exception using errcode = 'P0001', message = 'OPS_EDGE_CODE_INVALID';
  end if;

  if p_http_status is null or p_http_status not between 400 and 599 then
    raise exception using errcode = 'P0001', message = 'OPS_EDGE_HTTP_STATUS_INVALID';
  end if;

  insert into public.ops_edge_failure_events(function_name,error_code,http_status)
  values(p_function_name,p_error_code,p_http_status)
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.service_record_ops_edge_failure(text,text,integer) from public, anon, authenticated;
grant execute on function public.service_record_ops_edge_failure(text,text,integer) to service_role;

comment on table public.ops_edge_failure_events is
  'Sanitized operational telemetry only. Never store request bodies, identifiers, PII, tokens, card values or credentials.';
comment on table public.ops_alert_states is
  'Aggregate alert deduplication state. Contains only sanitized category/source/code metadata.';
