-- Phase 3 findings 5 + 8: configuration must govern the engine.
-- New reservations snapshot commercial configuration once. Historical rows are
-- not assigned an unverifiable confirmation percentage by this migration.

alter table public.services
  drop constraint if exists services_confirmation_percentage_check,
  add constraint services_confirmation_percentage_check
    check (confirmation_percentage is null or confirmation_percentage > 0 and confirmation_percentage <= 100);

alter table public.operation_settings
  drop constraint if exists operation_settings_default_confirmation_percentage_check,
  add constraint operation_settings_default_confirmation_percentage_check
    check (default_confirmation_percentage > 0 and default_confirmation_percentage <= 100);

alter table public.appointment_change_settlements
  drop constraint if exists appointment_change_settlements_commitment_check,
  add constraint appointment_change_settlements_commitment_check
    check (payment_commitment_percent >= 0 and payment_commitment_percent <= 100);

alter table public.appointment_change_policy_snapshots
  drop constraint if exists appointment_change_policy_snapsh_max_customer_reschedules_check,
  add constraint appointment_change_policy_snapshots_max_customer_reschedules_check
    check (max_customer_reschedules >= 0);

alter table public.appointments
  add column confirmation_percentage_snapshot numeric(5,2),
  add constraint appointments_confirmation_percentage_snapshot_check
    check (
      confirmation_percentage_snapshot is null
      or confirmation_percentage_snapshot > 0 and confirmation_percentage_snapshot <= 100
    );

comment on column public.appointments.confirmation_percentage_snapshot is
  'Immutable checkout confirmation target captured when the reservation is created. NULL is allowed only for legacy reservations whose historical value cannot be proven.';

-- Preserve any historical value that was explicitly recorded by a payment request.
-- Do not guess for appointments with no such evidence.
with evidenced as (
  select distinct on (pt.appointment_id)
    pt.appointment_id,
    pt.requested_percentage
  from public.payment_transactions pt
  where pt.payment_purpose = 'CONTRACT'
    and pt.transaction_type = 'CHARGE'
    and pt.requested_percentage is not null
    and pt.requested_percentage < 100
  order by pt.appointment_id, pt.created_at, pt.id
)
update public.appointments a
set confirmation_percentage_snapshot = e.requested_percentage
from evidenced e
where a.id = e.appointment_id
  and a.confirmation_percentage_snapshot is null;

create or replace function public.capture_appointment_commercial_configuration()
returns trigger
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_confirmation numeric(5,2);
begin
  if new.confirmation_percentage_snapshot is null then
    select coalesce(s.confirmation_percentage, os.default_confirmation_percentage)
    into v_confirmation
    from public.services s
    cross join public.operation_settings os
    where s.id = new.service_id
      and os.id = 1;

    if v_confirmation is null then
      raise exception using errcode='P0001', message='APPOINTMENT_CONFIRMATION_CONFIGURATION_MISSING';
    end if;

    new.confirmation_percentage_snapshot := v_confirmation;
  end if;

  return new;
end;
$$;

drop trigger if exists appointments_capture_commercial_configuration on public.appointments;
create trigger appointments_capture_commercial_configuration
before insert on public.appointments
for each row execute function public.capture_appointment_commercial_configuration();

create or replace function public.prevent_appointment_confirmation_snapshot_change()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if old.confirmation_percentage_snapshot is not null
     and new.confirmation_percentage_snapshot is distinct from old.confirmation_percentage_snapshot then
    raise exception using errcode='42501', message='APPOINTMENT_CONFIRMATION_SNAPSHOT_IMMUTABLE';
  end if;
  return new;
end;
$$;

drop trigger if exists appointments_protect_confirmation_snapshot on public.appointments;
create trigger appointments_protect_confirmation_snapshot
before update of confirmation_percentage_snapshot on public.appointments
for each row execute function public.prevent_appointment_confirmation_snapshot_change();

create or replace function public.normalize_change_policy_snapshot(p_policy jsonb)
returns jsonb
language sql
immutable
set search_path = public
as $$
  select case
    when p_policy is null then null
    else p_policy || jsonb_build_object(
      'max_customer_reschedules', coalesce((p_policy->>'max_customer_reschedules')::integer, 3),
      'policy_timezone', 'America/Sao_Paulo',
      'notice_boundary_semantics', 'EXACT_LIMIT_IS_OUTSIDE_WINDOW',
      'snapshot_schema_version', case
        when nullif(p_policy->>'reschedule_first_early_percent','') is not null
         and nullif(p_policy->>'reschedule_first_late_percent','') is not null
         and nullif(p_policy->>'reschedule_repeat_percent','') is not null
         and nullif(p_policy->>'cancellation_late_percent','') is not null
        then 'CONSOLIDATED_POLICY_V2'
        else 'CHANGE_POLICY_SNAPSHOT_V1'
      end
    )
  end;
$$;

create or replace function public.capture_current_appointment_change_policy_snapshot()
returns trigger
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_policy public.service_change_policies%rowtype;
  v_effective_at timestamptz;
  v_max_reschedules integer;
  v_policy_json jsonb;
begin
  if new.status not in ('AWAITING_PAYMENT','CONFIRMED') then return new; end if;
  if exists (select 1 from public.appointment_change_policy_snapshots s where s.appointment_id=new.id) then return new; end if;

  select cp.*
  into v_policy
  from public.service_change_policies cp
  where cp.service_id=new.service_id;

  if not found then return new; end if;

  select coalesce(s.max_reschedules, 3)
  into v_max_reschedules
  from public.services s
  where s.id=new.service_id;

  if not found then return new; end if;

  v_effective_at := case when new.status='AWAITING_PAYMENT' then new.created_at else coalesce(new.confirmed_at,new.created_at) end;
  v_policy_json := public.normalize_change_policy_snapshot(
    to_jsonb(v_policy) || jsonb_build_object('max_customer_reschedules',v_max_reschedules)
  );

  insert into public.appointment_change_policy_snapshots(
    appointment_id,service_id,policy_json,effective_at,source,
    max_customer_reschedules,policy_timezone,notice_boundary_semantics
  ) values (
    new.id,new.service_id,v_policy_json,v_effective_at,'BOOKING_CAPTURE',
    v_max_reschedules,'America/Sao_Paulo','EXACT_LIMIT_IS_OUTSIDE_WINDOW'
  );

  perform public.capture_appointment_policy_terms_snapshot(new.id,new.service_id,v_effective_at);
  return new;
end;
$$;

create or replace function public.service_get_public_payment_context(p_access_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_appointment_id uuid;
  v_appointment public.appointments%rowtype;
  v_customer public.customers%rowtype;
  v_summary jsonb;
  v_confirmation_percentage numeric(5,2);
  v_confirmation_target numeric(12,2);
  v_settled numeric(12,2);
  v_minimum_due numeric(12,2);
begin
  v_appointment_id := public.resolve_appointment_access_token(p_access_token,'PAY');
  select * into v_appointment from public.appointments where id=v_appointment_id;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if;
  if v_appointment.status not in ('AWAITING_PAYMENT','CONFIRMED') then raise exception using errcode='P0001',message='APPOINTMENT_NOT_PAYABLE'; end if;
  if v_appointment.status='AWAITING_PAYMENT' and (v_appointment.hold_expires_at is null or v_appointment.hold_expires_at<=now()) then
    raise exception using errcode='P0001',message='PAYMENT_HOLD_EXPIRED';
  end if;

  select * into v_customer from public.customers where id=v_appointment.primary_customer_id;
  if v_customer.id is null then raise exception using errcode='P0001',message='CUSTOMER_NOT_FOUND'; end if;

  v_confirmation_percentage := v_appointment.confirmation_percentage_snapshot;
  if v_confirmation_percentage is null then
    raise exception using errcode='P0001',message='APPOINTMENT_CONFIRMATION_SNAPSHOT_MISSING';
  end if;

  v_summary := public.get_appointment_financial_summary(v_appointment.id);
  v_settled := (v_summary->>'contract_settled')::numeric;
  v_confirmation_target := round(coalesce(v_appointment.commercial_value,0)*v_confirmation_percentage/100,2);
  v_minimum_due := round(greatest(v_confirmation_target-v_settled,0),2);

  return jsonb_build_object(
    'appointment_id',v_appointment.id,'public_code',v_appointment.public_code,
    'appointment_status',v_appointment.status,'financial_status',v_appointment.financial_status,
    'service_name',v_appointment.service_name_snapshot,'hold_expires_at',v_appointment.hold_expires_at,
    'commercial_value',coalesce(v_appointment.commercial_value,0),'contract_settled',v_settled,
    'contract_balance',(v_summary->>'contract_balance')::numeric,
    'confirmation_percentage',v_confirmation_percentage,'confirmation_target_amount',v_confirmation_target,
    'minimum_due_contract_amount',v_minimum_due,'minimum_available',v_minimum_due>0,
    'full_available',(v_summary->>'contract_balance')::numeric>0,
    'payer',jsonb_build_object('name',v_customer.name,'email',v_customer.email,
      'tax_id',regexp_replace(coalesce(v_customer.cpf_cnpj,''),'\D','','g'))
  );
end;
$$;

create or replace function public.service_create_payment_intent_by_token(
  p_access_token text,p_payment_kind text,p_method text,p_request_key text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_appointment_id uuid;
  v_appointment public.appointments%rowtype;
  v_percentage numeric(5,2);
  v_idempotency_key text;
begin
  if p_payment_kind not in ('MINIMUM','FULL') then raise exception using errcode='P0001',message='INVALID_PAYMENT_KIND'; end if;
  if p_method not in ('PIX','CARD') then raise exception using errcode='P0001',message='PUBLIC_PAYMENT_METHOD_NOT_ALLOWED'; end if;
  if p_request_key is null or p_request_key !~ '^[A-Za-z0-9_-]{12,100}$' then raise exception using errcode='P0001',message='PAYMENT_REQUEST_KEY_INVALID'; end if;

  v_appointment_id := public.resolve_appointment_access_token(p_access_token,'PAY');
  select * into v_appointment from public.appointments where id=v_appointment_id;

  if p_payment_kind='FULL' then v_percentage:=100;
  else
    v_percentage:=v_appointment.confirmation_percentage_snapshot;
    if v_percentage is null then raise exception using errcode='P0001',message='APPOINTMENT_CONFIRMATION_SNAPSHOT_MISSING'; end if;
  end if;

  v_idempotency_key := 'public:'||v_appointment_id::text||':'||p_request_key;
  return public.create_payment_intent(v_appointment_id,v_percentage,p_method,v_idempotency_key);
end;
$$;

create or replace function public.create_payment_intent(
  p_appointment_id uuid,p_payment_percentage numeric,p_method text,p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_appointment public.appointments%rowtype;
  v_existing public.payment_transactions%rowtype;
  v_summary jsonb;
  v_balance numeric(12,2); v_settled_before numeric(12,2);
  v_confirmation_percentage numeric(5,2); v_confirmation_target numeric(12,2);
  v_contract_amount numeric(12,2); v_discount_percent numeric(5,2);
  v_discount numeric(12,2); v_cash_amount numeric(12,2); v_amounts jsonb;
  v_transaction_id uuid; v_payment_kind text;
begin
  if p_method not in ('PIX','CARD') then raise exception using errcode='P0001',message='PUBLIC_PAYMENT_METHOD_NOT_ALLOWED'; end if;
  if p_idempotency_key is null or btrim(p_idempotency_key)='' then raise exception using errcode='P0001',message='IDEMPOTENCY_KEY_REQUIRED'; end if;

  select * into v_existing from public.payment_transactions where idempotency_key=p_idempotency_key;
  if found then
    if v_existing.appointment_id<>p_appointment_id or v_existing.method<>p_method or v_existing.requested_percentage is distinct from p_payment_percentage then
      raise exception using errcode='P0001',message='IDEMPOTENCY_KEY_CONFLICT';
    end if;
    return jsonb_build_object('transaction_id',v_existing.id,'appointment_id',v_existing.appointment_id,'status',v_existing.status,
      'payment_percentage',v_existing.requested_percentage,'contract_amount_settled',v_existing.contract_amount_settled,
      'payment_discount_amount',v_existing.payment_discount_amount,'cash_amount',v_existing.cash_amount,'method',v_existing.method,'idempotent_replay',true);
  end if;

  perform public.expire_due_appointment_holds();
  select * into v_appointment from public.appointments where id=p_appointment_id for update;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if;
  if v_appointment.status not in ('AWAITING_PAYMENT','CONFIRMED') then raise exception using errcode='P0001',message='APPOINTMENT_NOT_PAYABLE'; end if;
  if v_appointment.status='AWAITING_PAYMENT' and (v_appointment.hold_expires_at is null or v_appointment.hold_expires_at<=now()) then
    raise exception using errcode='P0001',message='PAYMENT_HOLD_EXPIRED';
  end if;

  v_confirmation_percentage:=v_appointment.confirmation_percentage_snapshot;
  if v_confirmation_percentage is null then raise exception using errcode='P0001',message='APPOINTMENT_CONFIRMATION_SNAPSHOT_MISSING'; end if;
  if p_payment_percentage<>100 and p_payment_percentage<>v_confirmation_percentage then
    raise exception using errcode='P0001',message='INVALID_PAYMENT_PERCENTAGE';
  end if;

  select os.pix_discount_percent into v_discount_percent from public.operation_settings os where os.id=1;
  v_summary:=public.get_appointment_financial_summary(p_appointment_id);
  v_balance:=(v_summary->>'contract_balance')::numeric;
  v_settled_before:=(v_summary->>'contract_settled')::numeric;
  if v_balance<=0 then raise exception using errcode='P0001',message='APPOINTMENT_ALREADY_PAID'; end if;

  v_confirmation_target:=round(coalesce(v_appointment.commercial_value,0)*v_confirmation_percentage/100,2);
  if p_payment_percentage=100 then
    v_payment_kind:='FULL_BALANCE'; v_contract_amount:=v_balance;
  else
    v_payment_kind:='CONFIRMATION_MINIMUM';
    v_contract_amount:=round(greatest(v_confirmation_target-v_settled_before,0),2);
    if v_contract_amount<=0 then raise exception using errcode='P0001',message='CONFIRMATION_PAYMENT_ALREADY_SATISFIED'; end if;
    v_contract_amount:=least(v_contract_amount,v_balance);
  end if;

  v_amounts:=public.service_calculate_payment_cash_amount(v_contract_amount,p_method,v_discount_percent);
  v_discount:=(v_amounts->>'payment_discount_amount')::numeric;
  v_cash_amount:=(v_amounts->>'cash_amount')::numeric;

  insert into public.payment_transactions(
    appointment_id,transaction_type,method,provider,status,contract_amount_settled,
    payment_discount_amount,cash_amount,idempotency_key,requested_percentage
  ) values (
    p_appointment_id,'CHARGE',p_method,'MERCADO_PAGO','PENDING',v_contract_amount,
    v_discount,v_cash_amount,p_idempotency_key,p_payment_percentage
  ) returning id into v_transaction_id;

  if v_appointment.financial_status not in ('PARTIALLY_PAID','PAID','UNPAID_AUTHORIZED') then
    update public.appointments set financial_status='PENDING',updated_at=now() where id=p_appointment_id;
  end if;

  return jsonb_build_object('transaction_id',v_transaction_id,'appointment_id',p_appointment_id,'status','PENDING',
    'payment_kind',v_payment_kind,'payment_percentage',p_payment_percentage,'confirmation_percentage',v_confirmation_percentage,
    'confirmation_target_amount',v_confirmation_target,'contract_settled_before',v_settled_before,'contract_balance_before',v_balance,
    'contract_amount_settled',v_contract_amount,'payment_discount_amount',v_discount,'cash_amount',v_cash_amount,
    'method',p_method,'provider','MERCADO_PAGO','idempotent_replay',false);
end;
$$;

create or replace function public.calculate_reservation_change(
  p_appointment_id uuid,p_action_type text,p_requested_at timestamptz,p_change_origin text,p_new_contract_value numeric
)
returns jsonb
language plpgsql
stable
set search_path=public
as $$
declare
  v_appointment public.appointments%rowtype;
  v_snapshot public.appointment_change_policy_snapshots%rowtype;
  v_policy jsonb; v_schema text; v_notice integer; v_seconds numeric; v_hours numeric(12,2); v_inside boolean;
  v_count integer; v_contract numeric(12,2); v_funds numeric(12,2); v_applied numeric(12,2); v_excess_before numeric(12,2);
  v_contract_coverage numeric(12,2); v_contract_coverage_after numeric(12,2); v_commitment numeric(5,2); v_target numeric(12,2);
  v_percent numeric(5,2):=0; v_theoretical numeric(12,2):=0; v_retained numeric(12,2):=0;
  v_after numeric(12,2):=0; v_applicable numeric(12,2):=0; v_excess_after numeric(12,2):=0;
  v_difference numeric(12,2):=0; v_refund numeric(12,2):=0;
  v_legacy_type public.change_penalty_type; v_legacy_value numeric(12,2):=0;
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

  v_policy:=v_snapshot.policy_json; v_schema:=coalesce(v_policy->>'snapshot_schema_version','CHANGE_POLICY_SNAPSHOT_V1');
  v_notice:=(v_policy->>'notice_hours')::integer;
  if v_notice is null then raise exception using errcode='P0001',message='APPOINTMENT_CHANGE_POLICY_SNAPSHOT_INVALID'; end if;

  v_seconds:=extract(epoch from (v_appointment.start_at-p_requested_at)); v_hours:=round(v_seconds/3600.0,2);
  v_inside:=v_seconds<(v_notice::numeric*3600); v_count:=public.appointment_client_reschedule_count(p_appointment_id);
  v_contract:=round(coalesce(v_appointment.commercial_value,0),2);
  v_funds:=round(public.appointment_customer_funds_amount(p_appointment_id),2);
  v_applied:=round(least(v_funds,v_contract),2); v_excess_before:=round(greatest(v_funds-v_contract,0),2);
  v_contract_coverage:=round(public.appointment_contract_coverage_amount(p_appointment_id),2);

  if v_appointment.billing_mode_snapshot='INVOICE' or v_appointment.financial_status='UNPAID_AUTHORIZED' then v_commitment:=0;
  elsif v_contract<=0 or v_contract_coverage>=v_contract then v_commitment:=100;
  else
    v_commitment:=v_appointment.confirmation_percentage_snapshot;
    if v_commitment is null then raise exception using errcode='P0001',message='APPOINTMENT_CONFIRMATION_SNAPSHOT_MISSING'; end if;
  end if;

  if p_change_origin='OPERATION' then v_percent:=0;
  elsif v_schema='CONSOLIDATED_POLICY_V2' then
    if p_action_type='RESCHEDULE' then
      if v_count>0 then v_percent:=(v_policy->>'reschedule_repeat_percent')::numeric;
      elsif v_inside then v_percent:=(v_policy->>'reschedule_first_late_percent')::numeric;
      else v_percent:=(v_policy->>'reschedule_first_early_percent')::numeric; end if;
    else v_percent:=case when v_inside then (v_policy->>'cancellation_late_percent')::numeric else 0 end; end if;
  else
    if p_action_type='RESCHEDULE' then
      if v_count>0 then v_legacy_type:=(v_policy->>'reschedule_repeat_penalty_type')::public.change_penalty_type; v_legacy_value:=(v_policy->>'reschedule_repeat_penalty_value')::numeric;
      elsif v_inside then v_legacy_type:=(v_policy->>'reschedule_late_penalty_type')::public.change_penalty_type; v_legacy_value:=(v_policy->>'reschedule_late_penalty_value')::numeric;
      else v_legacy_type:=(v_policy->>'reschedule_first_penalty_type')::public.change_penalty_type; v_legacy_value:=(v_policy->>'reschedule_first_penalty_value')::numeric; end if;
    else
      if v_inside then v_legacy_type:=(v_policy->>'cancellation_late_penalty_type')::public.change_penalty_type; v_legacy_value:=(v_policy->>'cancellation_late_penalty_value')::numeric;
      else v_legacy_type:=(v_policy->>'cancellation_early_penalty_type')::public.change_penalty_type; v_legacy_value:=(v_policy->>'cancellation_early_penalty_value')::numeric; end if;
    end if;
    if v_legacy_type='PERCENT' then v_percent:=v_legacy_value; elsif v_legacy_type='NONE' then v_percent:=0; else v_percent:=0; v_theoretical:=round(v_legacy_value,2); end if;
  end if;

  if v_theoretical=0 then v_theoretical:=round(v_contract*v_percent/100,2); end if;
  v_retained:=case when p_change_origin='OPERATION' then 0 else round(least(v_theoretical,v_applied),2) end;
  v_after:=round(greatest(v_funds-v_retained,0),2); v_contract_coverage_after:=round(greatest(v_contract_coverage-v_retained,0),2);
  if p_action_type='RESCHEDULE' then
    v_target:=round(p_new_contract_value*v_commitment/100,2); v_applicable:=round(least(v_after,p_new_contract_value),2);
    v_excess_after:=round(greatest(v_after-p_new_contract_value,0),2); v_difference:=round(greatest(v_target-v_contract_coverage_after,0),2);
  else
    v_target:=0; v_applicable:=round(greatest(v_applied-v_retained,0),2); v_excess_after:=v_excess_before; v_refund:=round(v_applicable+v_excess_before,2);
  end if;

  return jsonb_build_object(
    'appointment_id',p_appointment_id,'service_id',v_appointment.service_id,'action_type',p_action_type,'change_origin',p_change_origin,
    'requested_at',p_requested_at,'original_start_at',v_appointment.start_at,'hours_before_start',v_hours,'notice_hours',v_notice,
    'inside_notice_window',v_inside,'prior_customer_reschedules',v_count,'max_customer_reschedules',v_snapshot.max_customer_reschedules,
    'contract_value',v_contract,'new_contract_value',p_new_contract_value,'customer_funds_before',v_funds,
    'contract_applied_before',v_applied,'excess_before',v_excess_before,'contract_coverage_before',v_contract_coverage,
    'payment_commitment_percent',v_commitment,'confirmation_target_amount',v_target,
    'penalty_percent',v_percent,'theoretical_penalty',v_theoretical,'penalty_retained',v_retained,'penalty_amount',v_retained,
    'customer_funds_after_penalty',v_after,'contract_coverage_after_penalty',v_contract_coverage_after,
    'applicable_amount',v_applicable,'excess_amount',v_excess_after,'difference_due',v_difference,
    'refund_due',v_refund,'refundable_amount',v_refund,
    'customer_reschedule_limit_reached',(p_action_type='RESCHEDULE' and p_change_origin='CLIENT' and v_count>=v_snapshot.max_customer_reschedules),
    'snapshot_schema_version',v_schema
  );
end;
$$;

revoke all on function public.capture_appointment_commercial_configuration() from public,anon,authenticated,service_role;
revoke all on function public.prevent_appointment_confirmation_snapshot_change() from public,anon,authenticated;