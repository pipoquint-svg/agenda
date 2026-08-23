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
