-- Block 3 hygiene: bounded coupon pagination and removal of an orphaned no-show RPC.
-- The legacy admin_list_coupons() RPC remains intact for compatibility; the Gestão
-- Edge Function moves to the bounded page contract below.

create or replace function public.admin_list_coupons_page(
  p_offset integer default 0,
  p_limit integer default 25
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_total bigint;
  v_coupons jsonb;
begin
  if p_offset is null or p_offset < 0 then
    raise exception 'COUPON_OFFSET_INVALID';
  end if;

  if p_limit is null or p_limit < 1 or p_limit > 100 then
    raise exception 'COUPON_LIMIT_INVALID';
  end if;

  select count(*) into v_total from public.coupons;

  select coalesce(jsonb_agg(page.item order by page.created_at desc, page.code), '[]'::jsonb)
  into v_coupons
  from (
    select
      c.created_at,
      c.code,
      jsonb_build_object(
        'id', c.id,
        'code', c.code,
        'discount_type', c.discount_type,
        'discount_value', c.discount_value,
        'valid_from', c.valid_from,
        'valid_until', c.valid_until,
        'is_active', c.is_active,
        'source', c.source,
        'customer_id', c.customer_id,
        'customer_name', customer.name,
        'source_appointment_id', c.source_appointment_id,
        'max_uses', c.max_uses,
        'max_uses_per_customer', c.max_uses_per_customer,
        'used_count', c.used_count,
        'actual_used_count', (
          select count(*)
          from public.appointment_discounts ad
          where ad.coupon_id = c.id
        ),
        'status', case
          when not c.is_active then 'INACTIVE'
          when c.valid_from is not null and now() < c.valid_from then 'SCHEDULED'
          when c.valid_until is not null and now() > c.valid_until then 'EXPIRED'
          when c.max_uses is not null and c.used_count >= c.max_uses then 'EXHAUSTED'
          else 'ACTIVE'
        end,
        'service_ids', coalesce((
          select jsonb_agg(cs.service_id order by cs.service_id)
          from public.coupon_services cs
          where cs.coupon_id = c.id
        ), '[]'::jsonb)
      ) as item
    from public.coupons c
    left join public.customers customer on customer.id = c.customer_id
    order by c.created_at desc, c.code
    offset p_offset
    limit p_limit
  ) page;

  return jsonb_build_object(
    'coupons', v_coupons,
    'total', v_total,
    'limit', p_limit,
    'offset', p_offset,
    'has_more', (p_offset + p_limit) < v_total
  );
end;
$$;

revoke all on function public.admin_list_coupons_page(integer, integer) from public, anon, authenticated;
grant execute on function public.admin_list_coupons_page(integer, integer) to service_role;

-- Verified before removal on 2026-08-30:
-- * no repository consumer;
-- * no SQL routine/object dependency;
-- * EXECUTE was granted only to service_role.
drop function if exists public.service_admin_mark_appointment_no_show_evidenced(uuid, text, uuid, inet, text, text, text);
