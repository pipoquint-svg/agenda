-- Compatibility hardening for per-service checkout minimums and typed V3 penalties.
--
-- Goals:
-- 1. Legacy callers that still write services.confirmation_percentage keep producing
--    the same effective PERCENT checkout rule unless they explicitly update the
--    new typed pair in the same statement.
-- 2. V3 policy writes keep rejecting obsolete V1/credit knobs while allowing the
--    new typed fields.
-- 3. Ambiguous legacy FIXED policy snapshots remain fail-closed. Only explicit
--    CONSOLIDATED_POLICY_V3 fixed fields are canonical fixed penalties.

create or replace function public.service_checkout_minimum_legacy_confirmation_bridge()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'INSERT' then
    -- checkout_minimum_payment_* were added with PERCENT/50 defaults. When an old
    -- insert explicitly supplies confirmation_percentage but leaves the new pair
    -- at those defaults, preserve the old caller's intended percentage.
    if new.confirmation_percentage is not null
       and coalesce(new.checkout_minimum_payment_type, 'PERCENT') = 'PERCENT'
       and coalesce(new.checkout_minimum_payment_value, 50) = 50 then
      new.checkout_minimum_payment_type := 'PERCENT';
      new.checkout_minimum_payment_value := new.confirmation_percentage;
    end if;
    return new;
  end if;

  -- Legacy UPDATE: synchronize only when the typed pair itself was not changed.
  -- New V3 writers that update the typed pair in the same statement always win.
  if new.confirmation_percentage is distinct from old.confirmation_percentage
     and new.confirmation_percentage is not null
     and new.checkout_minimum_payment_type is not distinct from old.checkout_minimum_payment_type
     and new.checkout_minimum_payment_value is not distinct from old.checkout_minimum_payment_value then
    new.checkout_minimum_payment_type := 'PERCENT';
    new.checkout_minimum_payment_value := new.confirmation_percentage;
  end if;

  return new;
end;
$$;

revoke all on function public.service_checkout_minimum_legacy_confirmation_bridge() from public;

drop trigger if exists services_checkout_minimum_legacy_confirmation_bridge on public.services;
create trigger services_checkout_minimum_legacy_confirmation_bridge
before insert or update of confirmation_percentage, checkout_minimum_payment_type, checkout_minimum_payment_value
on public.services
for each row execute function public.service_checkout_minimum_legacy_confirmation_bridge();

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
  if not exists(select 1 from public.services where id=p_service_id) then
    raise exception using errcode='P0001',message='SERVICE_NOT_FOUND';
  end if;
  if p_policy is null or jsonb_typeof(p_policy)<>'object' then
    raise exception using errcode='P0001',message='INVALID_CHANGE_POLICY';
  end if;

  -- These are obsolete/ambiguous V1 or automatic-credit controls. The V3 fields
  -- reschedule_repeat_penalty_* and cancellation_late_penalty_* are intentionally
  -- NOT rejected because they are valid typed V3 fields.
  if p_policy ?| array[
    'reschedule_first_penalty_type','reschedule_first_penalty_value',
    'reschedule_late_penalty_type','reschedule_late_penalty_value',
    'cancellation_early_penalty_type','cancellation_early_penalty_value',
    'cancellation_early_refund_allowed','cancellation_early_credit_allowed',
    'cancellation_late_refund_allowed','cancellation_late_credit_allowed',
    'cancellation_credit_validity_days'
  ] then
    raise exception using errcode='P0001',message='LEGACY_CHANGE_POLICY_FIELDS_NOT_ACCEPTED';
  end if;

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

  begin
    v_notice:=case when p_policy?'notice_hours' then(p_policy->>'notice_hours')::integer else v_current.notice_hours end;

    if p_policy?'reschedule_first_early_penalty_type' or p_policy?'reschedule_first_early_penalty_value' then
      v_a_type:=upper(coalesce(p_policy->>'reschedule_first_early_penalty_type',v_current.reschedule_first_early_penalty_type::text));
      v_a_value:=coalesce((p_policy->>'reschedule_first_early_penalty_value')::numeric,v_current.reschedule_first_early_penalty_value);
    elsif p_policy?'reschedule_first_early_percent' then
      v_a_type:='PERCENT'; v_a_value:=(p_policy->>'reschedule_first_early_percent')::numeric;
    else
      v_a_type:=v_current.reschedule_first_early_penalty_type::text; v_a_value:=v_current.reschedule_first_early_penalty_value;
    end if;

    if p_policy?'reschedule_first_late_penalty_type' or p_policy?'reschedule_first_late_penalty_value' then
      v_b_type:=upper(coalesce(p_policy->>'reschedule_first_late_penalty_type',v_current.reschedule_first_late_penalty_type::text));
      v_b_value:=coalesce((p_policy->>'reschedule_first_late_penalty_value')::numeric,v_current.reschedule_first_late_penalty_value);
    elsif p_policy?'reschedule_first_late_percent' then
      v_b_type:='PERCENT'; v_b_value:=(p_policy->>'reschedule_first_late_percent')::numeric;
    else
      v_b_type:=v_current.reschedule_first_late_penalty_type::text; v_b_value:=v_current.reschedule_first_late_penalty_value;
    end if;

    if p_policy?'reschedule_repeat_penalty_type' or p_policy?'reschedule_repeat_penalty_value' then
      v_c_type:=upper(coalesce(p_policy->>'reschedule_repeat_penalty_type',v_current.reschedule_repeat_penalty_type::text));
      v_c_value:=coalesce((p_policy->>'reschedule_repeat_penalty_value')::numeric,v_current.reschedule_repeat_penalty_value);
    elsif p_policy?'reschedule_repeat_percent' then
      v_c_type:='PERCENT'; v_c_value:=(p_policy->>'reschedule_repeat_percent')::numeric;
    else
      v_c_type:=v_current.reschedule_repeat_penalty_type::text; v_c_value:=v_current.reschedule_repeat_penalty_value;
    end if;

    if p_policy?'cancellation_late_penalty_type' or p_policy?'cancellation_late_penalty_value' then
      v_d_type:=upper(coalesce(p_policy->>'cancellation_late_penalty_type',v_current.cancellation_late_penalty_type::text));
      v_d_value:=coalesce((p_policy->>'cancellation_late_penalty_value')::numeric,v_current.cancellation_late_penalty_value);
    elsif p_policy?'cancellation_late_percent' then
      v_d_type:='PERCENT'; v_d_value:=(p_policy->>'cancellation_late_percent')::numeric;
    else
      v_d_type:=v_current.cancellation_late_penalty_type::text; v_d_value:=v_current.cancellation_late_penalty_value;
    end if;
  exception
    when invalid_text_representation or numeric_value_out_of_range then
      raise exception using errcode='P0001',message='INVALID_CHANGE_POLICY';
  end;

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

    -- Legacy snapshots predate the V3 early/late typed contract. A fixed amount
    -- in that shape is ambiguous/lossy, so keep the historical fail-closed rule.
    if v_a_type='FIXED' or v_b_type='FIXED' or v_c_type='FIXED' or v_d_type='FIXED' then
      v_status:='UNSUPPORTED_LEGACY_SHAPE';
    end if;
  end if;

  if v_notice is null
     or v_a_type not in ('NONE','PERCENT','FIXED') or v_b_type not in ('NONE','PERCENT','FIXED')
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
