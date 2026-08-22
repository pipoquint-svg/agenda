-- Issue #83: non-repudiation evidence for cancellation/rescheduling.
-- Administrative mutations must not complete without request evidence.
-- Future token-based mutations must record possession of a secret token, never
-- misrepresent that as password-authenticated customer identity.

create table public.appointment_change_evidence (
  id uuid primary key default gen_random_uuid(),
  appointment_id uuid not null references public.appointments(id) on delete restrict,
  policy_action_id uuid references public.appointment_policy_actions(id) on delete restrict,
  action_type text not null check (action_type in ('CANCEL','RESCHEDULE')),
  event_type text not null check (event_type in ('REQUESTED','APPLIED')),
  actor_kind text not null check (actor_kind in ('ADMIN_USER','TOKEN_LINK')),
  admin_user_id uuid references public.admin_users(id) on delete restrict,
  appointment_access_token_id uuid references public.appointment_access_tokens(id) on delete restrict,
  channel text not null check (channel in ('ADMIN_UI','TOKEN_LINK')),
  request_id uuid not null,
  ip_address inet not null,
  ip_source text not null check (ip_source in ('CF_CONNECTING_IP','X_FORWARDED_FOR','X_REAL_IP')),
  user_agent text not null check (length(btrim(user_agent)) between 1 and 500),
  occurred_at timestamptz not null default clock_timestamp(),
  evidence_version text not null default 'V1',
  created_at timestamptz not null default clock_timestamp(),
  constraint appointment_change_evidence_actor_shape check (
    (
      actor_kind = 'ADMIN_USER'
      and admin_user_id is not null
      and appointment_access_token_id is null
      and channel = 'ADMIN_UI'
    )
    or
    (
      actor_kind = 'TOKEN_LINK'
      and admin_user_id is null
      and appointment_access_token_id is not null
      and channel = 'TOKEN_LINK'
    )
  )
);

create index appointment_change_evidence_appointment_idx
  on public.appointment_change_evidence(appointment_id, occurred_at);
create index appointment_change_evidence_policy_action_idx
  on public.appointment_change_evidence(policy_action_id, occurred_at)
  where policy_action_id is not null;
create index appointment_change_evidence_request_idx
  on public.appointment_change_evidence(request_id, occurred_at);

create or replace function public.reject_appointment_change_evidence_mutation()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  raise exception using errcode = 'P0001', message = 'APPOINTMENT_CHANGE_EVIDENCE_APPEND_ONLY';
end;
$$;

create trigger appointment_change_evidence_reject_update_delete
before update or delete on public.appointment_change_evidence
for each row execute function public.reject_appointment_change_evidence_mutation();

create trigger appointment_change_evidence_reject_truncate
before truncate on public.appointment_change_evidence
for each statement execute function public.reject_appointment_change_evidence_mutation();

revoke insert, update, delete, truncate on table public.appointment_change_evidence
  from public, anon, authenticated, service_role;
revoke all on function public.reject_appointment_change_evidence_mutation()
  from public, anon, authenticated, service_role;
grant select on table public.appointment_change_evidence to service_role;

create or replace function public.service_assert_change_request_evidence(
  p_request_ip inet,
  p_ip_source text,
  p_user_agent text,
  p_request_id uuid
)
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if p_request_ip is null then
    raise exception using errcode = 'P0001', message = 'CHANGE_REQUEST_IP_REQUIRED';
  end if;
  if p_ip_source not in ('CF_CONNECTING_IP','X_FORWARDED_FOR','X_REAL_IP') then
    raise exception using errcode = 'P0001', message = 'CHANGE_REQUEST_IP_SOURCE_INVALID';
  end if;
  if p_user_agent is null or length(btrim(p_user_agent)) = 0 or length(p_user_agent) > 500 then
    raise exception using errcode = 'P0001', message = 'CHANGE_REQUEST_USER_AGENT_REQUIRED';
  end if;
  if p_request_id is null then
    raise exception using errcode = 'P0001', message = 'CHANGE_REQUEST_ID_REQUIRED';
  end if;
end;
$$;

revoke all on function public.service_assert_change_request_evidence(inet,text,text,uuid)
  from public, anon, authenticated;
grant execute on function public.service_assert_change_request_evidence(inet,text,text,uuid)
  to service_role;

create or replace function public.service_admin_cancel_appointment_evidenced(
  p_appointment_id uuid,
  p_settlement_choice text,
  p_reason text,
  p_admin_id uuid,
  p_request_ip inet,
  p_ip_source text,
  p_user_agent text,
  p_request_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_requested_at timestamptz := clock_timestamp();
  v_result jsonb;
  v_policy_action_id uuid;
begin
  if not public.service_admin_has_permission(p_admin_id, 'AGENDA_MANAGE') then
    raise exception using errcode = 'P0001', message = 'ADMIN_PERMISSION_DENIED';
  end if;

  perform public.service_assert_change_request_evidence(
    p_request_ip, p_ip_source, p_user_agent, p_request_id
  );

  v_result := public.service_admin_cancel_appointment(
    p_appointment_id,
    p_settlement_choice,
    p_reason,
    v_requested_at,
    p_admin_id
  );

  v_policy_action_id := nullif(v_result->>'policy_action_id', '')::uuid;

  -- If cancellation was already completed before this request, do not fabricate a
  -- new request/applied pair for the historical mutation.
  if coalesce((v_result->>'already_cancelled')::boolean, false) then
    return v_result || jsonb_build_object('evidence_recorded', false, 'evidence_reason', 'ALREADY_CANCELLED');
  end if;

  insert into public.appointment_change_evidence(
    appointment_id, policy_action_id, action_type, event_type,
    actor_kind, admin_user_id, channel,
    request_id, ip_address, ip_source, user_agent, occurred_at
  ) values
  (
    p_appointment_id, v_policy_action_id, 'CANCEL', 'REQUESTED',
    'ADMIN_USER', p_admin_id, 'ADMIN_UI',
    p_request_id, p_request_ip, p_ip_source, left(p_user_agent, 500), v_requested_at
  ),
  (
    p_appointment_id, v_policy_action_id, 'CANCEL', 'APPLIED',
    'ADMIN_USER', p_admin_id, 'ADMIN_UI',
    p_request_id, p_request_ip, p_ip_source, left(p_user_agent, 500), clock_timestamp()
  );

  return v_result || jsonb_build_object('evidence_recorded', true, 'request_id', p_request_id);
end;
$$;

create or replace function public.service_admin_create_reschedule_hold_evidenced(
  p_appointment_id uuid,
  p_requested_start_at timestamptz,
  p_admin_id uuid,
  p_request_ip inet,
  p_ip_source text,
  p_user_agent text,
  p_request_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_requested_at timestamptz := clock_timestamp();
  v_result jsonb;
  v_policy_action_id uuid;
begin
  if not public.service_admin_has_permission(p_admin_id, 'AGENDA_MANAGE') then
    raise exception using errcode = 'P0001', message = 'ADMIN_PERMISSION_DENIED';
  end if;

  perform public.service_assert_change_request_evidence(
    p_request_ip, p_ip_source, p_user_agent, p_request_id
  );

  v_result := public.service_admin_create_reschedule_hold(
    p_appointment_id,
    p_requested_start_at,
    v_requested_at,
    p_admin_id
  );
  v_policy_action_id := (v_result->>'policy_action_id')::uuid;

  insert into public.appointment_change_evidence(
    appointment_id, policy_action_id, action_type, event_type,
    actor_kind, admin_user_id, channel,
    request_id, ip_address, ip_source, user_agent, occurred_at
  ) values (
    p_appointment_id, v_policy_action_id, 'RESCHEDULE', 'REQUESTED',
    'ADMIN_USER', p_admin_id, 'ADMIN_UI',
    p_request_id, p_request_ip, p_ip_source, left(p_user_agent, 500), v_requested_at
  );

  insert into public.audit_logs(
    admin_user_id, entity_type, entity_id, action, before_json, after_json, origin, request_id
  ) values (
    p_admin_id, 'APPOINTMENT', p_appointment_id, 'APPOINTMENT_RESCHEDULE_REQUESTED',
    jsonb_build_object('policy_action_id', v_policy_action_id),
    jsonb_build_object(
      'policy_action_id', v_policy_action_id,
      'requested_new_start_at', p_requested_start_at,
      'evidence_id', (
        select e.id from public.appointment_change_evidence e
        where e.request_id = p_request_id
          and e.event_type = 'REQUESTED'
          and e.policy_action_id = v_policy_action_id
        order by e.created_at desc limit 1
      )
    ),
    'ADMIN', p_request_id
  );

  return v_result || jsonb_build_object('evidence_recorded', true, 'request_id', p_request_id);
end;
$$;

create or replace function public.service_admin_apply_reschedule_evidenced(
  p_policy_action_id uuid,
  p_admin_id uuid,
  p_request_ip inet,
  p_ip_source text,
  p_user_agent text,
  p_request_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_result jsonb;
  v_appointment_id uuid;
begin
  if not public.service_admin_has_permission(p_admin_id, 'AGENDA_MANAGE') then
    raise exception using errcode = 'P0001', message = 'ADMIN_PERMISSION_DENIED';
  end if;

  perform public.service_assert_change_request_evidence(
    p_request_ip, p_ip_source, p_user_agent, p_request_id
  );

  v_result := public.service_admin_apply_reschedule(p_policy_action_id, p_admin_id);
  v_appointment_id := (v_result->>'appointment_id')::uuid;

  if coalesce((v_result->>'already_applied')::boolean, false) then
    return v_result || jsonb_build_object('evidence_recorded', false, 'evidence_reason', 'ALREADY_APPLIED');
  end if;

  insert into public.appointment_change_evidence(
    appointment_id, policy_action_id, action_type, event_type,
    actor_kind, admin_user_id, channel,
    request_id, ip_address, ip_source, user_agent, occurred_at
  ) values (
    v_appointment_id, p_policy_action_id, 'RESCHEDULE', 'APPLIED',
    'ADMIN_USER', p_admin_id, 'ADMIN_UI',
    p_request_id, p_request_ip, p_ip_source, left(p_user_agent, 500), clock_timestamp()
  );

  return v_result || jsonb_build_object('evidence_recorded', true, 'request_id', p_request_id);
end;
$$;

-- User-facing service-role paths must go through the evidence-enforcing wrappers.
revoke execute on function public.service_admin_cancel_appointment(uuid,text,text,timestamptz,uuid)
  from service_role;
revoke execute on function public.service_admin_create_reschedule_hold(uuid,timestamptz,timestamptz,uuid)
  from service_role;
revoke execute on function public.service_admin_apply_reschedule(uuid,uuid)
  from service_role;

revoke all on function public.service_admin_cancel_appointment_evidenced(uuid,text,text,uuid,inet,text,text,uuid)
  from public, anon, authenticated;
revoke all on function public.service_admin_create_reschedule_hold_evidenced(uuid,timestamptz,uuid,inet,text,text,uuid)
  from public, anon, authenticated;
revoke all on function public.service_admin_apply_reschedule_evidenced(uuid,uuid,inet,text,text,uuid)
  from public, anon, authenticated;

grant execute on function public.service_admin_cancel_appointment_evidenced(uuid,text,text,uuid,inet,text,text,uuid)
  to service_role;
grant execute on function public.service_admin_create_reschedule_hold_evidenced(uuid,timestamptz,uuid,inet,text,text,uuid)
  to service_role;
grant execute on function public.service_admin_apply_reschedule_evidenced(uuid,uuid,inet,text,text,uuid)
  to service_role;

comment on table public.appointment_change_evidence is
  'Append-only evidence trail for cancellation/rescheduling requests and applications. TOKEN_LINK means possession of an opaque secret link, not password-authenticated identity.';
