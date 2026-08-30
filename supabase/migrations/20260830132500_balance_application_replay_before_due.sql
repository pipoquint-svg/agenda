create or replace function public.service_apply_customer_balance_to_appointment(p_appointment_id uuid, p_policy_action_id uuid, p_choice_origin text, p_admin_id uuid, p_ip inet, p_user_agent text, p_request_id text, p_admin_request_reference text)
returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare
  v_appointment public.appointments%rowtype; v_balance numeric(12,2); v_due numeric(12,2); v_coverage numeric(12,2);
  v_settlement public.appointment_change_settlements%rowtype; v_key text; v_first_id uuid; v_applied numeric(12,2):=0;
  v_target numeric(12,2); v_take numeric(12,2); v_remaining numeric(12,2); v_allocated numeric(12,2);
  v_legacy numeric(12,2):=0; v_existing numeric(12,2):=0; v_credit record;
begin
  if p_choice_origin not in ('CLIENT_TOKEN','ADMIN_UI') or p_ip is null or nullif(btrim(p_user_agent),'') is null or nullif(btrim(p_request_id),'') is null then raise exception using errcode='P0001',message='BALANCE_AUTHORSHIP_EVIDENCE_REQUIRED'; end if;
  if p_choice_origin='ADMIN_UI' and (p_admin_id is null or nullif(btrim(p_admin_request_reference),'') is null) then raise exception using errcode='P0001',message='BALANCE_ADMIN_REQUEST_EVIDENCE_REQUIRED'; end if;
  select * into v_appointment from public.appointments where id=p_appointment_id for update;
  if not found or v_appointment.primary_customer_id is null then raise exception using errcode='P0001',message='APPOINTMENT_CUSTOMER_REQUIRED'; end if;

  v_key:='balance-apply:'||p_appointment_id::text||':'||coalesce(p_policy_action_id::text,'BOOKING');
  select coalesce(sum(amount),0)::numeric(12,2) into v_existing
  from public.customer_balance_movements
  where customer_id=v_appointment.primary_customer_id and direction='DEBIT' and idempotency_key like v_key||':%';
  if v_existing>0 then
    select id into v_first_id from public.customer_balance_movements
    where customer_id=v_appointment.primary_customer_id and direction='DEBIT' and idempotency_key like v_key||':%'
    order by created_at,id limit 1;
    return jsonb_build_object('movement_id',v_first_id,'appointment_id',p_appointment_id,'policy_action_id',p_policy_action_id,'amount_applied',v_existing,'amount_due_before',0,'balance_available',public.customer_balance_available(v_appointment.primary_customer_id),'customer_funds_under_reservation',public.appointment_customer_funds_amount(p_appointment_id),'contract_coverage',public.appointment_contract_coverage_amount(p_appointment_id),'idempotent_replay',true);
  end if;

  v_balance:=public.customer_balance_available(v_appointment.primary_customer_id);
  if v_balance<=0 then raise exception using errcode='P0001',message='CUSTOMER_BALANCE_EMPTY'; end if;
  if p_policy_action_id is null then
    v_due:=round(greatest(coalesce(v_appointment.commercial_value,0)-public.appointment_contract_coverage_amount(p_appointment_id),0),2);
  else
    select * into v_settlement from public.appointment_change_settlements where policy_action_id=p_policy_action_id and appointment_id=p_appointment_id;
    if not found or v_settlement.action_type<>'RESCHEDULE' then raise exception using errcode='P0001',message='CHANGE_SETTLEMENT_NOT_FOUND'; end if;
    v_coverage:=round(greatest(public.appointment_contract_coverage_amount(p_appointment_id)-v_settlement.penalty_retained,0),2);
    v_due:=round(greatest(v_settlement.confirmation_target_amount-v_coverage,0),2);
  end if;
  if v_due<=0 then raise exception using errcode='P0001',message='NO_AMOUNT_DUE_FOR_BALANCE_APPLICATION'; end if;
  v_target:=least(v_balance,v_due);
  select coalesce(sum(amount),0)::numeric(12,2) into v_legacy
  from public.customer_balance_movements where customer_id=v_appointment.primary_customer_id and direction='DEBIT' and source_credit_movement_id is null;
  for v_credit in
    select id,amount,coalesce(expires_at,created_at+interval '12 months') as expires_at
    from public.customer_balance_movements
    where customer_id=v_appointment.primary_customer_id and direction='CREDIT' and coalesce(expires_at,created_at+interval '12 months')>now()
    order by coalesce(expires_at,created_at+interval '12 months'),created_at,id for update
  loop
    select coalesce(sum(amount),0)::numeric(12,2) into v_allocated from public.customer_balance_movements where source_credit_movement_id=v_credit.id and direction='DEBIT';
    v_remaining:=greatest(v_credit.amount-v_allocated,0);
    if v_legacy>0 and v_remaining>0 then v_take:=least(v_legacy,v_remaining); v_legacy:=v_legacy-v_take; v_remaining:=v_remaining-v_take; end if;
    exit when v_applied>=v_target-0.009;
    if v_remaining>0 then
      v_take:=least(v_remaining,v_target-v_applied);
      insert into public.customer_balance_movements(customer_id,movement_type,direction,amount,appointment_id,policy_action_id,choice_origin,admin_user_id,admin_request_reference,ip_address,user_agent,request_id,idempotency_key,source_credit_movement_id)
      values(v_appointment.primary_customer_id,'APPLY_TO_APPOINTMENT','DEBIT',v_take,p_appointment_id,p_policy_action_id,p_choice_origin,p_admin_id,nullif(btrim(p_admin_request_reference),''),p_ip,p_user_agent,p_request_id,v_key||':'||v_credit.id::text,v_credit.id)
      returning id into v_first_id;
      v_applied:=v_applied+v_take;
    end if;
  end loop;
  if v_applied<=0 then raise exception using errcode='P0001',message='CUSTOMER_BALANCE_EMPTY'; end if;
  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,after_json,origin)
  values(p_admin_id,'APPOINTMENT',p_appointment_id,'CUSTOMER_BALANCE_APPLIED',jsonb_build_object('movement_id',v_first_id,'policy_action_id',p_policy_action_id,'amount',v_applied,'amount_due_before',v_due,'request_id',p_request_id,'consumption_order','EARLIEST_EXPIRY_FIRST'),case when p_choice_origin='ADMIN_UI' then 'ADMIN' else 'CLIENT' end);
  return jsonb_build_object('movement_id',v_first_id,'appointment_id',p_appointment_id,'policy_action_id',p_policy_action_id,'amount_applied',v_applied,'amount_due_before',v_due,'balance_available',public.customer_balance_available(v_appointment.primary_customer_id),'customer_funds_under_reservation',public.appointment_customer_funds_amount(p_appointment_id),'contract_coverage',public.appointment_contract_coverage_amount(p_appointment_id),'idempotent_replay',false);
end;
$function$;

revoke all on function public.service_apply_customer_balance_to_appointment(uuid,uuid,text,uuid,inet,text,text,text) from public,anon,authenticated;
grant execute on function public.service_apply_customer_balance_to_appointment(uuid,uuid,text,uuid,inet,text,text,text) to service_role;
