create or replace function public.service_admin_finance_pending_refunds(p_operation_scope text, p_admin_id uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_scope text := nullif(upper(btrim(coalesce(p_operation_scope,''))),'');
  v_rows jsonb;
begin
  if not public.service_admin_has_permission(p_admin_id,'FINANCE_VIEW') then
    raise exception using errcode='P0001', message='ADMIN_PERMISSION_DENIED';
  end if;
  if v_scope is not null and v_scope not in ('BLACKSHEEP','SABRINA') then
    raise exception using errcode='P0001', message='FINANCE_OPERATION_SCOPE_INVALID';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'policy_action_id', pa.id,
    'appointment_id', a.id,
    'public_code', a.public_code,
    'service_at', a.start_at,
    'operation_scope', s.operation_scope,
    'customer_id', c.id,
    'customer_name', c.name,
    'service_name', coalesce(a.service_name_snapshot,s.name),
    'target_refund', coalesce((p.plan->>'target_cash_amount')::numeric,0),
    'recorded_refund', coalesce((p.plan->>'recorded_refund_cash')::numeric,0),
    'remaining_refund', coalesce((p.plan->>'remaining_refund_cash')::numeric,0),
    'gateway_available', coalesce((p.plan->>'mercado_pago_available_cash')::numeric,0),
    'gateway_refund_amount', greatest(
      coalesce((p.plan->>'remaining_refund_cash')::numeric,0) - coalesce((p.plan->>'manual_refund_cash')::numeric,0),
      0
    ),
    'manual_refund_amount', coalesce((p.plan->>'manual_refund_cash')::numeric,0),
    'status', pa.status
  ) order by a.start_at desc),'[]'::jsonb)
  into v_rows
  from public.appointment_policy_actions pa
  join public.appointments a on a.id = pa.appointment_id
  join public.services s on s.id = a.service_id
  left join public.customers c on c.id = a.primary_customer_id
  cross join lateral (select public.service_get_cancellation_refund_plan(pa.id) as plan) p
  where pa.action_type = 'CANCEL'
    and pa.settlement_choice = 'REFUND'
    and pa.status = 'PENDING_REFUND'
    and coalesce((p.plan->>'remaining_refund_cash')::numeric,0) > 0.009
    and (v_scope is null or s.operation_scope = v_scope);

  return jsonb_build_object('operation_scope', v_scope, 'refunds', v_rows);
end;
$function$;
