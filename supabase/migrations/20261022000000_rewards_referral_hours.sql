-- Referral program pays in studio hours (decisions of 2026-10-21):
--   * when a referred friend's first rental is realized and paid, the referrer earns a free
--     hour package ("brinde Rewards"): 60 minutes by default, valid 180 days, any time of day,
--     no special-period surcharge, zero purchase value (no revenue is recognised);
--   * no monthly limit when the campaign's monthly_cap is null;
--   * the issuance ledger records either a coupon or an hour package.
-- The package is a regular hour package: it pays a whole reservation at checkout, like a
-- purchased one. Nothing here sends a message.

alter table public.hour_packages
  add column if not exists origin text not null default 'PURCHASE',
  add column if not exists marketing_campaign_id uuid null references public.marketing_campaigns(id) on delete restrict,
  add column if not exists source_appointment_id uuid null references public.appointments(id) on delete restrict;
alter table public.hour_packages
  drop constraint if exists hour_packages_origin_check;
alter table public.hour_packages
  add constraint hour_packages_origin_check check (origin in ('PURCHASE','REWARDS'));
alter table public.hour_packages
  drop constraint if exists hour_packages_purchased_value_check;
alter table public.hour_packages
  add constraint hour_packages_purchased_value_check check (
    (origin = 'PURCHASE' and purchased_value > 0)
    or (origin = 'REWARDS' and purchased_value = 0 and marketing_campaign_id is not null and source_appointment_id is not null)
  );
create unique index if not exists hour_packages_rewards_source_uq
  on public.hour_packages (marketing_campaign_id, source_appointment_id)
  where origin = 'REWARDS';

-- A free hour has no reference value: checkout reservations and usage accept zero.
alter table public.checkout_hour_package_reservations
  drop constraint if exists checkout_hour_package_reserv_package_reference_minute_val_check;
alter table public.checkout_hour_package_reservations
  add constraint checkout_hour_package_reserv_package_reference_minute_val_check check (package_reference_minute_value >= 0);
alter table public.appointment_package_usage
  drop constraint if exists appointment_package_usage_package_reference_minute_value_check;
alter table public.appointment_package_usage
  add constraint appointment_package_usage_package_reference_minute_value_check check (package_reference_minute_value >= 0);

alter table public.marketing_campaign_issuances
  alter column coupon_id drop not null,
  add column if not exists hour_package_id uuid null unique references public.hour_packages(id) on delete restrict;
alter table public.marketing_campaign_issuances
  drop constraint if exists marketing_campaign_issuance_one_reward;
alter table public.marketing_campaign_issuances
  add constraint marketing_campaign_issuance_one_reward check ((coupon_id is null) <> (hour_package_id is null));

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
    -- monthly_cap null means no limit (decision of 2026-10-21); absent keeps the old default of 5.
    v_cap := case
      when v_version.trigger_rules->'monthly_cap' = 'null'::jsonb then null
      when coalesce(v_version.trigger_rules->>'monthly_cap', '') ~ '^[0-9]{1,3}$' then (v_version.trigger_rules->>'monthly_cap')::integer
      when v_version.trigger_rules ? 'monthly_cap' then -1
      else 5
    end;
    if v_cap is not null and v_cap not between 1 and 50 then
      return v_base || jsonb_build_object('decision', 'BLOCKED', 'reason_code', 'MARKETING_CAMPAIGN_TRIGGER_RULES_INVALID');
    end if;
    if v_cap is not null and (
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

create or replace function public.service_issue_marketing_referral_hours(
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
  v_existing public.marketing_campaign_issuances%rowtype;
  v_package public.hour_packages%rowtype;
  v_eligibility jsonb;
  v_version public.marketing_campaign_versions%rowtype;
  v_campaign public.marketing_campaigns%rowtype;
  v_minutes integer;
  v_days integer;
begin
  if p_campaign_id is null or p_source_appointment_id is null
    or length(btrim(coalesce(p_idempotency_key, ''))) not between 8 and 256 then
    raise exception using errcode = '22023', message = 'MARKETING_CAMPAIGN_ISSUANCE_INPUT_INVALID';
  end if;

  select * into v_existing from public.marketing_campaign_issuances i
  where i.campaign_id = p_campaign_id and i.idempotency_key = btrim(p_idempotency_key)
  for update of i;
  if found then
    if v_existing.source_appointment_id is distinct from p_source_appointment_id or v_existing.hour_package_id is null then
      raise exception using errcode = '22023', message = 'MARKETING_CAMPAIGN_ISSUANCE_IDEMPOTENCY_KEY_REUSED';
    end if;
    select * into v_package from public.hour_packages where id = v_existing.hour_package_id;
    return jsonb_build_object('hour_package_id', v_package.id, 'customer_id', v_package.customer_id,
      'minutes', v_package.total_minutes, 'valid_until', v_package.valid_until, 'replayed', true);
  end if;

  perform 1 from public.marketing_campaigns where id = p_campaign_id for update;
  perform 1 from public.appointments where id = p_source_appointment_id for update;

  v_eligibility := public.service_evaluate_marketing_campaign_eligibility(p_campaign_id, p_source_appointment_id);
  if v_eligibility->>'decision' <> 'ELIGIBLE' then
    raise exception using errcode = 'P0001', message = 'MARKETING_CAMPAIGN_ISSUANCE_INELIGIBLE',
      detail = coalesce(v_eligibility->>'reason_code', 'MARKETING_CAMPAIGN_ELIGIBILITY_INVALID');
  end if;

  select * into v_campaign from public.marketing_campaigns where id = p_campaign_id;
  select * into v_version from public.marketing_campaign_versions
  where id = (v_eligibility->>'campaign_version_id')::uuid and campaign_id = p_campaign_id;
  if not found or v_version.trigger_kind <> 'REFERRAL_FIRST_RENTAL'
    or coalesce(v_version.trigger_rules->>'referrer_reward', 'COUPON') <> 'HOURS' then
    raise exception using errcode = 'P0001', message = 'MARKETING_CAMPAIGN_REWARD_NOT_HOURS';
  end if;
  v_minutes := coalesce(nullif(v_version.trigger_rules->>'referrer_reward_minutes', '')::integer, 60);
  v_days := coalesce(nullif(v_version.trigger_rules->>'referrer_reward_validity_days', '')::integer, 180);
  if v_minutes not between 15 and 600 or v_days not between 1 and 3650 then
    raise exception using errcode = '22023', message = 'MARKETING_CAMPAIGN_TRIGGER_RULES_INVALID';
  end if;

  insert into public.hour_packages(
    customer_id, name, total_minutes, purchased_value, valid_from, valid_until, status,
    special_surcharge_percent, standard_start_local_time, standard_end_local_time, notes,
    created_by_admin_id, origin, marketing_campaign_id, source_appointment_id
  ) values (
    (v_eligibility->>'customer_id')::uuid, 'Rewards · Indicação', v_minutes, 0, now(), now() + make_interval(days => v_days), 'ACTIVE',
    0, time '00:00', time '23:59:59', 'Brinde do programa de indicação ' || v_campaign.internal_name,
    v_version.published_by_admin_id, 'REWARDS', p_campaign_id, p_source_appointment_id
  ) returning * into v_package;

  insert into public.hour_package_services(hour_package_id, service_id)
  select v_package.id, s.service_id from public.marketing_campaign_version_services s where s.campaign_version_id = v_version.id;

  insert into public.marketing_campaign_issuances(
    tenant_id, campaign_id, campaign_version_id, coupon_id, hour_package_id, customer_id, source_appointment_id, idempotency_key
  ) values (
    v_campaign.tenant_id, p_campaign_id, v_version.id, null, v_package.id, v_package.customer_id, p_source_appointment_id, btrim(p_idempotency_key)
  );
  insert into public.marketing_campaign_audit_events(
    tenant_id, campaign_id, actor_admin_id, event_kind, after_snapshot
  ) values (
    v_campaign.tenant_id, p_campaign_id, v_version.published_by_admin_id, 'ISSUANCE_LINKED',
    jsonb_build_object('hour_package_id', v_package.id, 'customer_id', v_package.customer_id,
      'source_appointment_id', p_source_appointment_id, 'minutes', v_minutes, 'valid_until', v_package.valid_until)
  );
  return jsonb_build_object('hour_package_id', v_package.id, 'customer_id', v_package.customer_id,
    'minutes', v_minutes, 'valid_until', v_package.valid_until, 'replayed', false);
end;
$function$;

revoke all on function public.service_issue_marketing_referral_hours(uuid,uuid,text) from public, anon, authenticated;
grant execute on function public.service_issue_marketing_referral_hours(uuid,uuid,text) to service_role;
comment on function public.service_issue_marketing_referral_hours(uuid,uuid,text) is
  'Service-only: from a realized and paid referred first rental, gives the referrer a free REWARDS hour package once (S4 rules, monthly cap optional).';

-- The referral reward message joins the scheduled path of the coupon message.
alter table public.notification_template_configs
  drop constraint if exists notification_template_configs_whatsapp_dispatchable_events;
alter table public.notification_template_configs
  add constraint notification_template_configs_whatsapp_dispatchable_events
  check (
    channel <> 'WHATSAPP'
    or is_active = false
    or event_key in ('APPOINTMENT_APPROVED', 'APPOINTMENT_RESCHEDULED', 'APPOINTMENT_CANCELLED', 'APPOINTMENT_REMINDER', 'RENTAL_BALANCE_DUE',
      'REWARDS_COUPON_ISSUED', 'REWARDS_REFERRAL_REWARD')
  );
alter table public.notification_template_configs
  drop constraint if exists notification_template_configs_rewards_schedule;
alter table public.notification_template_configs
  add constraint notification_template_configs_rewards_schedule
  check (
    event_key not like 'REWARDS\_%'
    or schedule_mode = 'IMMEDIATE'
    or (event_key in ('REWARDS_COUPON_ISSUED', 'REWARDS_REFERRAL_REWARD') and schedule_mode = 'AFTER_END')
  );

create or replace function public.enqueue_rewards_coupon_after_payment()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
begin
  if new.financial_status is distinct from 'PAID'
    or old.financial_status is not distinct from 'PAID'
    or new.status not in ('CONFIRMED','COMPLETED')
    or new.core_end_at > now()
    or new.core_end_at <= now() - interval '7 days' then
    return new;
  end if;

  insert into public.integration_jobs(job_type,entity_type,entity_id,entity_version,payload_json,run_after,idempotency_key)
  select 'APPOINTMENT_SCHEDULED_MESSAGE','APPOINTMENT',new.id,new.version,
    jsonb_build_object('event_key',t.event_key,'channel','WHATSAPP','template_id',t.id::text,
      'schedule_key',t.id::text || ':' || new.version::text || ':' || t.schedule_mode || ':' || t.schedule_offset_minutes::text,
      'reason','PAID'),
    greatest(now(), new.core_end_at + make_interval(mins => t.schedule_offset_minutes)),
    'rewards-paid:' || t.id::text || ':' || new.id::text
  from public.notification_template_configs t
  join public.services s on s.id = new.service_id and s.operation_scope = 'BLACKSHEEP'
  where t.event_key in ('REWARDS_COUPON_ISSUED', 'REWARDS_REFERRAL_REWARD')
    and t.channel = 'WHATSAPP'
    and t.schedule_mode = 'AFTER_END'
  on conflict (idempotency_key) do nothing;
  return new;
end;
$function$;
