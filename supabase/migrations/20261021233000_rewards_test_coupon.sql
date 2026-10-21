-- Rewards complete test (requested 2026-10-21): an OWNER or ADMIN sends an approved Rewards
-- message to one customer with a real coupon. The coupon copies the campaign's current offer
-- (discount, services, validity), is single-use and bound to that customer, works at checkout
-- like any campaign coupon, and is not a campaign issuance: it neither counts for the
-- campaign rules nor stops the customer from earning the real reward later. Every test coupon
-- is recorded in audit_logs. A reminder message ("cupom vencendo") never creates a coupon: its
-- test reuses the customer's newest valid, unused coupon of that campaign (real or test).

create or replace function public.service_admin_issue_rewards_test_coupon(
  p_tenant_id uuid,
  p_campaign_id uuid,
  p_phone text,
  p_admin_id uuid,
  p_reuse_existing boolean default false
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $function$
declare
  v_campaign public.marketing_campaigns%rowtype;
  v_version public.marketing_campaign_versions%rowtype;
  v_coupon public.coupons%rowtype;
  v_customer public.customers%rowtype;
  v_digits text := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 11);
  v_matches integer;
begin
  perform public.service_admin_assert_marketing_campaign_actor(p_admin_id);
  select * into v_campaign from public.marketing_campaigns
  where id = p_campaign_id and tenant_id = p_tenant_id;
  if not found then
    raise exception using errcode = 'P0001', message = 'MARKETING_CAMPAIGN_NOT_FOUND';
  end if;
  if v_campaign.state in ('ENDED','ARCHIVED') then
    raise exception using errcode = '22023', message = 'MARKETING_CAMPAIGN_CLOSED';
  end if;
  -- The offer being tested: the published one, or the newest draft before activation.
  select * into v_version from public.marketing_campaign_versions
  where campaign_id = v_campaign.id
  order by (id = v_campaign.active_version_id) desc, version_number desc
  limit 1;
  -- The customer is the record with this phone (last 11 digits); it must be exactly one.
  select count(*) into v_matches from public.customers c
  where c.anonymized_at is null and length(v_digits) >= 10
    and right(regexp_replace(coalesce(c.phone, ''), '\D', '', 'g'), 11) = v_digits;
  if v_matches = 0 then
    raise exception using errcode = 'P0001', message = 'REWARDS_TEST_CUSTOMER_NOT_FOUND';
  elsif v_matches > 1 then
    raise exception using errcode = 'P0001', message = 'REWARDS_TEST_CUSTOMER_AMBIGUOUS';
  end if;
  select * into v_customer from public.customers c
  where c.anonymized_at is null and right(regexp_replace(coalesce(c.phone, ''), '\D', '', 'g'), 11) = v_digits;

  if p_reuse_existing then
    select c.* into v_coupon from public.coupons c
    where c.customer_id = v_customer.id and c.is_active and c.used_count < c.max_uses and c.valid_until > now()
      and (
        exists (select 1 from public.marketing_campaign_issuances i where i.coupon_id = c.id and i.campaign_id = v_campaign.id)
        or exists (select 1 from public.audit_logs l where l.entity_id = c.id and l.action = 'REWARDS_TEST_COUPON_ISSUED'
          and l.after_json->>'campaign_id' = v_campaign.id::text)
      )
    order by c.created_at desc
    limit 1;
    if not found then
      raise exception using errcode = 'P0001', message = 'REWARDS_TEST_NO_COUPON_TO_REMIND';
    end if;
    return jsonb_build_object('coupon_id', v_coupon.id, 'code', v_coupon.code, 'discount_type', v_coupon.discount_type,
      'discount_value', v_coupon.discount_value, 'valid_until', v_coupon.valid_until, 'customer_id', v_customer.id,
      'customer_name', v_customer.name, 'last_rental_at', public.marketing_rewards_last_rental_at(v_customer.id), 'reused', true);
  end if;

  insert into public.coupons(
    code, discount_type, discount_value, valid_from, valid_until, is_active,
    source, customer_id, max_uses, max_uses_per_customer, used_count, discount_scope, validity_basis
  ) values (
    'RW-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 16)),
    v_version.discount_type, v_version.discount_value, now(), now() + make_interval(days => v_version.validity_days), true,
    'PROMOTION', v_customer.id, 1, 1, 0, v_version.discount_scope, v_version.validity_basis
  ) returning * into v_coupon;
  insert into public.coupon_services(coupon_id, service_id)
  select v_coupon.id, s.service_id from public.marketing_campaign_version_services s where s.campaign_version_id = v_version.id;

  insert into public.audit_logs(admin_user_id, entity_type, entity_id, action, after_json, origin)
  values (p_admin_id, 'COUPON', v_coupon.id, 'REWARDS_TEST_COUPON_ISSUED',
    jsonb_build_object('campaign_id', v_campaign.id, 'campaign_version_id', v_version.id, 'customer_id', v_customer.id,
      'code', v_coupon.code, 'discount_type', v_coupon.discount_type, 'discount_value', v_coupon.discount_value,
      'valid_until', v_coupon.valid_until), 'ADMIN');
  return jsonb_build_object('coupon_id', v_coupon.id, 'code', v_coupon.code, 'discount_type', v_coupon.discount_type,
    'discount_value', v_coupon.discount_value, 'valid_until', v_coupon.valid_until, 'customer_id', v_customer.id,
    'customer_name', v_customer.name, 'last_rental_at', public.marketing_rewards_last_rental_at(v_customer.id), 'reused', false);
end;
$function$;

revoke all on function public.service_admin_issue_rewards_test_coupon(uuid,uuid,text,uuid,boolean) from public, anon, authenticated;
grant execute on function public.service_admin_issue_rewards_test_coupon(uuid,uuid,text,uuid,boolean) to service_role;
comment on function public.service_admin_issue_rewards_test_coupon(uuid,uuid,text,uuid,boolean) is
  'Service-only admin action: a real single-use coupon from the campaign offer for one customer, for a complete Rewards message test. Not a campaign issuance; audited.';
