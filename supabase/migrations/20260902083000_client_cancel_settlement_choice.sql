create or replace function public.service_client_cancel_appointment_evidenced_v2(
  p_token_id uuid,
  p_settlement_choice text,
  p_reason text,
  p_requested_at timestamptz,
  p_ip inet,
  p_user_agent text,
  p_request_id text,
  p_session_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_token public.appointment_access_tokens%rowtype;
  v_appointment public.appointments%rowtype;
  v_before jsonb;
  v_after jsonb;
  v_result jsonb;
  v_balance jsonb:=null;
  v_verified boolean:=false;
  v_request_id text:=nullif(left(btrim(coalesce(p_request_id,'')),200),'');
  v_choice text:=upper(btrim(coalesce(p_settlement_choice,'')));
  v_preview jsonb;
  v_refund numeric(12,2);
  v_policy_action_id uuid;
begin
  if p_token_id is null then raise exception using errcode='P0001',message='APPOINTMENT_TOKEN_INVALID'; end if;
  if p_requested_at is null then raise exception using errcode='P0001',message='CANCELLATION_REQUESTED_AT_REQUIRED'; end if;
  if p_ip is null or nullif(btrim(coalesce(p_user_agent,'')),'') is null or v_request_id is null then
    raise exception using errcode='P0001',message='AUTHORSHIP_CLIENT_EVIDENCE_REQUIRED';
  end if;

  select * into v_token from public.appointment_access_tokens where id=p_token_id for update;
  if not found or v_token.scope<>'CANCEL' or v_token.revoked_at is not null or v_token.consumed_at is not null or v_token.expires_at is null or v_token.expires_at<=clock_timestamp() then
    raise exception using errcode='P0001',message='APPOINTMENT_TOKEN_INVALID';
  end if;

  select * into v_appointment from public.appointments where id=v_token.appointment_id and deleted_at is null for update;
  if not found or v_appointment.start_at<=clock_timestamp() or v_token.expires_at<>v_appointment.start_at then
    raise exception using errcode='P0001',message='APPOINTMENT_TOKEN_INVALID';
  end if;

  select exists(
    select 1 from public.appointment_token_events e
    where e.appointment_access_token_id=v_token.id and e.event_type='VERIFIED' and e.request_id=v_request_id
  ) into v_verified;
  if not v_verified then raise exception using errcode='P0001',message='CANCEL_EMAIL_VERIFICATION_REQUIRED'; end if;

  v_preview:=public.calculate_reservation_change(v_appointment.id,'CANCEL',p_requested_at,'CLIENT',null);
  v_refund:=round(coalesce((v_preview->>'refund_due')::numeric,0),2);
  if v_refund>0.005 then
    if v_choice not in ('REFUND','CUSTOMER_BALANCE') then
      raise exception using errcode='P0001',message='CANCELLATION_SETTLEMENT_CHOICE_REQUIRED';
    end if;
  else
    v_choice:=null;
  end if;

  v_before:=public.service_appointment_authorship_snapshot(v_appointment.id);
  perform public.service_consume_appointment_action_token(
    v_token.id,'CANCEL_CONFIRMED',p_ip,p_user_agent,v_request_id,
    jsonb_build_object('financial_action',v_refund>0.005,'verification_method','REGISTERED_EMAIL','settlement',coalesce(v_choice,'NONE'))
  );

  v_result:=public.service_admin_cancel_appointment(
    v_appointment.id,null,nullif(left(btrim(coalesce(p_reason,'')),500),''),p_requested_at,'CLIENT',null
  );
  v_policy_action_id:=nullif(v_result->>'policy_action_id','')::uuid;

  if v_choice='CUSTOMER_BALANCE' and v_refund>0.005 then
    v_balance:=public.service_credit_customer_balance_from_return(
      v_appointment.id,v_policy_action_id,'CLIENT_TOKEN',null,p_ip,p_user_agent,v_request_id,null
    );
    v_result:=v_result||jsonb_build_object(
      'policy_action_status','APPLIED',
      'settlement_choice','CUSTOMER_BALANCE',
      'customer_balance',v_balance
    );
  elsif v_choice='REFUND' and v_refund>0.005 then
    v_result:=v_result||jsonb_build_object('settlement_choice','REFUND');
  end if;

  v_after:=public.service_appointment_authorship_snapshot(v_appointment.id);
  if v_before is distinct from v_after then
    perform public.service_record_appointment_authorship_event(
      v_appointment.id,'CLIENT_TOKEN','APPOINTMENT_CANCELLED',null,v_token.id,v_before,v_after,
      nullif(left(btrim(coalesce(p_reason,'')),500),''),p_ip,p_user_agent,v_request_id,p_session_id,null,null
    );
  end if;

  return v_result||jsonb_build_object('token_consumed',true,'settlement_choice',v_choice,'returnable_amount',v_refund);
end;
$function$;
