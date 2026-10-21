-- Rewards engine: "90 days without a rental" (INACTIVITY) and "after the free
-- visit" (FREE_VISIT_COMPLETED) triggers, next to the existing rental trigger.
-- Nothing here issues a coupon on its own or sends a message: the evaluators and
-- the candidate list are read-only, and the customer-anchored issuance is a
-- service-only function that no job calls while Rewards stays frozen.
--
-- Owner decisions (2026-10-21):
-- * Realized = COMPLETED, or CONFIRMED with its scheduled end in the past (same
--   rule as finance). Applies to the rental trigger too.
-- * Reservations without the S3 source snapshot are classified by the service
--   as registered today; snapshotted reservations keep their snapshot.
-- * The 90-day trigger also reaches customers whose last rental is in the
--   Amelia history (linked to a customer), so its coupon is anchored on the
--   customer instead of a reservation.

alter table public.marketing_campaign_versions
  drop constraint marketing_campaign_versions_trigger_kind_check;

alter table public.marketing_campaign_versions
  add constraint marketing_campaign_versions_trigger_kind_check
  check (trigger_kind in (
    'RENTAL_COMPLETED_FINANCIALLY_CLEARED','BIRTHDAY','FIRST_RENTAL',
    'INACTIVITY','BOOKING_CONFIRMED','MANUAL','CUSTOM','FREE_VISIT_COMPLETED'
  ));

-- RENTAL, VISIT or OTHER for a reservation: the S3 snapshot when present,
-- otherwise the service as registered today. Visits are never rentals.
create or replace function public.marketing_rewards_source_kind(p_appointment_id uuid)
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $function$
  select case
    when coalesce(a.rewards_source_operation_scope_snapshot, s.operation_scope) is distinct from 'BLACKSHEEP' then 'OTHER'
    when s.booking_product_type = 'FREE_VISIT' then 'VISIT'
    when coalesce(a.rewards_source_service_type_key_snapshot, st.key) = 'LOCACAO' then 'RENTAL'
    else 'OTHER'
  end
  from public.appointments a
  join public.services s on s.id = a.service_id
  left join public.service_type st on st.id = s.service_type_id
  where a.id = p_appointment_id
$function$;

-- End of the customer's last realized BlackSheep rental, in the Agenda or in
-- the Amelia history linked to the customer. Null when they never rented.
create or replace function public.marketing_rewards_last_rental_at(p_customer_id uuid)
returns timestamptz
language sql
stable
security definer
set search_path = public, pg_temp
as $function$
  select max(x.ended_at) from (
    select a.end_at as ended_at
    from public.appointments a
    where a.primary_customer_id = p_customer_id
      and not a.is_test
      and (a.status = 'COMPLETED' or (a.status = 'CONFIRMED' and a.end_at <= now()))
      and public.marketing_rewards_source_kind(a.id) = 'RENTAL'
    union all
    select coalesce(l.end_at, l.start_at)
    from public.legacy_amelia_bookings l
    where l.matched_customer_id = p_customer_id
      and l.status_raw = 'Aprovado'
      and coalesce(l.service_name, '') ilike '%loca%'
      and coalesce(l.end_at, l.start_at) <= now()
  ) x
$function$;

create or replace function public.service_evaluate_marketing_campaign_eligibility(
  p_campaign_id uuid,
  p_source_appointment_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $function$
declare
  v_campaign public.marketing_campaigns%rowtype;
  v_version public.marketing_campaign_versions%rowtype;
  v_appointment public.appointments%rowtype;
  v_kind text;
  v_realized boolean;
  v_base jsonb;
begin
  if p_campaign_id is null or p_source_appointment_id is null then
    return jsonb_build_object('decision', 'INELIGIBLE', 'reason_code', 'MARKETING_CAMPAIGN_INPUT_REQUIRED');
  end if;

  select * into v_campaign from public.marketing_campaigns where id = p_campaign_id;
  if not found then
    return jsonb_build_object('decision', 'INELIGIBLE', 'reason_code', 'MARKETING_CAMPAIGN_NOT_FOUND');
  end if;

  v_base := jsonb_build_object('campaign_id', v_campaign.id, 'tenant_id', v_campaign.tenant_id);

  if not exists (
    select 1 from public.tenants t
    where t.id = v_campaign.tenant_id and t.slug = 'blacksheep' and t.status = 'ACTIVE'
  ) then
    return v_base || jsonb_build_object('decision', 'BLOCKED', 'reason_code', 'MARKETING_CAMPAIGN_SOURCE_TENANT_UNMAPPED');
  end if;

  if v_campaign.state <> 'ACTIVE' then
    return v_base || jsonb_build_object('decision', 'INELIGIBLE', 'reason_code', 'MARKETING_CAMPAIGN_NOT_ACTIVE');
  end if;

  if (v_campaign.starts_at is not null and v_campaign.starts_at > now())
    or (v_campaign.ends_at is not null and v_campaign.ends_at <= now()) then
    return v_base || jsonb_build_object('decision', 'INELIGIBLE', 'reason_code', 'MARKETING_CAMPAIGN_OUTSIDE_WINDOW');
  end if;

  select * into v_version
  from public.marketing_campaign_versions
  where id = v_campaign.active_version_id and campaign_id = v_campaign.id and tenant_id = v_campaign.tenant_id;
  if not found or v_version.publication_status <> 'PUBLISHED' then
    return v_base || jsonb_build_object('decision', 'BLOCKED', 'reason_code', 'MARKETING_CAMPAIGN_ACTIVE_VERSION_INVALID');
  end if;

  v_base := v_base || jsonb_build_object('campaign_version_id', v_version.id);

  if v_version.trigger_kind = 'INACTIVITY' then
    -- Anchored on the customer: see service_evaluate_marketing_campaign_customer_eligibility.
    return v_base || jsonb_build_object('decision', 'INELIGIBLE', 'reason_code', 'MARKETING_CAMPAIGN_TRIGGER_CUSTOMER_BASED');
  end if;

  if v_version.trigger_kind not in ('RENTAL_COMPLETED_FINANCIALLY_CLEARED', 'FREE_VISIT_COMPLETED') then
    return v_base || jsonb_build_object('decision', 'INELIGIBLE', 'reason_code', 'MARKETING_CAMPAIGN_TRIGGER_NOT_SUPPORTED');
  end if;

  select * into v_appointment from public.appointments where id = p_source_appointment_id;
  if not found then
    return v_base || jsonb_build_object('decision', 'INELIGIBLE', 'reason_code', 'MARKETING_CAMPAIGN_SOURCE_APPOINTMENT_NOT_FOUND');
  end if;

  v_base := v_base || jsonb_build_object('source_appointment_id', v_appointment.id);
  v_kind := public.marketing_rewards_source_kind(v_appointment.id);
  v_realized := v_appointment.status = 'COMPLETED' or (v_appointment.status = 'CONFIRMED' and v_appointment.end_at <= now());

  if v_version.trigger_kind = 'FREE_VISIT_COMPLETED' then
    if v_kind <> 'VISIT' then
      return v_base || jsonb_build_object('decision', 'INELIGIBLE', 'reason_code', 'MARKETING_CAMPAIGN_SOURCE_NOT_BLACKSHEEP_VISIT');
    end if;
    if v_appointment.primary_customer_id is null then
      return v_base || jsonb_build_object('decision', 'BLOCKED', 'reason_code', 'MARKETING_CAMPAIGN_SOURCE_CUSTOMER_REQUIRED');
    end if;
    v_base := v_base || jsonb_build_object('customer_id', v_appointment.primary_customer_id);
    if v_appointment.is_test then
      return v_base || jsonb_build_object('decision', 'INELIGIBLE', 'reason_code', 'MARKETING_CAMPAIGN_SOURCE_IS_TEST');
    end if;
    if not v_realized then
      return v_base || jsonb_build_object('decision', 'INELIGIBLE', 'reason_code', 'MARKETING_CAMPAIGN_SOURCE_NOT_COMPLETED');
    end if;
    if exists (select 1 from public.customers c where c.id = v_appointment.primary_customer_id and c.anonymized_at is not null) then
      return v_base || jsonb_build_object('decision', 'INELIGIBLE', 'reason_code', 'MARKETING_CAMPAIGN_CUSTOMER_ANONYMIZED');
    end if;
    -- The visit coupon converts visitors: whoever already rented gets the rental coupon instead.
    if public.marketing_rewards_last_rental_at(v_appointment.primary_customer_id) is not null then
      return v_base || jsonb_build_object('decision', 'INELIGIBLE', 'reason_code', 'MARKETING_CAMPAIGN_CUSTOMER_ALREADY_RENTED');
    end if;
    if exists (
      select 1 from public.marketing_campaign_issuances i
      where i.campaign_id = v_campaign.id and i.customer_id = v_appointment.primary_customer_id
    ) then
      return v_base || jsonb_build_object('decision', 'INELIGIBLE', 'reason_code', 'MARKETING_CAMPAIGN_CUSTOMER_ALREADY_ISSUED');
    end if;
    return v_base || jsonb_build_object('decision', 'ELIGIBLE', 'reason_code', 'MARKETING_CAMPAIGN_ELIGIBLE');
  end if;

  -- RENTAL_COMPLETED_FINANCIALLY_CLEARED
  if v_kind <> 'RENTAL' then
    return v_base || jsonb_build_object('decision', 'INELIGIBLE', 'reason_code', 'MARKETING_CAMPAIGN_SOURCE_NOT_BLACKSHEEP_RENTAL');
  end if;
  if v_appointment.primary_customer_id is null then
    return v_base || jsonb_build_object('decision', 'BLOCKED', 'reason_code', 'MARKETING_CAMPAIGN_SOURCE_CUSTOMER_REQUIRED');
  end if;
  v_base := v_base || jsonb_build_object('customer_id', v_appointment.primary_customer_id);
  if not v_realized then
    return v_base || jsonb_build_object('decision', 'INELIGIBLE', 'reason_code', 'MARKETING_CAMPAIGN_SOURCE_NOT_COMPLETED');
  end if;
  if v_appointment.financial_status <> 'PAID' then
    return v_base || jsonb_build_object('decision', 'INELIGIBLE', 'reason_code', 'MARKETING_CAMPAIGN_SOURCE_NOT_FINANCIALLY_CLEARED');
  end if;
  if exists (
    select 1 from public.marketing_campaign_issuances i
    where i.campaign_id = v_campaign.id and i.source_appointment_id = v_appointment.id
  ) then
    return v_base || jsonb_build_object('decision', 'INELIGIBLE', 'reason_code', 'MARKETING_CAMPAIGN_SOURCE_ALREADY_ISSUED');
  end if;
  if not v_version.recurring_after_discounted_rental
    and exists (select 1 from public.appointment_discounts d where d.appointment_id = v_appointment.id) then
    return v_base || jsonb_build_object('decision', 'INELIGIBLE', 'reason_code', 'MARKETING_CAMPAIGN_RECURRING_DISCOUNTED_RENTAL_DISABLED');
  end if;
  return v_base || jsonb_build_object('decision', 'ELIGIBLE', 'reason_code', 'MARKETING_CAMPAIGN_ELIGIBLE');
end;
$function$;

-- 90 days without a rental, anchored on the customer.
create or replace function public.service_evaluate_marketing_campaign_customer_eligibility(
  p_campaign_id uuid,
  p_customer_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $function$
declare
  v_campaign public.marketing_campaigns%rowtype;
  v_version public.marketing_campaign_versions%rowtype;
  v_customer public.customers%rowtype;
  v_days integer;
  v_last_rental_at timestamptz;
  v_base jsonb;
begin
  if p_campaign_id is null or p_customer_id is null then
    return jsonb_build_object('decision', 'INELIGIBLE', 'reason_code', 'MARKETING_CAMPAIGN_INPUT_REQUIRED');
  end if;

  select * into v_campaign from public.marketing_campaigns where id = p_campaign_id;
  if not found then
    return jsonb_build_object('decision', 'INELIGIBLE', 'reason_code', 'MARKETING_CAMPAIGN_NOT_FOUND');
  end if;
  v_base := jsonb_build_object('campaign_id', v_campaign.id, 'tenant_id', v_campaign.tenant_id);

  if not exists (
    select 1 from public.tenants t
    where t.id = v_campaign.tenant_id and t.slug = 'blacksheep' and t.status = 'ACTIVE'
  ) then
    return v_base || jsonb_build_object('decision', 'BLOCKED', 'reason_code', 'MARKETING_CAMPAIGN_SOURCE_TENANT_UNMAPPED');
  end if;
  if v_campaign.state <> 'ACTIVE' then
    return v_base || jsonb_build_object('decision', 'INELIGIBLE', 'reason_code', 'MARKETING_CAMPAIGN_NOT_ACTIVE');
  end if;
  if (v_campaign.starts_at is not null and v_campaign.starts_at > now())
    or (v_campaign.ends_at is not null and v_campaign.ends_at <= now()) then
    return v_base || jsonb_build_object('decision', 'INELIGIBLE', 'reason_code', 'MARKETING_CAMPAIGN_OUTSIDE_WINDOW');
  end if;

  select * into v_version
  from public.marketing_campaign_versions
  where id = v_campaign.active_version_id and campaign_id = v_campaign.id and tenant_id = v_campaign.tenant_id;
  if not found or v_version.publication_status <> 'PUBLISHED' then
    return v_base || jsonb_build_object('decision', 'BLOCKED', 'reason_code', 'MARKETING_CAMPAIGN_ACTIVE_VERSION_INVALID');
  end if;
  v_base := v_base || jsonb_build_object('campaign_version_id', v_version.id);
  if v_version.trigger_kind <> 'INACTIVITY' then
    return v_base || jsonb_build_object('decision', 'INELIGIBLE', 'reason_code', 'MARKETING_CAMPAIGN_TRIGGER_NOT_SUPPORTED');
  end if;

  v_days := case
    when coalesce(v_version.trigger_rules->>'inactivity_days', '') ~ '^[0-9]{1,4}$' then (v_version.trigger_rules->>'inactivity_days')::integer
    when v_version.trigger_rules ? 'inactivity_days' then -1
    else 90
  end;
  if v_days not between 30 and 365 then
    return v_base || jsonb_build_object('decision', 'BLOCKED', 'reason_code', 'MARKETING_CAMPAIGN_TRIGGER_RULES_INVALID');
  end if;

  select * into v_customer from public.customers where id = p_customer_id;
  if not found then
    return v_base || jsonb_build_object('decision', 'INELIGIBLE', 'reason_code', 'MARKETING_CAMPAIGN_CUSTOMER_NOT_FOUND');
  end if;
  v_base := v_base || jsonb_build_object('customer_id', v_customer.id, 'inactivity_days', v_days);
  if v_customer.anonymized_at is not null then
    return v_base || jsonb_build_object('decision', 'INELIGIBLE', 'reason_code', 'MARKETING_CAMPAIGN_CUSTOMER_ANONYMIZED');
  end if;

  v_last_rental_at := public.marketing_rewards_last_rental_at(v_customer.id);
  if v_last_rental_at is null then
    return v_base || jsonb_build_object('decision', 'INELIGIBLE', 'reason_code', 'MARKETING_CAMPAIGN_CUSTOMER_NEVER_RENTED');
  end if;
  v_base := v_base || jsonb_build_object('last_rental_at', v_last_rental_at);
  if v_last_rental_at > now() - make_interval(days => v_days) then
    return v_base || jsonb_build_object('decision', 'INELIGIBLE', 'reason_code', 'MARKETING_CAMPAIGN_CUSTOMER_RECENTLY_ACTIVE');
  end if;

  -- Someone with a booking ahead has not gone away.
  if exists (
    select 1 from public.appointments a
    where a.primary_customer_id = v_customer.id and not a.is_test
      and a.status in ('HELD', 'AWAITING_PAYMENT', 'CONFIRMED') and a.end_at > now()
  ) or exists (
    select 1 from public.legacy_amelia_bookings l
    where l.matched_customer_id = v_customer.id and l.status_raw = 'Aprovado' and coalesce(l.end_at, l.start_at) > now()
  ) then
    return v_base || jsonb_build_object('decision', 'INELIGIBLE', 'reason_code', 'MARKETING_CAMPAIGN_CUSTOMER_HAS_UPCOMING_BOOKING');
  end if;

  -- One come-back coupon per absence: a new rental starts a new absence.
  if exists (
    select 1 from public.marketing_campaign_issuances i
    where i.campaign_id = v_campaign.id and i.customer_id = v_customer.id and i.issued_at > v_last_rental_at
  ) then
    return v_base || jsonb_build_object('decision', 'INELIGIBLE', 'reason_code', 'MARKETING_CAMPAIGN_CUSTOMER_ALREADY_ISSUED');
  end if;

  return v_base || jsonb_build_object('decision', 'ELIGIBLE', 'reason_code', 'MARKETING_CAMPAIGN_ELIGIBLE');
end;
$function$;

-- Who would receive the campaign's coupon right now. Read-only: a future job
-- would pass these to the issuance functions; nothing calls it while frozen.
create or replace function public.service_list_marketing_campaign_candidates(
  p_campaign_id uuid,
  p_limit integer default 200
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $function$
declare
  v_trigger text;
  v_limit integer := least(greatest(coalesce(p_limit, 200), 1), 1000);
  v_result jsonb := '[]'::jsonb;
  v_decision jsonb;
  v_row record;
begin
  select v.trigger_kind into v_trigger
  from public.marketing_campaigns c
  join public.marketing_campaign_versions v on v.id = c.active_version_id
  where c.id = p_campaign_id;
  if v_trigger is null then
    return v_result;
  end if;

  if v_trigger = 'INACTIVITY' then
    for v_row in
      select distinct x.customer_id from (
        select a.primary_customer_id as customer_id
        from public.appointments a
        where a.primary_customer_id is not null and not a.is_test
        union
        select l.matched_customer_id
        from public.legacy_amelia_bookings l
        where l.matched_customer_id is not null and l.status_raw = 'Aprovado'
      ) x
    loop
      v_decision := public.service_evaluate_marketing_campaign_customer_eligibility(p_campaign_id, v_row.customer_id);
      if v_decision->>'decision' = 'ELIGIBLE' then
        v_result := v_result || jsonb_build_array(jsonb_build_object(
          'customer_id', v_row.customer_id, 'last_rental_at', v_decision->'last_rental_at'));
        exit when jsonb_array_length(v_result) >= v_limit;
      end if;
    end loop;
  elsif v_trigger in ('RENTAL_COMPLETED_FINANCIALLY_CLEARED', 'FREE_VISIT_COMPLETED') then
    for v_row in
      select a.id, a.primary_customer_id
      from public.appointments a
      where a.primary_customer_id is not null and not a.is_test
        and (a.status = 'COMPLETED' or (a.status = 'CONFIRMED' and a.end_at <= now()))
        and not exists (
          select 1 from public.marketing_campaign_issuances i
          where i.campaign_id = p_campaign_id and i.source_appointment_id = a.id
        )
      order by a.end_at desc
    loop
      v_decision := public.service_evaluate_marketing_campaign_eligibility(p_campaign_id, v_row.id);
      if v_decision->>'decision' = 'ELIGIBLE' then
        v_result := v_result || jsonb_build_array(jsonb_build_object(
          'customer_id', v_row.primary_customer_id, 'source_appointment_id', v_row.id));
        exit when jsonb_array_length(v_result) >= v_limit;
      end if;
    end loop;
  end if;
  return v_result;
end;
$function$;

-- Coupon for a customer-anchored trigger (INACTIVITY), mirroring the S4
-- appointment issuance: same coupon shape, version link and audit envelope.
create or replace function public.service_issue_marketing_campaign_customer_coupon(
  p_campaign_id uuid,
  p_customer_id uuid,
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
    or p_customer_id is null
    or length(btrim(coalesce(p_idempotency_key, ''))) not between 8 and 256 then
    raise exception using errcode = '22023', message = 'MARKETING_CAMPAIGN_ISSUANCE_INPUT_INVALID';
  end if;

  select i.* into v_existing_issuance
  from public.marketing_campaign_issuances i
  where i.campaign_id = p_campaign_id and i.idempotency_key = btrim(p_idempotency_key)
  for update of i;
  if found then
    if v_existing_issuance.customer_id <> p_customer_id or v_existing_issuance.source_appointment_id is not null then
      raise exception using errcode = '22023', message = 'MARKETING_CAMPAIGN_ISSUANCE_IDEMPOTENCY_KEY_REUSED';
    end if;
    select * into v_existing_coupon from public.coupons where id = v_existing_issuance.coupon_id;
    return jsonb_build_object(
      'coupon_id', v_existing_coupon.id,
      'coupon_code', v_existing_coupon.code,
      'campaign_id', v_existing_issuance.campaign_id,
      'campaign_version_id', v_existing_issuance.campaign_version_id,
      'customer_id', v_existing_issuance.customer_id,
      'replayed', true
    );
  end if;

  perform 1 from public.marketing_campaigns where id = p_campaign_id for update;
  perform 1 from public.customers where id = p_customer_id for update;

  v_eligibility := public.service_evaluate_marketing_campaign_customer_eligibility(p_campaign_id, p_customer_id);
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
  if not exists (select 1 from public.marketing_campaign_version_services s where s.campaign_version_id = v_version.id) then
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
    'PROMOTION', p_customer_id, null,
    v_version.max_uses, v_version.max_uses_per_customer, 0, v_version.discount_scope
  ) returning id into v_coupon_id;

  insert into public.coupon_services(coupon_id, service_id)
  select v_coupon_id, s.service_id
  from public.marketing_campaign_version_services s
  where s.campaign_version_id = v_version.id;

  insert into public.marketing_campaign_issuances(
    tenant_id, campaign_id, campaign_version_id, coupon_id, customer_id, source_appointment_id, idempotency_key
  ) values (
    (v_eligibility->>'tenant_id')::uuid, p_campaign_id, v_version.id, v_coupon_id, p_customer_id, null, btrim(p_idempotency_key)
  );

  insert into public.marketing_campaign_audit_events(
    tenant_id, campaign_id, actor_admin_id, event_kind, after_snapshot
  ) values (
    (v_eligibility->>'tenant_id')::uuid, p_campaign_id, v_version.published_by_admin_id, 'ISSUANCE_LINKED',
    jsonb_build_object(
      'coupon_id', v_coupon_id,
      'campaign_version_id', v_version.id,
      'customer_id', p_customer_id,
      'last_rental_at', v_eligibility->'last_rental_at'
    )
  );

  return jsonb_build_object(
    'coupon_id', v_coupon_id,
    'coupon_code', v_coupon_code,
    'campaign_id', p_campaign_id,
    'campaign_version_id', v_version.id,
    'customer_id', p_customer_id,
    'replayed', false
  );
end;
$function$;

revoke all on function public.marketing_rewards_source_kind(uuid) from public, anon, authenticated;
grant execute on function public.marketing_rewards_source_kind(uuid) to service_role;
revoke all on function public.marketing_rewards_last_rental_at(uuid) from public, anon, authenticated;
grant execute on function public.marketing_rewards_last_rental_at(uuid) to service_role;
revoke all on function public.service_evaluate_marketing_campaign_eligibility(uuid,uuid) from public, anon, authenticated;
grant execute on function public.service_evaluate_marketing_campaign_eligibility(uuid,uuid) to service_role;
revoke all on function public.service_evaluate_marketing_campaign_customer_eligibility(uuid,uuid) from public, anon, authenticated;
grant execute on function public.service_evaluate_marketing_campaign_customer_eligibility(uuid,uuid) to service_role;
revoke all on function public.service_list_marketing_campaign_candidates(uuid,integer) from public, anon, authenticated;
grant execute on function public.service_list_marketing_campaign_candidates(uuid,integer) to service_role;
revoke all on function public.service_issue_marketing_campaign_customer_coupon(uuid,uuid,text) from public, anon, authenticated;
grant execute on function public.service_issue_marketing_campaign_customer_coupon(uuid,uuid,text) to service_role;

comment on function public.service_evaluate_marketing_campaign_eligibility(uuid,uuid) is
  'Rewards read-only eligibility for reservation-anchored triggers: rental (realized and paid) and free visit (realized, customer never rented). Realized = COMPLETED or CONFIRMED with end in the past; unsnapshotted reservations use the current service.';
comment on function public.service_evaluate_marketing_campaign_customer_eligibility(uuid,uuid) is
  'Rewards read-only eligibility for INACTIVITY: last realized BlackSheep rental (Agenda or linked Amelia history) at least trigger_rules.inactivity_days ago (default 90), no booking ahead, one coupon per absence.';
comment on function public.service_list_marketing_campaign_candidates(uuid,integer) is
  'Rewards read-only candidate list for a campaign: customers (and source reservations) eligible now. No job calls it while Rewards stays frozen.';
comment on function public.service_issue_marketing_campaign_customer_coupon(uuid,uuid,text) is
  'Rewards customer-anchored issuance for INACTIVITY, mirroring S4. Service-only; not called by any job while Rewards stays frozen.';
