alter table public.customer_balance_movements
  add column if not exists expires_at timestamptz,
  add column if not exists source_credit_movement_id uuid references public.customer_balance_movements(id) on delete restrict;

create index if not exists customer_balance_movements_customer_expiry_idx
  on public.customer_balance_movements(customer_id, expires_at, created_at)
  where direction='CREDIT';
create index if not exists customer_balance_movements_source_credit_idx
  on public.customer_balance_movements(source_credit_movement_id)
  where source_credit_movement_id is not null;

create or replace function public.customer_balance_available(p_customer_id uuid)
returns numeric
language sql
stable
set search_path to 'public'
as $function$
with credit_lots as (
  select c.id,
         greatest(c.amount-coalesce(sum(d.amount),0),0)::numeric(12,2) as remaining
  from public.customer_balance_movements c
  left join public.customer_balance_movements d
    on d.source_credit_movement_id=c.id and d.direction='DEBIT'
  where c.customer_id=p_customer_id
    and c.direction='CREDIT'
    and coalesce(c.expires_at,c.created_at+interval '12 months')>now()
  group by c.id,c.amount
), legacy_debits as (
  select coalesce(sum(amount),0)::numeric(12,2) as amount
  from public.customer_balance_movements
  where customer_id=p_customer_id and direction='DEBIT' and source_credit_movement_id is null
), reserved_refunds as (
  select coalesce(sum(amount),0)::numeric(12,2) as amount
  from public.customer_balance_refund_requests
  where customer_id=p_customer_id and status in('PENDING','COMPLETED')
)
select round(greatest(coalesce((select sum(remaining) from credit_lots),0)
  -(select amount from legacy_debits)
  -(select amount from reserved_refunds),0),2)::numeric(12,2);
$function$;

create or replace function public.service_credit_customer_balance_from_return(p_appointment_id uuid, p_policy_action_id uuid, p_choice_origin text, p_admin_id uuid, p_ip inet, p_user_agent text, p_request_id text, p_admin_request_reference text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_appointment public.appointments%rowtype;
  v_action public.appointment_policy_actions%rowtype;
  v_settlement public.appointment_change_settlements%rowtype;
  v_amount numeric(12,2); v_key text; v_id uuid; v_expires timestamptz;
begin
  if p_choice_origin not in ('CLIENT_TOKEN','ADMIN_UI') or p_ip is null or nullif(btrim(p_user_agent),'') is null or nullif(btrim(p_request_id),'') is null then
    raise exception using errcode='P0001',message='BALANCE_AUTHORSHIP_EVIDENCE_REQUIRED';
  end if;
  if p_choice_origin='ADMIN_UI' and (p_admin_id is null or nullif(btrim(p_admin_request_reference),'') is null) then
    raise exception using errcode='P0001',message='BALANCE_ADMIN_REQUEST_EVIDENCE_REQUIRED';
  end if;
  select * into v_appointment from public.appointments where id=p_appointment_id for update;
  if not found or v_appointment.primary_customer_id is null then raise exception using errcode='P0001',message='APPOINTMENT_CUSTOMER_REQUIRED'; end if;
  select * into v_action from public.appointment_policy_actions where id=p_policy_action_id and appointment_id=p_appointment_id for update;
  if not found or v_action.action_type<>'CANCEL' then raise exception using errcode='P0001',message='CANCELLATION_ACTION_REQUIRED_FOR_BALANCE_RETURN'; end if;
  select * into v_settlement from public.appointment_change_settlements where policy_action_id=v_action.id;
  if not found then raise exception using errcode='P0001',message='CHANGE_SETTLEMENT_NOT_FOUND'; end if;
  v_amount:=v_settlement.refund_due;
  if v_amount<=0 then raise exception using errcode='P0001',message='NO_RETURNABLE_AMOUNT'; end if;
  v_key:='balance-credit:'||p_appointment_id::text||':'||p_policy_action_id::text;
  v_expires:=now()+interval '12 months';
  insert into public.customer_balance_movements as cbm(customer_id,movement_type,direction,amount,appointment_id,policy_action_id,choice_origin,admin_user_id,admin_request_reference,ip_address,user_agent,request_id,idempotency_key,expires_at)
  values(v_appointment.primary_customer_id,'CREDIT_FROM_RETURN','CREDIT',v_amount,p_appointment_id,p_policy_action_id,p_choice_origin,p_admin_id,nullif(btrim(p_admin_request_reference),''),p_ip,p_user_agent,p_request_id,v_key,v_expires)
  on conflict(idempotency_key) do update set expires_at=coalesce(cbm.expires_at,excluded.expires_at)
  returning id,coalesce(expires_at,created_at+interval '12 months') into v_id,v_expires;
  update public.appointment_policy_actions set settlement_choice='CUSTOMER_BALANCE',status='APPLIED',updated_at=now() where id=v_action.id;
  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,after_json,origin)
  values(p_admin_id,'APPOINTMENT',p_appointment_id,'CUSTOMER_BALANCE_CREATED',jsonb_build_object('policy_action_id',v_action.id,'amount',v_amount,'customer_id',v_appointment.primary_customer_id,'choice_origin',p_choice_origin,'request_id',p_request_id,'expires_at',v_expires),case when p_choice_origin='ADMIN_UI' then 'ADMIN' else 'CLIENT' end);
  return jsonb_build_object('movement_id',v_id,'customer_id',v_appointment.primary_customer_id,'amount',v_amount,'expires_at',v_expires,'validity_months',12,'balance_available',public.customer_balance_available(v_appointment.primary_customer_id));
end;
$function$;

create or replace function public.service_finalize_appointment_excess(p_appointment_id uuid, p_settlement_choice text, p_choice_origin text, p_admin_id uuid, p_ip inet, p_user_agent text, p_request_id text, p_admin_request_reference text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_appointment public.appointments%rowtype; v_amount numeric(12,2); v_choice text;
  v_existing public.appointment_final_settlements%rowtype; v_movement uuid; v_key text; v_final_id uuid; v_expires timestamptz;
begin
  select * into v_appointment from public.appointments where id=p_appointment_id for update;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if;
  if v_appointment.status<>'COMPLETED' then raise exception using errcode='P0001',message='FINAL_EXCESS_ONLY_AFTER_SERVICE_COMPLETED'; end if;
  if v_appointment.primary_customer_id is null then raise exception using errcode='P0001',message='APPOINTMENT_CUSTOMER_REQUIRED'; end if;
  select * into v_existing from public.appointment_final_settlements where appointment_id=p_appointment_id;
  if found then return jsonb_build_object('final_settlement_id',v_existing.id,'appointment_id',p_appointment_id,'excess_amount',v_existing.excess_amount,'settlement_choice',v_existing.settlement_choice,'status',v_existing.status,'idempotent_replay',true); end if;
  v_amount:=public.appointment_returnable_excess(p_appointment_id);
  if v_amount<=0 then raise exception using errcode='P0001',message='NO_FINAL_EXCESS_TO_SETTLE'; end if;
  v_choice:=coalesce(nullif(upper(btrim(coalesce(p_settlement_choice,''))),''),'REFUND');
  if v_choice='CREDIT' then raise exception using errcode='P0001',message='LEGACY_CANCELLATION_CREDIT_REMOVED'; end if;
  if v_choice not in ('REFUND','CUSTOMER_BALANCE') then raise exception using errcode='P0001',message='INVALID_FINAL_SETTLEMENT_CHOICE'; end if;
  if v_choice='CUSTOMER_BALANCE' then
    if p_choice_origin not in ('CLIENT_TOKEN','ADMIN_UI') or p_ip is null or nullif(btrim(p_user_agent),'') is null or nullif(btrim(p_request_id),'') is null then raise exception using errcode='P0001',message='BALANCE_AUTHORSHIP_EVIDENCE_REQUIRED'; end if;
    if p_choice_origin='ADMIN_UI' and (p_admin_id is null or nullif(btrim(p_admin_request_reference),'') is null) then raise exception using errcode='P0001',message='BALANCE_ADMIN_REQUEST_EVIDENCE_REQUIRED'; end if;
    v_key:='balance-final-excess:'||p_appointment_id::text;
    v_expires:=now()+interval '12 months';
    insert into public.customer_balance_movements(customer_id,movement_type,direction,amount,appointment_id,policy_action_id,choice_origin,admin_user_id,admin_request_reference,ip_address,user_agent,request_id,idempotency_key,expires_at)
    values(v_appointment.primary_customer_id,'CREDIT_FROM_RETURN','CREDIT',v_amount,p_appointment_id,null,p_choice_origin,p_admin_id,nullif(btrim(p_admin_request_reference),''),p_ip,p_user_agent,p_request_id,v_key,v_expires)
    returning id into v_movement;
  end if;
  insert into public.appointment_final_settlements(appointment_id,customer_id,excess_amount,settlement_choice,status,balance_movement_id,choice_origin,admin_user_id,admin_request_reference,ip_address,user_agent,request_id)
  values(p_appointment_id,v_appointment.primary_customer_id,v_amount,v_choice,case when v_choice='REFUND' then 'PENDING_REFUND' else 'BALANCE_CREDITED' end,v_movement,case when v_choice='CUSTOMER_BALANCE' then p_choice_origin else null end,case when v_choice='CUSTOMER_BALANCE' then p_admin_id else null end,case when v_choice='CUSTOMER_BALANCE' then nullif(btrim(p_admin_request_reference),'') else null end,case when v_choice='CUSTOMER_BALANCE' then p_ip else null end,case when v_choice='CUSTOMER_BALANCE' then p_user_agent else null end,case when v_choice='CUSTOMER_BALANCE' then p_request_id else null end)
  returning id into v_final_id;
  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,after_json,origin)
  values(p_admin_id,'APPOINTMENT',p_appointment_id,'APPOINTMENT_FINAL_EXCESS_SETTLED',jsonb_build_object('final_settlement_id',v_final_id,'excess_amount',v_amount,'settlement_choice',v_choice,'balance_movement_id',v_movement,'balance_expires_at',v_expires),case when p_choice_origin='CLIENT_TOKEN' then 'CLIENT' else 'ADMIN' end);
  return jsonb_build_object('final_settlement_id',v_final_id,'appointment_id',p_appointment_id,'excess_amount',v_amount,'settlement_choice',v_choice,'status',case when v_choice='REFUND' then 'PENDING_REFUND' else 'BALANCE_CREDITED' end,'balance_movement_id',v_movement,'balance_expires_at',v_expires,'idempotent_replay',false);
end;
$function$;

create or replace function public.service_apply_customer_balance_to_appointment(p_appointment_id uuid, p_policy_action_id uuid, p_choice_origin text, p_admin_id uuid, p_ip inet, p_user_agent text, p_request_id text, p_admin_request_reference text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
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
  v_key:='balance-apply:'||p_appointment_id::text||':'||coalesce(p_policy_action_id::text,'BOOKING');
  select coalesce(sum(amount),0)::numeric(12,2),min(id) into v_existing,v_first_id
  from public.customer_balance_movements
  where customer_id=v_appointment.primary_customer_id and direction='DEBIT' and idempotency_key like v_key||':%';
  if v_existing>0 then
    return jsonb_build_object('movement_id',v_first_id,'appointment_id',p_appointment_id,'policy_action_id',p_policy_action_id,'amount_applied',v_existing,'amount_due_before',v_due,'balance_available',public.customer_balance_available(v_appointment.primary_customer_id),'customer_funds_under_reservation',public.appointment_customer_funds_amount(p_appointment_id),'contract_coverage',public.appointment_contract_coverage_amount(p_appointment_id),'idempotent_replay',true);
  end if;
  select coalesce(sum(amount),0)::numeric(12,2) into v_legacy
  from public.customer_balance_movements where customer_id=v_appointment.primary_customer_id and direction='DEBIT' and source_credit_movement_id is null;
  for v_credit in
    select id,amount,coalesce(expires_at,created_at+interval '12 months') as expires_at
    from public.customer_balance_movements
    where customer_id=v_appointment.primary_customer_id and direction='CREDIT' and coalesce(expires_at,created_at+interval '12 months')>now()
    order by coalesce(expires_at,created_at+interval '12 months'),created_at,id
    for update
  loop
    select coalesce(sum(amount),0)::numeric(12,2) into v_allocated from public.customer_balance_movements where source_credit_movement_id=v_credit.id and direction='DEBIT';
    v_remaining:=greatest(v_credit.amount-v_allocated,0);
    if v_legacy>0 and v_remaining>0 then
      v_take:=least(v_legacy,v_remaining); v_legacy:=v_legacy-v_take; v_remaining:=v_remaining-v_take;
    end if;
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

create or replace function public.service_finance_customer_balance_report(p_from timestamptz, p_to timestamptz)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare v_open numeric(12,2); v_credits numeric(12,2); v_applied numeric(12,2); v_refunds numeric(12,2); v_expired numeric(12,2);
begin
  if p_from is null or p_to is null or p_to<=p_from then raise exception using errcode='P0001',message='INVALID_REPORT_PERIOD'; end if;
  select coalesce(sum(public.customer_balance_available(c.id)),0)::numeric(12,2) into v_open from public.customers c;
  select coalesce(sum(amount) filter(where movement_type='CREDIT_FROM_RETURN'),0)::numeric(12,2),coalesce(sum(amount) filter(where movement_type='APPLY_TO_APPOINTMENT'),0)::numeric(12,2)
  into v_credits,v_applied from public.customer_balance_movements where created_at>=p_from and created_at<p_to;
  select coalesce(sum(amount),0)::numeric(12,2) into v_refunds from public.customer_balance_refund_requests where requested_at>=p_from and requested_at<p_to;
  select coalesce(sum(greatest(c.amount-coalesce((select sum(d.amount) from public.customer_balance_movements d where d.source_credit_movement_id=c.id and d.direction='DEBIT'),0),0)),0)::numeric(12,2)
  into v_expired from public.customer_balance_movements c
  where c.direction='CREDIT' and coalesce(c.expires_at,c.created_at+interval '12 months')>=p_from and coalesce(c.expires_at,c.created_at+interval '12 months')<p_to;
  return jsonb_build_object('period_from',p_from,'period_to',p_to,'customer_balance_open_liability',v_open,'balance_credited_in_period',v_credits,'balance_applied_to_reservations_in_period',v_applied,'balance_refund_requests_in_period',v_refunds,'balance_expired_in_period',v_expired,'validity_months',12,'accounting_classification','LIABILITY_NOT_REVENUE');
end;
$function$;

create or replace function public.service_admin_finance_pending_refunds(p_operation_scope text, p_admin_id uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public','pg_temp'
as $function$
declare v_scope text:=nullif(upper(btrim(coalesce(p_operation_scope,''))),''); v_rows jsonb;
begin
  if not public.service_admin_has_permission(p_admin_id,'FINANCE_VIEW') then raise exception using errcode='P0001',message='ADMIN_PERMISSION_DENIED'; end if;
  if v_scope is not null and v_scope not in('BLACKSHEEP','SABRINA') then raise exception using errcode='P0001',message='FINANCE_OPERATION_SCOPE_INVALID'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'policy_action_id',pa.id,'appointment_id',a.id,'public_code',a.public_code,'service_at',a.start_at,'operation_scope',s.operation_scope,
    'customer_id',c.id,'customer_name',c.name,'service_name',coalesce(a.service_name_snapshot,s.name),
    'target_refund',coalesce((p.plan->>'target_cash_amount')::numeric,0),'recorded_refund',coalesce((p.plan->>'recorded_refund_cash')::numeric,0),
    'gateway_available',coalesce((p.plan->>'mercado_pago_available_cash')::numeric,0),'manual_refund_amount',coalesce((p.plan->>'manual_refund_cash')::numeric,0),
    'status',pa.status) order by a.start_at desc),'[]'::jsonb) into v_rows
  from public.appointment_policy_actions pa
  join public.appointments a on a.id=pa.appointment_id
  join public.services s on s.id=a.service_id
  left join public.customers c on c.id=a.primary_customer_id
  cross join lateral (select public.service_get_cancellation_refund_plan(pa.id) as plan) p
  where pa.action_type='CANCEL' and pa.settlement_choice='REFUND' and pa.status='PENDING_REFUND'
    and coalesce((p.plan->>'manual_refund_cash')::numeric,0)>0.009
    and (v_scope is null or s.operation_scope=v_scope);
  return jsonb_build_object('operation_scope',v_scope,'refunds',v_rows);
end;
$function$;

create or replace function public.service_admin_record_cancellation_manual_refund(p_policy_action_id uuid, p_method text, p_cash_amount numeric, p_reference text, p_paid_at timestamptz, p_admin_id uuid, p_ip inet, p_user_agent text, p_request_id text)
returns jsonb
language plpgsql
security definer
set search_path to 'public','pg_temp'
as $function$
declare
  v_action public.appointment_policy_actions%rowtype; v_plan jsonb; v_after jsonb; v_method text:=upper(btrim(coalesce(p_method,'')));
  v_amount numeric(12,2):=round(coalesce(p_cash_amount,0),2); v_left numeric(12,2); v_parent public.payment_transactions%rowtype;
  v_refunded_cash numeric(12,2); v_refunded_contract numeric(12,2); v_cash_remaining numeric(12,2); v_contract_remaining numeric(12,2);
  v_take numeric(12,2); v_contract_take numeric(12,2); v_total_recorded numeric(12,2); v_first_id uuid; v_refund_id uuid; v_paid_at timestamptz:=coalesce(p_paid_at,now());
begin
  if not public.service_admin_has_permission(p_admin_id,'FINANCE_MANAGE') then raise exception using errcode='P0001',message='ADMIN_PERMISSION_DENIED'; end if;
  if v_method not in('CASH','PIX') then raise exception using errcode='P0001',message='MANUAL_REFUND_METHOD_INVALID'; end if;
  if v_amount<=0 then raise exception using errcode='P0001',message='MANUAL_REFUND_AMOUNT_INVALID'; end if;
  if nullif(btrim(coalesce(p_reference,'')),'') is null or p_ip is null or nullif(btrim(coalesce(p_user_agent,'')),'') is null or nullif(btrim(coalesce(p_request_id,'')),'') is null then raise exception using errcode='P0001',message='MANUAL_REFUND_EVIDENCE_REQUIRED'; end if;
  select * into v_action from public.appointment_policy_actions where id=p_policy_action_id for update;
  if not found or v_action.action_type<>'CANCEL' or v_action.settlement_choice<>'REFUND' or v_action.status<>'PENDING_REFUND' then raise exception using errcode='P0001',message='CANCELLATION_REFUND_NOT_PENDING'; end if;
  v_plan:=public.service_get_cancellation_refund_plan(p_policy_action_id);
  if v_amount>coalesce((v_plan->>'manual_refund_cash')::numeric,0)+0.009 then raise exception using errcode='P0001',message='MANUAL_REFUND_EXCEEDS_OFF_GATEWAY_AMOUNT'; end if;
  v_left:=v_amount;
  for v_parent in
    select * from public.payment_transactions
    where appointment_id=v_action.appointment_id and transaction_type='CHARGE' and payment_purpose='CONTRACT'
      and status in('APPROVED','PARTIALLY_REFUNDED','REFUNDED') and cash_amount>0
      and (provider<>'MERCADO_PAGO' or provider_payment_id is null)
    order by paid_at nulls last,created_at,id
    for update
  loop
    exit when v_left<=0.009;
    select coalesce(sum(cash_amount),0),coalesce(sum(contract_amount_settled),0) into v_refunded_cash,v_refunded_contract
    from public.payment_transactions where parent_transaction_id=v_parent.id and transaction_type='REFUND' and status in('APPROVED','REFUNDED');
    v_cash_remaining:=greatest(v_parent.cash_amount-v_refunded_cash,0);
    v_contract_remaining:=greatest(v_parent.contract_amount_settled-v_refunded_contract,0);
    if v_cash_remaining<=0.009 then continue; end if;
    v_take:=least(v_left,v_cash_remaining);
    v_contract_take:=case when v_cash_remaining>0 then least(v_contract_remaining,round(v_take*v_contract_remaining/v_cash_remaining,2)) else 0 end;
    insert into public.payment_transactions(appointment_id,transaction_type,method,provider,status,contract_amount_settled,cash_amount,parent_transaction_id,paid_at,created_by_admin_id,notes,idempotency_key,policy_action_id,payment_purpose)
    values(v_action.appointment_id,'REFUND',v_method,'MANUAL','APPROVED',v_contract_take,v_take,v_parent.id,v_paid_at,p_admin_id,btrim(p_reference),'manual-cancel-refund:'||p_policy_action_id::text||':'||p_request_id||':'||v_parent.id::text,p_policy_action_id,'CONTRACT')
    on conflict(idempotency_key) do update set idempotency_key=excluded.idempotency_key
    returning id into v_refund_id;
    if v_first_id is null then v_first_id:=v_refund_id; end if;
    select coalesce(sum(cash_amount),0) into v_refunded_cash from public.payment_transactions where parent_transaction_id=v_parent.id and transaction_type='REFUND' and status in('APPROVED','REFUNDED');
    update public.payment_transactions set status=case when v_refunded_cash>=cash_amount-0.009 then 'REFUNDED' else 'PARTIALLY_REFUNDED' end,updated_at=now() where id=v_parent.id;
    v_left:=v_left-v_take;
  end loop;
  if v_left>0.009 then raise exception using errcode='P0001',message='MANUAL_REFUND_ALLOCATION_FAILED'; end if;
  select coalesce(sum(cash_amount),0)::numeric(12,2) into v_total_recorded from public.payment_transactions where policy_action_id=p_policy_action_id and transaction_type='REFUND' and status in('APPROVED','REFUNDED');
  if v_total_recorded>=v_action.refundable_amount-0.009 then update public.appointment_policy_actions set status='REFUNDED',updated_at=now() where id=p_policy_action_id; end if;
  perform public.refresh_appointment_financial_status(v_action.appointment_id);
  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,after_json,origin)
  values(p_admin_id,'APPOINTMENT',v_action.appointment_id,'MANUAL_CANCELLATION_REFUND_RECORDED',jsonb_build_object('policy_action_id',p_policy_action_id,'refund_transaction_id',v_first_id,'method',v_method,'cash_amount',v_amount,'reference',btrim(p_reference),'paid_at',v_paid_at,'request_id',p_request_id),'ADMIN');
  v_after:=public.service_get_cancellation_refund_plan(p_policy_action_id);
  return v_after||jsonb_build_object('refund_transaction_id',v_first_id,'manual_refund_recorded',v_amount,'method',v_method,'paid_at',v_paid_at);
end;
$function$;

create or replace function public.service_admin_finance_month_close(p_month date, p_operation_scope text, p_admin_id uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public','pg_temp'
as $function$
declare
  v_scope text:=nullif(upper(btrim(coalesce(p_operation_scope,''))),''); v_month_start date:=date_trunc('month',p_month)::date; v_month_end date:=(date_trunc('month',p_month)+interval '1 month')::date;
  v_start timestamptz:=(v_month_start::timestamp at time zone 'America/Sao_Paulo'); v_end timestamptz:=(v_month_end::timestamp at time zone 'America/Sao_Paulo');
  v_count integer:=0; v_contracted numeric(12,2):=0; v_gross_settled numeric(12,2):=0; v_contract_refunded numeric(12,2):=0; v_net_settled numeric(12,2):=0; v_outstanding numeric(12,2):=0;
  v_cash_received numeric(12,2):=0; v_cash_refunded numeric(12,2):=0; v_balance_open numeric(12,2):=0; v_balance_credited numeric(12,2):=0; v_balance_applied numeric(12,2):=0; v_balance_expired numeric(12,2):=0;
begin
  if not public.service_admin_has_permission(p_admin_id,'FINANCE_VIEW') then raise exception using errcode='P0001',message='ADMIN_PERMISSION_DENIED'; end if;
  if v_scope is not null and v_scope not in('BLACKSHEEP','SABRINA') then raise exception using errcode='P0001',message='FINANCE_OPERATION_SCOPE_INVALID'; end if;
  select count(*)::integer,coalesce(sum(a.commercial_value),0)::numeric(12,2),coalesce(sum(x.gross_settled),0)::numeric(12,2),coalesce(sum(x.refunded),0)::numeric(12,2)
  into v_count,v_contracted,v_gross_settled,v_contract_refunded
  from public.appointments a join public.services s on s.id=a.service_id
  left join lateral (
    select coalesce((select sum(pt.contract_amount_settled) from public.payment_transactions pt where pt.appointment_id=a.id and pt.transaction_type='CHARGE' and pt.payment_purpose='CONTRACT' and pt.status in('APPROVED','PARTIALLY_REFUNDED','REFUNDED')),0)
      +coalesce((select sum(cbm.amount) from public.customer_balance_movements cbm where cbm.appointment_id=a.id and cbm.movement_type='APPLY_TO_APPOINTMENT' and cbm.direction='DEBIT'),0) as gross_settled,
      coalesce((select sum(pt.contract_amount_settled) from public.payment_transactions pt where pt.appointment_id=a.id and pt.transaction_type='REFUND' and pt.payment_purpose='CONTRACT' and pt.status in('APPROVED','REFUNDED')),0) as refunded
  ) x on true
  where a.status in('COMPLETED','NO_SHOW') and a.start_at>=v_start and a.start_at<v_end and (v_scope is null or s.operation_scope=v_scope);
  v_net_settled:=round(greatest(v_gross_settled-v_contract_refunded,0),2); v_outstanding:=round(greatest(v_contracted-v_net_settled,0),2);
  select coalesce(sum(pt.cash_amount) filter(where pt.transaction_type='CHARGE' and pt.status in('APPROVED','PARTIALLY_REFUNDED','REFUNDED')),0)::numeric(12,2),coalesce(sum(pt.cash_amount) filter(where pt.transaction_type='REFUND' and pt.status in('APPROVED','REFUNDED')),0)::numeric(12,2)
  into v_cash_received,v_cash_refunded
  from public.payment_transactions pt join public.appointments a on a.id=pt.appointment_id join public.services s on s.id=a.service_id
  where coalesce(pt.paid_at,pt.created_at)>=v_start and coalesce(pt.paid_at,pt.created_at)<v_end and (v_scope is null or s.operation_scope=v_scope);
  if v_scope is null then select coalesce(sum(public.customer_balance_available(c.id)),0)::numeric(12,2) into v_balance_open from public.customers c;
  else
    select coalesce(sum(greatest(cbm.amount-coalesce((select sum(d.amount) from public.customer_balance_movements d where d.source_credit_movement_id=cbm.id and d.direction='DEBIT'),0),0)),0)::numeric(12,2)
    into v_balance_open from public.customer_balance_movements cbm join public.appointments a on a.id=cbm.appointment_id join public.services s on s.id=a.service_id
    where cbm.direction='CREDIT' and coalesce(cbm.expires_at,cbm.created_at+interval '12 months')>now() and s.operation_scope=v_scope;
  end if;
  select coalesce(sum(cbm.amount) filter(where cbm.direction='CREDIT'),0)::numeric(12,2),coalesce(sum(cbm.amount) filter(where cbm.direction='DEBIT'),0)::numeric(12,2)
  into v_balance_credited,v_balance_applied from public.customer_balance_movements cbm left join public.appointments a on a.id=cbm.appointment_id left join public.services s on s.id=a.service_id
  where cbm.created_at>=v_start and cbm.created_at<v_end and (v_scope is null or s.operation_scope=v_scope);
  select coalesce(sum(greatest(cbm.amount-coalesce((select sum(d.amount) from public.customer_balance_movements d where d.source_credit_movement_id=cbm.id and d.direction='DEBIT'),0),0)),0)::numeric(12,2)
  into v_balance_expired from public.customer_balance_movements cbm left join public.appointments a on a.id=cbm.appointment_id left join public.services s on s.id=a.service_id
  where cbm.direction='CREDIT' and coalesce(cbm.expires_at,cbm.created_at+interval '12 months')>=v_start and coalesce(cbm.expires_at,cbm.created_at+interval '12 months')<v_end and (v_scope is null or s.operation_scope=v_scope);
  return jsonb_build_object('month',to_char(v_month_start,'YYYY-MM'),'operation_scope',v_scope,'service_count',v_count,'revenue',round(v_contracted,2),
    'services',jsonb_build_object('service_count',v_count,'contracted',round(v_contracted,2),'statuses',jsonb_build_array('COMPLETED','NO_SHOW')),
    'contract',jsonb_build_object('gross_settled',round(v_gross_settled,2),'refunded',round(v_contract_refunded,2),'net_settled',v_net_settled,'outstanding',v_outstanding),
    'cash',jsonb_build_object('received',round(v_cash_received,2),'refunded',round(v_cash_refunded,2),'net',round(v_cash_received-v_cash_refunded,2)),
    'customer_balance',jsonb_build_object('open_liability',round(v_balance_open,2),'credited_in_month',round(v_balance_credited,2),'applied_in_month',round(v_balance_applied,2),'expired_in_month',round(v_balance_expired,2),'validity_months',12,'accounting_classification','LIABILITY_NOT_REVENUE'),
    'range',jsonb_build_object('start_at',v_start,'end_at',v_end),'timezone','America/Sao_Paulo');
end;
$function$;

create or replace function public.service_admin_finance_nfse_export(p_month date, p_operation_scope text, p_admin_id uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public','pg_temp'
as $function$
declare v_scope text:=nullif(upper(btrim(coalesce(p_operation_scope,''))),''); v_month_start date:=date_trunc('month',p_month)::date; v_month_end date:=(date_trunc('month',p_month)+interval '1 month')::date; v_start timestamptz:=(v_month_start::timestamp at time zone 'America/Sao_Paulo'); v_end timestamptz:=(v_month_end::timestamp at time zone 'America/Sao_Paulo'); v_rows jsonb;
begin
  if not public.service_admin_has_permission(p_admin_id,'FINANCE_VIEW') then raise exception using errcode='P0001',message='ADMIN_PERMISSION_DENIED'; end if;
  if v_scope is not null and v_scope not in('BLACKSHEEP','SABRINA') then raise exception using errcode='P0001',message='FINANCE_OPERATION_SCOPE_INVALID'; end if;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.service_at,x.appointment_id),'[]'::jsonb) into v_rows from (
    select a.id appointment_id,a.public_code,a.start_at service_at,to_char(a.start_at at time zone 'America/Sao_Paulo','DD/MM/YYYY') date,coalesce(c.name,'') client,coalesce(c.cpf_cnpj,'') cpf_cnpj,coalesce(c.address,'') address,coalesce(c.email,'') email,coalesce(a.service_name_snapshot,s.name,'') service,coalesce(a.commercial_value,0)::numeric(12,2) value,
      public.appointment_contract_coverage_amount(a.id)::numeric(12,2) contract_settled,round(greatest(coalesce(a.commercial_value,0)-public.appointment_contract_coverage_amount(a.id),0),2)::numeric(12,2) outstanding,a.financial_status,a.status appointment_status,s.operation_scope,
      coalesce(pm.payment_method,'Não recebido') payment_method,case s.operation_scope when 'BLACKSHEEP' then 'BlackSheep' when 'SABRINA' then 'Sabrina Pierri' else coalesce(s.operation_scope,'') end operation
    from public.appointments a left join public.customers c on c.id=a.primary_customer_id left join public.services s on s.id=a.service_id
    left join lateral (
      select string_agg(q.label,' + ' order by q.label) payment_method from (
        select distinct case pt.method when 'PIX' then 'Pix' when 'CASH' then 'Dinheiro' when 'CREDIT_CARD' then 'Cartão de crédito' when 'DEBIT_CARD' then 'Cartão de débito' when 'BANK_TRANSFER' then 'Transferência' else 'Outro' end label
        from public.payment_transactions pt where pt.appointment_id=a.id and pt.transaction_type='CHARGE' and pt.payment_purpose='CONTRACT' and pt.status in('APPROVED','PARTIALLY_REFUNDED','REFUNDED')
        union select 'Saldo do cliente' where exists(select 1 from public.customer_balance_movements cbm where cbm.appointment_id=a.id and cbm.movement_type='APPLY_TO_APPOINTMENT' and cbm.direction='DEBIT')
      ) q
    ) pm on true
    where a.status in('COMPLETED','NO_SHOW') and a.start_at>=v_start and a.start_at<v_end and (v_scope is null or s.operation_scope=v_scope)
  ) x;
  return jsonb_build_object('month',to_char(v_month_start,'YYYY-MM'),'operation_scope',v_scope,'timezone','America/Sao_Paulo','rows',v_rows);
end;
$function$;

revoke execute on function public.service_admin_finance_pending_refunds(text,uuid) from public,anon,authenticated;
revoke execute on function public.service_admin_record_cancellation_manual_refund(uuid,text,numeric,text,timestamptz,uuid,inet,text,text) from public,anon,authenticated;
grant execute on function public.service_admin_finance_pending_refunds(text,uuid) to service_role;
grant execute on function public.service_admin_record_cancellation_manual_refund(uuid,text,numeric,text,timestamptz,uuid,inet,text,text) to service_role;
