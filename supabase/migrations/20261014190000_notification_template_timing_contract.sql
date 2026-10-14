-- Additive timing contract. Scheduled jobs are consumed only by the matching worker deployment.
alter table public.notification_template_configs
  add column if not exists schedule_mode text not null default 'IMMEDIATE'
    check (schedule_mode in ('IMMEDIATE', 'BEFORE_START', 'AFTER_END')),
  add column if not exists schedule_offset_minutes integer null
    check (schedule_offset_minutes is null or schedule_offset_minutes >= 1);

alter table public.notification_template_configs
  add constraint notification_template_schedule_offset_check
  check (
    (schedule_mode = 'IMMEDIATE' and schedule_offset_minutes is null)
    or (schedule_mode in ('BEFORE_START', 'AFTER_END') and schedule_offset_minutes is not null)
  );

comment on column public.notification_template_configs.schedule_mode is
  'IMMEDIATE, BEFORE_START (appointment start) or AFTER_END (appointment core end).';

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
  if v_mode not in ('IMMEDIATE','BEFORE_START','AFTER_END') then raise exception 'NOTIFICATION_SCHEDULE_MODE_INVALID'; end if;
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

revoke all on function public.service_admin_upsert_notification_template_v3(uuid,text,text,text,text,uuid,text,text,text,boolean,jsonb,integer,uuid[],uuid,text,integer) from public, anon, authenticated;
grant execute on function public.service_admin_upsert_notification_template_v3(uuid,text,text,text,text,uuid,text,text,text,boolean,jsonb,integer,uuid[],uuid,text,integer) to service_role;

create or replace function public.service_admin_list_notification_templates_v3()
returns table(
  id uuid,event_key text,channel text,audience text,operation_scope text,category_id uuid,
  category_name text,title_template text,body_template text,html_template text,is_active boolean,
  variable_schema jsonb,reminder_offset_minutes integer,service_ids uuid[],version_count bigint,
  updated_at timestamptz,schedule_mode text,schedule_offset_minutes integer
) language sql security definer set search_path to 'public', 'pg_temp' as $$
  select v.*, t.schedule_mode, t.schedule_offset_minutes
  from public.service_admin_list_notification_templates_v2() v
  join public.notification_template_configs t on t.id=v.id;
$$;
revoke all on function public.service_admin_list_notification_templates_v3() from public, anon, authenticated;
grant execute on function public.service_admin_list_notification_templates_v3() to service_role;

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
revoke all on function public.enqueue_scheduled_notification_templates(uuid) from public, anon, authenticated;
grant execute on function public.enqueue_scheduled_notification_templates(uuid) to service_role;
