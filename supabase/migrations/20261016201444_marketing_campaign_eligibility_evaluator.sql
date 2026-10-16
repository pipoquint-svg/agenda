-- BlackSheep Rewards S3: deterministic, read-only eligibility evaluation.
-- No coupon, message, job, checkout, campaign state, or appointment state is
-- created or changed here. S4 alone may turn an ELIGIBLE response into an
-- idempotent issuance.
--
-- Appointments predate the tenant foundation. Until appointment ownership is
-- migrated, only the canonical `blacksheep` tenant may evaluate a source
-- appointment, and only when its service is explicitly BLACKSHEEP rental.

alter table public.appointments
  add column rewards_source_operation_scope_snapshot text,
  add column rewards_source_service_type_key_snapshot text,
  add constraint appointments_rewards_source_operation_scope_snapshot_check
    check (rewards_source_operation_scope_snapshot is null or rewards_source_operation_scope_snapshot in ('BLACKSHEEP','SABRINA')),
  add constraint appointments_rewards_source_service_type_key_snapshot_check
    check (rewards_source_service_type_key_snapshot is null or rewards_source_service_type_key_snapshot = upper(btrim(rewards_source_service_type_key_snapshot)));

create or replace function public.trg_appointment_capture_rewards_source_snapshot()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_operation_scope text;
  v_service_type_key text;
begin
  select s.operation_scope, st.key
    into v_operation_scope, v_service_type_key
  from public.services s
  left join public.service_type st on st.id = s.service_type_id
  where s.id = new.service_id;

  if not found then
    raise exception using errcode = 'P0001', message = 'REWARDS_SOURCE_SERVICE_NOT_FOUND';
  end if;

  new.rewards_source_operation_scope_snapshot := v_operation_scope;
  new.rewards_source_service_type_key_snapshot := v_service_type_key;
  return new;
end;
$function$;

create trigger appointments_capture_rewards_source_snapshot
before insert or update of service_id on public.appointments
for each row execute function public.trg_appointment_capture_rewards_source_snapshot();

revoke all on function public.trg_appointment_capture_rewards_source_snapshot()
  from public, anon, authenticated, service_role;

create or replace function public.trg_appointment_guard_rewards_source_snapshot()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
begin
  if new.service_id is not distinct from old.service_id
    and (
      new.rewards_source_operation_scope_snapshot is distinct from old.rewards_source_operation_scope_snapshot
      or new.rewards_source_service_type_key_snapshot is distinct from old.rewards_source_service_type_key_snapshot
    ) then
    raise exception using errcode = 'P0001', message = 'MARKETING_CAMPAIGN_SOURCE_SNAPSHOT_IMMUTABLE';
  end if;
  return new;
end;
$function$;

create trigger appointments_guard_rewards_source_snapshot
before update of rewards_source_operation_scope_snapshot, rewards_source_service_type_key_snapshot, service_id on public.appointments
for each row execute function public.trg_appointment_guard_rewards_source_snapshot();

revoke all on function public.trg_appointment_guard_rewards_source_snapshot()
  from public, anon, authenticated, service_role;

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
begin
  if p_campaign_id is null or p_source_appointment_id is null then
    return jsonb_build_object(
      'decision', 'INELIGIBLE',
      'reason_code', 'MARKETING_CAMPAIGN_INPUT_REQUIRED'
    );
  end if;

  select * into v_campaign
  from public.marketing_campaigns
  where id = p_campaign_id;

  if not found then
    return jsonb_build_object(
      'decision', 'INELIGIBLE',
      'reason_code', 'MARKETING_CAMPAIGN_NOT_FOUND'
    );
  end if;

  if not exists (
    select 1 from public.tenants t
    where t.id = v_campaign.tenant_id
      and t.slug = 'blacksheep'
      and t.status = 'ACTIVE'
  ) then
    return jsonb_build_object(
      'decision', 'BLOCKED',
      'reason_code', 'MARKETING_CAMPAIGN_SOURCE_TENANT_UNMAPPED',
      'campaign_id', v_campaign.id,
      'tenant_id', v_campaign.tenant_id
    );
  end if;

  if v_campaign.state <> 'ACTIVE' then
    return jsonb_build_object(
      'decision', 'INELIGIBLE',
      'reason_code', 'MARKETING_CAMPAIGN_NOT_ACTIVE',
      'campaign_id', v_campaign.id,
      'tenant_id', v_campaign.tenant_id
    );
  end if;

  if (v_campaign.starts_at is not null and v_campaign.starts_at > now())
    or (v_campaign.ends_at is not null and v_campaign.ends_at <= now()) then
    return jsonb_build_object(
      'decision', 'INELIGIBLE',
      'reason_code', 'MARKETING_CAMPAIGN_OUTSIDE_WINDOW',
      'campaign_id', v_campaign.id,
      'tenant_id', v_campaign.tenant_id
    );
  end if;

  select * into v_version
  from public.marketing_campaign_versions
  where id = v_campaign.active_version_id
    and campaign_id = v_campaign.id
    and tenant_id = v_campaign.tenant_id;

  if not found or v_version.publication_status <> 'PUBLISHED' then
    return jsonb_build_object(
      'decision', 'BLOCKED',
      'reason_code', 'MARKETING_CAMPAIGN_ACTIVE_VERSION_INVALID',
      'campaign_id', v_campaign.id,
      'tenant_id', v_campaign.tenant_id
    );
  end if;

  if v_version.trigger_kind <> 'RENTAL_COMPLETED_FINANCIALLY_CLEARED' then
    return jsonb_build_object(
      'decision', 'INELIGIBLE',
      'reason_code', 'MARKETING_CAMPAIGN_TRIGGER_NOT_SUPPORTED',
      'campaign_id', v_campaign.id,
      'campaign_version_id', v_version.id,
      'tenant_id', v_campaign.tenant_id
    );
  end if;

  select * into v_appointment
  from public.appointments
  where id = p_source_appointment_id;

  if not found then
    return jsonb_build_object(
      'decision', 'INELIGIBLE',
      'reason_code', 'MARKETING_CAMPAIGN_SOURCE_APPOINTMENT_NOT_FOUND',
      'campaign_id', v_campaign.id,
      'campaign_version_id', v_version.id,
      'tenant_id', v_campaign.tenant_id
    );
  end if;

  if v_appointment.rewards_source_operation_scope_snapshot is null
    or v_appointment.rewards_source_service_type_key_snapshot is null then
    return jsonb_build_object(
      'decision', 'BLOCKED',
      'reason_code', 'MARKETING_CAMPAIGN_SOURCE_OWNERSHIP_UNSNAPSHOTTED',
      'campaign_id', v_campaign.id,
      'campaign_version_id', v_version.id,
      'tenant_id', v_campaign.tenant_id,
      'source_appointment_id', v_appointment.id
    );
  end if;

  if v_appointment.rewards_source_operation_scope_snapshot <> 'BLACKSHEEP'
    or v_appointment.rewards_source_service_type_key_snapshot <> 'LOCACAO' then
    return jsonb_build_object(
      'decision', 'INELIGIBLE',
      'reason_code', 'MARKETING_CAMPAIGN_SOURCE_NOT_BLACKSHEEP_RENTAL',
      'campaign_id', v_campaign.id,
      'campaign_version_id', v_version.id,
      'tenant_id', v_campaign.tenant_id,
      'source_appointment_id', v_appointment.id
    );
  end if;

  if v_appointment.primary_customer_id is null then
    return jsonb_build_object(
      'decision', 'BLOCKED',
      'reason_code', 'MARKETING_CAMPAIGN_SOURCE_CUSTOMER_REQUIRED',
      'campaign_id', v_campaign.id,
      'campaign_version_id', v_version.id,
      'tenant_id', v_campaign.tenant_id,
      'source_appointment_id', v_appointment.id
    );
  end if;

  if v_appointment.status <> 'COMPLETED' then
    return jsonb_build_object(
      'decision', 'INELIGIBLE',
      'reason_code', 'MARKETING_CAMPAIGN_SOURCE_NOT_COMPLETED',
      'campaign_id', v_campaign.id,
      'campaign_version_id', v_version.id,
      'tenant_id', v_campaign.tenant_id,
      'source_appointment_id', v_appointment.id,
      'customer_id', v_appointment.primary_customer_id
    );
  end if;

  if v_appointment.financial_status <> 'PAID' then
    return jsonb_build_object(
      'decision', 'INELIGIBLE',
      'reason_code', 'MARKETING_CAMPAIGN_SOURCE_NOT_FINANCIALLY_CLEARED',
      'campaign_id', v_campaign.id,
      'campaign_version_id', v_version.id,
      'tenant_id', v_campaign.tenant_id,
      'source_appointment_id', v_appointment.id,
      'customer_id', v_appointment.primary_customer_id
    );
  end if;

  if exists (
    select 1 from public.marketing_campaign_issuances i
    where i.campaign_id = v_campaign.id
      and i.source_appointment_id = v_appointment.id
  ) then
    return jsonb_build_object(
      'decision', 'INELIGIBLE',
      'reason_code', 'MARKETING_CAMPAIGN_SOURCE_ALREADY_ISSUED',
      'campaign_id', v_campaign.id,
      'campaign_version_id', v_version.id,
      'tenant_id', v_campaign.tenant_id,
      'source_appointment_id', v_appointment.id,
      'customer_id', v_appointment.primary_customer_id
    );
  end if;

  if not v_version.recurring_after_discounted_rental
    and exists (
      select 1 from public.appointment_discounts d
      where d.appointment_id = v_appointment.id
    ) then
    return jsonb_build_object(
      'decision', 'INELIGIBLE',
      'reason_code', 'MARKETING_CAMPAIGN_RECURRING_DISCOUNTED_RENTAL_DISABLED',
      'campaign_id', v_campaign.id,
      'campaign_version_id', v_version.id,
      'tenant_id', v_campaign.tenant_id,
      'source_appointment_id', v_appointment.id,
      'customer_id', v_appointment.primary_customer_id
    );
  end if;

  return jsonb_build_object(
    'decision', 'ELIGIBLE',
    'reason_code', 'MARKETING_CAMPAIGN_ELIGIBLE',
    'campaign_id', v_campaign.id,
    'campaign_version_id', v_version.id,
    'tenant_id', v_campaign.tenant_id,
    'source_appointment_id', v_appointment.id,
    'customer_id', v_appointment.primary_customer_id
  );
end;
$function$;

revoke all on function public.service_evaluate_marketing_campaign_eligibility(uuid,uuid)
  from public, anon, authenticated;
grant execute on function public.service_evaluate_marketing_campaign_eligibility(uuid,uuid)
  to service_role;

comment on function public.service_evaluate_marketing_campaign_eligibility(uuid,uuid) is
  'S3 read-only eligibility evaluator for an active BlackSheep rental Rewards campaign. It does not issue a coupon, write audit state, queue messaging, or modify checkout.';
