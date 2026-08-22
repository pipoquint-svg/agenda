-- Administrative mutation for per-service reschedule/cancellation policy.
-- The Edge Function authenticates admin users before calling this service-role RPC.

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
  v_notice_hours integer;
  v_reschedule_first_type public.change_penalty_type;
  v_reschedule_first_value numeric(12,2);
  v_reschedule_repeat_type public.change_penalty_type;
  v_reschedule_repeat_value numeric(12,2);
  v_reschedule_late_type public.change_penalty_type;
  v_reschedule_late_value numeric(12,2);
  v_cancel_early_type public.change_penalty_type;
  v_cancel_early_value numeric(12,2);
  v_cancel_late_type public.change_penalty_type;
  v_cancel_late_value numeric(12,2);
  v_early_refund boolean;
  v_early_credit boolean;
  v_late_refund boolean;
  v_late_credit boolean;
  v_credit_days integer;
begin
  if not exists (select 1 from public.services where id = p_service_id) then
    raise exception using errcode = 'P0001', message = 'SERVICE_NOT_FOUND';
  end if;

  if p_policy is null or jsonb_typeof(p_policy) <> 'object' then
    raise exception using errcode = 'P0001', message = 'INVALID_CHANGE_POLICY';
  end if;

  select * into v_current
  from public.service_change_policies
  where service_id = p_service_id;

  v_notice_hours := coalesce((p_policy->>'notice_hours')::integer, v_current.notice_hours, 48);

  v_reschedule_first_type := coalesce(
    nullif(p_policy->>'reschedule_first_penalty_type', '')::public.change_penalty_type,
    v_current.reschedule_first_penalty_type,
    'NONE'::public.change_penalty_type
  );
  v_reschedule_first_value := coalesce((p_policy->>'reschedule_first_penalty_value')::numeric, v_current.reschedule_first_penalty_value, 0);

  v_reschedule_repeat_type := coalesce(
    nullif(p_policy->>'reschedule_repeat_penalty_type', '')::public.change_penalty_type,
    v_current.reschedule_repeat_penalty_type,
    'PERCENT'::public.change_penalty_type
  );
  v_reschedule_repeat_value := coalesce((p_policy->>'reschedule_repeat_penalty_value')::numeric, v_current.reschedule_repeat_penalty_value, 20);

  v_reschedule_late_type := coalesce(
    nullif(p_policy->>'reschedule_late_penalty_type', '')::public.change_penalty_type,
    v_current.reschedule_late_penalty_type,
    'PERCENT'::public.change_penalty_type
  );
  v_reschedule_late_value := coalesce((p_policy->>'reschedule_late_penalty_value')::numeric, v_current.reschedule_late_penalty_value, 20);

  v_cancel_early_type := coalesce(
    nullif(p_policy->>'cancellation_early_penalty_type', '')::public.change_penalty_type,
    v_current.cancellation_early_penalty_type,
    'NONE'::public.change_penalty_type
  );
  v_cancel_early_value := coalesce((p_policy->>'cancellation_early_penalty_value')::numeric, v_current.cancellation_early_penalty_value, 0);

  v_cancel_late_type := coalesce(
    nullif(p_policy->>'cancellation_late_penalty_type', '')::public.change_penalty_type,
    v_current.cancellation_late_penalty_type,
    'PERCENT'::public.change_penalty_type
  );
  v_cancel_late_value := coalesce((p_policy->>'cancellation_late_penalty_value')::numeric, v_current.cancellation_late_penalty_value, 20);

  v_early_refund := coalesce((p_policy->>'cancellation_early_refund_allowed')::boolean, v_current.cancellation_early_refund_allowed, true);
  v_early_credit := coalesce((p_policy->>'cancellation_early_credit_allowed')::boolean, v_current.cancellation_early_credit_allowed, true);
  v_late_refund := coalesce((p_policy->>'cancellation_late_refund_allowed')::boolean, v_current.cancellation_late_refund_allowed, true);
  v_late_credit := coalesce((p_policy->>'cancellation_late_credit_allowed')::boolean, v_current.cancellation_late_credit_allowed, true);
  v_credit_days := coalesce((p_policy->>'cancellation_credit_validity_days')::integer, v_current.cancellation_credit_validity_days, 90);

  if v_notice_hours < 0 or v_credit_days <= 0 then
    raise exception using errcode = 'P0001', message = 'INVALID_CHANGE_POLICY';
  end if;

  insert into public.service_change_policies(
    service_id,
    notice_hours,
    reschedule_first_penalty_type,
    reschedule_first_penalty_value,
    reschedule_repeat_penalty_type,
    reschedule_repeat_penalty_value,
    reschedule_late_penalty_type,
    reschedule_late_penalty_value,
    cancellation_early_penalty_type,
    cancellation_early_penalty_value,
    cancellation_late_penalty_type,
    cancellation_late_penalty_value,
    cancellation_early_refund_allowed,
    cancellation_early_credit_allowed,
    cancellation_late_refund_allowed,
    cancellation_late_credit_allowed,
    cancellation_credit_validity_days
  ) values (
    p_service_id,
    v_notice_hours,
    v_reschedule_first_type,
    v_reschedule_first_value,
    v_reschedule_repeat_type,
    v_reschedule_repeat_value,
    v_reschedule_late_type,
    v_reschedule_late_value,
    v_cancel_early_type,
    v_cancel_early_value,
    v_cancel_late_type,
    v_cancel_late_value,
    v_early_refund,
    v_early_credit,
    v_late_refund,
    v_late_credit,
    v_credit_days
  )
  on conflict (service_id) do update
  set notice_hours = excluded.notice_hours,
      reschedule_first_penalty_type = excluded.reschedule_first_penalty_type,
      reschedule_first_penalty_value = excluded.reschedule_first_penalty_value,
      reschedule_repeat_penalty_type = excluded.reschedule_repeat_penalty_type,
      reschedule_repeat_penalty_value = excluded.reschedule_repeat_penalty_value,
      reschedule_late_penalty_type = excluded.reschedule_late_penalty_type,
      reschedule_late_penalty_value = excluded.reschedule_late_penalty_value,
      cancellation_early_penalty_type = excluded.cancellation_early_penalty_type,
      cancellation_early_penalty_value = excluded.cancellation_early_penalty_value,
      cancellation_late_penalty_type = excluded.cancellation_late_penalty_type,
      cancellation_late_penalty_value = excluded.cancellation_late_penalty_value,
      cancellation_early_refund_allowed = excluded.cancellation_early_refund_allowed,
      cancellation_early_credit_allowed = excluded.cancellation_early_credit_allowed,
      cancellation_late_refund_allowed = excluded.cancellation_late_refund_allowed,
      cancellation_late_credit_allowed = excluded.cancellation_late_credit_allowed,
      cancellation_credit_validity_days = excluded.cancellation_credit_validity_days,
      updated_at = now()
  returning * into v_result;

  return to_jsonb(v_result) - 'service_id' - 'created_at' - 'updated_at';
exception
  when invalid_text_representation or numeric_value_out_of_range then
    raise exception using errcode = 'P0001', message = 'INVALID_CHANGE_POLICY';
end;
$$;

revoke all on function public.service_admin_upsert_change_policy(uuid,jsonb) from public, anon, authenticated;
grant execute on function public.service_admin_upsert_change_policy(uuid,jsonb) to service_role;

comment on function public.service_admin_upsert_change_policy(uuid,jsonb) is
  'Admin-only per-service reschedule/cancellation policy mutation. Table constraints remain authoritative for penalty shapes.';
