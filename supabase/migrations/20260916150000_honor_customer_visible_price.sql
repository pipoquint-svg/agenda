-- Honor the customer-visible price for reservations that were historically affected
-- by the coupon double-application bug. The technical coupon snapshot remains corrected,
-- but the customer obligation returns to the exact amount that was shown at booking time.
--
-- This migration does not create payments, receipts, refunds, Pix charges or cash entries.
-- It restores commercial_value + financial_status from the pre-repair audit snapshot and
-- records the seller-funded commercial adjustment explicitly in audit_logs.

DO $honor_customer_visible_price$
DECLARE
  v_row record;
  v_honored_total numeric(12,2);
  v_adjustment numeric(12,2);
  v_honored_status text;
BEGIN
  FOR v_row IN
    SELECT DISTINCT ON (a.id)
      a.id,
      a.public_code,
      a.commercial_value AS current_total,
      a.financial_status AS current_financial_status,
      al.before_json,
      al.created_at AS repair_created_at
    FROM public.appointments a
    JOIN public.audit_logs al
      ON al.entity_id = a.id
     AND al.entity_type = 'APPOINTMENT'
     AND al.action = 'COUPON_DOUBLE_APPLICATION_REPAIRED'
    WHERE a.deleted_at IS NULL
    ORDER BY a.id, al.created_at DESC
  LOOP
    v_honored_total := round((v_row.before_json->>'commercial_value')::numeric, 2);
    v_honored_status := v_row.before_json->>'financial_status';
    v_adjustment := round(coalesce(v_row.current_total,0) - coalesce(v_honored_total,0), 2);

    IF v_adjustment > 0.01
       AND NOT EXISTS (
         SELECT 1
         FROM public.audit_logs existing
         WHERE existing.entity_type = 'APPOINTMENT'
           AND existing.entity_id = v_row.id
           AND existing.action = 'SYSTEM_PRICE_HONORED'
       )
    THEN
      UPDATE public.appointments
      SET commercial_value = v_honored_total,
          financial_status = coalesce(v_honored_status, financial_status),
          updated_at = now()
      WHERE id = v_row.id;

      INSERT INTO public.audit_logs(
        admin_user_id,
        entity_type,
        entity_id,
        action,
        before_json,
        after_json,
        origin
      ) VALUES (
        NULL,
        'APPOINTMENT',
        v_row.id,
        'SYSTEM_PRICE_HONORED',
        jsonb_build_object(
          'public_code', v_row.public_code,
          'technical_total', v_row.current_total,
          'financial_status', v_row.current_financial_status,
          'source_repair_created_at', v_row.repair_created_at
        ),
        jsonb_build_object(
          'public_code', v_row.public_code,
          'honored_total', v_honored_total,
          'adjustment_amount', v_adjustment,
          'financial_status', v_honored_status,
          'reason', 'Preço exibido ao cliente no momento da reserva foi honrado após correção de dupla aplicação de cupom',
          'payments_unchanged', true,
          'cash_unchanged', true
        ),
        'SYSTEM'
      );
    END IF;
  END LOOP;
END;
$honor_customer_visible_price$;

-- Expose the audited commercial adjustment in the existing FINANCE_VIEW envelope so
-- the admin UI can explain intentional historical price honoring instead of flagging it
-- as an unexplained inconsistency.
CREATE OR REPLACE FUNCTION public.service_admin_get_appointment(p_appointment_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  WITH base AS (
    SELECT public.service_admin_get_appointment_base(p_appointment_id) payload
  ),
  coupon_snapshot AS (
    SELECT jsonb_build_object(
      'coupon_id', ad.coupon_id,
      'code', ad.code_snapshot,
      'discount_type', ad.discount_type_snapshot,
      'discount_value', ad.discount_value_snapshot,
      'discount_amount', ad.calculated_discount_amount,
      'final_value', a.commercial_value
    ) coupon
    FROM public.appointment_discounts ad
    JOIN public.appointments a ON a.id = ad.appointment_id
    WHERE ad.appointment_id = p_appointment_id
    ORDER BY ad.created_at
    LIMIT 1
  ),
  commercial_adjustment AS (
    SELECT jsonb_build_object(
      'type', 'SYSTEM_PRICE_HONOR',
      'amount', round((al.after_json->>'adjustment_amount')::numeric,2),
      'reason', al.after_json->>'reason',
      'technical_total', round((al.before_json->>'technical_total')::numeric,2),
      'honored_total', round((al.after_json->>'honored_total')::numeric,2),
      'created_at', al.created_at
    ) adjustment
    FROM public.audit_logs al
    WHERE al.entity_type='APPOINTMENT'
      AND al.entity_id=p_appointment_id
      AND al.action='SYSTEM_PRICE_HONORED'
    ORDER BY al.created_at DESC
    LIMIT 1
  )
  SELECT base.payload || jsonb_build_object(
    'financial',
      coalesce(base.payload->'financial','{}'::jsonb)
      || jsonb_build_object('coupon', (SELECT coupon FROM coupon_snapshot))
      || CASE
           WHEN EXISTS (SELECT 1 FROM commercial_adjustment)
           THEN jsonb_build_object('commercial_adjustment', (SELECT adjustment FROM commercial_adjustment))
           ELSE '{}'::jsonb
         END
  )
  FROM base;
$function$;

COMMENT ON FUNCTION public.service_admin_get_appointment(uuid) IS
  'Admin appointment detail including coupon snapshot and audited seller-funded commercial adjustment when a historical customer-visible price is honored.';