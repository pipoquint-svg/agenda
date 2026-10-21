-- WhatsApp com prazo só é agendado se o horário ainda não passou. Uma reserva feita a
-- menos de 48h do início não recebe o lembrete de 48h junto com a confirmação; o mesmo
-- vale para qualquer prazo. O e-mail agendado continua como antes.
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
    -- Prazo que já passou (reserva feita em cima da hora) não vira WhatsApp atrasado.
    and case t.schedule_mode
      when 'BEFORE_START' then a.start_at - make_interval(mins => t.schedule_offset_minutes)
      when 'AFTER_START' then a.start_at + make_interval(mins => t.schedule_offset_minutes)
      when 'BEFORE_END' then a.core_end_at - make_interval(mins => t.schedule_offset_minutes)
      else a.core_end_at + make_interval(mins => t.schedule_offset_minutes)
    end > now()
  on conflict (idempotency_key) do nothing;
  get diagnostics v_whatsapp = row_count;
  return v_count + v_whatsapp;
end;
$$;
