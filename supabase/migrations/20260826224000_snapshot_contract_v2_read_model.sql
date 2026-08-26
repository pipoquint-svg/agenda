-- V1.5 freeze gate — canonical read contract for immutable policy snapshots.
-- Historical snapshot rows and their policy_json are never rewritten. Consumers can
-- migrate to this read model while old V1 evidence remains byte-for-byte intact.

create or replace function public.canonical_change_policy_snapshot_contract(p_policy jsonb)
returns jsonb
language plpgsql
immutable
set search_path = public, pg_temp
as $$
declare
  v_source_schema text;
  v_notice_hours numeric;
  v_first_early numeric;
  v_first_late numeric;
  v_repeat numeric;
  v_cancel_late numeric;
  v_max_reschedules integer;
  v_status text;
begin
  if p_policy is null or jsonb_typeof(p_policy) <> 'object' then
    return jsonb_build_object(
      'contract_schema_version', 'CHANGE_POLICY_CONTRACT_V2',
      'source_schema_version', null,
      'normalization_status', 'INVALID_SOURCE'
    );
  end if;

  v_source_schema := coalesce(nullif(p_policy->>'snapshot_schema_version',''), 'CHANGE_POLICY_SNAPSHOT_V1');
  v_notice_hours := nullif(p_policy->>'notice_hours','')::numeric;

  -- V2 values win. V1 percentage/none mirrors are normalized only when their
  -- semantics are lossless. FIXED legacy penalties deliberately remain unsupported.
  v_first_early := case
    when nullif(p_policy->>'reschedule_first_early_percent','') is not null
      then (p_policy->>'reschedule_first_early_percent')::numeric
    when p_policy->>'reschedule_first_penalty_type' = 'NONE' then 0
    when p_policy->>'reschedule_first_penalty_type' = 'PERCENT'
      then nullif(p_policy->>'reschedule_first_penalty_value','')::numeric
    else null
  end;

  v_first_late := case
    when nullif(p_policy->>'reschedule_first_late_percent','') is not null
      then (p_policy->>'reschedule_first_late_percent')::numeric
    when p_policy->>'reschedule_late_penalty_type' = 'NONE' then 0
    when p_policy->>'reschedule_late_penalty_type' = 'PERCENT'
      then nullif(p_policy->>'reschedule_late_penalty_value','')::numeric
    else null
  end;

  v_repeat := case
    when nullif(p_policy->>'reschedule_repeat_percent','') is not null
      then (p_policy->>'reschedule_repeat_percent')::numeric
    when p_policy->>'reschedule_repeat_penalty_type' = 'NONE' then 0
    when p_policy->>'reschedule_repeat_penalty_type' = 'PERCENT'
      then nullif(p_policy->>'reschedule_repeat_penalty_value','')::numeric
    else null
  end;

  v_cancel_late := case
    when nullif(p_policy->>'cancellation_late_percent','') is not null
      then (p_policy->>'cancellation_late_percent')::numeric
    when p_policy->>'cancellation_late_penalty_type' = 'NONE' then 0
    when p_policy->>'cancellation_late_penalty_type' = 'PERCENT'
      then nullif(p_policy->>'cancellation_late_penalty_value','')::numeric
    else null
  end;

  v_max_reschedules := coalesce(nullif(p_policy->>'max_customer_reschedules','')::integer, 3);

  v_status := case
    when v_notice_hours is null
      or v_first_early is null
      or v_first_late is null
      or v_repeat is null
      or v_cancel_late is null
      then 'UNSUPPORTED_LEGACY_SHAPE'
    else 'CANONICAL'
  end;

  return jsonb_build_object(
    'contract_schema_version', 'CHANGE_POLICY_CONTRACT_V2',
    'source_schema_version', v_source_schema,
    'normalization_status', v_status,
    'notice_hours', v_notice_hours,
    'reschedule_first_early_percent', v_first_early,
    'reschedule_first_late_percent', v_first_late,
    'reschedule_repeat_percent', v_repeat,
    'cancellation_late_percent', v_cancel_late,
    'max_customer_reschedules', v_max_reschedules,
    'policy_timezone', coalesce(nullif(p_policy->>'policy_timezone',''), 'America/Sao_Paulo'),
    'notice_boundary_semantics', coalesce(
      nullif(p_policy->>'notice_boundary_semantics',''),
      'EXACT_LIMIT_IS_OUTSIDE_WINDOW'
    )
  );
end;
$$;

revoke all on function public.canonical_change_policy_snapshot_contract(jsonb) from public, anon, authenticated;
grant execute on function public.canonical_change_policy_snapshot_contract(jsonb) to service_role;

create or replace view public.appointment_change_policy_snapshot_contract_v2
with (security_invoker = true)
as
select
  s.appointment_id,
  s.service_id,
  s.effective_at,
  s.source,
  s.captured_at,
  s.policy_json->>'snapshot_schema_version' as source_schema_version,
  public.canonical_change_policy_snapshot_contract(s.policy_json) as canonical_policy
from public.appointment_change_policy_snapshots s;

revoke all on table public.appointment_change_policy_snapshot_contract_v2 from public, anon, authenticated;
grant select on table public.appointment_change_policy_snapshot_contract_v2 to service_role;

comment on function public.canonical_change_policy_snapshot_contract(jsonb) is
  'Read-only compatibility adapter for immutable V1/V2 policy snapshots. Never mutates historical evidence; lossy legacy FIXED shapes are marked unsupported.';
comment on view public.appointment_change_policy_snapshot_contract_v2 is
  'Canonical V2 read contract over immutable appointment policy snapshots. Raw historical policy_json remains authoritative evidence in the source table.';
