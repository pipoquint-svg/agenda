-- Rewards campaigns can be edited and deleted from the Gestão.
--   * Edit: name, public name and description are updated in place. A new offer
--     (trigger, discount, services, validity) becomes a new immutable version;
--     earlier versions stay as history. The offer of an ACTIVE or SCHEDULED
--     campaign cannot change: pause it first.
--   * Delete: a DRAFT that was never published, issued nothing, has no referral
--     code and no message sent to Meta is removed, with a snapshot kept in the
--     append-only audit_logs. Any other campaign is archived, so coupons already
--     issued and their history are preserved.
-- Neither action issues coupons or sends messages.

alter table public.marketing_campaign_audit_events
  drop constraint if exists marketing_campaign_audit_events_event_kind_check;
alter table public.marketing_campaign_audit_events
  add constraint marketing_campaign_audit_events_event_kind_check
  check (event_kind in (
    'CREATED','VERSION_CREATED','SCHEDULED','ACTIVATED','PAUSED','RESUMED','ENDED','ARCHIVED',
    'ISSUANCE_LINKED','REVOKED','REFERRAL_CODE_CREATED','UPDATED'
  ));

create or replace function public.service_admin_update_marketing_campaign(
  p_tenant_id uuid,
  p_campaign_id uuid,
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
  v_existing_event public.marketing_campaign_audit_events%rowtype;
  v_before jsonb;
  v_version_id uuid;
begin
  perform public.service_admin_assert_marketing_campaign_actor(p_admin_id);
  if p_request_id is null then
    raise exception using errcode = '22023', message = 'MARKETING_CAMPAIGN_REQUEST_ID_REQUIRED';
  end if;
  select * into v_existing_event
  from public.marketing_campaign_audit_events
  where request_id = p_request_id;
  if found then
    if v_existing_event.campaign_id <> p_campaign_id or v_existing_event.event_kind <> 'UPDATED' then
      raise exception using errcode = '22023', message = 'MARKETING_CAMPAIGN_REQUEST_ID_REUSED';
    end if;
    return jsonb_build_object(
      'campaign_id', p_campaign_id,
      'version_id', (v_existing_event.after_snapshot->>'version_id')::uuid,
      'replayed', true
    );
  end if;

  select * into v_campaign
  from public.marketing_campaigns
  where id = p_campaign_id and tenant_id = p_tenant_id
  for update;
  if not found then
    raise exception using errcode = 'P0001', message = 'MARKETING_CAMPAIGN_NOT_FOUND';
  end if;
  if v_campaign.state in ('ENDED','ARCHIVED') then
    raise exception using errcode = '22023', message = 'MARKETING_CAMPAIGN_CLOSED';
  end if;
  if btrim(coalesce(p_internal_name, '')) = '' then
    raise exception using errcode = '22023', message = 'MARKETING_CAMPAIGN_IDENTITY_INVALID';
  end if;
  if p_offer is not null and v_campaign.state in ('ACTIVE','SCHEDULED') then
    raise exception using errcode = '22023', message = 'MARKETING_CAMPAIGN_PAUSE_TO_EDIT_OFFER';
  end if;

  v_before := to_jsonb(v_campaign);
  update public.marketing_campaigns
  set internal_name = btrim(p_internal_name),
      public_name = nullif(btrim(p_public_name), ''),
      description = nullif(btrim(p_description), ''),
      updated_by_admin_id = p_admin_id,
      updated_at = now()
  where id = v_campaign.id
  returning * into v_campaign;

  if p_offer is not null then
    -- The version action keeps its own replay key, derived from this request.
    v_version_id := (public.service_admin_create_marketing_campaign_version(
      v_campaign.id, p_offer, p_admin_id, md5(p_request_id::text || ':version')::uuid
    )->>'version_id')::uuid;
  end if;

  insert into public.marketing_campaign_audit_events(
    tenant_id, campaign_id, actor_admin_id, event_kind, before_snapshot, after_snapshot, request_id
  ) values (
    v_campaign.tenant_id, v_campaign.id, p_admin_id, 'UPDATED', v_before,
    jsonb_build_object('campaign', to_jsonb(v_campaign), 'version_id', v_version_id), p_request_id
  );
  return jsonb_build_object('campaign_id', v_campaign.id, 'version_id', v_version_id, 'replayed', false);
end;
$function$;

create or replace function public.service_admin_delete_marketing_campaign(
  p_tenant_id uuid,
  p_campaign_id uuid,
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
  v_deleted public.audit_logs%rowtype;
  v_template_ids uuid[];
  v_snapshot jsonb;
  v_result jsonb;
begin
  perform public.service_admin_assert_marketing_campaign_actor(p_admin_id);
  if p_request_id is null then
    raise exception using errcode = '22023', message = 'MARKETING_CAMPAIGN_REQUEST_ID_REQUIRED';
  end if;
  select * into v_deleted
  from public.audit_logs
  where request_id = p_request_id and action = 'MARKETING_CAMPAIGN_DELETED';
  if found then
    if v_deleted.entity_id <> p_campaign_id then
      raise exception using errcode = '22023', message = 'MARKETING_CAMPAIGN_REQUEST_ID_REUSED';
    end if;
    return jsonb_build_object('campaign_id', p_campaign_id, 'outcome', 'DELETED', 'replayed', true);
  end if;

  select * into v_campaign
  from public.marketing_campaigns
  where id = p_campaign_id and tenant_id = p_tenant_id
  for update;
  if not found then
    raise exception using errcode = 'P0001', message = 'MARKETING_CAMPAIGN_NOT_FOUND';
  end if;

  if v_campaign.state <> 'DRAFT'
    or exists (
      select 1 from public.marketing_campaign_versions v
      where v.campaign_id = v_campaign.id
        and (v.publication_status <> 'DRAFT' or v.published_at is not null)
    )
    or exists (select 1 from public.marketing_campaign_issuances i where i.campaign_id = v_campaign.id)
    or exists (select 1 from public.marketing_referral_codes r where r.campaign_id = v_campaign.id)
    or exists (
      select 1
      from public.marketing_campaign_message_templates t
      join public.whatsapp_template_submissions s on s.notification_template_id = t.template_id
      where t.campaign_id = v_campaign.id
    ) then
    if v_campaign.state = 'ARCHIVED' then
      return jsonb_build_object('campaign_id', v_campaign.id, 'outcome', 'ARCHIVED', 'replayed', true);
    end if;
    v_result := public.service_admin_transition_marketing_campaign(
      v_campaign.id, 'ARCHIVED', null, 'Excluída na Gestão', p_admin_id, p_request_id
    );
    return jsonb_build_object(
      'campaign_id', v_campaign.id, 'outcome', 'ARCHIVED', 'replayed', coalesce((v_result->>'replayed')::boolean, false)
    );
  end if;

  select coalesce(array_agg(t.template_id), '{}') into v_template_ids
  from public.marketing_campaign_message_templates t
  where t.campaign_id = v_campaign.id;
  v_snapshot := jsonb_build_object(
    'campaign', to_jsonb(v_campaign),
    'versions', coalesce((
      select jsonb_agg(to_jsonb(v) order by v.version_number)
      from public.marketing_campaign_versions v where v.campaign_id = v_campaign.id
    ), '[]'::jsonb),
    'message_template_ids', to_jsonb(v_template_ids)
  );

  delete from public.marketing_campaign_audit_events where campaign_id = v_campaign.id;
  delete from public.marketing_campaign_version_services s
  using public.marketing_campaign_versions v
  where s.campaign_version_id = v.id and v.campaign_id = v_campaign.id;
  delete from public.marketing_campaign_versions where campaign_id = v_campaign.id;
  delete from public.marketing_campaigns where id = v_campaign.id;
  delete from public.notification_template_configs where id = any(v_template_ids);

  insert into public.audit_logs(admin_user_id, entity_type, entity_id, action, before_json, origin, request_id)
  values (p_admin_id, 'MARKETING_CAMPAIGN', v_campaign.id, 'MARKETING_CAMPAIGN_DELETED', v_snapshot, 'ADMIN', p_request_id);
  return jsonb_build_object('campaign_id', v_campaign.id, 'outcome', 'DELETED', 'replayed', false);
end;
$function$;

revoke all on function public.service_admin_update_marketing_campaign(uuid,uuid,text,text,text,jsonb,uuid,uuid) from public, anon, authenticated;
revoke all on function public.service_admin_delete_marketing_campaign(uuid,uuid,uuid,uuid) from public, anon, authenticated;
grant execute on function public.service_admin_update_marketing_campaign(uuid,uuid,text,text,text,jsonb,uuid,uuid) to service_role;
grant execute on function public.service_admin_delete_marketing_campaign(uuid,uuid,uuid,uuid) to service_role;

comment on function public.service_admin_update_marketing_campaign(uuid,uuid,text,text,text,jsonb,uuid,uuid) is
  'Private admin action: renames a campaign and, when an offer is given, appends a new immutable version. The offer of an ACTIVE or SCHEDULED campaign cannot change.';
comment on function public.service_admin_delete_marketing_campaign(uuid,uuid,uuid,uuid) is
  'Private admin action: removes a never-published DRAFT with no issuance, referral code or Meta submission (snapshot in audit_logs); archives any other campaign.';
