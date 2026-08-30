-- Consolidated change policy V3: every existing penalty field may be PERCENT or FIXED.
-- Existing V2 percentage values are preserved as PERCENT rules.

alter table public.service_change_policies
  add column if not exists reschedule_first_early_penalty_type public.change_penalty_type,
  add column if not exists reschedule_first_early_penalty_value numeric(12,2),
  add column if not exists reschedule_first_late_penalty_type public.change_penalty_type,
  add column if not exists reschedule_first_late_penalty_value numeric(12,2),
  add column if not exists reschedule_repeat_penalty_type public.change_penalty_type,
  add column if not exists reschedule_repeat_penalty_value numeric(12,2),
  add column if not exists cancellation_late_penalty_type public.change_penalty_type,
  add column if not exists cancellation_late_penalty_value numeric(12,2);

update public.service_change_policies
set reschedule_first_early_penalty_type=coalesce(reschedule_first_early_penalty_type,'PERCENT'::public.change_penalty_type),
    reschedule_first_early_penalty_value=coalesce(reschedule_first_early_penalty_value,reschedule_first_early_percent),
    reschedule_first_late_penalty_type=coalesce(reschedule_first_late_penalty_type,'PERCENT'::public.change_penalty_type),
    reschedule_first_late_penalty_value=coalesce(reschedule_first_late_penalty_value,reschedule_first_late_percent),
    reschedule_repeat_penalty_type=coalesce(reschedule_repeat_penalty_type,'PERCENT'::public.change_penalty_type),
    reschedule_repeat_penalty_value=coalesce(reschedule_repeat_penalty_value,reschedule_repeat_percent),
    cancellation_late_penalty_type=coalesce(cancellation_late_penalty_type,'PERCENT'::public.change_penalty_type),
    cancellation_late_penalty_value=coalesce(cancellation_late_penalty_value,cancellation_late_percent);

alter table public.service_change_policies
  alter column reschedule_first_early_penalty_type set default 'PERCENT'::public.change_penalty_type,
  alter column reschedule_first_late_penalty_type set default 'PERCENT'::public.change_penalty_type,
  alter column reschedule_repeat_penalty_type set default 'PERCENT'::public.change_penalty_type,
  alter column cancellation_late_penalty_type set default 'PERCENT'::public.change_penalty_type,
  alter column reschedule_first_early_penalty_type set not null,
  alter column reschedule_first_early_penalty_value set not null,
  alter column reschedule_first_late_penalty_type set not null,
  alter column reschedule_first_late_penalty_value set not null,
  alter column reschedule_repeat_penalty_type set not null,
  alter column reschedule_repeat_penalty_value set not null,
  alter column cancellation_late_penalty_type set not null,
  alter column cancellation_late_penalty_value set not null;

alter table public.service_change_policies drop constraint if exists service_change_policies_typed_penalties_check;
alter table public.service_change_policies add constraint service_change_policies_typed_penalties_check check (
  reschedule_first_early_penalty_type in ('PERCENT','FIXED')
  and reschedule_first_late_penalty_type in ('PERCENT','FIXED')
  and reschedule_repeat_penalty_type in ('PERCENT','FIXED')
  and cancellation_late_penalty_type in ('PERCENT','FIXED')
  and reschedule_first_early_penalty_value >= 0
  and reschedule_first_late_penalty_value >= 0
  and reschedule_repeat_penalty_value >= 0
  and cancellation_late_penalty_value >= 0
  and (reschedule_first_early_penalty_type <> 'PERCENT' or reschedule_first_early_penalty_value <= 100)
  and (reschedule_first_late_penalty_type <> 'PERCENT' or reschedule_first_late_penalty_value <= 100)
  and (reschedule_repeat_penalty_type <> 'PERCENT' or reschedule_repeat_penalty_value <= 100)
  and (cancellation_late_penalty_type <> 'PERCENT' or cancellation_late_penalty_value <= 100)
);

create or replace function public.service_admin_upsert_change_policy(p_service_id uuid,p_policy jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_current public.service_change_policies%rowtype;
  v_exists boolean;
  v_notice integer;
  v_a_type text; v_a_value numeric(12,2);
  v_b_type text; v_b_value numeric(12,2);
  v_c_type text; v_c_value numeric(12,2);
  v_d_type text; v_d_value numeric(12,2);
  v_result public.service_change_policies%rowtype;
begin
  if not exists(select 1 from public.services where id=p_service_id) then raise exception using errcode='P0001',message='SERVICE_NOT_FOUND'; end if;
  if p_policy is null or jsonb_typeof(p_policy)<>'object' then raise exception using errcode='P0001',message='INVALID_CHANGE_POLICY'; end if;

  select * into v_current from public.service_change_policies where service_id=p_service_id for update;
  v_exists:=found;
  if not v_exists and not (
    p_policy ? 'notice_hours'
    and (
      p_policy ?& array[
        'reschedule_first_early_penalty_type','reschedule_first_early_penalty_value',
        'reschedule_first_late_penalty_type','reschedule_first_late_penalty_value',
        'reschedule_repeat_penalty_type','reschedule_repeat_penalty_value',
        'cancellation_late_penalty_type','cancellation_late_penalty_value'
      ]
      or p_policy ?& array[
        'reschedule_first_early_percent','reschedule_first_late_percent','reschedule_repeat_percent','cancellation_late_percent'
      ]
    )
  ) then
    raise exception using errcode='P0001',message='CHANGE_POLICY_COMPLETE_CONFIGURATION_REQUIRED';
  end if;

  v_notice:=case when p_policy?'notice_hours' then(p_policy->>'notice_hours')::integer else v_current.notice_hours end;

  if p_policy?'reschedule_first_early_penalty_type' or p_policy?'reschedule_first_early_penalty_value' then
    v_a_type:=upper(coalesce(p_policy->>'reschedule_first_early_penalty_type',v_current.reschedule_first_early_penalty_type::text));
    v_a_value:=coalesce((p_policy->>'reschedule_first_early_penalty_value')::numeric,v_current.reschedule_first_early_penalty_value);
  elsif p_policy?'reschedule_first_early_percent' then
    v_a_type:='PERCENT'; v_a_value:=(p_policy->>'reschedule_first_early_percent')::numeric;
  else v_a_type:=v_current.reschedule_first_early_penalty_type::text; v_a_value:=v_current.reschedule_first_early_penalty_value; end if;

  if p_policy?'reschedule_first_late_penalty_type' or p_policy?'reschedule_first_late_penalty_value' then
    v_b_type:=upper(coalesce(p_policy->>'reschedule_first_late_penalty_type',v_current.reschedule_first_late_penalty_type::text));
    v_b_value:=coalesce((p_policy->>'reschedule_first_late_penalty_value')::numeric,v_current.reschedule_first_late_penalty_value);
  elsif p_policy?'reschedule_first_late_percent' then
    v_b_type:='PERCENT'; v_b_value:=(p_policy->>'reschedule_first_late_percent')::numeric;
  else v_b_type:=v_current.reschedule_first_late_penalty_type::text; v_b_value:=v_current.reschedule_first_late_penalty_value; end if;

  if p_policy?'reschedule_repeat_penalty_type' or p_policy?'reschedule_repeat_penalty_value' then
    v_c_type:=upper(coalesce(p_policy->>'reschedule_repeat_penalty_type',v_current.reschedule_repeat_penalty_type::text));
    v_c_value:=coalesce((p_policy->>'reschedule_repeat_penalty_value')::numeric,v_current.reschedule_repeat_penalty_value);
  elsif p_policy?'reschedule_repeat_percent' then
    v_c_type:='PERCENT'; v_c_value:=(p_policy->>'reschedule_repeat_percent')::numeric;
  else v_c_type:=v_current.reschedule_repeat_penalty_type::text; v_c_value:=v_current.reschedule_repeat_penalty_value; end if;

  if p_policy?'cancellation_late_penalty_type' or p_policy?'cancellation_late_penalty_value' then
    v_d_type:=upper(coalesce(p_policy->>'cancellation_late_penalty_type',v_current.cancellation_late_penalty_type::text));
    v_d_value:=coalesce((p_policy->>'cancellation_late_penalty_value')::numeric,v_current.cancellation_late_penalty_value);
  elsif p_policy?'cancellation_late_percent' then
    v_d_type:='PERCENT'; v_d_value:=(p_policy->>'cancellation_late_percent')::numeric;
  else v_d_type:=v_current.cancellation_late_penalty_type::text; v_d_value:=v_current.cancellation_late_penalty_value; end if;

  if v_notice is null or v_notice<0
     or v_a_type not in ('PERCENT','FIXED') or v_a_value is null or v_a_value<0 or (v_a_type='PERCENT' and v_a_value>100)
     or v_b_type not in ('PERCENT','FIXED') or v_b_value is null or v_b_value<0 or (v_b_type='PERCENT' and v_b_value>100)
     or v_c_type not in ('PERCENT','FIXED') or v_c_value is null or v_c_value<0 or (v_c_type='PERCENT' and v_c_value>100)
     or v_d_type not in ('PERCENT','FIXED') or v_d_value is null or v_d_value<0 or (v_d_type='PERCENT' and v_d_value>100) then
    raise exception using errcode='P0001',message='INVALID_CHANGE_POLICY';
  end if;

  insert into public.service_change_policies(
    service_id,notice_hours,
    reschedule_first_early_percent,reschedule_first_late_percent,reschedule_repeat_percent,cancellation_late_percent,
    reschedule_first_early_penalty_type,reschedule_first_early_penalty_value,
    reschedule_first_late_penalty_type,reschedule_first_late_penalty_value,
    reschedule_repeat_penalty_type,reschedule_repeat_penalty_value,
    cancellation_late_penalty_type,cancellation_late_penalty_value
  ) values(
    p_service_id,v_notice,
    case when v_a_type='PERCENT' then v_a_value else 0 end,
    case when v_b_type='PERCENT' then v_b_value else 0 end,
    case when v_c_type='PERCENT' then v_c_value else 0 end,
    case when v_d_type='PERCENT' then v_d_value else 0 end,
    v_a_type::public.change_penalty_type,v_a_value,
    v_b_type::public.change_penalty_type,v_b_value,
    v_c_type::public.change_penalty_type,v_c_value,
    v_d_type::public.change_penalty_type,v_d_value
  ) on conflict(service_id) do update set
    notice_hours=excluded.notice_hours,
    reschedule_first_early_percent=excluded.reschedule_first_early_percent,
    reschedule_first_late_percent=excluded.reschedule_first_late_percent,
    reschedule_repeat_percent=excluded.reschedule_repeat_percent,
    cancellation_late_percent=excluded.cancellation_late_percent,
    reschedule_first_early_penalty_type=excluded.reschedule_first_early_penalty_type,
    reschedule_first_early_penalty_value=excluded.reschedule_first_early_penalty_value,
    reschedule_first_late_penalty_type=excluded.reschedule_first_late_penalty_type,
    reschedule_first_late_penalty_value=excluded.reschedule_first_late_penalty_value,
    reschedule_repeat_penalty_type=excluded.reschedule_repeat_penalty_type,
    reschedule_repeat_penalty_value=excluded.reschedule_repeat_penalty_value,
    cancellation_late_penalty_type=excluded.cancellation_late_penalty_type,
    cancellation_late_penalty_value=excluded.cancellation_late_penalty_value,
    updated_at=now()
  returning * into v_result;

  return jsonb_build_object(
    'notice_hours',v_result.notice_hours,
    'reschedule_first_early_penalty_type',v_result.reschedule_first_early_penalty_type,
    'reschedule_first_early_penalty_value',v_result.reschedule_first_early_penalty_value,
    'reschedule_first_late_penalty_type',v_result.reschedule_first_late_penalty_type,
    'reschedule_first_late_penalty_value',v_result.reschedule_first_late_penalty_value,
    'reschedule_repeat_penalty_type',v_result.reschedule_repeat_penalty_type,
    'reschedule_repeat_penalty_value',v_result.reschedule_repeat_penalty_value,
    'cancellation_late_penalty_type',v_result.cancellation_late_penalty_type,
    'cancellation_late_penalty_value',v_result.cancellation_late_penalty_value,
    'reschedule_first_early_percent',v_result.reschedule_first_early_percent,
    'reschedule_first_late_percent',v_result.reschedule_first_late_percent,
    'reschedule_repeat_percent',v_result.reschedule_repeat_percent,
    'cancellation_late_percent',v_result.cancellation_late_percent
  );
end;
$$;

create or replace function public.normalize_change_policy_snapshot(p_policy jsonb)
returns jsonb
language sql
stable
set search_path = public, pg_temp
as $$
  select case when p_policy is null then null else p_policy||jsonb_build_object(
    'max_customer_reschedules',coalesce((p_policy->>'max_customer_reschedules')::integer,3),
    'policy_timezone','America/Sao_Paulo',
    'notice_boundary_semantics','EXACT_LIMIT_IS_OUTSIDE_WINDOW',
    'snapshot_schema_version',case
      when nullif(p_policy->>'reschedule_first_early_penalty_type','') is not null
       and nullif(p_policy->>'reschedule_first_early_penalty_value','') is not null
       and nullif(p_policy->>'reschedule_first_late_penalty_type','') is not null
       and nullif(p_policy->>'reschedule_first_late_penalty_value','') is not null
       and nullif(p_policy->>'reschedule_repeat_penalty_type','') is not null
       and nullif(p_policy->>'reschedule_repeat_penalty_value','') is not null
       and nullif(p_policy->>'cancellation_late_penalty_type','') is not null
       and nullif(p_policy->>'cancellation_late_penalty_value','') is not null
        then 'CONSOLIDATED_POLICY_V3'
      when nullif(p_policy->>'reschedule_first_early_percent','') is not null
       and nullif(p_policy->>'reschedule_first_late_percent','') is not null
       and nullif(p_policy->>'reschedule_repeat_percent','') is not null
       and nullif(p_policy->>'cancellation_late_percent','') is not null
        then 'CONSOLIDATED_POLICY_V2'
      else 'CHANGE_POLICY_SNAPSHOT_V1'
    end
  ) end;
$$;

create or replace function public.canonical_change_policy_snapshot_contract(p_policy jsonb)
returns jsonb
language plpgsql
stable
set search_path = public, pg_temp
as $$
declare
  v_policy jsonb;
  v_schema text;
  v_notice numeric;
  v_a_type text; v_a_value numeric;
  v_b_type text; v_b_value numeric;
  v_c_type text; v_c_value numeric;
  v_d_type text; v_d_value numeric;
  v_max integer;
  v_status text:='CANONICAL';
begin
  if p_policy is null or jsonb_typeof(p_policy)<>'object' then
    return jsonb_build_object('contract_schema_version','CHANGE_POLICY_CONTRACT_V3','source_schema_version',null,'normalization_status','INVALID_SOURCE');
  end if;
  v_policy:=public.normalize_change_policy_snapshot(p_policy);
  v_schema:=v_policy->>'snapshot_schema_version';
  v_notice:=nullif(v_policy->>'notice_hours','')::numeric;
  v_max:=coalesce(nullif(v_policy->>'max_customer_reschedules','')::integer,3);

  if v_schema='CONSOLIDATED_POLICY_V3' then
    v_a_type:=v_policy->>'reschedule_first_early_penalty_type'; v_a_value:=nullif(v_policy->>'reschedule_first_early_penalty_value','')::numeric;
    v_b_type:=v_policy->>'reschedule_first_late_penalty_type'; v_b_value:=nullif(v_policy->>'reschedule_first_late_penalty_value','')::numeric;
    v_c_type:=v_policy->>'reschedule_repeat_penalty_type'; v_c_value:=nullif(v_policy->>'reschedule_repeat_penalty_value','')::numeric;
    v_d_type:=v_policy->>'cancellation_late_penalty_type'; v_d_value:=nullif(v_policy->>'cancellation_late_penalty_value','')::numeric;
  elsif v_schema='CONSOLIDATED_POLICY_V2' then
    v_a_type:='PERCENT'; v_a_value:=nullif(v_policy->>'reschedule_first_early_percent','')::numeric;
    v_b_type:='PERCENT'; v_b_value:=nullif(v_policy->>'reschedule_first_late_percent','')::numeric;
    v_c_type:='PERCENT'; v_c_value:=nullif(v_policy->>'reschedule_repeat_percent','')::numeric;
    v_d_type:='PERCENT'; v_d_value:=nullif(v_policy->>'cancellation_late_percent','')::numeric;
  else
    v_a_type:=coalesce(v_policy->>'reschedule_first_penalty_type','NONE'); v_a_value:=coalesce(nullif(v_policy->>'reschedule_first_penalty_value','')::numeric,0);
    v_b_type:=coalesce(v_policy->>'reschedule_late_penalty_type','NONE'); v_b_value:=coalesce(nullif(v_policy->>'reschedule_late_penalty_value','')::numeric,0);
    v_c_type:=coalesce(v_policy->>'reschedule_repeat_penalty_type','NONE'); v_c_value:=coalesce(nullif(v_policy->>'reschedule_repeat_penalty_value','')::numeric,0);
    v_d_type:=coalesce(v_policy->>'cancellation_late_penalty_type','NONE'); v_d_value:=coalesce(nullif(v_policy->>'cancellation_late_penalty_value','')::numeric,0);
  end if;

  if v_notice is null or v_a_type not in ('NONE','PERCENT','FIXED') or v_b_type not in ('NONE','PERCENT','FIXED')
     or v_c_type not in ('NONE','PERCENT','FIXED') or v_d_type not in ('NONE','PERCENT','FIXED')
     or v_a_value is null or v_b_value is null or v_c_value is null or v_d_value is null then
    v_status:='UNSUPPORTED_LEGACY_SHAPE';
  end if;

  return jsonb_build_object(
    'contract_schema_version','CHANGE_POLICY_CONTRACT_V3','source_schema_version',v_schema,'normalization_status',v_status,
    'notice_hours',v_notice,
    'reschedule_first_early_penalty_type',v_a_type,'reschedule_first_early_penalty_value',v_a_value,
    'reschedule_first_late_penalty_type',v_b_type,'reschedule_first_late_penalty_value',v_b_value,
    'reschedule_repeat_penalty_type',v_c_type,'reschedule_repeat_penalty_value',v_c_value,
    'cancellation_late_penalty_type',v_d_type,'cancellation_late_penalty_value',v_d_value,
    'reschedule_first_early_percent',case when v_a_type='PERCENT' then v_a_value else null end,
    'reschedule_first_late_percent',case when v_b_type='PERCENT' then v_b_value else null end,
    'reschedule_repeat_percent',case when v_c_type='PERCENT' then v_c_value else null end,
    'cancellation_late_percent',case when v_d_type='PERCENT' then v_d_value else null end,
    'max_customer_reschedules',v_max,
    'policy_timezone',coalesce(nullif(v_policy->>'policy_timezone',''),'America/Sao_Paulo'),
    'notice_boundary_semantics',coalesce(nullif(v_policy->>'notice_boundary_semantics',''),'EXACT_LIMIT_IS_OUTSIDE_WINDOW')
  );
end;
$$;

create or replace function public.calculate_reservation_change(
  p_appointment_id uuid,
  p_action_type text,
  p_requested_at timestamptz,
  p_change_origin text,
  p_new_contract_value numeric
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
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
  v_commitment_type text;
  v_commitment_value numeric(12,2);
  v_commitment_percent numeric(7,2);
  v_target numeric(12,2);
  v_percent numeric(7,2):=0;
  v_penalty_type public.change_penalty_type:='NONE';
  v_penalty_value numeric(12,2):=0;
  v_theoretical numeric(12,2):=0;
  v_retained numeric(12,2):=0;
  v_after numeric(12,2):=0;
  v_applicable numeric(12,2):=0;
  v_excess_after numeric(12,2):=0;
  v_difference numeric(12,2):=0;
  v_refund numeric(12,2):=0;
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
    v_commitment_type:='PERCENT'; v_commitment_value:=0;
  elsif v_contract<=0 or v_contract_coverage>=v_contract then
    v_commitment_type:='PERCENT'; v_commitment_value:=100;
  else
    v_commitment_type:=coalesce(v_appointment.checkout_minimum_payment_type_snapshot,'PERCENT');
    v_commitment_value:=coalesce(v_appointment.checkout_minimum_payment_value_snapshot,v_appointment.confirmation_percentage_snapshot);
    if v_commitment_value is null then raise exception using errcode='P0001',message='APPOINTMENT_CONFIRMATION_SNAPSHOT_MISSING'; end if;
  end if;

  if p_change_origin='OPERATION' and v_admin_waiver then
    v_penalty_type:='NONE'; v_penalty_value:=0;
  elsif v_schema='CONSOLIDATED_POLICY_V3' then
    if p_action_type='RESCHEDULE' then
      if v_count>0 then
        v_penalty_type:=(v_policy->>'reschedule_repeat_penalty_type')::public.change_penalty_type;
        v_penalty_value:=(v_policy->>'reschedule_repeat_penalty_value')::numeric;
      elsif v_inside then
        v_penalty_type:=(v_policy->>'reschedule_first_late_penalty_type')::public.change_penalty_type;
        v_penalty_value:=(v_policy->>'reschedule_first_late_penalty_value')::numeric;
      else
        v_penalty_type:=(v_policy->>'reschedule_first_early_penalty_type')::public.change_penalty_type;
        v_penalty_value:=(v_policy->>'reschedule_first_early_penalty_value')::numeric;
      end if;
    elsif v_inside then
      v_penalty_type:=(v_policy->>'cancellation_late_penalty_type')::public.change_penalty_type;
      v_penalty_value:=(v_policy->>'cancellation_late_penalty_value')::numeric;
    else
      v_penalty_type:='NONE'; v_penalty_value:=0;
    end if;
  elsif v_schema='CONSOLIDATED_POLICY_V2' then
    v_penalty_type:='PERCENT';
    if p_action_type='RESCHEDULE' then
      if v_count>0 then v_penalty_value:=(v_policy->>'reschedule_repeat_percent')::numeric;
      elsif v_inside then v_penalty_value:=(v_policy->>'reschedule_first_late_percent')::numeric;
      else v_penalty_value:=(v_policy->>'reschedule_first_early_percent')::numeric;
      end if;
    else
      v_penalty_value:=case when v_inside then (v_policy->>'cancellation_late_percent')::numeric else 0 end;
    end if;
  else
    if p_action_type='RESCHEDULE' then
      if v_count>0 then
        v_penalty_type:=(v_policy->>'reschedule_repeat_penalty_type')::public.change_penalty_type;
        v_penalty_value:=(v_policy->>'reschedule_repeat_penalty_value')::numeric;
      elsif v_inside then
        v_penalty_type:=(v_policy->>'reschedule_late_penalty_type')::public.change_penalty_type;
        v_penalty_value:=(v_policy->>'reschedule_late_penalty_value')::numeric;
      else
        v_penalty_type:=(v_policy->>'reschedule_first_penalty_type')::public.change_penalty_type;
        v_penalty_value:=(v_policy->>'reschedule_first_penalty_value')::numeric;
      end if;
    else
      if v_inside then
        v_penalty_type:=(v_policy->>'cancellation_late_penalty_type')::public.change_penalty_type;
        v_penalty_value:=(v_policy->>'cancellation_late_penalty_value')::numeric;
      else
        v_penalty_type:=(v_policy->>'cancellation_early_penalty_type')::public.change_penalty_type;
        v_penalty_value:=(v_policy->>'cancellation_early_penalty_value')::numeric;
      end if;
    end if;
  end if;

  if v_penalty_type='PERCENT' then
    v_percent:=v_penalty_value;
    v_theoretical:=round(v_contract*v_penalty_value/100,2);
  elsif v_penalty_type='FIXED' then
    v_percent:=0;
    v_theoretical:=round(v_penalty_value,2);
  else
    v_percent:=0; v_theoretical:=0;
  end if;

  v_retained:=case when p_change_origin='OPERATION' and v_admin_waiver then 0 else round(least(v_theoretical,v_applied),2) end;
  v_after:=round(greatest(v_funds-v_retained,0),2);
  v_contract_coverage_after:=round(greatest(v_contract_coverage-v_retained,0),2);

  if p_action_type='RESCHEDULE' then
    v_target:=public.service_checkout_minimum_target(p_new_contract_value,v_commitment_type,v_commitment_value);
    v_commitment_percent:=case
      when v_commitment_type='PERCENT' then v_commitment_value
      when p_new_contract_value>0 then round(v_target*100/p_new_contract_value,2)
      else 100 end;
    v_applicable:=round(least(v_after,p_new_contract_value),2);
    v_excess_after:=round(greatest(v_after-p_new_contract_value,0),2);
    v_difference:=round(greatest(v_target-v_contract_coverage_after,0),2);
  else
    v_target:=0;
    v_commitment_percent:=case when v_commitment_type='PERCENT' then v_commitment_value else v_appointment.confirmation_percentage_snapshot end;
    v_applicable:=round(greatest(v_applied-v_retained,0),2);
    v_excess_after:=v_excess_before;
    v_refund:=round(v_applicable+v_excess_before,2);
  end if;

  return jsonb_build_object(
    'appointment_id',p_appointment_id,'service_id',v_appointment.service_id,'action_type',p_action_type,'change_origin',p_change_origin,
    'requested_at',p_requested_at,'original_start_at',v_appointment.start_at,'hours_before_start',v_hours,'notice_hours',v_notice,
    'inside_notice_window',v_inside,'prior_customer_reschedules',v_count,'max_customer_reschedules',v_snapshot.max_customer_reschedules,
    'contract_value',v_contract,'new_contract_value',p_new_contract_value,'customer_funds_before',v_funds,'contract_applied_before',v_applied,
    'excess_before',v_excess_before,'contract_coverage_before',v_contract_coverage,
    'payment_commitment_type',v_commitment_type,'payment_commitment_value',v_commitment_value,'payment_commitment_percent',v_commitment_percent,
    'confirmation_target_amount',v_target,
    'penalty_type',v_penalty_type,'penalty_value',v_penalty_value,'penalty_percent',v_percent,'theoretical_penalty',v_theoretical,
    'penalty_retained',v_retained,'penalty_amount',v_retained,
    'penalty_waived',(p_change_origin='OPERATION' and v_admin_waiver),'customer_funds_after_penalty',v_after,
    'contract_coverage_after_penalty',v_contract_coverage_after,'applicable_amount',v_applicable,'excess_amount',v_excess_after,
    'difference_due',v_difference,'refund_due',v_refund,'refundable_amount',v_refund,
    'customer_reschedule_limit_reached',(p_action_type='RESCHEDULE' and p_change_origin='CLIENT' and v_count>=v_snapshot.max_customer_reschedules),
    'snapshot_schema_version',v_schema
  );
end;
$$;

create or replace function public.apply_typed_change_penalty_metadata()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_policy jsonb;
  v_schema text;
  v_type public.change_penalty_type;
  v_value numeric(12,2);
begin
  select policy_json into v_policy from public.appointment_change_policy_snapshots where appointment_id=new.appointment_id;
  if v_policy is null then return new; end if;
  v_schema:=coalesce(v_policy->>'snapshot_schema_version','CHANGE_POLICY_SNAPSHOT_V1');
  if v_schema<>'CONSOLIDATED_POLICY_V3' then return new; end if;

  if new.action_type='RESCHEDULE' then
    if coalesce(new.prior_customer_reschedules,0)>0 then
      v_type:=(v_policy->>'reschedule_repeat_penalty_type')::public.change_penalty_type;
      v_value:=(v_policy->>'reschedule_repeat_penalty_value')::numeric;
    elsif coalesce(new.is_inside_notice_window,false) then
      v_type:=(v_policy->>'reschedule_first_late_penalty_type')::public.change_penalty_type;
      v_value:=(v_policy->>'reschedule_first_late_penalty_value')::numeric;
    else
      v_type:=(v_policy->>'reschedule_first_early_penalty_type')::public.change_penalty_type;
      v_value:=(v_policy->>'reschedule_first_early_penalty_value')::numeric;
    end if;
  elsif new.action_type='CANCEL' and coalesce(new.is_inside_notice_window,false) then
    v_type:=(v_policy->>'cancellation_late_penalty_type')::public.change_penalty_type;
    v_value:=(v_policy->>'cancellation_late_penalty_value')::numeric;
  else
    v_type:='NONE'; v_value:=0;
  end if;

  new.penalty_type:=v_type;
  new.penalty_value:=v_value;
  new.policy_schema_version:=coalesce(new.policy_schema_version,v_schema);
  return new;
end;
$$;

drop trigger if exists appointment_policy_actions_typed_penalty_metadata on public.appointment_policy_actions;
create trigger appointment_policy_actions_typed_penalty_metadata
before insert or update of appointment_id,action_type,is_inside_notice_window,prior_customer_reschedules
on public.appointment_policy_actions
for each row execute function public.apply_typed_change_penalty_metadata();