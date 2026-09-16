-- Repair historical appointments created before the checkout coupon single-application fix.
-- The persisted checkout hold is the authoritative commercial snapshot. This migration
-- does not create charges, refunds, payment intents, or change appointment scheduling/status.
-- It only restores contract/coupon amounts, refreshes the derived financial status, and
-- records an audit event for each repaired appointment.

do $repair_double_applied_coupon_history$
declare
  v_row record;
  v_before jsonb;
  v_after jsonb;
  v_new_financial_status public.financial_status;
begin
  for v_row in
    select
      a.id as appointment_id,
      a.public_code,
      a.commercial_value as old_commercial_value,
      a.coupon_discount as old_coupon_discount,
      a.financial_status as old_financial_status,
      h.applied_coupon_id,
      h.coupon_code_snapshot,
      h.pre_discount_value,
      h.commercial_value as correct_commercial_value,
      h.coupon_discount as correct_coupon_discount
    from public.checkout_holds h
    join public.appointments a on a.id = h.promoted_appointment_id
    where h.applied_coupon_id is not null
      and h.promoted_appointment_id is not null
      and h.pre_discount_value is not null
      and abs(h.pre_discount_value - (h.commercial_value + h.coupon_discount)) <= 0.01
      and (
        abs(a.commercial_value - h.commercial_value) > 0.01
        or abs(a.coupon_discount - h.coupon_discount) > 0.01
      )
    order by a.created_at
    for update of a
  loop
    v_before := jsonb_build_object(
      'public_code', v_row.public_code,
      'commercial_value', v_row.old_commercial_value,
      'coupon_discount', v_row.old_coupon_discount,
      'financial_status', v_row.old_financial_status,
      'authoritative_checkout_subtotal', v_row.pre_discount_value,
      'authoritative_checkout_total', v_row.correct_commercial_value,
      'authoritative_coupon_discount', v_row.correct_coupon_discount,
      'coupon_code', v_row.coupon_code_snapshot
    );

    update public.appointments
    set commercial_value = v_row.correct_commercial_value,
        coupon_discount = v_row.correct_coupon_discount,
        updated_at = now()
    where id = v_row.appointment_id;

    update public.appointment_discounts
    set calculated_discount_amount = v_row.correct_coupon_discount
    where appointment_id = v_row.appointment_id
      and coupon_id = v_row.applied_coupon_id;

    v_new_financial_status := public.refresh_appointment_financial_status(v_row.appointment_id);

    select jsonb_build_object(
      'public_code', a.public_code,
      'commercial_value', a.commercial_value,
      'coupon_discount', a.coupon_discount,
      'financial_status', a.financial_status,
      'coupon_code', v_row.coupon_code_snapshot,
      'payments_unchanged', true
    )
    into v_after
    from public.appointments a
    where a.id = v_row.appointment_id;

    insert into public.audit_logs(
      entity_type,
      entity_id,
      action,
      before_json,
      after_json,
      origin
    ) values (
      'APPOINTMENT',
      v_row.appointment_id,
      'COUPON_DOUBLE_APPLICATION_REPAIRED',
      v_before,
      v_after,
      'SYSTEM'
    );
  end loop;
end;
$repair_double_applied_coupon_history$;