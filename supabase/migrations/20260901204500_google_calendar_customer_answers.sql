create or replace function public.get_google_appointment_desired_state(p_appointment_id uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_appointment public.appointments%rowtype;
  v_write public.service_employee_calendar_write%rowtype;
  v_calendar public.google_calendars%rowtype;
  v_customer public.customers%rowtype;
  v_start_at timestamptz;
  v_end_at timestamptz;
  v_action text;
  v_summary text;
  v_description text;
  v_answers text;
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

  if v_appointment.primary_customer_id is not null then
    select * into v_customer
    from public.customers
    where id = v_appointment.primary_customer_id;
  end if;

  if v_write.time_scope = 'CORE_ONLY' then
    v_start_at := coalesce(v_appointment.core_start_at, v_appointment.start_at);
    v_end_at := coalesce(v_appointment.core_end_at, v_appointment.end_at);
  else
    v_start_at := v_appointment.start_at;
    v_end_at := v_appointment.end_at;
  end if;

  select string_agg(
    aa.label_snapshot || ': ' ||
      case
        when jsonb_typeof(aa.value_json) = 'string' then aa.value_json #>> '{}'
        else aa.value_json::text
      end,
    E'\n' order by aa.created_at, aa.id
  )
  into v_answers
  from public.appointment_answers aa
  where aa.appointment_id = v_appointment.id
    and aa.value_json is not null
    and aa.value_json <> 'null'::jsonb
    and btrim(case when jsonb_typeof(aa.value_json) = 'string' then coalesce(aa.value_json #>> '{}','') else aa.value_json::text end) <> '';

  v_summary := coalesce(nullif(v_appointment.service_name_snapshot, ''), 'Reserva BlackSheep Agenda')
    || ' - '
    || coalesce(nullif(v_customer.name, ''), 'Cliente');

  v_description := 'BlackSheep Agenda • Reserva ' || v_appointment.public_code
    || case when nullif(v_customer.name, '') is not null then E'\n\nCliente: ' || v_customer.name else '' end
    || case when nullif(v_customer.email, '') is not null then E'\nE-mail: ' || v_customer.email else '' end
    || case when nullif(v_customer.phone, '') is not null then E'\nWhatsApp: ' || v_customer.phone else '' end
    || case when nullif(v_customer.cpf_cnpj, '') is not null then E'\nCPF/CNPJ: ' || v_customer.cpf_cnpj else '' end
    || case when v_appointment.people_count is not null then E'\nPessoas: ' || v_appointment.people_count::text else '' end
    || case when nullif(v_answers, '') is not null then E'\n\nRespostas da reserva:\n' || v_answers else '' end;

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
    'description', v_description
  );
end;
$function$;
