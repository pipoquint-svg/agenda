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
