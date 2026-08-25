-- Preserve the existing appointment detail contract and add the coupon snapshot used by this reservation.
-- Coupon information lives inside the existing `financial` envelope so admin-agenda's FINANCE_VIEW
-- redaction removes the entire object for operators without financial access.

alter function public.service_admin_get_appointment(uuid)
  rename to service_admin_get_appointment_base;

create or replace function public.service_admin_get_appointment(p_appointment_id uuid)
returns jsonb
language sql
stable
security definer
set search_path=public
as $$
with base as (
  select public.service_admin_get_appointment_base(p_appointment_id) as payload
), coupon_snapshot as (
  select jsonb_build_object(
    'coupon_id', ad.coupon_id,
    'code', ad.code_snapshot,
    'discount_type', ad.discount_type_snapshot,
    'discount_value', ad.discount_value_snapshot,
    'discount_amount', ad.calculated_discount_amount,
    'final_value', a.commercial_value
  ) as coupon
  from public.appointment_discounts ad
  join public.appointments a on a.id=ad.appointment_id
  where ad.appointment_id=p_appointment_id
  order by ad.created_at
  limit 1
)
select base.payload || jsonb_build_object(
  'financial', coalesce(base.payload->'financial','{}'::jsonb)
    || jsonb_build_object('coupon',(select coupon from coupon_snapshot))
)
from base;
$$;

revoke all on function public.service_admin_get_appointment_base(uuid) from public,anon,authenticated;
revoke all on function public.service_admin_get_appointment(uuid) from public,anon,authenticated;
grant execute on function public.service_admin_get_appointment_base(uuid) to service_role;
grant execute on function public.service_admin_get_appointment(uuid) to service_role;
