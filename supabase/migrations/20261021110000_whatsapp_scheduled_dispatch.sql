-- Envio agendado por WhatsApp (confirmado pelo usuário em 2026-10-21: cobrança de saldo
-- com link de pagamento 25 minutos antes do término da reserva, para clientes reais).
--   * a cobrança de saldo (RENTAL_BALANCE_DUE) entra nos eventos que podem ter modelo de
--     WhatsApp ativo;
--   * enqueue_scheduled_notification_templates também agenda os modelos de WhatsApp da
--     BlackSheep com prazo. O trabalho leva channel=WHATSAPP e template_id; o
--     integration-worker manda para o whatsapp-send, que só envia se o modelo estiver
--     ativo, aprovado, sem alteração e com o mesmo prazo do agendamento. Por isso o
--     modelo inativo também é agendado: ativar depois já vale para as reservas futuras;
--   * salvar o disparo de um modelo de WhatsApp reagenda as reservas futuras com o novo
--     prazo (o agendamento antigo fica sem efeito porque o prazo não bate mais);
--   * as reservas futuras já confirmadas recebem o agendamento agora.
alter table public.notification_template_configs
  drop constraint if exists notification_template_configs_whatsapp_dispatchable_events;
alter table public.notification_template_configs
  add constraint notification_template_configs_whatsapp_dispatchable_events
  check (
    channel <> 'WHATSAPP'
    or is_active = false
    or event_key in ('APPOINTMENT_APPROVED', 'APPOINTMENT_RESCHEDULED', 'APPOINTMENT_CANCELLED', 'RENTAL_BALANCE_DUE')
  );

create or replace function public.enqueue_scheduled_notification_templates(p_appointment_id uuid)
returns integer language plpgsql security definer set search_path to 'public', 'pg_temp' as $$
declare v_count integer; v_whatsapp integer;
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

  insert into public.integration_jobs(job_type,entity_type,entity_id,entity_version,payload_json,run_after,idempotency_key)
  select
    'APPOINTMENT_SCHEDULED_MESSAGE','APPOINTMENT',a.id,a.version,
    jsonb_build_object('event_key',t.event_key,'channel','WHATSAPP','template_id',t.id::text,
      'schedule_key',t.id::text || ':' || a.version::text || ':' || t.schedule_mode || ':' || t.schedule_offset_minutes::text,'reason','SCHEDULED'),
    case t.schedule_mode
      when 'BEFORE_START' then a.start_at - make_interval(mins => t.schedule_offset_minutes)
      when 'AFTER_START' then a.start_at + make_interval(mins => t.schedule_offset_minutes)
      when 'BEFORE_END' then a.core_end_at - make_interval(mins => t.schedule_offset_minutes)
      else a.core_end_at + make_interval(mins => t.schedule_offset_minutes)
    end,
    'notification-schedule:' || t.id::text || ':' || a.id::text || ':v' || a.version::text || ':' || t.schedule_mode || ':' || t.schedule_offset_minutes::text
  from public.appointments a
  join public.services s on s.id=a.service_id and s.operation_scope='BLACKSHEEP'
  join public.notification_template_configs t on t.channel='WHATSAPP' and t.audience='CUSTOMER' and t.schedule_mode <> 'IMMEDIATE'
    and (t.operation_scope is null or t.operation_scope=s.operation_scope)
  where a.id=p_appointment_id and a.status='CONFIRMED'
    and (not exists(select 1 from public.notification_template_services ts where ts.template_id=t.id)
      or exists(select 1 from public.notification_template_services ts where ts.template_id=t.id and ts.service_id=a.service_id))
  on conflict (idempotency_key) do nothing;
  get diagnostics v_whatsapp = row_count;
  return v_count + v_whatsapp;
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
  v_channel text;
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
         t.operation_scope, t.channel
    into v_before, v_scope, v_channel
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

  -- WhatsApp: as reservas futuras passam a usar o novo prazo.
  if v_channel = 'WHATSAPP' and v_mode <> 'IMMEDIATE' then
    insert into public.integration_jobs(job_type,entity_type,entity_id,entity_version,payload_json,run_after,idempotency_key)
    select 'APPOINTMENT_SCHEDULED_MESSAGE','APPOINTMENT',x.id,x.version,
      jsonb_build_object('event_key',x.event_key,'channel','WHATSAPP','template_id',p_template_id::text,
        'schedule_key',p_template_id::text || ':' || x.version::text || ':' || v_mode || ':' || p_schedule_offset_minutes::text,'reason','SCHEDULED'),
      x.run_after,
      'notification-schedule:' || p_template_id::text || ':' || x.id::text || ':v' || x.version::text || ':' || v_mode || ':' || p_schedule_offset_minutes::text
    from (
      select a.id, a.version, t.event_key,
        case v_mode
          when 'BEFORE_START' then a.start_at - make_interval(mins => p_schedule_offset_minutes)
          when 'AFTER_START' then a.start_at + make_interval(mins => p_schedule_offset_minutes)
          when 'BEFORE_END' then a.core_end_at - make_interval(mins => p_schedule_offset_minutes)
          else a.core_end_at + make_interval(mins => p_schedule_offset_minutes)
        end as run_after
      from public.appointments a
      join public.services s on s.id = a.service_id and s.operation_scope = 'BLACKSHEEP'
      join public.notification_template_configs t on t.id = p_template_id
      where a.status = 'CONFIRMED'
        and (t.operation_scope is null or t.operation_scope = s.operation_scope)
        and (not exists(select 1 from public.notification_template_services ts where ts.template_id = t.id)
          or exists(select 1 from public.notification_template_services ts where ts.template_id = t.id and ts.service_id = a.service_id))
    ) x
    where x.run_after > now()
    on conflict (idempotency_key) do nothing;
  end if;

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

-- Reservas futuras já confirmadas: agenda os modelos de WhatsApp com prazo.
insert into public.integration_jobs(job_type,entity_type,entity_id,entity_version,payload_json,run_after,idempotency_key)
select 'APPOINTMENT_SCHEDULED_MESSAGE','APPOINTMENT',x.id,x.version,
  jsonb_build_object('event_key',x.event_key,'channel','WHATSAPP','template_id',x.template_id::text,
    'schedule_key',x.template_id::text || ':' || x.version::text || ':' || x.schedule_mode || ':' || x.schedule_offset_minutes::text,'reason','SCHEDULED'),
  x.run_after,
  'notification-schedule:' || x.template_id::text || ':' || x.id::text || ':v' || x.version::text || ':' || x.schedule_mode || ':' || x.schedule_offset_minutes::text
from (
  select a.id, a.version, t.id as template_id, t.event_key, t.schedule_mode, t.schedule_offset_minutes,
    case t.schedule_mode
      when 'BEFORE_START' then a.start_at - make_interval(mins => t.schedule_offset_minutes)
      when 'AFTER_START' then a.start_at + make_interval(mins => t.schedule_offset_minutes)
      when 'BEFORE_END' then a.core_end_at - make_interval(mins => t.schedule_offset_minutes)
      else a.core_end_at + make_interval(mins => t.schedule_offset_minutes)
    end as run_after
  from public.appointments a
  join public.services s on s.id = a.service_id and s.operation_scope = 'BLACKSHEEP'
  join public.notification_template_configs t on t.channel = 'WHATSAPP' and t.audience = 'CUSTOMER' and t.schedule_mode <> 'IMMEDIATE'
    and (t.operation_scope is null or t.operation_scope = s.operation_scope)
  where a.status = 'CONFIRMED'
    and (not exists(select 1 from public.notification_template_services ts where ts.template_id = t.id)
      or exists(select 1 from public.notification_template_services ts where ts.template_id = t.id and ts.service_id = a.service_id))
) x
where x.run_after > now()
on conflict (idempotency_key) do nothing;
