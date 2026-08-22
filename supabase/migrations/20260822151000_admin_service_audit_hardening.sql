-- Retrospective audit hardening for administrative service mutations.
-- New audited wrappers are the only service-role mutation surface. Historical
-- functions remain in the schema for migration compatibility but are no longer
-- executable by service_role directly.

create or replace function public.service_admin_service_snapshot(p_service_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'service', to_jsonb(s),
    'pricing_tiers', coalesce((
      select jsonb_agg(to_jsonb(t) order by t.sort_order, t.min_blocks, t.id)
      from public.service_duration_pricing_tiers t
      where t.service_id = s.id
    ), '[]'::jsonb),
    'duration_presets', coalesce((
      select jsonb_agg(to_jsonb(p) order by p.sort_order, p.block_count, p.id)
      from public.service_duration_presets p
      where p.service_id = s.id
    ), '[]'::jsonb),
    'change_policy', (
      select to_jsonb(cp)
      from public.service_change_policies cp
      where cp.service_id = s.id
    )
  )
  from public.services s
  where s.id = p_service_id;
$$;

create or replace function public.service_admin_update_timing_audited(
  p_service_id uuid,
  p_duration_mode text,
  p_base_duration_minutes integer,
  p_booking_block_minutes integer,
  p_minimum_booking_blocks integer,
  p_maximum_booking_blocks integer,
  p_base_price numeric,
  p_price_per_block numeric,
  p_buffer_before_minutes integer,
  p_buffer_after_minutes integer,
  p_admin_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_before jsonb;
  v_after jsonb;
  v_result jsonb;
  v_old_base numeric;
  v_old_block numeric;
begin
  if not public.service_admin_has_permission(p_admin_id, 'SERVICES_MANAGE') then
    raise exception using errcode = 'P0001', message = 'ADMIN_PERMISSION_DENIED';
  end if;

  select base_price, price_per_block into v_old_base, v_old_block
  from public.services where id = p_service_id for update;
  if not found then
    raise exception using errcode = 'P0001', message = 'SERVICE_NOT_FOUND';
  end if;

  if v_old_base is distinct from p_base_price
     or v_old_block is distinct from (case when p_duration_mode = 'BLOCKS' then p_price_per_block else null end) then
    if not public.service_admin_has_permission(p_admin_id, 'FINANCE_MANAGE') then
      raise exception using errcode = 'P0001', message = 'ADMIN_PERMISSION_DENIED';
    end if;
  end if;

  v_before := public.service_admin_service_snapshot(p_service_id);
  v_result := public.service_admin_update_timing(
    p_service_id, p_duration_mode, p_base_duration_minutes,
    p_booking_block_minutes, p_minimum_booking_blocks, p_maximum_booking_blocks,
    p_base_price, p_price_per_block, p_buffer_before_minutes, p_buffer_after_minutes
  );
  v_after := public.service_admin_service_snapshot(p_service_id);

  if v_before is distinct from v_after then
    insert into public.audit_logs(admin_user_id, entity_type, entity_id, action, before_json, after_json, origin)
    values (p_admin_id, 'SERVICE', p_service_id, 'SERVICE_TIMING_UPDATED', v_before, v_after, 'ADMIN');
  end if;
  return v_result;
end;
$$;

create or replace function public.service_admin_replace_duration_configuration_audited(
  p_service_id uuid,
  p_pricing_tiers jsonb,
  p_duration_presets jsonb,
  p_admin_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_before jsonb;
  v_after jsonb;
  v_result jsonb;
begin
  if not public.service_admin_has_permission(p_admin_id, 'SERVICES_MANAGE')
     or not public.service_admin_has_permission(p_admin_id, 'FINANCE_MANAGE') then
    raise exception using errcode = 'P0001', message = 'ADMIN_PERMISSION_DENIED';
  end if;

  v_before := public.service_admin_service_snapshot(p_service_id);
  if v_before is null then
    raise exception using errcode = 'P0001', message = 'SERVICE_NOT_FOUND';
  end if;

  v_result := public.service_admin_replace_duration_configuration(
    p_service_id, p_pricing_tiers, p_duration_presets
  );
  v_after := public.service_admin_service_snapshot(p_service_id);

  if v_before is distinct from v_after then
    insert into public.audit_logs(admin_user_id, entity_type, entity_id, action, before_json, after_json, origin)
    values (p_admin_id, 'SERVICE', p_service_id, 'SERVICE_DURATION_CONFIGURATION_UPDATED', v_before, v_after, 'ADMIN');
  end if;
  return v_result;
end;
$$;

create or replace function public.service_admin_upsert_change_policy_audited(
  p_service_id uuid,
  p_policy jsonb,
  p_admin_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_before jsonb;
  v_after jsonb;
  v_result jsonb;
  v_exists boolean;
  v_required_keys text[] := array[
    'notice_hours',
    'reschedule_first_penalty_type','reschedule_first_penalty_value',
    'reschedule_repeat_penalty_type','reschedule_repeat_penalty_value',
    'reschedule_late_penalty_type','reschedule_late_penalty_value',
    'cancellation_early_penalty_type','cancellation_early_penalty_value',
    'cancellation_late_penalty_type','cancellation_late_penalty_value',
    'cancellation_early_refund_allowed','cancellation_early_credit_allowed',
    'cancellation_late_refund_allowed','cancellation_late_credit_allowed',
    'cancellation_credit_validity_days'
  ];
begin
  if not public.service_admin_has_permission(p_admin_id, 'SERVICES_MANAGE')
     or not public.service_admin_has_permission(p_admin_id, 'FINANCE_MANAGE') then
    raise exception using errcode = 'P0001', message = 'ADMIN_PERMISSION_DENIED';
  end if;
  if p_policy is null or jsonb_typeof(p_policy) <> 'object' then
    raise exception using errcode = 'P0001', message = 'INVALID_CHANGE_POLICY';
  end if;

  select exists(select 1 from public.service_change_policies where service_id = p_service_id)
    into v_exists;
  if not v_exists and not (p_policy ?& v_required_keys) then
    raise exception using errcode = 'P0001', message = 'CHANGE_POLICY_COMPLETE_CONFIGURATION_REQUIRED';
  end if;

  v_before := public.service_admin_service_snapshot(p_service_id);
  if v_before is null then
    raise exception using errcode = 'P0001', message = 'SERVICE_NOT_FOUND';
  end if;

  v_result := public.service_admin_upsert_change_policy(p_service_id, p_policy);
  v_after := public.service_admin_service_snapshot(p_service_id);

  if v_before is distinct from v_after then
    insert into public.audit_logs(admin_user_id, entity_type, entity_id, action, before_json, after_json, origin)
    values (p_admin_id, 'SERVICE', p_service_id, 'SERVICE_CHANGE_POLICY_UPDATED', v_before, v_after, 'ADMIN');
  end if;
  return v_result;
end;
$$;

revoke all on function public.service_admin_service_snapshot(uuid) from public, anon, authenticated;
revoke all on function public.service_admin_update_timing_audited(uuid,text,integer,integer,integer,integer,numeric,numeric,integer,integer,uuid) from public, anon, authenticated;
revoke all on function public.service_admin_replace_duration_configuration_audited(uuid,jsonb,jsonb,uuid) from public, anon, authenticated;
revoke all on function public.service_admin_upsert_change_policy_audited(uuid,jsonb,uuid) from public, anon, authenticated;

grant execute on function public.service_admin_service_snapshot(uuid) to service_role;
grant execute on function public.service_admin_update_timing_audited(uuid,text,integer,integer,integer,integer,numeric,numeric,integer,integer,uuid) to service_role;
grant execute on function public.service_admin_replace_duration_configuration_audited(uuid,jsonb,jsonb,uuid) to service_role;
grant execute on function public.service_admin_upsert_change_policy_audited(uuid,jsonb,uuid) to service_role;

-- Do not leave an unaudited service-role bypass available to Edge Functions.
revoke execute on function public.service_admin_update_timing(uuid,text,integer,integer,integer,integer,numeric,numeric,integer,integer) from service_role;
revoke execute on function public.service_admin_replace_duration_configuration(uuid,jsonb,jsonb) from service_role;
revoke execute on function public.service_admin_upsert_change_policy(uuid,jsonb) from service_role;
