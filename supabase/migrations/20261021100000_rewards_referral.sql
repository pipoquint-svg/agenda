-- Rewards engine, slice 2: referral program (owner decision 2026-10-20, both sides win).
-- 1. A customer who has rented gets a personal referral code to share.
-- 2. A friend who never rented uses it and gets a discount on the first rental.
-- 3. When that first rental is realized and paid, the referrer earns a coupon.
-- Guards: the code only works for someone who never rented (Agenda or Amelia),
-- never for the referrer (same customer, e-mail, phone or CPF/CNPJ), and the
-- referrer's rewards are capped per month (trigger_rules.monthly_cap, 1-50, default 5).
-- Nothing creates codes, issues coupons or sends messages on its own while
-- Rewards stays frozen; the checkout rule only affects referral coupons.

alter table public.marketing_campaign_versions
  drop constraint marketing_campaign_versions_trigger_kind_check;

alter table public.marketing_campaign_versions
  add constraint marketing_campaign_versions_trigger_kind_check
  check (trigger_kind in (
    'RENTAL_COMPLETED_FINANCIALLY_CLEARED','BIRTHDAY','FIRST_RENTAL',
    'INACTIVITY','BOOKING_CONFIRMED','MANUAL','CUSTOM','FREE_VISIT_COMPLETED','REFERRAL_FIRST_RENTAL'
  ));

alter table public.marketing_campaign_audit_events
  drop constraint marketing_campaign_audit_events_event_kind_check;

alter table public.marketing_campaign_audit_events
  add constraint marketing_campaign_audit_events_event_kind_check
  check (event_kind in (
    'CREATED','VERSION_CREATED','SCHEDULED','ACTIVATED','PAUSED','RESUMED','ENDED','ARCHIVED',
    'ISSUANCE_LINKED','REVOKED','REFERRAL_CODE_CREATED'
  ));

-- One personal code per referrer and referral campaign. The code is a shareable
-- coupon (no customer binding) restricted at checkout to first-time customers.
create table public.marketing_referral_codes (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  campaign_id uuid not null,
  referrer_customer_id uuid not null references public.customers(id) on delete restrict,
  coupon_id uuid not null unique references public.coupons(id) on delete restrict,
  code text not null unique check (code ~ '^IND-[A-Z0-9]{6}$'),
  created_at timestamptz not null default now(),
  constraint marketing_referral_code_campaign_fk
    foreign key (campaign_id, tenant_id) references public.marketing_campaigns(id, tenant_id) on delete restrict,
  constraint marketing_referral_code_referrer_unique unique (campaign_id, referrer_customer_id)
);

alter table public.marketing_referral_codes enable row level security;
revoke all on public.marketing_referral_codes from public, anon, authenticated, service_role;
grant select on public.marketing_referral_codes to service_role;

comment on table public.marketing_referral_codes is
  'Rewards referral codes: one shareable coupon per referrer and campaign, written only by service_ensure_marketing_referral_code.';

-- Same person behind two customer records: same id, e-mail, phone (last 11 digits) or CPF/CNPJ digits.
create or replace function public.marketing_referral_same_person(p_left uuid, p_right uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $function$
  select p_left = p_right or exists (
    select 1 from public.customers l, public.customers r
    where l.id = p_left and r.id = p_right and (
      (nullif(lower(btrim(l.email)), '') is not null and lower(btrim(l.email)) = lower(btrim(r.email)))
      or (nullif(right(regexp_replace(coalesce(l.phone, ''), '\D', '', 'g'), 11), '') is not null
          and right(regexp_replace(coalesce(l.phone, ''), '\D', '', 'g'), 11) = right(regexp_replace(coalesce(r.phone, ''), '\D', '', 'g'), 11))
      or (nullif(regexp_replace(coalesce(l.cpf_cnpj, ''), '\D', '', 'g'), '') is not null
          and regexp_replace(coalesce(l.cpf_cnpj, ''), '\D', '', 'g') = regexp_replace(coalesce(r.cpf_cnpj, ''), '\D', '', 'g'))
    )
  )
$function$;

-- Why a referral coupon cannot be used by this customer (null when it can, or
-- when the coupon is not a referral code). Called by both checkout guards.
create or replace function public.coupon_referral_violation(p_coupon_id uuid, p_customer_id uuid, p_appointment_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $function$
declare
  v_referral public.marketing_referral_codes%rowtype;
begin
  select * into v_referral from public.marketing_referral_codes where coupon_id = p_coupon_id;
  if not found then return null; end if;
  if p_customer_id is null then return 'COUPON_CUSTOMER_REQUIRED'; end if;
  if public.marketing_referral_same_person(v_referral.referrer_customer_id, p_customer_id) then
    return 'COUPON_REFERRAL_SELF';
  end if;
  -- Any other rental (done, booked or being paid), in the Agenda or in Amelia,
  -- means this is not a first rental. The reservation using the code is excluded.
  if exists (
      select 1 from public.appointments a
      where a.primary_customer_id = p_customer_id and not a.is_test
        and a.id is distinct from p_appointment_id
        and a.status in ('HELD', 'AWAITING_PAYMENT', 'CONFIRMED', 'COMPLETED')
        and public.marketing_rewards_source_kind(a.id) = 'RENTAL'
    ) or exists (
      select 1 from public.legacy_amelia_bookings l
      where l.matched_customer_id = p_customer_id and l.status_raw = 'Aprovado'
        and coalesce(l.service_name, '') ilike '%loca%'
    ) then
    return 'COUPON_REFERRAL_NOT_FIRST_RENTAL';
  end if;
  return null;
end;
$function$;

-- Checkout guards (S0.5 definitions) now also apply the referral rule.
create or replace function public.enforce_coupon_customer_usage_limit()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_limit integer;
  v_customer_id uuid;
  v_used integer;
  v_referral_error text;
begin
  if new.coupon_id is null then return new; end if;
  select c.max_uses_per_customer into v_limit from public.coupons c where c.id = new.coupon_id for update;
  select a.primary_customer_id into v_customer_id from public.appointments a where a.id = new.appointment_id;
  v_referral_error := public.coupon_referral_violation(new.coupon_id, v_customer_id, new.appointment_id);
  if v_referral_error is not null then raise exception using errcode='P0001', message=v_referral_error; end if;
  if v_limit is null then return new; end if;
  if v_customer_id is null then raise exception using errcode='P0001', message='COUPON_CUSTOMER_REQUIRED'; end if;
  select count(*)::integer into v_used
  from public.appointment_discounts ad
  join public.appointments a on a.id = ad.appointment_id
  where ad.coupon_id = new.coupon_id
    and a.primary_customer_id = v_customer_id
    and public.coupon_redemption_status(ad.released_at, ad.redeemed_at, a.status) <> 'RELEASED';
  if v_used >= v_limit then raise exception using errcode='P0001', message='COUPON_CUSTOMER_USAGE_LIMIT_REACHED'; end if;
  return new;
end;
$$;

create or replace function public.enforce_checkout_coupon_customer()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_coupon public.coupons%rowtype;
  v_used integer;
  v_referral_error text;
begin
  if new.applied_coupon_id is null or new.primary_customer_id is null then return new; end if;
  select * into v_coupon from public.coupons where id = new.applied_coupon_id for update;
  if not found or not v_coupon.is_active or (v_coupon.valid_from is not null and now() < v_coupon.valid_from) or (v_coupon.valid_until is not null and now() > v_coupon.valid_until) then raise exception using errcode='P0001', message='INVALID_COUPON'; end if;
  if v_coupon.customer_id is not null and v_coupon.customer_id <> new.primary_customer_id then raise exception using errcode='P0001', message='COUPON_CUSTOMER_MISMATCH'; end if;
  v_referral_error := public.coupon_referral_violation(v_coupon.id, new.primary_customer_id, null);
  if v_referral_error is not null then raise exception using errcode='P0001', message=v_referral_error; end if;
  if v_coupon.max_uses is not null and v_coupon.used_count >= v_coupon.max_uses then raise exception using errcode='P0001', message='COUPON_USAGE_LIMIT_REACHED'; end if;
  if v_coupon.max_uses_per_customer is not null then
    select count(*)::integer into v_used
    from public.appointment_discounts ad
    join public.appointments a on a.id = ad.appointment_id
    where ad.coupon_id = v_coupon.id
      and a.primary_customer_id = new.primary_customer_id
      and public.coupon_redemption_status(ad.released_at, ad.redeemed_at, a.status) <> 'RELEASED';
    if v_used >= v_coupon.max_uses_per_customer then raise exception using errcode='P0001', message='COUPON_CUSTOMER_USAGE_LIMIT_REACHED'; end if;
  end if;
  return new;
end;
$$;

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
  v_referral public.marketing_referral_codes%rowtype;
  v_cap integer;
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

  if v_version.trigger_kind not in ('RENTAL_COMPLETED_FINANCIALLY_CLEARED', 'FREE_VISIT_COMPLETED', 'REFERRAL_FIRST_RENTAL') then
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

  if v_version.trigger_kind = 'REFERRAL_FIRST_RENTAL' then
    -- The source is the referred friend's first rental; the reward goes to the referrer.
    if v_kind <> 'RENTAL' then
      return v_base || jsonb_build_object('decision', 'INELIGIBLE', 'reason_code', 'MARKETING_CAMPAIGN_SOURCE_NOT_BLACKSHEEP_RENTAL');
    end if;
    if v_appointment.primary_customer_id is null then
      return v_base || jsonb_build_object('decision', 'BLOCKED', 'reason_code', 'MARKETING_CAMPAIGN_SOURCE_CUSTOMER_REQUIRED');
    end if;
    if v_appointment.is_test then
      return v_base || jsonb_build_object('decision', 'INELIGIBLE', 'reason_code', 'MARKETING_CAMPAIGN_SOURCE_IS_TEST');
    end if;
    select r.* into v_referral
    from public.appointment_discounts d
    join public.marketing_referral_codes r on r.coupon_id = d.coupon_id
    where d.appointment_id = v_appointment.id and r.campaign_id = v_campaign.id and d.released_at is null
    limit 1;
    if not found then
      return v_base || jsonb_build_object('decision', 'INELIGIBLE', 'reason_code', 'MARKETING_CAMPAIGN_SOURCE_NOT_REFERRED');
    end if;
    v_base := v_base || jsonb_build_object('customer_id', v_referral.referrer_customer_id, 'referred_customer_id', v_appointment.primary_customer_id);
    if not v_realized then
      return v_base || jsonb_build_object('decision', 'INELIGIBLE', 'reason_code', 'MARKETING_CAMPAIGN_SOURCE_NOT_COMPLETED');
    end if;
    if v_appointment.financial_status <> 'PAID' then
      return v_base || jsonb_build_object('decision', 'INELIGIBLE', 'reason_code', 'MARKETING_CAMPAIGN_SOURCE_NOT_FINANCIALLY_CLEARED');
    end if;
    if public.marketing_referral_same_person(v_referral.referrer_customer_id, v_appointment.primary_customer_id) then
      return v_base || jsonb_build_object('decision', 'INELIGIBLE', 'reason_code', 'MARKETING_CAMPAIGN_REFERRAL_SELF');
    end if;
    if exists (
      select 1 from public.appointments a2
      where a2.primary_customer_id = v_appointment.primary_customer_id and a2.id <> v_appointment.id and not a2.is_test
        and a2.start_at < v_appointment.start_at
        and (a2.status = 'COMPLETED' or (a2.status = 'CONFIRMED' and a2.end_at <= now()))
        and public.marketing_rewards_source_kind(a2.id) = 'RENTAL'
    ) or exists (
      select 1 from public.legacy_amelia_bookings l
      where l.matched_customer_id = v_appointment.primary_customer_id and l.status_raw = 'Aprovado'
        and coalesce(l.service_name, '') ilike '%loca%' and coalesce(l.end_at, l.start_at) < v_appointment.start_at
    ) then
      return v_base || jsonb_build_object('decision', 'INELIGIBLE', 'reason_code', 'MARKETING_CAMPAIGN_REFERRAL_NOT_FIRST_RENTAL');
    end if;
    if exists (select 1 from public.customers c where c.id = v_referral.referrer_customer_id and c.anonymized_at is not null) then
      return v_base || jsonb_build_object('decision', 'INELIGIBLE', 'reason_code', 'MARKETING_CAMPAIGN_CUSTOMER_ANONYMIZED');
    end if;
    if exists (
      select 1 from public.marketing_campaign_issuances i
      where i.campaign_id = v_campaign.id and i.source_appointment_id = v_appointment.id
    ) then
      return v_base || jsonb_build_object('decision', 'INELIGIBLE', 'reason_code', 'MARKETING_CAMPAIGN_SOURCE_ALREADY_ISSUED');
    end if;
    v_cap := case
      when coalesce(v_version.trigger_rules->>'monthly_cap', '') ~ '^[0-9]{1,3}$' then (v_version.trigger_rules->>'monthly_cap')::integer
      when v_version.trigger_rules ? 'monthly_cap' then -1
      else 5
    end;
    if v_cap not between 1 and 50 then
      return v_base || jsonb_build_object('decision', 'BLOCKED', 'reason_code', 'MARKETING_CAMPAIGN_TRIGGER_RULES_INVALID');
    end if;
    if (
      select count(*) from public.marketing_campaign_issuances i
      where i.campaign_id = v_campaign.id and i.customer_id = v_referral.referrer_customer_id
        and date_trunc('month', i.issued_at at time zone 'America/Sao_Paulo') = date_trunc('month', now() at time zone 'America/Sao_Paulo')
    ) >= v_cap then
      return v_base || jsonb_build_object('decision', 'INELIGIBLE', 'reason_code', 'MARKETING_CAMPAIGN_REFERRAL_MONTHLY_CAP');
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
  elsif v_trigger in ('RENTAL_COMPLETED_FINANCIALLY_CLEARED', 'FREE_VISIT_COMPLETED', 'REFERRAL_FIRST_RENTAL') then
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
          'customer_id', v_decision->'customer_id', 'source_appointment_id', v_row.id));
        exit when jsonb_array_length(v_result) >= v_limit;
      end if;
    end loop;
  end if;
  return v_result;
end;
$function$;

-- The referrer's personal code: created once per campaign, only for a customer
-- who has rented. The friend's discount comes from trigger_rules.
create or replace function public.service_ensure_marketing_referral_code(p_campaign_id uuid, p_customer_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $function$
declare
  v_campaign public.marketing_campaigns%rowtype;
  v_version public.marketing_campaign_versions%rowtype;
  v_existing public.marketing_referral_codes%rowtype;
  v_type text;
  v_value numeric;
  v_code text;
  v_coupon_id uuid;
  v_attempt integer := 0;
  v_alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
begin
  if p_campaign_id is null or p_customer_id is null then
    raise exception using errcode = '22023', message = 'MARKETING_REFERRAL_INPUT_INVALID';
  end if;

  select * into v_existing from public.marketing_referral_codes where campaign_id = p_campaign_id and referrer_customer_id = p_customer_id;
  if found then
    return jsonb_build_object('code', v_existing.code, 'coupon_id', v_existing.coupon_id, 'created', false);
  end if;

  select * into v_campaign from public.marketing_campaigns where id = p_campaign_id for update;
  if not found then raise exception using errcode = 'P0001', message = 'MARKETING_CAMPAIGN_NOT_FOUND'; end if;
  if v_campaign.state <> 'ACTIVE' then raise exception using errcode = 'P0001', message = 'MARKETING_CAMPAIGN_NOT_ACTIVE'; end if;
  select * into v_version from public.marketing_campaign_versions
  where id = v_campaign.active_version_id and campaign_id = v_campaign.id and tenant_id = v_campaign.tenant_id;
  if not found or v_version.publication_status <> 'PUBLISHED' or v_version.trigger_kind <> 'REFERRAL_FIRST_RENTAL' then
    raise exception using errcode = 'P0001', message = 'MARKETING_REFERRAL_CAMPAIGN_INVALID';
  end if;

  v_type := upper(coalesce(v_version.trigger_rules->>'referred_discount_type', ''));
  v_value := case when coalesce(v_version.trigger_rules->>'referred_discount_value', '') ~ '^[0-9]+(\.[0-9]{1,2})?$'
    then (v_version.trigger_rules->>'referred_discount_value')::numeric end;
  if v_type not in ('PERCENT', 'FIXED') or v_value is null or v_value <= 0 or (v_type = 'PERCENT' and v_value > 100) then
    raise exception using errcode = 'P0001', message = 'MARKETING_CAMPAIGN_TRIGGER_RULES_INVALID';
  end if;

  perform 1 from public.customers where id = p_customer_id for update;
  if exists (select 1 from public.customers c where c.id = p_customer_id and c.anonymized_at is not null) then
    raise exception using errcode = 'P0001', message = 'MARKETING_CAMPAIGN_CUSTOMER_ANONYMIZED';
  end if;
  if public.marketing_rewards_last_rental_at(p_customer_id) is null then
    raise exception using errcode = 'P0001', message = 'MARKETING_REFERRAL_REFERRER_NEVER_RENTED';
  end if;

  loop
    v_attempt := v_attempt + 1;
    v_code := 'IND-' || (
      select string_agg(substr(v_alphabet, 1 + floor(random() * length(v_alphabet))::integer, 1), '')
      from generate_series(1, 6)
    );
    exit when not exists (select 1 from public.coupons where upper(code) = v_code);
    if v_attempt >= 20 then raise exception using errcode = 'P0001', message = 'MARKETING_REFERRAL_CODE_UNAVAILABLE'; end if;
  end loop;

  insert into public.coupons(
    code, discount_type, discount_value, valid_from, valid_until, is_active,
    source, customer_id, source_appointment_id, max_uses, max_uses_per_customer, used_count, discount_scope
  ) values (
    v_code, v_type, v_value, now(), v_campaign.ends_at, true,
    'PROMOTION', null, null, null, 1, 0, 'SERVICE_ONLY'
  ) returning id into v_coupon_id;

  insert into public.coupon_services(coupon_id, service_id)
  select v_coupon_id, s.service_id
  from public.marketing_campaign_version_services s
  where s.campaign_version_id = v_version.id;

  insert into public.marketing_referral_codes(tenant_id, campaign_id, referrer_customer_id, coupon_id, code)
  values (v_campaign.tenant_id, v_campaign.id, p_customer_id, v_coupon_id, v_code);

  insert into public.marketing_campaign_audit_events(tenant_id, campaign_id, actor_admin_id, event_kind, after_snapshot)
  values (v_campaign.tenant_id, v_campaign.id, v_version.published_by_admin_id, 'REFERRAL_CODE_CREATED',
          jsonb_build_object('coupon_id', v_coupon_id, 'referrer_customer_id', p_customer_id));

  return jsonb_build_object('code', v_code, 'coupon_id', v_coupon_id, 'created', true);
end;
$function$;

revoke all on function public.marketing_referral_same_person(uuid,uuid) from public, anon, authenticated;
grant execute on function public.marketing_referral_same_person(uuid,uuid) to service_role;
revoke all on function public.coupon_referral_violation(uuid,uuid,uuid) from public, anon, authenticated;
grant execute on function public.coupon_referral_violation(uuid,uuid,uuid) to service_role;
revoke all on function public.service_ensure_marketing_referral_code(uuid,uuid) from public, anon, authenticated;
grant execute on function public.service_ensure_marketing_referral_code(uuid,uuid) to service_role;
revoke all on function public.service_evaluate_marketing_campaign_eligibility(uuid,uuid) from public, anon, authenticated;
grant execute on function public.service_evaluate_marketing_campaign_eligibility(uuid,uuid) to service_role;
revoke all on function public.service_list_marketing_campaign_candidates(uuid,integer) from public, anon, authenticated;
grant execute on function public.service_list_marketing_campaign_candidates(uuid,integer) to service_role;

comment on function public.service_ensure_marketing_referral_code(uuid,uuid) is
  'Rewards referral: the referrer''s personal shareable code (one per campaign), only for a customer who has rented. Service-only; no job calls it while Rewards stays frozen.';
comment on function public.coupon_referral_violation(uuid,uuid,uuid) is
  'Checkout guard for referral coupons: never the referrer (same person), only someone who never rented.';
