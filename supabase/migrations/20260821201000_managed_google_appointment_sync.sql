alter table public.service_employee_calendar_write
  add column time_scope text not null default 'FULL_APPOINTMENT'
    check (time_scope in ('FULL_APPOINTMENT','CORE_ONLY'));

create unique index google_calendar_events_active_managed_appointment_uq
  on public.google_calendar_events (google_calendar_id, agenda_appointment_id)
  where managed_by_agenda
    and agenda_appointment_id is not null
    and status <> 'cancelled';

create or replace function public.get_google_appointment_desired_state(p_appointment_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_appointment public.appointments%rowtype;
  v_write public.service_employee_calendar_write%rowtype;
  v_calendar public.google_calendars%rowtype;
  v_start_at timestamptz;
  v_end_at timestamptz;
  v_action text;
  v_summary text;
begin
  select * into v_appointment
  from public.appointments
  where id = p_appointment_id;

  if not found then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_NOT_FOUND';
  end if;

  if v_appointment.status in ('CONFIRMED','COMPLETED','NO_SHOW') then
    v_action := 'PRESENT';
  else
    v_action := 'ABSENT';
  end if;

  select * into v_write
  from public.service_employee_calendar_write
  where service_employee_id = v_appointment.service_employee_id;

  if not found then
    if v_action = 'ABSENT' then
      return jsonb_build_object(
        'appointment_id', v_appointment.id,
        'version', v_appointment.version,
        'appointment_status', v_appointment.status,
        'desired_action', 'ABSENT',
        'calendar_configured', false
      );
    end if;
    raise exception using errcode = 'P0001', message = 'GOOGLE_WRITE_CALENDAR_NOT_CONFIGURED';
  end if;

  select * into v_calendar
  from public.google_calendars
  where id = v_write.google_calendar_id
    and is_active;

  if not found then
    raise exception using errcode = 'P0001', message = 'GOOGLE_WRITE_CALENDAR_NOT_AVAILABLE';
  end if;

  if v_write.time_scope = 'CORE_ONLY' then
    v_start_at := coalesce(v_appointment.core_start_at, v_appointment.start_at);
    v_end_at := coalesce(v_appointment.core_end_at, v_appointment.end_at);
  else
    v_start_at := v_appointment.start_at;
    v_end_at := v_appointment.end_at;
  end if;

  v_summary := coalesce(nullif(v_appointment.service_name_snapshot, ''), 'Reserva BlackSheep Agenda');

  return jsonb_build_object(
    'appointment_id', v_appointment.id,
    'public_code', v_appointment.public_code,
    'version', v_appointment.version,
    'appointment_status', v_appointment.status,
    'desired_action', v_action,
    'calendar_configured', true,
    'time_scope', v_write.time_scope,
    'start_at', v_start_at,
    'end_at', v_end_at,
    'google_calendar_id', v_calendar.id,
    'remote_calendar_id', v_calendar.google_calendar_id,
    'calendar_timezone', v_calendar.timezone,
    'google_connection_id', v_calendar.google_connection_id,
    'summary', v_summary,
    'description', 'BlackSheep Agenda • Reserva ' || v_appointment.public_code
  );
end;
$$;

revoke all on function public.get_google_appointment_desired_state(uuid) from public, anon, authenticated;
grant execute on function public.get_google_appointment_desired_state(uuid) to service_role;

create or replace function public.discard_integration_job_stale(
  p_job_id uuid,
  p_worker_id text,
  p_current_version integer
)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_job public.integration_jobs%rowtype;
begin
  select * into v_job
  from public.integration_jobs
  where id = p_job_id
  for update;

  if not found then
    raise exception using errcode = 'P0001', message = 'INTEGRATION_JOB_NOT_FOUND';
  end if;

  if v_job.status <> 'PROCESSING' or v_job.locked_by is distinct from p_worker_id then
    raise exception using errcode = 'P0001', message = 'INTEGRATION_JOB_LOCK_MISMATCH';
  end if;

  if v_job.entity_version is null or v_job.entity_version >= p_current_version then
    raise exception using errcode = 'P0001', message = 'INTEGRATION_JOB_NOT_STALE';
  end if;

  update public.integration_jobs
  set status = 'DISCARDED_STALE',
      last_error = 'STALE_ENTITY_VERSION:' || v_job.entity_version::text || '<' || p_current_version::text,
      locked_at = null,
      locked_by = null,
      processed_at = now(),
      updated_at = now()
  where id = p_job_id;
end;
$$;

revoke all on function public.discard_integration_job_stale(uuid,text,integer) from public, anon, authenticated;
grant execute on function public.discard_integration_job_stale(uuid,text,integer) to service_role;

comment on column public.service_employee_calendar_write.time_scope is
  'Controls whether managed Google events cover the full customer appointment envelope or only the immutable service core.';

comment on function public.get_google_appointment_desired_state(uuid) is
  'Canonical desired-state projection used by GOOGLE_APPOINTMENT_SYNC workers. Google is a mirror, never the booking authority.';
