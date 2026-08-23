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
