CREATE OR REPLACE FUNCTION public.calculate_reservation_change(p_appointment_id uuid, p_action_type text, p_requested_at timestamptz, p_change_origin text, p_new_contract_value numeric)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_appointment public.appointments%rowtype;
  v_snapshot public.appointment_change_policy_snapshots%rowtype;
  v_policy jsonb;
  v_schema text;
  v_notice integer;
  v_seconds numeric;
  v_hours numeric(12,2);
  v_inside boolean;
  v_count integer;
  v_contract numeric(12,2);
  v_funds numeric(12,2);
  v_applied numeric(12,2);
  v_excess_before numeric(12,2);
  v_contract_coverage numeric(12,2);
  v_contract_coverage_after numeric(12,2);
  v_commitment numeric(5,2);
  v_target numeric(12,2);
  v_percent numeric(5,2):=0;
  v_theoretical numeric(12,2):=0;
  v_retained numeric(12,2):=0;
  v_after numeric(12,2):=0;
  v_applicable numeric(12,2):=0;
  v_excess_after numeric(12,2):=0;
  v_difference numeric(12,2):=0;
  v_refund numeric(12,2):=0;
  v_legacy_type public.change_penalty_type;
  v_legacy_value numeric(12,2):=0;
  v_admin_waiver boolean := lower(coalesce(current_setting('app.change_penalty_waived', true),'false'))='true';
begin
  if p_action_type not in ('RESCHEDULE','CANCEL') then raise exception using errcode='P0001',message='INVALID_CHANGE_ACTION'; end if;
  if p_requested_at is null then raise exception using errcode='P0001',message='CHANGE_REQUESTED_AT_REQUIRED'; end if;
  if p_change_origin not in ('CLIENT','OPERATION') then raise exception using errcode='P0001',message='CHANGE_ORIGIN_REQUIRED'; end if;
  if p_action_type='RESCHEDULE' and p_new_contract_value is null then raise exception using errcode='P0001',message='NEW_CONTRACT_VALUE_REQUIRED'; end if;
  if p_new_contract_value is not null and p_new_contract_value<0 then raise exception using errcode='P0001',message='NEW_CONTRACT_VALUE_INVALID'; end if;

  select * into v_appointment from public.appointments where id=p_appointment_id and deleted_at is null;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if;
  select * into v_snapshot from public.appointment_change_policy_snapshots where appointment_id=p_appointment_id;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_CHANGE_POLICY_SNAPSHOT_MISSING'; end if;

  v_policy:=v_snapshot.policy_json;
  v_schema:=coalesce(v_policy->>'snapshot_schema_version','CHANGE_POLICY_SNAPSHOT_V1');
  v_notice:=(v_policy->>'notice_hours')::integer;
  if v_notice is null then raise exception using errcode='P0001',message='APPOINTMENT_CHANGE_POLICY_SNAPSHOT_INVALID'; end if;

  v_seconds:=extract(epoch from(v_appointment.start_at-p_requested_at));
  v_hours:=round(v_seconds/3600.0,2);
  v_inside:=v_seconds<(v_notice::numeric*3600);
  v_count:=public.appointment_client_reschedule_count(p_appointment_id);
  v_contract:=round(coalesce(v_appointment.commercial_value,0),2);
  v_funds:=round(public.appointment_customer_funds_amount(p_appointment_id),2);
  v_applied:=round(least(v_funds,v_contract),2);
  v_excess_before:=round(greatest(v_funds-v_contract,0),2);
  v_contract_coverage:=round(public.appointment_contract_coverage_amount(p_appointment_id),2);

  if v_appointment.billing_mode_snapshot='INVOICE' or v_appointment.financial_status='UNPAID_AUTHORIZED' then
    v_commitment:=0;
  elsif v_contract<=0 or v_contract_coverage>=v_contract then
    v_commitment:=100;
  else
    v_commitment:=v_appointment.confirmation_percentage_snapshot;
    if v_commitment is null then raise exception using errcode='P0001',message='APPOINTMENT_CONFIRMATION_SNAPSHOT_MISSING'; end if;
  end if;

  if p_change_origin='OPERATION' and v_admin_waiver then
    v_percent:=0;
  elsif v_schema='CONSOLIDATED_POLICY_V2' then
    if p_action_type='RESCHEDULE' then
      if v_count>0 then v_percent:=(v_policy->>'reschedule_repeat_percent')::numeric;
      elsif v_inside then v_percent:=(v_policy->>'reschedule_first_late_percent')::numeric;
      else v_percent:=(v_policy->>'reschedule_first_early_percent')::numeric;
      end if;
    else
      v_percent:=case when v_inside then (v_policy->>'cancellation_late_percent')::numeric else 0 end;
    end if;
  else
    if p_action_type='RESCHEDULE' then
      if v_count>0 then
        v_legacy_type:=(v_policy->>'reschedule_repeat_penalty_type')::public.change_penalty_type;
        v_legacy_value:=(v_policy->>'reschedule_repeat_penalty_value')::numeric;
      elsif v_inside then
        v_legacy_type:=(v_policy->>'reschedule_late_penalty_type')::public.change_penalty_type;
        v_legacy_value:=(v_policy->>'reschedule_late_penalty_value')::numeric;
      else
        v_legacy_type:=(v_policy->>'reschedule_first_penalty_type')::public.change_penalty_type;
        v_legacy_value:=(v_policy->>'reschedule_first_penalty_value')::numeric;
      end if;
    else
      if v_inside then
        v_legacy_type:=(v_policy->>'cancellation_late_penalty_type')::public.change_penalty_type;
        v_legacy_value:=(v_policy->>'cancellation_late_penalty_value')::numeric;
      else
        v_legacy_type:=(v_policy->>'cancellation_early_penalty_type')::public.change_penalty_type;
        v_legacy_value:=(v_policy->>'cancellation_early_penalty_value')::numeric;
      end if;
    end if;
    if v_legacy_type='PERCENT' then v_percent:=v_legacy_value;
    elsif v_legacy_type='NONE' then v_percent:=0;
    else v_percent:=0; v_theoretical:=round(v_legacy_value,2);
    end if;
  end if;

  if v_theoretical=0 then v_theoretical:=round(v_contract*v_percent/100,2); end if;
  v_retained:=case when p_change_origin='OPERATION' and v_admin_waiver then 0 else round(least(v_theoretical,v_applied),2) end;
  v_after:=round(greatest(v_funds-v_retained,0),2);
  v_contract_coverage_after:=round(greatest(v_contract_coverage-v_retained,0),2);

  if p_action_type='RESCHEDULE' then
    v_target:=round(p_new_contract_value*v_commitment/100,2);
    v_applicable:=round(least(v_after,p_new_contract_value),2);
    v_excess_after:=round(greatest(v_after-p_new_contract_value,0),2);
    v_difference:=round(greatest(v_target-v_contract_coverage_after,0),2);
  else
    v_target:=0;
    v_applicable:=round(greatest(v_applied-v_retained,0),2);
    v_excess_after:=v_excess_before;
    v_refund:=round(v_applicable+v_excess_before,2);
  end if;

  return jsonb_build_object(
    'appointment_id',p_appointment_id,'service_id',v_appointment.service_id,'action_type',p_action_type,'change_origin',p_change_origin,
    'requested_at',p_requested_at,'original_start_at',v_appointment.start_at,'hours_before_start',v_hours,'notice_hours',v_notice,
    'inside_notice_window',v_inside,'prior_customer_reschedules',v_count,'max_customer_reschedules',v_snapshot.max_customer_reschedules,
    'contract_value',v_contract,'new_contract_value',p_new_contract_value,'customer_funds_before',v_funds,'contract_applied_before',v_applied,
    'excess_before',v_excess_before,'contract_coverage_before',v_contract_coverage,'payment_commitment_percent',v_commitment,
    'confirmation_target_amount',v_target,'penalty_percent',v_percent,'theoretical_penalty',v_theoretical,'penalty_retained',v_retained,
    'penalty_amount',v_retained,'penalty_waived',(p_change_origin='OPERATION' and v_admin_waiver),'customer_funds_after_penalty',v_after,
    'contract_coverage_after_penalty',v_contract_coverage_after,'applicable_amount',v_applicable,'excess_amount',v_excess_after,
    'difference_due',v_difference,'refund_due',v_refund,'refundable_amount',v_refund,
    'customer_reschedule_limit_reached',(p_action_type='RESCHEDULE' and p_change_origin='CLIENT' and v_count>=v_snapshot.max_customer_reschedules),
    'snapshot_schema_version',v_schema
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.service_admin_change_preview_v3(p_admin_id uuid, p_appointment_id uuid, p_action_type text, p_requested_at timestamptz, p_new_contract_value numeric, p_settlement_choice text, p_penalty_waived boolean, p_waiver_reason text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_standard jsonb; v_effective jsonb; v_appointment public.appointments%rowtype;
  v_balance numeric(12,2):=0; v_provider_available numeric(12,2):=0; v_returnable numeric(12,2):=0;
  v_gateway numeric(12,2):=0; v_manual numeric(12,2):=0; v_balance_result numeric(12,2):=0;
  v_allowed jsonb:='[]'::jsonb; v_selected text; v_can_finance boolean:=false;
begin
  if not public.service_admin_has_permission(p_admin_id,'AGENDA_MANAGE') then raise exception using errcode='P0001',message='ADMIN_PERMISSION_DENIED'; end if;
  if p_action_type not in ('CANCEL','RESCHEDULE') then raise exception using errcode='P0001',message='INVALID_CHANGE_ACTION'; end if;
  v_can_finance:=public.service_admin_has_permission(p_admin_id,'FINANCE_MANAGE');
  if coalesce(p_penalty_waived,false) then
    if not v_can_finance then raise exception using errcode='P0001',message='ADMIN_PERMISSION_DENIED'; end if;
    if nullif(btrim(coalesce(p_waiver_reason,'')),'') is null then raise exception using errcode='P0001',message='WAIVER_REASON_REQUIRED'; end if;
  end if;

  perform set_config('app.change_penalty_waived','false',true);
  v_standard:=public.calculate_reservation_change(p_appointment_id,p_action_type,p_requested_at,'OPERATION',p_new_contract_value);
  if coalesce(p_penalty_waived,false) then
    perform set_config('app.change_penalty_waived','true',true);
    v_effective:=public.calculate_reservation_change(p_appointment_id,p_action_type,p_requested_at,'OPERATION',p_new_contract_value);
  else v_effective:=v_standard; end if;

  select * into v_appointment from public.appointments where id=p_appointment_id and deleted_at is null;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if;
  if v_appointment.primary_customer_id is not null then v_balance:=public.customer_balance_available(v_appointment.primary_customer_id); end if;
  v_balance_result:=v_balance;

  if p_action_type='CANCEL' then
    v_returnable:=round(coalesce((v_effective->>'refund_due')::numeric,0),2);
    select round(coalesce(sum(greatest(pt.cash_amount-coalesce((select sum(rf.cash_amount) from public.payment_transactions rf where rf.parent_transaction_id=pt.id and rf.payment_purpose='CONTRACT' and rf.transaction_type='REFUND' and rf.status in('APPROVED','REFUNDED')),0),0)),0),2)
      into v_provider_available
      from public.payment_transactions pt
      where pt.appointment_id=p_appointment_id and pt.payment_purpose='CONTRACT' and pt.transaction_type='CHARGE'
        and pt.provider='MERCADO_PAGO' and pt.provider_payment_id is not null and pt.status in('APPROVED','PARTIALLY_REFUNDED','REFUNDED');
    if v_returnable>0 then
      v_allowed:=jsonb_build_array('REFUND');
      if v_can_finance then v_allowed:=v_allowed||jsonb_build_array('CUSTOMER_BALANCE'); end if;
      v_selected:=upper(coalesce(nullif(btrim(p_settlement_choice),''),'REFUND'));
    else v_allowed:=jsonb_build_array('NONE'); v_selected:='NONE'; end if;
    if not (v_allowed ? v_selected) then raise exception using errcode='P0001',message='SETTLEMENT_CHOICE_NOT_ALLOWED'; end if;
    if v_selected='REFUND' then
      v_gateway:=round(least(v_returnable,v_provider_available),2);
      v_manual:=round(greatest(v_returnable-v_gateway,0),2);
    elsif v_selected='CUSTOMER_BALANCE' then v_balance_result:=round(v_balance+v_returnable,2);
    end if;
  end if;

  perform set_config('app.change_penalty_waived',case when coalesce(p_penalty_waived,false) then 'true' else 'false' end,true);
  return v_effective || jsonb_build_object(
    'paid_amount',coalesce((v_effective->>'customer_funds_before')::numeric,0),'penalty_amount',coalesce((v_effective->>'penalty_retained')::numeric,0),
    'penalty_waived',coalesce(p_penalty_waived,false),'waiver_reason',case when coalesce(p_penalty_waived,false) then btrim(p_waiver_reason) else null end,
    'policy_penalty_percent',coalesce((v_standard->>'penalty_percent')::numeric,0),'policy_penalty_amount',coalesce((v_standard->>'penalty_retained')::numeric,0),
    'waived_penalty_amount',case when coalesce(p_penalty_waived,false) then coalesce((v_standard->>'penalty_retained')::numeric,0) else 0 end,
    'returnable_amount',v_returnable,'gateway_refund_capacity',round(least(v_returnable,v_provider_available),2),
    'manual_refund_if_refund',round(greatest(v_returnable-least(v_returnable,v_provider_available),0),2),
    'gateway_refund_amount',v_gateway,'manual_refund_amount',v_manual,'customer_balance_before',v_balance,'customer_balance_result',v_balance_result,
    'allowed_settlements',v_allowed,'selected_settlement',v_selected
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.service_admin_cancel_appointment_evidenced_v3(p_appointment_id uuid, p_settlement_choice text, p_reason text, p_requested_at timestamptz, p_admin_id uuid, p_ip inet, p_user_agent text, p_request_id text, p_session_id text, p_penalty_waived boolean, p_waiver_reason text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_preview jsonb; v_result jsonb; v_choice text;
begin
  v_choice:=upper(coalesce(nullif(btrim(p_settlement_choice),''),'NONE'));
  v_preview:=public.service_admin_change_preview_v3(p_admin_id,p_appointment_id,'CANCEL',p_requested_at,null,v_choice,p_penalty_waived,p_waiver_reason);
  perform set_config('app.change_penalty_waived',case when coalesce(p_penalty_waived,false) then 'true' else 'false' end,true);
  v_result:=public.service_admin_cancel_appointment_evidenced(
    p_appointment_id,case when v_choice='REFUND' then 'REFUND' else null end,p_reason,p_requested_at,'OPERATION',p_admin_id,p_ip,p_user_agent,p_request_id,p_session_id
  );
  if coalesce(p_penalty_waived,false) then
    insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
    values(p_admin_id,'APPOINTMENT',p_appointment_id,'CHANGE_PENALTY_WAIVED',
      jsonb_build_object('action_type','CANCEL','policy_penalty_percent',v_preview->'policy_penalty_percent','policy_penalty_amount',v_preview->'policy_penalty_amount'),
      jsonb_build_object('action_type','CANCEL','applied_penalty_percent',v_preview->'penalty_percent','applied_penalty_amount',v_preview->'penalty_amount','waiver_reason',btrim(p_waiver_reason),'policy_action_id',v_result->'policy_action_id'),'ADMIN');
  end if;
  return v_result || jsonb_build_object('preview',v_preview,'requested_settlement_choice',v_choice,'penalty_waived',coalesce(p_penalty_waived,false),'waiver_reason',case when coalesce(p_penalty_waived,false) then btrim(p_waiver_reason) else null end);
end;
$function$;

CREATE OR REPLACE FUNCTION public.service_admin_create_reschedule_hold_v3(p_appointment_id uuid, p_requested_start_at timestamptz, p_requested_at timestamptz, p_admin_id uuid, p_penalty_waived boolean, p_waiver_reason text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_result jsonb; v_standard jsonb;
begin
  if not public.service_admin_has_permission(p_admin_id,'AGENDA_MANAGE') then raise exception using errcode='P0001',message='ADMIN_PERMISSION_DENIED'; end if;
  if coalesce(p_penalty_waived,false) then
    if not public.service_admin_has_permission(p_admin_id,'FINANCE_MANAGE') then raise exception using errcode='P0001',message='ADMIN_PERMISSION_DENIED'; end if;
    if nullif(btrim(coalesce(p_waiver_reason,'')),'') is null then raise exception using errcode='P0001',message='WAIVER_REASON_REQUIRED'; end if;
  end if;
  perform set_config('app.change_penalty_waived',case when coalesce(p_penalty_waived,false) then 'true' else 'false' end,true);
  v_result:=public.service_admin_create_reschedule_hold(p_appointment_id,p_requested_start_at,p_requested_at,'OPERATION',p_admin_id);
  perform set_config('app.change_penalty_waived','false',true);
  v_standard:=public.calculate_reservation_change(p_appointment_id,'RESCHEDULE',p_requested_at,'OPERATION',(v_result->>'new_contract_value')::numeric);
  if coalesce(p_penalty_waived,false) then
    insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
    values(p_admin_id,'APPOINTMENT',p_appointment_id,'CHANGE_PENALTY_WAIVED',
      jsonb_build_object('action_type','RESCHEDULE','policy_penalty_percent',v_standard->'penalty_percent','policy_penalty_amount',v_standard->'penalty_retained'),
      jsonb_build_object('action_type','RESCHEDULE','applied_penalty_percent',v_result->'penalty_percent','applied_penalty_amount',v_result->'penalty_retained','waiver_reason',btrim(p_waiver_reason),'policy_action_id',v_result->'policy_action_id'),'ADMIN');
  end if;
  perform set_config('app.change_penalty_waived',case when coalesce(p_penalty_waived,false) then 'true' else 'false' end,true);
  return v_result || jsonb_build_object(
    'paid_amount',public.appointment_customer_funds_amount(p_appointment_id),'penalty_amount',coalesce((v_result->>'penalty_retained')::numeric,0),
    'penalty_waived',coalesce(p_penalty_waived,false),'waiver_reason',case when coalesce(p_penalty_waived,false) then btrim(p_waiver_reason) else null end,
    'policy_penalty_percent',coalesce((v_standard->>'penalty_percent')::numeric,0),'policy_penalty_amount',coalesce((v_standard->>'penalty_retained')::numeric,0),
    'waived_penalty_amount',case when coalesce(p_penalty_waived,false) then coalesce((v_standard->>'penalty_retained')::numeric,0) else 0 end
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.service_admin_mark_appointment_no_show_evidenced(p_appointment_id uuid, p_reason text, p_admin_id uuid, p_ip inet, p_user_agent text, p_request_id text, p_session_id text DEFAULT NULL::text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_before jsonb; v_after jsonb; v_appointment public.appointments%rowtype; v_financial jsonb;
begin
  if not public.service_admin_has_permission(p_admin_id,'AGENDA_MANAGE') then raise exception using errcode='P0001',message='ADMIN_PERMISSION_DENIED'; end if;
  if p_ip is null or nullif(btrim(coalesce(p_user_agent,'')),'') is null or nullif(btrim(coalesce(p_request_id,'')),'') is null then raise exception using errcode='P0001',message='AUTHORSHIP_ADMIN_EVIDENCE_REQUIRED'; end if;
  select * into v_appointment from public.appointments where id=p_appointment_id and deleted_at is null for update;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if;
  if v_appointment.status<>'CONFIRMED' then raise exception using errcode='P0001',message='APPOINTMENT_NOT_ELIGIBLE_FOR_NO_SHOW'; end if;
  if now()<v_appointment.start_at then raise exception using errcode='P0001',message='NO_SHOW_BEFORE_APPOINTMENT_START'; end if;
  v_before:=public.service_appointment_authorship_snapshot(p_appointment_id);
  update public.appointments set status='NO_SHOW',no_show_at=now(),version=version+1,updated_at=now() where id=p_appointment_id;
  v_after:=public.service_appointment_authorship_snapshot(p_appointment_id);
  perform public.service_record_appointment_authorship_event(p_appointment_id,'ADMIN_UI','APPOINTMENT_NO_SHOW',p_admin_id,null,v_before,v_after,nullif(btrim(coalesce(p_reason,'')),''),p_ip,p_user_agent,p_request_id,p_session_id,null,null);
  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
  values(p_admin_id,'APPOINTMENT',p_appointment_id,'APPOINTMENT_NO_SHOW',v_before,v_after||jsonb_build_object('reason',nullif(btrim(coalesce(p_reason,'')),''),'financial_rule','SERVICE_PERFORMED_NO_REFUND_NO_CREDIT_BALANCE_DUE_REMAINS'),'ADMIN');
  v_financial:=public.get_appointment_financial_summary(p_appointment_id);
  return jsonb_build_object('appointment_id',p_appointment_id,'status','NO_SHOW','no_show_at',now(),'financial',v_financial);
end;
$function$;

REVOKE ALL ON FUNCTION public.service_admin_change_preview_v3(uuid,uuid,text,timestamptz,numeric,text,boolean,text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.service_admin_cancel_appointment_evidenced_v3(uuid,text,text,timestamptz,uuid,inet,text,text,text,boolean,text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.service_admin_create_reschedule_hold_v3(uuid,timestamptz,timestamptz,uuid,boolean,text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.service_admin_mark_appointment_no_show_evidenced(uuid,text,uuid,inet,text,text,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.service_admin_change_preview_v3(uuid,uuid,text,timestamptz,numeric,text,boolean,text) TO service_role;
GRANT EXECUTE ON FUNCTION public.service_admin_cancel_appointment_evidenced_v3(uuid,text,text,timestamptz,uuid,inet,text,text,text,boolean,text) TO service_role;
GRANT EXECUTE ON FUNCTION public.service_admin_create_reschedule_hold_v3(uuid,timestamptz,timestamptz,uuid,boolean,text) TO service_role;
GRANT EXECUTE ON FUNCTION public.service_admin_mark_appointment_no_show_evidenced(uuid,text,uuid,inet,text,text,text) TO service_role;

ALTER TABLE public.notification_template_configs DROP CONSTRAINT IF EXISTS notification_template_configs_event_key_check;
ALTER TABLE public.notification_template_configs ADD CONSTRAINT notification_template_configs_event_key_check CHECK (event_key = ANY (ARRAY[
  'APPOINTMENT_APPROVED'::text,'APPOINTMENT_PENDING'::text,'APPOINTMENT_REJECTED'::text,'APPOINTMENT_CANCELLED'::text,
  'APPOINTMENT_CHANGED'::text,'APPOINTMENT_RESCHEDULED'::text,'APPOINTMENT_REMINDER'::text,'WAITLIST_AVAILABLE'::text,
  'BIRTHDAY'::text,'RENTAL_BALANCE_DUE'::text,'ADMIN_USER_INVITE'::text,'MANUAL'::text,'REFUND_FAILED'::text
]));

DELETE FROM public.notification_template_configs
WHERE event_key='REFUND_FAILED' AND channel='EMAIL' AND audience='EMPLOYEE' AND operation_scope IN ('BLACKSHEEP','SABRINA');

INSERT INTO public.notification_template_configs(event_key,channel,audience,operation_scope,title_template,body_template,is_active,variable_schema)
VALUES
('REFUND_FAILED','EMAIL','EMPLOYEE','BLACKSHEEP','Atenção: estorno pendente — {{appointment.public_code}}','Não foi possível concluir o estorno da reserva {{appointment.public_code}}.\n\nValor pendente: {{refund.amount}}\nMotivo técnico: {{refund.error_code}}\n\nA pendência continua registrada na Gestão. Confira o Mercado Pago e tente novamente.',true,'["appointment.public_code","refund.amount","refund.error_code","operation.name"]'::jsonb),
('REFUND_FAILED','EMAIL','EMPLOYEE','SABRINA','Atenção: estorno pendente — {{appointment.public_code}}','Não foi possível concluir o estorno da reserva {{appointment.public_code}}.\n\nValor pendente: {{refund.amount}}\nMotivo técnico: {{refund.error_code}}\n\nA pendência continua registrada na Gestão. Confira o Mercado Pago e tente novamente.',true,'["appointment.public_code","refund.amount","refund.error_code","operation.name"]'::jsonb);
