create or replace function public.service_get_cancellation_refund_plan(p_policy_action_id uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_action public.appointment_policy_actions%rowtype;
  v_target numeric(12,2);
  v_recorded numeric(12,2);
  v_remaining numeric(12,2);
  v_provider_available numeric(12,2) := 0;
  v_plan jsonb := '[]'::jsonb;
  v_take numeric(12,2);
  r record;
begin
  select * into v_action
  from public.appointment_policy_actions
  where id = p_policy_action_id and action_type = 'CANCEL';

  if not found then
    raise exception using errcode='P0001', message='CANCELLATION_ACTION_NOT_FOUND';
  end if;

  if v_action.settlement_choice <> 'REFUND' or v_action.status not in ('PENDING_REFUND','REFUNDED') then
    raise exception using errcode='P0001', message='CANCELLATION_REFUND_NOT_PENDING';
  end if;

  v_target := round(coalesce(v_action.refundable_amount,0),2);

  select coalesce(sum(pt.cash_amount),0)::numeric(12,2)
    into v_recorded
  from public.payment_transactions pt
  where pt.policy_action_id = v_action.id
    and pt.payment_purpose = 'CONTRACT'
    and pt.transaction_type = 'REFUND'
    and pt.status in ('APPROVED','REFUNDED');

  v_remaining := round(greatest(v_target-v_recorded,0),2);

  for r in
    select
      pt.id as transaction_id,
      coalesce(nullif(pt.provider_payload_json->>'provider_transaction_id',''), pt.provider_payment_id) as provider_payment_id,
      pt.method,
      pt.cash_amount,
      pt.contract_amount_settled,
      greatest(
        pt.cash_amount - coalesce((
          select sum(rf.cash_amount)
          from public.payment_transactions rf
          where rf.parent_transaction_id = pt.id
            and rf.payment_purpose = 'CONTRACT'
            and rf.transaction_type = 'REFUND'
            and rf.status in ('APPROVED','REFUNDED')
        ),0),
        0
      )::numeric(12,2) as refundable_cash
    from public.payment_transactions pt
    where pt.appointment_id = v_action.appointment_id
      and pt.payment_purpose = 'CONTRACT'
      and pt.transaction_type = 'CHARGE'
      and pt.provider = 'MERCADO_PAGO'
      and coalesce(nullif(pt.provider_payload_json->>'provider_transaction_id',''), pt.provider_payment_id) is not null
      and pt.status in ('APPROVED','PARTIALLY_REFUNDED','REFUNDED')
    order by pt.paid_at nulls last, pt.created_at, pt.id
  loop
    if r.refundable_cash <= 0 then
      continue;
    end if;

    v_provider_available := v_provider_available + r.refundable_cash;

    if v_remaining > 0 then
      v_take := least(v_remaining, r.refundable_cash);
      v_plan := v_plan || jsonb_build_array(jsonb_build_object(
        'parent_transaction_id', r.transaction_id,
        'provider_payment_id', r.provider_payment_id,
        'method', r.method,
        'available_cash', r.refundable_cash,
        'refund_cash', v_take
      ));
      v_remaining := round(v_remaining-v_take,2);
    end if;
  end loop;

  return jsonb_build_object(
    'policy_action_id', v_action.id,
    'appointment_id', v_action.appointment_id,
    'status', v_action.status,
    'target_cash_amount', v_target,
    'recorded_refund_cash', v_recorded,
    'remaining_refund_cash', round(greatest(v_target-v_recorded,0),2),
    'mercado_pago_available_cash', round(v_provider_available,2),
    'manual_refund_cash', round(greatest((v_target-v_recorded)-v_provider_available,0),2),
    'payments', v_plan
  );
end;
$function$;
