-- Canonical record of the production migration applied on 2026-10-16.
--
-- This migration has already been executed in production under this exact
-- version. Keeping its source in Git restores migration-history parity and
-- prevents any future release from treating a legitimate schema change as an
-- unknown remote-only record.

create or replace function public.service_admin_get_appointment(p_appointment_id uuid)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  with base as (
    select public.service_admin_get_appointment_base(p_appointment_id) payload
  ),
  coupon_snapshot as (
    select jsonb_build_object(
      'coupon_id', ad.coupon_id,
      'code', ad.code_snapshot,
      'discount_type', ad.discount_type_snapshot,
      'discount_value', ad.discount_value_snapshot,
      'discount_amount', ad.calculated_discount_amount,
      'final_value', a.commercial_value
    ) coupon
    from public.appointment_discounts ad
    join public.appointments a on a.id = ad.appointment_id
    where ad.appointment_id = p_appointment_id
    order by ad.created_at
    limit 1
  ),
  commercial_adjustment as (
    select jsonb_build_object(
      'type', 'SYSTEM_PRICE_HONOR',
      'amount', round((al.after_json->>'adjustment_amount')::numeric, 2),
      'reason', al.after_json->>'reason',
      'technical_total', round((al.before_json->>'technical_total')::numeric, 2),
      'honored_total', round((al.after_json->>'honored_total')::numeric, 2),
      'created_at', al.created_at
    ) adjustment
    from public.audit_logs al
    where al.entity_type = 'APPOINTMENT'
      and al.entity_id = p_appointment_id
      and al.action = 'SYSTEM_PRICE_HONORED'
    order by al.created_at desc
    limit 1
  )
  select base.payload || jsonb_build_object(
    'appointment', coalesce(base.payload->'appointment', '{}'::jsonb) || jsonb_build_object(
      'included_people', s.included_people
    ),
    'financial', coalesce(base.payload->'financial', '{}'::jsonb) || jsonb_build_object(
      'coupon', (select coupon from coupon_snapshot)
    ) || case
      when exists (select 1 from commercial_adjustment) then jsonb_build_object(
        'commercial_adjustment', (select adjustment from commercial_adjustment)
      )
      else '{}'::jsonb
    end
  )
  from base
  left join public.appointments a on a.id = p_appointment_id
  left join public.services s on s.id = a.service_id;
$function$;
