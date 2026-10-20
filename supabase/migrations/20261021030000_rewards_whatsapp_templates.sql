-- Rewards WhatsApp message templates: one set per campaign, edited in the
-- Rewards area of Gestão and submittable for Meta approval. They are drafts
-- only (WhatsApp templates can never be active) and nothing enqueues these
-- events: Rewards delivery (S6) stays frozen until explicitly released.
--
-- Events:
--   REWARDS_WINBACK          90 days since the last rental, coupon to come back
--   REWARDS_COUPON_ISSUED    a Rewards coupon was released to the customer
--   REWARDS_COUPON_EXPIRING  the coupon's window to confirm a booking is ending

alter table public.notification_template_configs
  drop constraint notification_template_configs_event_key_check;

alter table public.notification_template_configs
  add constraint notification_template_configs_event_key_check
  check (
    event_key = any (
      array[
        'APPOINTMENT_APPROVED'::text,
        'APPOINTMENT_PENDING'::text,
        'APPOINTMENT_REJECTED'::text,
        'APPOINTMENT_CANCELLED'::text,
        'APPOINTMENT_CHANGED'::text,
        'APPOINTMENT_RESCHEDULED'::text,
        'APPOINTMENT_REMINDER'::text,
        'WAITLIST_AVAILABLE'::text,
        'WAITLIST_SIGNUP_TEAM'::text,
        'BIRTHDAY'::text,
        'RENTAL_BALANCE_DUE'::text,
        'ADMIN_USER_INVITE'::text,
        'MANUAL'::text,
        'REFUND_FAILED'::text,
        'REFUND_COMPLETED'::text,
        'PRE_RESERVATION_CREATED'::text,
        'PAYMENT_PENDING_CREATED'::text,
        'REWARDS_WINBACK'::text,
        'REWARDS_COUPON_ISSUED'::text,
        'REWARDS_COUPON_EXPIRING'::text
      ]
    )
  );

-- One template per campaign and event. The template itself lives in
-- notification_template_configs, so versions, WhatsApp fields and Meta
-- submissions reuse the rental notification machinery.
create table public.marketing_campaign_message_templates (
  campaign_id uuid not null references public.marketing_campaigns(id) on delete cascade,
  event_key text not null
    check (event_key in ('REWARDS_WINBACK','REWARDS_COUPON_ISSUED','REWARDS_COUPON_EXPIRING')),
  template_id uuid not null unique references public.notification_template_configs(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (campaign_id, event_key)
);

alter table public.marketing_campaign_message_templates enable row level security;
revoke all on public.marketing_campaign_message_templates from public, anon, authenticated, service_role;
grant select on public.marketing_campaign_message_templates to service_role;

comment on table public.marketing_campaign_message_templates is
  'Rewards WhatsApp drafts per campaign and event. Configuration only: no delivery path reads these events while Rewards S6 is frozen.';

create or replace function public.service_admin_upsert_rewards_message_template(
  p_tenant_id uuid,
  p_campaign_id uuid,
  p_event_key text,
  p_title_template text,
  p_body_template text,
  p_variable_schema jsonb,
  p_actor_admin_id uuid
) returns uuid
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_event text := upper(btrim(coalesce(p_event_key, '')));
  v_id uuid;
  v_before jsonb;
  v_after jsonb;
  v_version integer;
begin
  if v_event not in ('REWARDS_WINBACK','REWARDS_COUPON_ISSUED','REWARDS_COUPON_EXPIRING') then
    raise exception using errcode = 'P0001', message = 'NOTIFICATION_EVENT_INVALID';
  end if;
  if not exists (
    select 1 from public.marketing_campaigns c where c.id = p_campaign_id and c.tenant_id = p_tenant_id
  ) then
    raise exception using errcode = 'P0001', message = 'REWARDS_CAMPAIGN_NOT_FOUND';
  end if;
  if coalesce(btrim(p_title_template), '') = '' then raise exception using errcode = 'P0001', message = 'NOTIFICATION_TITLE_REQUIRED'; end if;
  if p_variable_schema is null or jsonb_typeof(p_variable_schema) <> 'array' then
    raise exception using errcode = 'P0001', message = 'NOTIFICATION_VARIABLE_SCHEMA_INVALID';
  end if;

  select l.template_id into v_id
  from public.marketing_campaign_message_templates l
  where l.campaign_id = p_campaign_id and l.event_key = v_event
  for update;

  if v_id is null then
    -- Always a WhatsApp customer draft for BlackSheep: never active, no services, no schedule.
    insert into public.notification_template_configs (
      event_key, channel, audience, operation_scope, category_id, title_template, body_template, html_template,
      is_active, variable_schema, reminder_offset_minutes, created_by_admin_id, updated_by_admin_id
    ) values (
      v_event, 'WHATSAPP', 'CUSTOMER', 'BLACKSHEEP', null, btrim(p_title_template), coalesce(p_body_template, ''), null,
      false, p_variable_schema, null, p_actor_admin_id, p_actor_admin_id
    ) returning id into v_id;
    insert into public.marketing_campaign_message_templates (campaign_id, event_key, template_id)
    values (p_campaign_id, v_event, v_id);
  else
    select to_jsonb(t) into v_before from public.notification_template_configs t where t.id = v_id for update;
    update public.notification_template_configs set
      title_template = btrim(p_title_template),
      body_template = coalesce(p_body_template, ''),
      variable_schema = p_variable_schema,
      is_active = false,
      updated_by_admin_id = p_actor_admin_id,
      updated_at = now()
    where id = v_id;
  end if;

  select to_jsonb(t) || jsonb_build_object('marketing_campaign_id', p_campaign_id)
    into v_after from public.notification_template_configs t where t.id = v_id;
  select coalesce(max(version_number), 0) + 1 into v_version
    from public.notification_template_versions where template_id = v_id;
  insert into public.notification_template_versions(template_id, version_number, snapshot, changed_by_admin_id)
    values (v_id, v_version, v_after, p_actor_admin_id);
  insert into public.audit_logs(admin_user_id, entity_type, entity_id, action, before_json, after_json, origin)
    values (p_actor_admin_id, 'NOTIFICATION_TEMPLATE', v_id, case when v_before is null then 'CREATE' else 'UPDATE' end, v_before, v_after, 'ADMIN');
  return v_id;
end;
$function$;

revoke all on function public.service_admin_upsert_rewards_message_template(uuid,uuid,text,text,text,jsonb,uuid) from public, anon, authenticated;
grant execute on function public.service_admin_upsert_rewards_message_template(uuid,uuid,text,text,text,jsonb,uuid) to service_role;
