-- Administrative contract for consolidated change-policy V2.
-- Creation requires the complete V2 contract. Updates may patch existing V2
-- values, but omission only preserves an already-persisted value; it never
-- invents a percentage, notice window or validity period.

alter table public.service_change_policies
  alter column cancellation_credit_validity_days drop not null;

-- Forward V2 policies do not advertise the legacy automatic-credit option.
update public.service_change_policies
set cancellation_early_refund_allowed = true,
    cancellation_early_credit_allowed = false,
    cancellation_late_refund_allowed = true,
    cancellation_late_credit_allowed = false,
    cancellation_credit_validity_days = null,
    updated_at = now()
where reschedule_first_early_percent is not null
  and reschedule_first_late_percent is not null
  and reschedule_repeat_percent is not null
  and cancellation_late_percent is not null;

create or replace function public.service_admin_upsert_change_policy(
  p_service_id uuid,
  p_policy jsonb
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_current public.service_change_policies%rowtype;
  v_result public.service_change_policies%rowtype;
  v_exists boolean;
  v_notice_hours integer;
  v_first_early numeric(5,2);
  v_first_late numeric(5,2);
  v_repeat numeric(5,2);
  v_cancel_late numeric(5,2);
  v_required_keys text[] := array[
    'notice_hours',
    'reschedule_first_early_percent',
    'reschedule_first_late_percent',
    'reschedule_repeat_percent',
    'cancellation_late_percent'
  ];
begin
  if not exists(select 1 from public.services where id=p_service_id) then
    raise exception using errcode='P0001', message='SERVICE_NOT_FOUND';
  end if;
  if p_policy is null or jsonb_typeof(p_policy)<>'object' then
    raise exception using errcode='P0001', message='INVALID_CHANGE_POLICY';
  end if;

  select * into v_current
  from public.service_change_policies
  where service_id=p_service_id
  for update;
  v_exists:=found;

  if not v_exists and not (p_policy ?& v_required_keys) then
    raise exception using errcode='P0001', message='CHANGE_POLICY_COMPLETE_CONFIGURATION_REQUIRED';
  end if;

  -- Reject legacy policy knobs from the administrative write surface. Their
  -- columns remain temporarily only to honor issued legacy credits/reservations.
  if p_policy ?| array[
    'reschedule_first_penalty_type','reschedule_first_penalty_value',
    'reschedule_repeat_penalty_type','reschedule_repeat_penalty_value',
    'reschedule_late_penalty_type','reschedule_late_penalty_value',
    'cancellation_early_penalty_type','cancellation_early_penalty_value',
    'cancellation_late_penalty_type','cancellation_late_penalty_value',
    'cancellation_early_refund_allowed','cancellation_early_credit_allowed',
    'cancellation_late_refund_allowed','cancellation_late_credit_allowed',
    'cancellation_credit_validity_days'
  ] then
    raise exception using errcode='P0001', message='LEGACY_CHANGE_POLICY_FIELDS_NOT_ACCEPTED';
  end if;

  begin
    v_notice_hours:=case when p_policy ? 'notice_hours'
      then (p_policy->>'notice_hours')::integer else v_current.notice_hours end;
    v_first_early:=case when p_policy ? 'reschedule_first_early_percent'
      then (p_policy->>'reschedule_first_early_percent')::numeric else v_current.reschedule_first_early_percent end;
    v_first_late:=case when p_policy ? 'reschedule_first_late_percent'
      then (p_policy->>'reschedule_first_late_percent')::numeric else v_current.reschedule_first_late_percent end;
    v_repeat:=case when p_policy ? 'reschedule_repeat_percent'
      then (p_policy->>'reschedule_repeat_percent')::numeric else v_current.reschedule_repeat_percent end;
    v_cancel_late:=case when p_policy ? 'cancellation_late_percent'
      then (p_policy->>'cancellation_late_percent')::numeric else v_current.cancellation_late_percent end;
  exception
    when invalid_text_representation or numeric_value_out_of_range then
      raise exception using errcode='P0001', message='INVALID_CHANGE_POLICY';
  end;

  if v_notice_hours is null or v_notice_hours<0
     or v_first_early is null or v_first_early not between 0 and 100
     or v_first_late is null or v_first_late not between 0 and 100
     or v_repeat is null or v_repeat not between 0 and 100
     or v_cancel_late is null or v_cancel_late not between 0 and 100 then
    raise exception using errcode='P0001', message='INVALID_CHANGE_POLICY';
  end if;

  insert into public.service_change_policies(
    service_id, notice_hours,
    reschedule_first_penalty_type,reschedule_first_penalty_value,
    reschedule_repeat_penalty_type,reschedule_repeat_penalty_value,
    reschedule_late_penalty_type,reschedule_late_penalty_value,
    cancellation_early_penalty_type,cancellation_early_penalty_value,
    cancellation_late_penalty_type,cancellation_late_penalty_value,
    cancellation_early_refund_allowed,cancellation_early_credit_allowed,
    cancellation_late_refund_allowed,cancellation_late_credit_allowed,
    cancellation_credit_validity_days,
    reschedule_first_early_percent,reschedule_first_late_percent,
    reschedule_repeat_percent,cancellation_late_percent
  ) values (
    p_service_id,v_notice_hours,
    case when v_first_early=0 then 'NONE'::public.change_penalty_type else 'PERCENT'::public.change_penalty_type end,v_first_early,
    case when v_repeat=0 then 'NONE'::public.change_penalty_type else 'PERCENT'::public.change_penalty_type end,v_repeat,
    case when v_first_late=0 then 'NONE'::public.change_penalty_type else 'PERCENT'::public.change_penalty_type end,v_first_late,
    'NONE',0,
    case when v_cancel_late=0 then 'NONE'::public.change_penalty_type else 'PERCENT'::public.change_penalty_type end,v_cancel_late,
    true,false,true,false,null,
    v_first_early,v_first_late,v_repeat,v_cancel_late
  )
  on conflict(service_id) do update
  set notice_hours=excluded.notice_hours,
      reschedule_first_early_percent=excluded.reschedule_first_early_percent,
      reschedule_first_late_percent=excluded.reschedule_first_late_percent,
      reschedule_repeat_percent=excluded.reschedule_repeat_percent,
      cancellation_late_percent=excluded.cancellation_late_percent,
      cancellation_early_refund_allowed=true,
      cancellation_early_credit_allowed=false,
      cancellation_late_refund_allowed=true,
      cancellation_late_credit_allowed=false,
      cancellation_credit_validity_days=null,
      updated_at=now()
  returning * into v_result;

  return jsonb_build_object(
    'notice_hours',v_result.notice_hours,
    'reschedule_first_early_percent',v_result.reschedule_first_early_percent,
    'reschedule_first_late_percent',v_result.reschedule_first_late_percent,
    'reschedule_repeat_percent',v_result.reschedule_repeat_percent,
    'cancellation_late_percent',v_result.cancellation_late_percent
  );
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
begin
  if not public.service_admin_has_permission(p_admin_id,'SERVICES_MANAGE')
     or not public.service_admin_has_permission(p_admin_id,'FINANCE_MANAGE') then
    raise exception using errcode='P0001', message='ADMIN_PERMISSION_DENIED';
  end if;
  if p_policy is null or jsonb_typeof(p_policy)<>'object' then
    raise exception using errcode='P0001', message='INVALID_CHANGE_POLICY';
  end if;

  v_before:=public.service_admin_service_snapshot(p_service_id);
  if v_before is null then
    raise exception using errcode='P0001', message='SERVICE_NOT_FOUND';
  end if;

  v_result:=public.service_admin_upsert_change_policy(p_service_id,p_policy);
  v_after:=public.service_admin_service_snapshot(p_service_id);

  if v_before is distinct from v_after then
    insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
    values(p_admin_id,'SERVICE',p_service_id,'SERVICE_CHANGE_POLICY_UPDATED',v_before,v_after,'ADMIN');
  end if;
  return v_result;
end;
$$;

revoke all on function public.service_admin_upsert_change_policy(uuid,jsonb) from public,anon,authenticated,service_role;
revoke all on function public.service_admin_upsert_change_policy_audited(uuid,jsonb,uuid) from public,anon,authenticated;
grant execute on function public.service_admin_upsert_change_policy_audited(uuid,jsonb,uuid) to service_role;
