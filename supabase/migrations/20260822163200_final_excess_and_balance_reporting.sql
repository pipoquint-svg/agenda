-- Final settlement of customer-owned excess and accounting-facing balance report.

create table public.appointment_final_settlements (
  id uuid primary key default gen_random_uuid(),
  appointment_id uuid not null unique references public.appointments(id) on delete restrict,
  customer_id uuid not null references public.customers(id) on delete restrict,
  excess_amount numeric(12,2) not null check (excess_amount>0),
  settlement_choice text not null check (settlement_choice in ('REFUND','CUSTOMER_BALANCE')),
  status text not null check (status in ('PENDING_REFUND','BALANCE_CREDITED','REFUNDED','FAILED')),
  balance_movement_id uuid references public.customer_balance_movements(id) on delete restrict,
  choice_origin text check (choice_origin is null or choice_origin in ('CLIENT_TOKEN','ADMIN_UI')),
  admin_user_id uuid references public.admin_users(id) on delete restrict,
  admin_request_reference text,
  ip_address inet,
  user_agent text,
  request_id text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (
    settlement_choice='REFUND'
    or (
      balance_movement_id is not null and choice_origin is not null and ip_address is not null
      and nullif(btrim(user_agent),'') is not null and nullif(btrim(request_id),'') is not null
    )
  )
);
alter table public.appointment_final_settlements enable row level security;
revoke all on public.appointment_final_settlements from public,anon,authenticated;
grant select on public.appointment_final_settlements to service_role;

create or replace function public.appointment_returnable_excess(p_appointment_id uuid)
returns numeric(12,2)
language plpgsql stable set search_path=public as $$
declare v_appointment public.appointments%rowtype; v_funds numeric(12,2);
begin
  select * into v_appointment from public.appointments where id=p_appointment_id;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if;
  v_funds:=public.appointment_customer_funds_amount(p_appointment_id);
  return round(greatest(v_funds-coalesce(v_appointment.commercial_value,0),0),2);
end;
$$;

-- Explicit customer-balance conversion from a cancellation return. Excess from a
-- completed service uses service_finalize_appointment_excess instead.
create or replace function public.service_credit_customer_balance_from_return(
  p_appointment_id uuid,p_policy_action_id uuid,p_choice_origin text,p_admin_id uuid,
  p_ip inet,p_user_agent text,p_request_id text,p_admin_request_reference text
)
returns jsonb
language plpgsql volatile security definer set search_path=public as $$
declare v_appointment public.appointments%rowtype; v_action public.appointment_policy_actions%rowtype; v_settlement public.appointment_change_settlements%rowtype; v_amount numeric(12,2); v_key text; v_id uuid;
begin
  if p_choice_origin not in ('CLIENT_TOKEN','ADMIN_UI') or p_ip is null or nullif(btrim(p_user_agent),'') is null or nullif(btrim(p_request_id),'') is null then raise exception using errcode='P0001',message='BALANCE_AUTHORSHIP_EVIDENCE_REQUIRED'; end if;
  if p_choice_origin='ADMIN_UI' and (p_admin_id is null or nullif(btrim(p_admin_request_reference),'') is null) then raise exception using errcode='P0001',message='BALANCE_ADMIN_REQUEST_EVIDENCE_REQUIRED'; end if;
  select * into v_appointment from public.appointments where id=p_appointment_id for update;
  if not found or v_appointment.primary_customer_id is null then raise exception using errcode='P0001',message='APPOINTMENT_CUSTOMER_REQUIRED'; end if;
  select * into v_action from public.appointment_policy_actions where id=p_policy_action_id and appointment_id=p_appointment_id for update;
  if not found or v_action.action_type<>'CANCEL' then raise exception using errcode='P0001',message='CANCELLATION_ACTION_REQUIRED_FOR_BALANCE_RETURN'; end if;
  select * into v_settlement from public.appointment_change_settlements where policy_action_id=v_action.id;
  if not found then raise exception using errcode='P0001',message='CHANGE_SETTLEMENT_NOT_FOUND'; end if;
  v_amount:=v_settlement.refund_due;
  if v_amount<=0 then raise exception using errcode='P0001',message='NO_RETURNABLE_AMOUNT'; end if;
  v_key:='balance-credit:'||p_appointment_id::text||':'||p_policy_action_id::text;
  insert into public.customer_balance_movements(customer_id,movement_type,direction,amount,appointment_id,policy_action_id,choice_origin,admin_user_id,admin_request_reference,ip_address,user_agent,request_id,idempotency_key)
  values(v_appointment.primary_customer_id,'CREDIT_FROM_RETURN','CREDIT',v_amount,p_appointment_id,p_policy_action_id,p_choice_origin,p_admin_id,nullif(btrim(p_admin_request_reference),''),p_ip,p_user_agent,p_request_id,v_key)
  on conflict(idempotency_key) do update set idempotency_key=excluded.idempotency_key returning id into v_id;
  update public.appointment_policy_actions set settlement_choice='CUSTOMER_BALANCE',status='APPLIED',updated_at=now() where id=v_action.id;
  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,after_json,origin)
  values(p_admin_id,'APPOINTMENT',p_appointment_id,'CUSTOMER_BALANCE_CREATED',jsonb_build_object('policy_action_id',v_action.id,'amount',v_amount,'customer_id',v_appointment.primary_customer_id,'choice_origin',p_choice_origin,'request_id',p_request_id),case when p_choice_origin='ADMIN_UI' then 'ADMIN' else 'CLIENT' end);
  return jsonb_build_object('movement_id',v_id,'customer_id',v_appointment.primary_customer_id,'amount',v_amount,'balance_available',public.customer_balance_available(v_appointment.primary_customer_id));
end;
$$;

create or replace function public.service_finalize_appointment_excess(
  p_appointment_id uuid,p_settlement_choice text,p_choice_origin text,p_admin_id uuid,
  p_ip inet,p_user_agent text,p_request_id text,p_admin_request_reference text
)
returns jsonb
language plpgsql volatile security definer set search_path=public as $$
declare
  v_appointment public.appointments%rowtype; v_amount numeric(12,2); v_choice text; v_existing public.appointment_final_settlements%rowtype;
  v_movement uuid; v_key text; v_final_id uuid;
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
    insert into public.customer_balance_movements(customer_id,movement_type,direction,amount,appointment_id,policy_action_id,choice_origin,admin_user_id,admin_request_reference,ip_address,user_agent,request_id,idempotency_key)
    values(v_appointment.primary_customer_id,'CREDIT_FROM_RETURN','CREDIT',v_amount,p_appointment_id,null,p_choice_origin,p_admin_id,nullif(btrim(p_admin_request_reference),''),p_ip,p_user_agent,p_request_id,v_key)
    returning id into v_movement;
  end if;

  insert into public.appointment_final_settlements(appointment_id,customer_id,excess_amount,settlement_choice,status,balance_movement_id,choice_origin,admin_user_id,admin_request_reference,ip_address,user_agent,request_id)
  values(p_appointment_id,v_appointment.primary_customer_id,v_amount,v_choice,case when v_choice='REFUND' then 'PENDING_REFUND' else 'BALANCE_CREDITED' end,v_movement,
    case when v_choice='CUSTOMER_BALANCE' then p_choice_origin else null end,case when v_choice='CUSTOMER_BALANCE' then p_admin_id else null end,
    case when v_choice='CUSTOMER_BALANCE' then nullif(btrim(p_admin_request_reference),'') else null end,
    case when v_choice='CUSTOMER_BALANCE' then p_ip else null end,case when v_choice='CUSTOMER_BALANCE' then p_user_agent else null end,
    case when v_choice='CUSTOMER_BALANCE' then p_request_id else null end)
  returning id into v_final_id;

  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,after_json,origin)
  values(p_admin_id,'APPOINTMENT',p_appointment_id,'APPOINTMENT_FINAL_EXCESS_SETTLED',jsonb_build_object('final_settlement_id',v_final_id,'excess_amount',v_amount,'settlement_choice',v_choice,'balance_movement_id',v_movement),case when p_choice_origin='CLIENT_TOKEN' then 'CLIENT' else 'ADMIN' end);
  return jsonb_build_object('final_settlement_id',v_final_id,'appointment_id',p_appointment_id,'excess_amount',v_amount,'settlement_choice',v_choice,'status',case when v_choice='REFUND' then 'PENDING_REFUND' else 'BALANCE_CREDITED' end,'balance_movement_id',v_movement,'idempotent_replay',false);
end;
$$;

-- Financial summary now separates penalties, customer balance and customer-owned excess.
create or replace function public.get_appointment_financial_summary(p_appointment_id uuid)
returns jsonb
language plpgsql stable set search_path=public as $$
declare
  v_appointment public.appointments%rowtype; v_cash numeric(12,2); v_balance_applied numeric(12,2); v_penalties numeric(12,2);
  v_funds numeric(12,2); v_contract_applied numeric(12,2); v_excess numeric(12,2); v_pending integer;
begin
  select * into v_appointment from public.appointments where id=p_appointment_id;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if;
  v_cash:=public.appointment_net_paid_amount(p_appointment_id);
  select coalesce(sum(amount),0)::numeric(12,2) into v_balance_applied from public.customer_balance_movements where appointment_id=p_appointment_id and movement_type='APPLY_TO_APPOINTMENT';
  select coalesce(sum(acs.penalty_retained),0)::numeric(12,2) into v_penalties
  from public.appointment_change_settlements acs join public.appointment_policy_actions apa on apa.id=acs.policy_action_id
  where acs.appointment_id=p_appointment_id and ((acs.action_type='RESCHEDULE' and apa.status='APPLIED') or acs.action_type='CANCEL');
  v_funds:=public.appointment_customer_funds_amount(p_appointment_id);
  v_contract_applied:=round(least(v_funds,coalesce(v_appointment.commercial_value,0)),2);
  v_excess:=round(greatest(v_funds-coalesce(v_appointment.commercial_value,0),0),2);
  select count(*)::integer into v_pending from public.payment_transactions where appointment_id=p_appointment_id and payment_purpose='CONTRACT' and transaction_type='CHARGE' and status='PENDING';
  return jsonb_build_object('appointment_id',p_appointment_id,'commercial_value',coalesce(v_appointment.commercial_value,0),
    'cash_contract_net',v_cash,'customer_balance_applied',v_balance_applied,'penalties_retained',v_penalties,
    'customer_funds_under_reservation',v_funds,'contract_applied',v_contract_applied,'customer_excess_held',v_excess,
    'contract_balance',round(greatest(coalesce(v_appointment.commercial_value,0)-v_contract_applied,0),2),
    'pending_charge_count',v_pending,'financial_status',v_appointment.financial_status);
end;
$$;

create or replace function public.service_finance_customer_balance_report(p_from timestamptz,p_to timestamptz)
returns jsonb
language plpgsql stable security definer set search_path=public as $$
declare v_open numeric(12,2); v_credits numeric(12,2); v_applied numeric(12,2); v_refunds numeric(12,2);
begin
  if p_from is null or p_to is null or p_to<=p_from then raise exception using errcode='P0001',message='INVALID_REPORT_PERIOD'; end if;
  select coalesce(sum(public.customer_balance_available(c.id)),0)::numeric(12,2) into v_open from public.customers c;
  select coalesce(sum(amount) filter(where movement_type='CREDIT_FROM_RETURN'),0)::numeric(12,2),coalesce(sum(amount) filter(where movement_type='APPLY_TO_APPOINTMENT'),0)::numeric(12,2)
  into v_credits,v_applied from public.customer_balance_movements where created_at>=p_from and created_at<p_to;
  select coalesce(sum(amount),0)::numeric(12,2) into v_refunds from public.customer_balance_refund_requests where requested_at>=p_from and requested_at<p_to;
  return jsonb_build_object('period_from',p_from,'period_to',p_to,'customer_balance_open_liability',v_open,'balance_credited_in_period',v_credits,'balance_applied_to_reservations_in_period',v_applied,'balance_refund_requests_in_period',v_refunds,'accounting_classification','LIABILITY_NOT_REVENUE');
end;
$$;

revoke all on function public.appointment_returnable_excess(uuid) from public,anon,authenticated;
revoke all on function public.service_finalize_appointment_excess(uuid,text,text,uuid,inet,text,text,text) from public,anon,authenticated;
revoke all on function public.service_finance_customer_balance_report(timestamptz,timestamptz) from public,anon,authenticated;
grant execute on function public.appointment_returnable_excess(uuid) to service_role;
grant execute on function public.service_finalize_appointment_excess(uuid,text,text,uuid,inet,text,text,text) to service_role;
grant execute on function public.service_finance_customer_balance_report(timestamptz,timestamptz) to service_role;
