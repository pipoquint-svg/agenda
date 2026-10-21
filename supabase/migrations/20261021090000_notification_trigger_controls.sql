-- Disparo separado do conteúdo da notificação.
--   * o prazo pode ser antes ou depois do início, e antes ou depois do término
--     (AFTER_START e BEFORE_END se juntam a BEFORE_START e AFTER_END);
--   * service_admin_update_notification_trigger_v1 salva só o disparo (modo, prazo e
--     serviços), sem mexer no conteúdo, em is_active nem em updated_at. Assim um
--     modelo de WhatsApp aprovado pela Meta continua aprovado (o whatsapp-send compara
--     updated_at com submitted_at). A mudança fica no histórico e na auditoria.
alter table public.notification_template_configs
  drop constraint if exists notification_template_configs_schedule_mode_check;
alter table public.notification_template_configs
  add constraint notification_template_configs_schedule_mode_check
  check (schedule_mode in ('IMMEDIATE', 'BEFORE_START', 'AFTER_START', 'BEFORE_END', 'AFTER_END'));

alter table public.notification_template_configs
  drop constraint if exists notification_template_schedule_offset_check;
alter table public.notification_template_configs
  add constraint notification_template_schedule_offset_check
  check (
    (schedule_mode = 'IMMEDIATE' and schedule_offset_minutes is null)
    or (schedule_mode <> 'IMMEDIATE' and schedule_offset_minutes is not null)
  );

alter table public.notification_template_configs
  add column if not exists trigger_updated_at timestamptz null;

comment on column public.notification_template_configs.schedule_mode is
  'IMMEDIATE, BEFORE_START/AFTER_START (appointment start) or BEFORE_END/AFTER_END (appointment core end).';
comment on column public.notification_template_configs.trigger_updated_at is
  'Last change to the trigger only (schedule or services); content changes use updated_at.';

create or replace function public.service_admin_upsert_notification_template_v3(
  p_template_id uuid, p_event_key text, p_channel text, p_audience text,
  p_operation_scope text, p_category_id uuid, p_title_template text,
  p_body_template text, p_html_template text, p_is_active boolean,
  p_variable_schema jsonb, p_reminder_offset_minutes integer,
  p_service_ids uuid[], p_actor_admin_id uuid, p_schedule_mode text,
  p_schedule_offset_minutes integer
) returns uuid language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare v_id uuid; v_mode text := coalesce(p_schedule_mode, 'IMMEDIATE');
begin
  if v_mode not in ('IMMEDIATE','BEFORE_START','AFTER_START','BEFORE_END','AFTER_END') then raise exception 'NOTIFICATION_SCHEDULE_MODE_INVALID'; end if;
  if (v_mode='IMMEDIATE' and p_schedule_offset_minutes is not null)
    or (v_mode<>'IMMEDIATE' and coalesce(p_schedule_offset_minutes,0) < 1) then
    raise exception 'NOTIFICATION_SCHEDULE_OFFSET_INVALID';
  end if;
  v_id := public.service_admin_upsert_notification_template_v2(
    p_template_id,p_event_key,p_channel,p_audience,p_operation_scope,p_category_id,
    p_title_template,p_body_template,p_html_template,p_is_active,p_variable_schema,
    p_reminder_offset_minutes,p_service_ids,p_actor_admin_id
  );
  update public.notification_template_configs
  set schedule_mode=v_mode, schedule_offset_minutes=p_schedule_offset_minutes,
      updated_at=now(), updated_by_admin_id=p_actor_admin_id
  where id=v_id;
  return v_id;
end;
$$;

create or replace function public.service_admin_update_notification_trigger_v1(
  p_template_id uuid, p_schedule_mode text, p_schedule_offset_minutes integer,
  p_service_ids uuid[], p_actor_admin_id uuid
) returns uuid language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare
  v_mode text := coalesce(p_schedule_mode, 'IMMEDIATE');
  v_before jsonb;
  v_after jsonb;
  v_scope text;
  v_version integer;
begin
  if v_mode not in ('IMMEDIATE','BEFORE_START','AFTER_START','BEFORE_END','AFTER_END') then raise exception 'NOTIFICATION_SCHEDULE_MODE_INVALID'; end if;
  if (v_mode='IMMEDIATE' and p_schedule_offset_minutes is not null)
    or (v_mode<>'IMMEDIATE' and coalesce(p_schedule_offset_minutes,0) < 1) then
    raise exception 'NOTIFICATION_SCHEDULE_OFFSET_INVALID';
  end if;
  if exists (select 1 from unnest(coalesce(p_service_ids, '{}'::uuid[])) sid where not exists (select 1 from public.services s where s.id = sid)) then
    raise exception 'NOTIFICATION_SERVICE_NOT_FOUND';
  end if;

  select to_jsonb(t) || jsonb_build_object('service_ids', coalesce((select jsonb_agg(ts.service_id order by ts.service_id) from public.notification_template_services ts where ts.template_id = t.id), '[]'::jsonb)),
         t.operation_scope
    into v_before, v_scope
    from public.notification_template_configs t where t.id = p_template_id for update;
  if v_before is null then raise exception 'NOTIFICATION_TEMPLATE_NOT_FOUND'; end if;
  if v_scope is not null and exists (
    select 1 from unnest(coalesce(p_service_ids, '{}'::uuid[])) sid
    join public.services s on s.id = sid
    where s.operation_scope is distinct from v_scope
  ) then raise exception 'NOTIFICATION_SERVICE_SCOPE_MISMATCH'; end if;

  update public.notification_template_configs
  set schedule_mode = v_mode, schedule_offset_minutes = p_schedule_offset_minutes,
      trigger_updated_at = now(), updated_by_admin_id = p_actor_admin_id
  where id = p_template_id;

  delete from public.notification_template_services where template_id = p_template_id;
  insert into public.notification_template_services(template_id, service_id)
    select p_template_id, sid from unnest(coalesce(p_service_ids, '{}'::uuid[])) sid on conflict do nothing;

  select to_jsonb(t) || jsonb_build_object('service_ids', coalesce((select jsonb_agg(ts.service_id order by ts.service_id) from public.notification_template_services ts where ts.template_id = t.id), '[]'::jsonb))
    into v_after from public.notification_template_configs t where t.id = p_template_id;
  select coalesce(max(version_number),0) + 1 into v_version from public.notification_template_versions where template_id = p_template_id;
  insert into public.notification_template_versions(template_id, version_number, snapshot, changed_by_admin_id)
    values (p_template_id, v_version, v_after, p_actor_admin_id);
  insert into public.audit_logs(admin_user_id, entity_type, entity_id, action, before_json, after_json, origin)
    values (p_actor_admin_id, 'NOTIFICATION_TEMPLATE', p_template_id, 'UPDATE_TRIGGER', v_before, v_after, 'ADMIN');
  return p_template_id;
end;
$$;
revoke all on function public.service_admin_update_notification_trigger_v1(uuid,text,integer,uuid[],uuid) from public, anon, authenticated;
grant execute on function public.service_admin_update_notification_trigger_v1(uuid,text,integer,uuid[],uuid) to service_role;

create or replace function public.enqueue_scheduled_notification_templates(p_appointment_id uuid)
returns integer language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare v_count integer;
begin
  insert into public.integration_jobs(job_type,entity_type,entity_id,entity_version,payload_json,run_after,idempotency_key)
  select
    'APPOINTMENT_SCHEDULED_MESSAGE','APPOINTMENT',a.id,a.version,
    jsonb_build_object('event_key',t.event_key,'schedule_key',t.id::text || ':' || a.version::text || ':' || t.schedule_mode || ':' || coalesce(t.schedule_offset_minutes,0)::text,'reason','SCHEDULED'),
    case t.schedule_mode
      when 'BEFORE_START' then a.start_at - make_interval(mins => t.schedule_offset_minutes)
      when 'AFTER_START' then a.start_at + make_interval(mins => t.schedule_offset_minutes)
      when 'BEFORE_END' then a.core_end_at - make_interval(mins => t.schedule_offset_minutes)
      when 'AFTER_END' then a.core_end_at + make_interval(mins => t.schedule_offset_minutes)
      else now()
    end,
    'notification-schedule:' || t.id::text || ':' || a.id::text || ':v' || a.version::text || ':' || t.schedule_mode || ':' || coalesce(t.schedule_offset_minutes,0)::text
  from public.appointments a
  join public.services s on s.id=a.service_id
  join public.notification_template_configs t on t.is_active and t.channel='EMAIL' and t.audience='CUSTOMER' and t.schedule_mode <> 'IMMEDIATE'
    and (t.operation_scope is null or t.operation_scope=s.operation_scope)
  where a.id=p_appointment_id and a.status='CONFIRMED'
    and (not exists(select 1 from public.notification_template_services ts where ts.template_id=t.id)
      or exists(select 1 from public.notification_template_services ts where ts.template_id=t.id and ts.service_id=a.service_id))
  on conflict (idempotency_key) do nothing;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;
