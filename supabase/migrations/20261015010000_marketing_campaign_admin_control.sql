-- BlackSheep Rewards S2: private, audited campaign administration.
-- This migration deliberately does not issue coupons, send messages, or alter checkout.

alter table public.marketing_campaigns
  add column created_request_id uuid;

create unique index marketing_campaigns_created_request_id_unique
  on public.marketing_campaigns(created_request_id)
  where created_request_id is not null;

alter table public.marketing_campaign_versions
  add column publication_status text not null default 'DRAFT'
    check (publication_status in ('DRAFT','PUBLISHED','SUPERSEDED')),
  add column published_at timestamptz,
  add column published_by_admin_id uuid references public.admin_users(id) on delete restrict,
  add constraint marketing_campaign_version_publication_metadata
    check (
      (publication_status = 'DRAFT' and published_at is null and published_by_admin_id is null)
      or (publication_status in ('PUBLISHED','SUPERSEDED') and published_at is not null and published_by_admin_id is not null)
    );

create unique index marketing_campaign_versions_one_published_per_campaign
  on public.marketing_campaign_versions(campaign_id)
  where publication_status = 'PUBLISHED';

alter table public.marketing_campaigns
  add column active_version_id uuid,
  add constraint marketing_campaign_active_version_scope_fk
    foreign key (active_version_id, id, tenant_id)
    references public.marketing_campaign_versions(id, campaign_id, tenant_id)
    on delete restrict,
  add constraint marketing_campaign_publish_before_operating
    check (state not in ('SCHEDULED','ACTIVE') or active_version_id is not null);

alter table public.marketing_campaign_audit_events
  add column request_id uuid;

create unique index marketing_campaign_audit_events_request_id_unique
  on public.marketing_campaign_audit_events(request_id)
  where request_id is not null;

alter table public.marketing_campaign_audit_events
  alter column actor_admin_id set not null;

alter table public.marketing_campaign_audit_events
  drop constraint marketing_campaign_audit_events_actor_admin_id_fkey,
  add constraint marketing_campaign_audit_events_actor_admin_id_fkey
    foreign key (actor_admin_id) references public.admin_users(id) on delete restrict;

create or replace function public.service_admin_assert_marketing_campaign_actor(p_admin_id uuid)
returns void
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $function$
begin
  if p_admin_id is null or not exists (
    select 1
    from public.admin_users au
    where au.id = p_admin_id
      and au.is_active
      and au.role in ('OWNER','ADMIN')
  ) then
    raise exception using errcode = '42501', message = 'MARKETING_CAMPAIGN_ADMIN_PERMISSION_DENIED';
  end if;
end;
$function$;

create or replace function public.service_admin_create_marketing_campaign(
  p_tenant_id uuid,
  p_campaign_key text,
  p_internal_name text,
  p_public_name text,
  p_description text,
  p_offer jsonb,
  p_admin_id uuid,
  p_request_id uuid
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
  v_campaign_key text := lower(btrim(coalesce(p_campaign_key, '')));
  v_internal_name text := btrim(coalesce(p_internal_name, ''));
  v_discount_scope text := upper(btrim(coalesce(p_offer->>'discount_scope', '')));
  v_max_uses integer := coalesce((p_offer->>'max_uses')::integer, 1);
  v_max_uses_per_customer integer := coalesce((p_offer->>'max_uses_per_customer')::integer, 1);
  v_stacking_policy text := upper(btrim(coalesce(p_offer->>'stacking_policy', 'EXCLUSIVE')));
  v_service_ids jsonb := p_offer->'eligibility_rules'->'service_ids';
begin
  perform public.service_admin_assert_marketing_campaign_actor(p_admin_id);
  if p_tenant_id is null or not exists (select 1 from public.tenants where id = p_tenant_id) then
    raise exception using errcode = 'P0001', message = 'MARKETING_CAMPAIGN_TENANT_NOT_FOUND';
  end if;
  if p_request_id is null then
    raise exception using errcode = '22023', message = 'MARKETING_CAMPAIGN_REQUEST_ID_REQUIRED';
  end if;
  select * into v_campaign
  from public.marketing_campaigns
  where created_request_id = p_request_id;
  if found then
    select * into v_version
    from public.marketing_campaign_versions
    where campaign_id = v_campaign.id
    order by version_number
    limit 1;
    return jsonb_build_object('campaign_id', v_campaign.id, 'version_id', v_version.id, 'replayed', true);
  end if;
  if v_campaign_key = '' or v_internal_name = '' then
    raise exception using errcode = '22023', message = 'MARKETING_CAMPAIGN_IDENTITY_INVALID';
  end if;
  if jsonb_typeof(p_offer) <> 'object' then
    raise exception using errcode = '22023', message = 'MARKETING_CAMPAIGN_OFFER_INVALID';
  end if;
  if v_service_ids is null then
    raise exception using errcode = '22023', message = 'MARKETING_CAMPAIGN_TARGET_SERVICES_REQUIRED';
  end if;
  if jsonb_typeof(v_service_ids) <> 'array' or jsonb_array_length(v_service_ids) = 0 then
    raise exception using errcode = '22023', message = 'MARKETING_CAMPAIGN_TARGET_SERVICES_INVALID';
  end if;
  if v_discount_scope <> 'SERVICE_ONLY'
    or coalesce((p_offer->>'applies_to_extras')::boolean, false)
    or coalesce((p_offer->>'applies_to_hour_packages')::boolean, false)
    or v_max_uses <> 1
    or v_max_uses_per_customer <> 1
    or v_stacking_policy <> 'EXCLUSIVE' then
    raise exception using errcode = '22023', message = 'MARKETING_CAMPAIGN_REWARDS_POLICY_INVALID';
  end if;

  insert into public.marketing_campaigns(
    tenant_id, campaign_key, internal_name, public_name, description,
    created_by_admin_id, updated_by_admin_id, created_request_id
  ) values (
    p_tenant_id, v_campaign_key, v_internal_name, nullif(btrim(p_public_name), ''), nullif(btrim(p_description), ''),
    p_admin_id, p_admin_id, p_request_id
  ) on conflict (created_request_id) where created_request_id is not null do nothing
  returning * into v_campaign;

  if not found then
    select * into v_campaign
    from public.marketing_campaigns
    where created_request_id = p_request_id;
    select * into v_version
    from public.marketing_campaign_versions
    where campaign_id = v_campaign.id
    order by version_number
    limit 1;
    return jsonb_build_object('campaign_id', v_campaign.id, 'version_id', v_version.id, 'replayed', true);
  end if;

  insert into public.marketing_campaign_versions(
    tenant_id, campaign_id, version_number, trigger_kind, discount_type, discount_value,
    discount_scope, validity_basis, validity_days, max_uses, max_uses_per_customer,
    recurring_after_discounted_rental, applies_to_extras, applies_to_hour_packages,
    stacking_policy, max_discount_amount, eligibility_rules, trigger_rules, message_rules,
    created_by_admin_id
  ) values (
    p_tenant_id, v_campaign.id, 1,
    upper(btrim(p_offer->>'trigger_kind')), upper(btrim(p_offer->>'discount_type')), (p_offer->>'discount_value')::numeric,
    v_discount_scope, upper(btrim(p_offer->>'validity_basis')), (p_offer->>'validity_days')::integer,
    v_max_uses, v_max_uses_per_customer,
    coalesce((p_offer->>'recurring_after_discounted_rental')::boolean, false), false, false,
    v_stacking_policy, nullif(p_offer->>'max_discount_amount', '')::numeric,
    coalesce(p_offer->'eligibility_rules', '{}'::jsonb), coalesce(p_offer->'trigger_rules', '{}'::jsonb),
    coalesce(p_offer->'message_rules', '{}'::jsonb), p_admin_id
  ) returning * into v_version;

  insert into public.marketing_campaign_audit_events(
    tenant_id, campaign_id, actor_admin_id, event_kind, after_snapshot, request_id
  ) values (
    p_tenant_id, v_campaign.id, p_admin_id, 'CREATED',
    jsonb_build_object('campaign', to_jsonb(v_campaign)), p_request_id
  ), (
    p_tenant_id, v_campaign.id, p_admin_id, 'VERSION_CREATED',
    jsonb_build_object('version', to_jsonb(v_version)), null
  );

  return jsonb_build_object('campaign_id', v_campaign.id, 'version_id', v_version.id, 'replayed', false);
end;
$function$;

create or replace function public.service_admin_create_marketing_campaign_version(
  p_campaign_id uuid,
  p_offer jsonb,
  p_admin_id uuid,
  p_request_id uuid
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
  v_existing_event public.marketing_campaign_audit_events%rowtype;
  v_discount_scope text := upper(btrim(coalesce(p_offer->>'discount_scope', '')));
  v_max_uses integer := coalesce((p_offer->>'max_uses')::integer, 1);
  v_max_uses_per_customer integer := coalesce((p_offer->>'max_uses_per_customer')::integer, 1);
  v_stacking_policy text := upper(btrim(coalesce(p_offer->>'stacking_policy', 'EXCLUSIVE')));
  v_service_ids jsonb := p_offer->'eligibility_rules'->'service_ids';
begin
  perform public.service_admin_assert_marketing_campaign_actor(p_admin_id);
  if p_request_id is null then
    raise exception using errcode = '22023', message = 'MARKETING_CAMPAIGN_REQUEST_ID_REQUIRED';
  end if;
  select * into v_existing_event
  from public.marketing_campaign_audit_events
  where request_id = p_request_id;
  if found then
    if v_existing_event.campaign_id <> p_campaign_id or v_existing_event.event_kind <> 'VERSION_CREATED' then
      raise exception using errcode = '22023', message = 'MARKETING_CAMPAIGN_REQUEST_ID_REUSED';
    end if;
    return jsonb_build_object('campaign_id', p_campaign_id, 'version_id', (v_existing_event.after_snapshot->'version'->>'id')::uuid, 'replayed', true);
  end if;
  if jsonb_typeof(p_offer) <> 'object' then
    raise exception using errcode = '22023', message = 'MARKETING_CAMPAIGN_OFFER_INVALID';
  end if;
  if v_service_ids is null then
    raise exception using errcode = '22023', message = 'MARKETING_CAMPAIGN_TARGET_SERVICES_REQUIRED';
  end if;
  if jsonb_typeof(v_service_ids) <> 'array' or jsonb_array_length(v_service_ids) = 0 then
    raise exception using errcode = '22023', message = 'MARKETING_CAMPAIGN_TARGET_SERVICES_INVALID';
  end if;
  if v_discount_scope <> 'SERVICE_ONLY'
    or coalesce((p_offer->>'applies_to_extras')::boolean, false)
    or coalesce((p_offer->>'applies_to_hour_packages')::boolean, false)
    or v_max_uses <> 1
    or v_max_uses_per_customer <> 1
    or v_stacking_policy <> 'EXCLUSIVE' then
    raise exception using errcode = '22023', message = 'MARKETING_CAMPAIGN_REWARDS_POLICY_INVALID';
  end if;

  select * into v_campaign from public.marketing_campaigns where id = p_campaign_id for update;
  if not found then
    raise exception using errcode = 'P0001', message = 'MARKETING_CAMPAIGN_NOT_FOUND';
  end if;
  if v_campaign.state = 'ARCHIVED' then
    raise exception using errcode = 'P0001', message = 'MARKETING_CAMPAIGN_ARCHIVED';
  end if;

  insert into public.marketing_campaign_versions(
    tenant_id, campaign_id, version_number, trigger_kind, discount_type, discount_value,
    discount_scope, validity_basis, validity_days, max_uses, max_uses_per_customer,
    recurring_after_discounted_rental, applies_to_extras, applies_to_hour_packages,
    stacking_policy, max_discount_amount, eligibility_rules, trigger_rules, message_rules,
    created_by_admin_id
  ) values (
    v_campaign.tenant_id, v_campaign.id,
    (select coalesce(max(version_number), 0) + 1 from public.marketing_campaign_versions where campaign_id = v_campaign.id),
    upper(btrim(p_offer->>'trigger_kind')), upper(btrim(p_offer->>'discount_type')), (p_offer->>'discount_value')::numeric,
    v_discount_scope, upper(btrim(p_offer->>'validity_basis')), (p_offer->>'validity_days')::integer,
    v_max_uses, v_max_uses_per_customer,
    coalesce((p_offer->>'recurring_after_discounted_rental')::boolean, false), false, false,
    v_stacking_policy, nullif(p_offer->>'max_discount_amount', '')::numeric,
    coalesce(p_offer->'eligibility_rules', '{}'::jsonb), coalesce(p_offer->'trigger_rules', '{}'::jsonb),
    coalesce(p_offer->'message_rules', '{}'::jsonb), p_admin_id
  ) returning * into v_version;

  insert into public.marketing_campaign_audit_events(
    tenant_id, campaign_id, actor_admin_id, event_kind, after_snapshot, request_id
  ) values (
    v_campaign.tenant_id, v_campaign.id, p_admin_id, 'VERSION_CREATED',
    jsonb_build_object('version', to_jsonb(v_version)), p_request_id
  );
  return jsonb_build_object('campaign_id', v_campaign.id, 'version_id', v_version.id, 'replayed', false);
end;
$function$;

create or replace function public.service_admin_transition_marketing_campaign(
  p_campaign_id uuid,
  p_state text,
  p_publish_version_id uuid,
  p_reason text,
  p_admin_id uuid,
  p_request_id uuid
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
  v_existing_event public.marketing_campaign_audit_events%rowtype;
  v_before jsonb;
  v_target_state text := upper(btrim(coalesce(p_state, '')));
  v_event_kind text;
begin
  perform public.service_admin_assert_marketing_campaign_actor(p_admin_id);
  if p_request_id is null then
    raise exception using errcode = '22023', message = 'MARKETING_CAMPAIGN_REQUEST_ID_REQUIRED';
  end if;
  select * into v_existing_event
  from public.marketing_campaign_audit_events
  where request_id = p_request_id;
  if found then
    if v_existing_event.campaign_id <> p_campaign_id
      or v_existing_event.event_kind not in ('SCHEDULED','ACTIVATED','PAUSED','RESUMED','ENDED','ARCHIVED') then
      raise exception using errcode = '22023', message = 'MARKETING_CAMPAIGN_REQUEST_ID_REUSED';
    end if;
    return jsonb_build_object('campaign_id', p_campaign_id, 'state', v_existing_event.after_snapshot->'campaign'->>'state', 'replayed', true);
  end if;

  select * into v_campaign from public.marketing_campaigns where id = p_campaign_id for update;
  if not found then
    raise exception using errcode = 'P0001', message = 'MARKETING_CAMPAIGN_NOT_FOUND';
  end if;
  v_before := to_jsonb(v_campaign);
  if not (
    (v_campaign.state = 'DRAFT' and v_target_state in ('SCHEDULED','ACTIVE','ARCHIVED')) or
    (v_campaign.state = 'SCHEDULED' and v_target_state in ('ACTIVE','PAUSED','ENDED','ARCHIVED')) or
    (v_campaign.state = 'ACTIVE' and v_target_state in ('PAUSED','ENDED','ARCHIVED')) or
    (v_campaign.state = 'PAUSED' and v_target_state in ('ACTIVE','ENDED','ARCHIVED')) or
    (v_campaign.state = 'ENDED' and v_target_state = 'ARCHIVED')
  ) then
    raise exception using errcode = '22023', message = 'MARKETING_CAMPAIGN_STATE_TRANSITION_INVALID';
  end if;

  if p_publish_version_id is not null then
    select * into v_version
    from public.marketing_campaign_versions
    where id = p_publish_version_id and campaign_id = v_campaign.id and tenant_id = v_campaign.tenant_id
    for update;
    if not found or v_version.publication_status = 'SUPERSEDED' then
      raise exception using errcode = '22023', message = 'MARKETING_CAMPAIGN_VERSION_NOT_PUBLISHABLE';
    end if;
    if v_campaign.active_version_id is distinct from v_version.id
      or v_version.publication_status <> 'PUBLISHED' then
      update public.marketing_campaign_versions
      set publication_status = 'SUPERSEDED'
      where campaign_id = v_campaign.id and publication_status = 'PUBLISHED';
      update public.marketing_campaign_versions
      set publication_status = 'PUBLISHED', published_at = now(), published_by_admin_id = p_admin_id
      where id = v_version.id;
    end if;
  end if;

  if v_target_state in ('SCHEDULED','ACTIVE') then
    select * into v_version
    from public.marketing_campaign_versions
    where id = coalesce(p_publish_version_id, v_campaign.active_version_id)
      and campaign_id = v_campaign.id
      and tenant_id = v_campaign.tenant_id
      and publication_status = 'PUBLISHED';
    if not found then
      raise exception using errcode = '22023', message = 'MARKETING_CAMPAIGN_PUBLISHED_VERSION_REQUIRED';
    end if;
  end if;

  update public.marketing_campaigns
  set state = v_target_state,
      active_version_id = coalesce(p_publish_version_id, active_version_id),
      updated_by_admin_id = p_admin_id,
      updated_at = now()
  where id = v_campaign.id
  returning * into v_campaign;

  v_event_kind := case v_target_state
    when 'SCHEDULED' then 'SCHEDULED'
    when 'ACTIVE' then case when v_before->>'state' = 'PAUSED' then 'RESUMED' else 'ACTIVATED' end
    when 'PAUSED' then 'PAUSED'
    when 'ENDED' then 'ENDED'
    when 'ARCHIVED' then 'ARCHIVED'
  end;
  insert into public.marketing_campaign_audit_events(
    tenant_id, campaign_id, actor_admin_id, event_kind, before_snapshot, after_snapshot, reason, request_id
  ) values (
    v_campaign.tenant_id, v_campaign.id, p_admin_id, v_event_kind, v_before,
    jsonb_build_object('campaign', to_jsonb(v_campaign)), nullif(btrim(p_reason), ''), p_request_id
  );
  return jsonb_build_object('campaign_id', v_campaign.id, 'state', v_campaign.state, 'active_version_id', v_campaign.active_version_id, 'replayed', false);
end;
$function$;

revoke all on function public.service_admin_assert_marketing_campaign_actor(uuid) from public, anon, authenticated;
revoke all on function public.service_admin_create_marketing_campaign(uuid,text,text,text,text,jsonb,uuid,uuid) from public, anon, authenticated;
revoke all on function public.service_admin_create_marketing_campaign_version(uuid,jsonb,uuid,uuid) from public, anon, authenticated;
revoke all on function public.service_admin_transition_marketing_campaign(uuid,text,uuid,text,uuid,uuid) from public, anon, authenticated;
grant execute on function public.service_admin_assert_marketing_campaign_actor(uuid) to service_role;
grant execute on function public.service_admin_create_marketing_campaign(uuid,text,text,text,text,jsonb,uuid,uuid) to service_role;
grant execute on function public.service_admin_create_marketing_campaign_version(uuid,jsonb,uuid,uuid) to service_role;
grant execute on function public.service_admin_transition_marketing_campaign(uuid,text,uuid,text,uuid,uuid) to service_role;

comment on function public.service_admin_create_marketing_campaign(uuid,text,text,text,text,jsonb,uuid,uuid) is
  'S2 private admin action: creates a DRAFT campaign and immutable first offer version. It neither issues coupons nor sends messages.';
comment on function public.service_admin_transition_marketing_campaign(uuid,text,uuid,text,uuid,uuid) is
  'S2 private admin action: performs only allowed state transitions and publishes the explicit active version required before scheduling or activation.';
