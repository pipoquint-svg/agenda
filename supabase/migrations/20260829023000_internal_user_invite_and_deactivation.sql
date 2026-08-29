-- Etapa 3 — jornada do usuário interno.
-- Expand-only around the existing admin/Auth boundaries: adds one editable invite
-- template/event and one service-role-only deactivation mutation.

alter table public.notification_template_configs
  drop constraint if exists notification_template_configs_event_key_check;

alter table public.notification_template_configs
  add constraint notification_template_configs_event_key_check check (event_key in (
    'APPOINTMENT_APPROVED',
    'APPOINTMENT_PENDING',
    'APPOINTMENT_REJECTED',
    'APPOINTMENT_CANCELLED',
    'APPOINTMENT_CHANGED',
    'APPOINTMENT_RESCHEDULED',
    'APPOINTMENT_REMINDER',
    'WAITLIST_AVAILABLE',
    'BIRTHDAY',
    'RENTAL_BALANCE_DUE',
    'ADMIN_USER_INVITE',
    'MANUAL'
  ));

create or replace function public.service_admin_upsert_notification_template(
  p_template_id uuid,
  p_event_key text,
  p_channel text,
  p_audience text,
  p_operation_scope text,
  p_category_id uuid,
  p_title_template text,
  p_body_template text,
  p_is_active boolean,
  p_variable_schema jsonb,
  p_reminder_offset_minutes integer,
  p_service_ids uuid[],
  p_actor_admin_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid;
  v_before jsonb;
  v_after jsonb;
  v_version integer;
begin
  if p_event_key not in (
    'APPOINTMENT_APPROVED','APPOINTMENT_PENDING','APPOINTMENT_REJECTED','APPOINTMENT_CANCELLED',
    'APPOINTMENT_CHANGED','APPOINTMENT_RESCHEDULED','APPOINTMENT_REMINDER','WAITLIST_AVAILABLE','BIRTHDAY',
    'RENTAL_BALANCE_DUE','ADMIN_USER_INVITE','MANUAL'
  ) then raise exception 'NOTIFICATION_EVENT_INVALID'; end if;
  if p_channel not in ('EMAIL','GOOGLE_CALENDAR') then raise exception 'NOTIFICATION_CHANNEL_INVALID'; end if;
  if p_audience not in ('CUSTOMER','EMPLOYEE') then raise exception 'NOTIFICATION_AUDIENCE_INVALID'; end if;
  if p_operation_scope is not null and p_operation_scope not in ('SABRINA','BLACKSHEEP') then
    raise exception 'NOTIFICATION_OPERATION_SCOPE_INVALID';
  end if;
  if coalesce(btrim(p_title_template), '') = '' then raise exception 'NOTIFICATION_TITLE_REQUIRED'; end if;
  if p_variable_schema is null or jsonb_typeof(p_variable_schema) <> 'array' then raise exception 'NOTIFICATION_VARIABLE_SCHEMA_INVALID'; end if;
  if p_reminder_offset_minutes is not null and p_reminder_offset_minutes < 0 then raise exception 'NOTIFICATION_REMINDER_OFFSET_INVALID'; end if;

  if p_category_id is not null and not exists (select 1 from public.categories where id = p_category_id) then
    raise exception 'NOTIFICATION_CATEGORY_NOT_FOUND';
  end if;
  if exists (
    select 1 from unnest(coalesce(p_service_ids, '{}'::uuid[])) sid
    where not exists (select 1 from public.services s where s.id = sid)
  ) then raise exception 'NOTIFICATION_SERVICE_NOT_FOUND'; end if;

  if p_template_id is null then
    insert into public.notification_template_configs (
      event_key, channel, audience, operation_scope, category_id, title_template, body_template,
      is_active, variable_schema, reminder_offset_minutes, created_by_admin_id, updated_by_admin_id
    ) values (
      p_event_key, p_channel, p_audience, p_operation_scope, p_category_id, btrim(p_title_template), coalesce(p_body_template,''),
      coalesce(p_is_active,false), p_variable_schema, p_reminder_offset_minutes, p_actor_admin_id, p_actor_admin_id
    ) returning id into v_id;
  else
    select to_jsonb(t) into v_before from public.notification_template_configs t where t.id = p_template_id for update;
    if v_before is null then raise exception 'NOTIFICATION_TEMPLATE_NOT_FOUND'; end if;
    update public.notification_template_configs
      set event_key = p_event_key,
          channel = p_channel,
          audience = p_audience,
          operation_scope = p_operation_scope,
          category_id = p_category_id,
          title_template = btrim(p_title_template),
          body_template = coalesce(p_body_template,''),
          is_active = coalesce(p_is_active,false),
          variable_schema = p_variable_schema,
          reminder_offset_minutes = p_reminder_offset_minutes,
          updated_by_admin_id = p_actor_admin_id,
          updated_at = now()
      where id = p_template_id;
    v_id := p_template_id;
  end if;

  delete from public.notification_template_services where template_id = v_id;
  insert into public.notification_template_services(template_id, service_id)
    select v_id, sid from unnest(coalesce(p_service_ids, '{}'::uuid[])) sid
    on conflict do nothing;

  select to_jsonb(t) || jsonb_build_object(
    'service_ids', coalesce((select jsonb_agg(ts.service_id order by ts.service_id) from public.notification_template_services ts where ts.template_id = v_id), '[]'::jsonb)
  ) into v_after
  from public.notification_template_configs t where t.id = v_id;

  select coalesce(max(version_number),0) + 1 into v_version
  from public.notification_template_versions where template_id = v_id;

  insert into public.notification_template_versions(template_id, version_number, snapshot, changed_by_admin_id)
  values (v_id, v_version, v_after, p_actor_admin_id);

  insert into public.audit_logs(admin_user_id, entity_type, entity_id, action, before_json, after_json, origin)
  values (
    p_actor_admin_id,
    'NOTIFICATION_TEMPLATE',
    v_id,
    case when v_before is null then 'CREATE' else 'UPDATE' end,
    v_before,
    v_after,
    'ADMIN'
  );

  return v_id;
end;
$$;

revoke all on function public.service_admin_upsert_notification_template(uuid,text,text,text,text,uuid,text,text,boolean,jsonb,integer,uuid[],uuid) from public, anon, authenticated;
grant execute on function public.service_admin_upsert_notification_template(uuid,text,text,text,text,uuid,text,text,boolean,jsonb,integer,uuid[],uuid) to service_role;

create or replace function public.service_admin_deactivate_admin_user(
  p_target_admin_id uuid,
  p_actor_admin_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_target public.admin_users%rowtype;
  v_before jsonb;
  v_after jsonb;
begin
  if not exists (
    select 1 from public.admin_users a
    where a.id = p_actor_admin_id and a.is_active
  ) then
    raise exception 'ADMIN_ACCESS_DENIED';
  end if;

  if not public.service_admin_has_permission(p_actor_admin_id, 'TEAM_MANAGE') then
    raise exception 'ADMIN_PERMISSION_DENIED';
  end if;

  if p_target_admin_id = p_actor_admin_id then
    raise exception 'ADMIN_SELF_DEACTIVATION_FORBIDDEN';
  end if;

  select * into v_target
  from public.admin_users
  where id = p_target_admin_id
  for update;

  if not found then
    raise exception 'ADMIN_USER_NOT_FOUND';
  end if;

  if v_target.role = 'OWNER' then
    raise exception 'ADMIN_OWNER_DEACTIVATION_FORBIDDEN';
  end if;

  if not v_target.is_active then
    return jsonb_build_object(
      'id', v_target.id,
      'auth_user_id', v_target.auth_user_id,
      'is_active', false,
      'already_inactive', true
    );
  end if;

  v_before := to_jsonb(v_target);

  update public.admin_users
  set is_active = false,
      updated_at = now()
  where id = v_target.id;

  select to_jsonb(a) into v_after
  from public.admin_users a
  where a.id = v_target.id;

  insert into public.audit_logs(
    admin_user_id, entity_type, entity_id, action, before_json, after_json, origin
  ) values (
    p_actor_admin_id, 'ADMIN_USER', v_target.id, 'USER_DEACTIVATED', v_before, v_after, 'ADMIN'
  );

  return jsonb_build_object(
    'id', v_target.id,
    'auth_user_id', v_target.auth_user_id,
    'is_active', false,
    'already_inactive', false
  );
end;
$$;

revoke all on function public.service_admin_deactivate_admin_user(uuid,uuid) from public, anon, authenticated;
grant execute on function public.service_admin_deactivate_admin_user(uuid,uuid) to service_role;

insert into public.notification_template_configs (
  event_key, channel, audience, operation_scope, category_id,
  title_template, body_template, is_active, variable_schema,
  reminder_offset_minutes, created_by_admin_id, updated_by_admin_id
)
select
  'ADMIN_USER_INVITE',
  'EMAIL',
  'EMPLOYEE',
  'BLACKSHEEP',
  null,
  'Seu acesso à Gestão BlackSheep',
  E'Olá, {{employee.name}}.\n\nVocê recebeu acesso à Gestão BlackSheep.\n\nDefina sua própria senha e conclua o primeiro acesso pelo link abaixo:\n{{auth.invite_url}}\n\nEste link é pessoal, expira e só pode ser usado uma vez.\n\n{{operation.name}}',
  true,
  '["employee.name","auth.invite_url","operation.name","operation.site_url"]'::jsonb,
  null,
  null,
  null
where not exists (
  select 1
  from public.notification_template_configs t
  where t.event_key = 'ADMIN_USER_INVITE'
    and t.channel = 'EMAIL'
    and t.audience = 'EMPLOYEE'
    and t.operation_scope = 'BLACKSHEEP'
    and t.category_id is null
    and not exists (select 1 from public.notification_template_services nts where nts.template_id = t.id)
);

insert into public.notification_template_versions(template_id, version_number, snapshot, changed_by_admin_id)
select
  t.id,
  1,
  to_jsonb(t) || jsonb_build_object('service_ids', '[]'::jsonb),
  null
from public.notification_template_configs t
where t.event_key = 'ADMIN_USER_INVITE'
  and t.channel = 'EMAIL'
  and t.audience = 'EMPLOYEE'
  and t.operation_scope = 'BLACKSHEEP'
  and t.category_id is null
  and not exists (select 1 from public.notification_template_versions v where v.template_id = t.id);

comment on function public.service_admin_deactivate_admin_user(uuid,uuid)
  is 'Deactivates a non-owner admin immediately at the authoritative admin_users boundary. Service-role only; Auth session ban is applied by the admin Edge Function.';
