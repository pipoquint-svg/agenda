-- Rewards S4: turn a previously eligible completed rental into one private,
-- customer-bound coupon. This function deliberately does not dispatch a
-- message, invoke checkout, or change campaign/appointment state.
create or replace function public.service_issue_marketing_campaign_coupon(
  p_campaign_id uuid,
  p_source_appointment_id uuid,
  p_idempotency_key text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $function$
declare
  v_existing_issuance public.marketing_campaign_issuances%rowtype;
  v_existing_coupon public.coupons%rowtype;
  v_version public.marketing_campaign_versions%rowtype;
  v_eligibility jsonb;
  v_coupon_id uuid;
  v_coupon_code text;
begin
  if p_campaign_id is null
    or p_source_appointment_id is null
    or length(btrim(coalesce(p_idempotency_key, ''))) not between 8 and 256 then
    raise exception using errcode = '22023', message = 'MARKETING_CAMPAIGN_ISSUANCE_INPUT_INVALID';
  end if;

  select i.*
    into v_existing_issuance
  from public.marketing_campaign_issuances i
  where i.campaign_id = p_campaign_id
    and i.idempotency_key = btrim(p_idempotency_key)
  for update of i;

  if found then
    if v_existing_issuance.source_appointment_id is distinct from p_source_appointment_id then
      raise exception using errcode = '22023', message = 'MARKETING_CAMPAIGN_ISSUANCE_IDEMPOTENCY_KEY_REUSED';
    end if;
    select * into v_existing_coupon
    from public.coupons
    where id = v_existing_issuance.coupon_id;
    return jsonb_build_object(
      'coupon_id', v_existing_coupon.id,
      'coupon_code', v_existing_coupon.code,
      'campaign_id', v_existing_issuance.campaign_id,
      'campaign_version_id', v_existing_issuance.campaign_version_id,
      'source_appointment_id', v_existing_issuance.source_appointment_id,
      'customer_id', v_existing_issuance.customer_id,
      'replayed', true
    );
  end if;

  -- Lock in a stable order before evaluating. This serializes competing issue
  -- attempts for the same source while campaign transitions are in flight.
  perform 1
  from public.marketing_campaigns
  where id = p_campaign_id
  for update;
  perform 1
  from public.appointments
  where id = p_source_appointment_id
  for update;

  v_eligibility := public.service_evaluate_marketing_campaign_eligibility(
    p_campaign_id,
    p_source_appointment_id
  );
  if v_eligibility->>'decision' <> 'ELIGIBLE' then
    raise exception using
      errcode = 'P0001',
      message = 'MARKETING_CAMPAIGN_ISSUANCE_INELIGIBLE',
      detail = coalesce(v_eligibility->>'reason_code', 'MARKETING_CAMPAIGN_ELIGIBILITY_INVALID');
  end if;

  select * into v_version
  from public.marketing_campaign_versions
  where id = (v_eligibility->>'campaign_version_id')::uuid
    and campaign_id = p_campaign_id
    and tenant_id = (v_eligibility->>'tenant_id')::uuid
  for key share;
  if not found then
    raise exception using errcode = 'P0001', message = 'MARKETING_CAMPAIGN_ISSUANCE_VERSION_INVALID';
  end if;

  if not exists (
    select 1
    from public.marketing_campaign_version_services s
    where s.campaign_version_id = v_version.id
  ) then
    raise exception using errcode = 'P0001', message = 'MARKETING_CAMPAIGN_TARGET_SERVICES_REQUIRED';
  end if;

  v_coupon_code := 'RW-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 16));
  insert into public.coupons(
    code, discount_type, discount_value, valid_from, valid_until, is_active,
    source, customer_id, source_appointment_id, max_uses, max_uses_per_customer,
    used_count, discount_scope
  ) values (
    v_coupon_code, v_version.discount_type, v_version.discount_value, now(),
    now() + make_interval(days => v_version.validity_days), true,
    'PROMOTION', (v_eligibility->>'customer_id')::uuid, p_source_appointment_id,
    v_version.max_uses, v_version.max_uses_per_customer, 0, v_version.discount_scope
  ) returning id into v_coupon_id;

  insert into public.coupon_services(coupon_id, service_id)
  select v_coupon_id, s.service_id
  from public.marketing_campaign_version_services s
  where s.campaign_version_id = v_version.id;

  insert into public.marketing_campaign_issuances(
    tenant_id, campaign_id, campaign_version_id, coupon_id, customer_id,
    source_appointment_id, idempotency_key
  ) values (
    (v_eligibility->>'tenant_id')::uuid, p_campaign_id, v_version.id, v_coupon_id,
    (v_eligibility->>'customer_id')::uuid, p_source_appointment_id, btrim(p_idempotency_key)
  );

  insert into public.marketing_campaign_audit_events(
    tenant_id, campaign_id, actor_admin_id, event_kind, after_snapshot
  ) values (
    (v_eligibility->>'tenant_id')::uuid, p_campaign_id, null, 'ISSUANCE_LINKED',
    jsonb_build_object(
      'coupon_id', v_coupon_id,
      'campaign_version_id', v_version.id,
      'source_appointment_id', p_source_appointment_id,
      'customer_id', (v_eligibility->>'customer_id')::uuid
    )
  );

  return jsonb_build_object(
    'coupon_id', v_coupon_id,
    'coupon_code', v_coupon_code,
    'campaign_id', p_campaign_id,
    'campaign_version_id', v_version.id,
    'source_appointment_id', p_source_appointment_id,
    'customer_id', (v_eligibility->>'customer_id')::uuid,
    'replayed', false
  );
end;
$function$;

revoke all on function public.service_issue_marketing_campaign_coupon(uuid,uuid,text)
  from public, anon, authenticated;
grant execute on function public.service_issue_marketing_campaign_coupon(uuid,uuid,text)
  to service_role;

comment on function public.service_issue_marketing_campaign_coupon(uuid,uuid,text) is
  'S4 private Rewards issuance: evaluates a completed paid BlackSheep rental, creates one customer-bound SERVICE_ONLY coupon, links the immutable campaign version, and audits the issuance. It never sends messages or invokes checkout.';
