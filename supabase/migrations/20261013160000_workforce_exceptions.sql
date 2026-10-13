-- Workforce S2 — governed journey exceptions (ADR-017).
-- Live extra work (start/finish with authoritative server time), retroactive
-- employee records, manager events, one OPEN period per employee, idempotency.
-- The raw reported period is immutable once set; review/correction arrive in S4.

create table workforce.work_exceptions (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  employer_id uuid not null,
  employee_id uuid not null,
  exception_type text not null,
  source text not null,
  status text not null,
  event_date date not null,
  event_end_date date,
  all_day boolean not null default false,
  reported_start timestamptz,
  reported_end timestamptz,
  employee_note text,
  manager_note text,
  recorded_by_admin_id uuid not null references public.admin_users(id) on delete restrict,
  created_at timestamptz not null default now(),
  finished_at timestamptz,
  period tstzrange generated always as (
    case when reported_start is null then null
         else tstzrange(reported_start, coalesce(reported_end, 'infinity'::timestamptz), '[)') end
  ) stored,
  constraint work_exceptions_tenant_id_key unique (tenant_id, id),
  constraint work_exceptions_employee_fkey foreign key (tenant_id, employee_id)
    references workforce.employees(tenant_id, id) on delete restrict,
  constraint work_exceptions_employer_fkey foreign key (tenant_id, employer_id)
    references workforce.employers(tenant_id, id) on delete restrict,
  constraint work_exceptions_type_valid check (exception_type in (
    'EXTRA_WORK', 'EARLY_LEAVE', 'LATE_ARRIVAL', 'ABSENCE', 'MEDICAL_LEAVE', 'OTHER'
  )),
  constraint work_exceptions_source_valid check (source in (
    'EMPLOYEE', 'MANAGER', 'RETROACTIVE_EMPLOYEE', 'RETROACTIVE_MANAGER', 'SYSTEM_SUGGESTION'
  )),
  constraint work_exceptions_status_valid check (status in (
    'OPEN', 'RECORDED', 'PENDING_REVIEW', 'VALIDATED', 'MANAGER_CONTESTED',
    'CORRECTION_REQUESTED', 'WITHDRAWN_BY_EMPLOYEE'
  )),
  -- Only a live employee extra period can be OPEN, and only OPEN lacks an end.
  constraint work_exceptions_open_shape check (
    (status = 'OPEN') = (reported_start is not null and reported_end is null and not all_day)
    and (status <> 'OPEN' or (exception_type = 'EXTRA_WORK' and source = 'EMPLOYEE'))
  ),
  constraint work_exceptions_period_shape check (
    (all_day and reported_start is null and reported_end is null
       and exception_type in ('ABSENCE', 'MEDICAL_LEAVE', 'OTHER')
       and event_end_date is not null and event_end_date >= event_date
       and event_end_date <= event_date + 30)
    or (not all_day and reported_start is not null and event_end_date is null
       and (reported_end is null or (reported_end > reported_start
            and reported_end <= reported_start + interval '24 hours')))
  ),
  constraint work_exceptions_extra_timed check (exception_type <> 'EXTRA_WORK' or not all_day),
  constraint work_exceptions_notes_valid check (
    (employee_note is null or length(employee_note) <= 1000)
    and (manager_note is null or length(manager_note) <= 1000)
  ),
  -- Extra periods of the same employee never overlap (double counting).
  constraint work_exceptions_extra_no_overlap exclude using gist (employee_id with =, period with &&)
    where (exception_type = 'EXTRA_WORK' and status <> 'WITHDRAWN_BY_EMPLOYEE')
);

-- A double click or concurrent request can never open two periods.
create unique index work_exceptions_single_open_key on workforce.work_exceptions(employee_id) where status = 'OPEN';
create index work_exceptions_employee_date_idx on workforce.work_exceptions(tenant_id, employee_id, event_date);

comment on table workforce.work_exceptions is
  'Raw exception records. reported_start/end are the authoritative raw period (server time for live records) and are never edited; corrections create new interpretations (S4).';
comment on column workforce.work_exceptions.employee_note is
  'Free text that may hold sensitive data. Never copied to reports, e-mail, audit log or error messages.';
comment on column workforce.work_exceptions.manager_note is
  'Owner-internal note. Never shown to the accountant.';

alter table workforce.work_exceptions enable row level security;
alter table workforce.work_exceptions force row level security;
create policy work_exceptions_owner_only on workforce.work_exceptions
  as permissive for all to postgres using (true) with check (true);

-- Raw data guard: identity, type, source and the raw period are immutable; the
-- only raw mutation is closing an OPEN period once (reported_end null -> value).
-- Status follows an explicit transition table that later slices extend.
create table workforce.work_exception_status_transitions (
  from_status text not null,
  to_status text not null,
  primary key (from_status, to_status)
);
insert into workforce.work_exception_status_transitions(from_status, to_status) values
  ('OPEN', 'RECORDED');
alter table workforce.work_exception_status_transitions enable row level security;
alter table workforce.work_exception_status_transitions force row level security;
create policy work_exception_status_transitions_owner_only on workforce.work_exception_status_transitions
  as permissive for all to postgres using (true) with check (true);

create function workforce.guard_work_exception()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'WORKFORCE_IMMUTABLE:%', tg_table_name using errcode = 'P0001';
  end if;
  if new.id is distinct from old.id
     or new.tenant_id is distinct from old.tenant_id
     or new.employer_id is distinct from old.employer_id
     or new.employee_id is distinct from old.employee_id
     or new.exception_type is distinct from old.exception_type
     or new.source is distinct from old.source
     or new.event_date is distinct from old.event_date
     or new.event_end_date is distinct from old.event_end_date
     or new.all_day is distinct from old.all_day
     or new.reported_start is distinct from old.reported_start
     or (old.reported_end is not null and new.reported_end is distinct from old.reported_end)
     or new.employee_note is distinct from old.employee_note
     or new.recorded_by_admin_id is distinct from old.recorded_by_admin_id
     or new.created_at is distinct from old.created_at
     or (old.finished_at is not null and new.finished_at is distinct from old.finished_at) then
    raise exception 'WORKFORCE_IMMUTABLE:%', tg_table_name using errcode = 'P0001';
  end if;
  if new.status is distinct from old.status and not exists (
    select 1 from workforce.work_exception_status_transitions t
    where t.from_status = old.status and t.to_status = new.status
  ) then
    raise exception 'WORKFORCE_STATUS_TRANSITION_INVALID:%', lower(old.status || '_to_' || new.status) using errcode = 'P0001';
  end if;
  return new;
end;
$$;

create trigger work_exceptions_guard before update or delete on workforce.work_exceptions
  for each row execute function workforce.guard_work_exception();

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Local wall-clock input "YYYY-MM-DDTHH:MM" interpreted in the employer timezone.
-- The browser never sends an offset; the server owns the conversion.
create function workforce.payload_local_timestamp(p_payload jsonb, p_key text, p_timezone text)
returns timestamptz
language plpgsql
stable
set search_path = ''
as $$
declare
  v_value text := workforce.payload_text(p_payload, p_key, 16);
begin
  if v_value is null then
    return null;
  end if;
  if v_value !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T([01][0-9]|2[0-3]):[0-5][0-9]$' then
    raise exception 'WORKFORCE_FIELD_INVALID:%', p_key using errcode = 'P0001';
  end if;
  begin
    return (replace(v_value, 'T', ' ')::timestamp) at time zone p_timezone;
  exception when others then
    raise exception 'WORKFORCE_FIELD_INVALID:%', p_key using errcode = 'P0001';
  end;
end;
$$;

create function workforce.employer_timezone(p_employer_id uuid)
returns text
language sql
stable
set search_path = ''
as $$
  select e.timezone from workforce.employers e where e.id = p_employer_id;
$$;

create function workforce.exception_json(p_exception workforce.work_exceptions, p_audience text)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_timezone text := workforce.employer_timezone(p_exception.employer_id);
  v_result jsonb;
begin
  v_result := jsonb_build_object(
    'exception_id', p_exception.id,
    'exception_type', p_exception.exception_type,
    'source', p_exception.source,
    'status', p_exception.status,
    'event_date', p_exception.event_date,
    'event_end_date', p_exception.event_end_date,
    'all_day', p_exception.all_day,
    'reported_start', p_exception.reported_start,
    'reported_end', p_exception.reported_end,
    'reported_start_local', to_char(p_exception.reported_start at time zone v_timezone, 'YYYY-MM-DD"T"HH24:MI'),
    'reported_end_local', to_char(p_exception.reported_end at time zone v_timezone, 'YYYY-MM-DD"T"HH24:MI'),
    'raw_minutes', case when p_exception.reported_end is null then null
      else floor(extract(epoch from p_exception.reported_end - p_exception.reported_start) / 60)::int end,
    'created_at', p_exception.created_at,
    'finished_at', p_exception.finished_at,
    'employee_note', p_exception.employee_note
  );
  if p_audience = 'OWNER' then
    v_result := v_result || jsonb_build_object(
      'employee_id', p_exception.employee_id,
      'manager_note', p_exception.manager_note,
      'recorded_by_admin_id', p_exception.recorded_by_admin_id
    );
  end if;
  return v_result;
end;
$$;

-- Audit snapshots never carry free-text notes (LGPD, §14 of the spec).
create function workforce.exception_audit_json(p_exception workforce.work_exceptions)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select to_jsonb(p_exception) - array['employee_note', 'manager_note', 'period']
    || jsonb_build_object(
      'has_employee_note', p_exception.employee_note is not null,
      'has_manager_note', p_exception.manager_note is not null
    );
$$;

-- Shared validation for non-live records (employee retroactive or manager event).
create function workforce.insert_recorded_exception(
  p_employee workforce.employees,
  p_actor_admin_id uuid,
  p_actor_kind text,
  p_payload jsonb
)
returns workforce.work_exceptions
language plpgsql
set search_path = ''
as $$
declare
  v_timezone text := workforce.employer_timezone(p_employee.employer_id);
  v_today date := workforce.local_today(p_employee.employer_id);
  v_type text := upper(workforce.payload_text(p_payload, 'exception_type', 32));
  v_all_day boolean := coalesce(workforce.payload_bool(p_payload, 'all_day'), false);
  v_start timestamptz;
  v_end timestamptz;
  v_date date;
  v_end_date date;
  v_source text;
  v_status text;
  v_row workforce.work_exceptions;
begin
  if v_type is null or v_type not in ('EXTRA_WORK', 'EARLY_LEAVE', 'LATE_ARRIVAL', 'ABSENCE', 'MEDICAL_LEAVE', 'OTHER') then
    raise exception 'WORKFORCE_FIELD_INVALID:exception_type' using errcode = 'P0001';
  end if;

  if v_all_day then
    if v_type not in ('ABSENCE', 'MEDICAL_LEAVE', 'OTHER') then
      raise exception 'WORKFORCE_FIELD_INVALID:all_day' using errcode = 'P0001';
    end if;
    if p_payload ? 'start_local' or p_payload ? 'end_local' then
      raise exception 'WORKFORCE_FIELD_INVALID:all_day' using errcode = 'P0001';
    end if;
    v_date := workforce.payload_date(p_payload, 'event_date');
    v_end_date := coalesce(workforce.payload_date(p_payload, 'event_end_date'), v_date);
    if v_date is null then
      raise exception 'WORKFORCE_PAYLOAD_FIELD_REQUIRED:event_date' using errcode = 'P0001';
    end if;
    if v_end_date < v_date or v_end_date > v_date + 30 then
      raise exception 'WORKFORCE_FIELD_INVALID:event_end_date' using errcode = 'P0001';
    end if;
  else
    if p_payload ? 'event_date' or p_payload ? 'event_end_date' then
      raise exception 'WORKFORCE_FIELD_INVALID:event_date' using errcode = 'P0001';
    end if;
    v_start := workforce.payload_local_timestamp(p_payload, 'start_local', v_timezone);
    v_end := workforce.payload_local_timestamp(p_payload, 'end_local', v_timezone);
    if v_start is null or v_end is null then
      raise exception 'WORKFORCE_PAYLOAD_FIELD_REQUIRED:period' using errcode = 'P0001';
    end if;
    if v_end <= v_start or v_end > v_start + interval '24 hours' then
      raise exception 'WORKFORCE_PERIOD_INVALID' using errcode = 'P0001';
    end if;
    -- A recorded period must already have happened; future work cannot be declared.
    if v_end > now() then
      raise exception 'WORKFORCE_PERIOD_IN_FUTURE' using errcode = 'P0001';
    end if;
    v_date := (v_start at time zone v_timezone)::date;
  end if;

  if p_employee.hired_on is not null and v_date < p_employee.hired_on then
    raise exception 'WORKFORCE_PERIOD_BEFORE_EMPLOYMENT' using errcode = 'P0001';
  end if;
  if v_all_day and v_date > v_today + 60 then
    raise exception 'WORKFORCE_PERIOD_IN_FUTURE' using errcode = 'P0001';
  end if;

  if p_actor_kind = 'EMPLOYEE' then
    v_source := case when v_date = v_today and not v_all_day then 'EMPLOYEE' else 'RETROACTIVE_EMPLOYEE' end;
    v_status := case when v_source = 'EMPLOYEE' then 'RECORDED' else 'PENDING_REVIEW' end;
  else
    v_source := case when v_date = v_today then 'MANAGER' else 'RETROACTIVE_MANAGER' end;
    v_status := 'RECORDED';
  end if;

  insert into workforce.work_exceptions(
    tenant_id, employer_id, employee_id, exception_type, source, status,
    event_date, event_end_date, all_day, reported_start, reported_end,
    employee_note, manager_note, recorded_by_admin_id, finished_at
  ) values (
    p_employee.tenant_id, p_employee.employer_id, p_employee.id, v_type, v_source, v_status,
    v_date, case when v_all_day then v_end_date end, v_all_day, v_start, v_end,
    case when p_actor_kind = 'EMPLOYEE' then workforce.payload_text(p_payload, 'note', 1000) end,
    case when p_actor_kind = 'OWNER' then workforce.payload_text(p_payload, 'note', 1000) end,
    p_actor_admin_id,
    now()
  )
  returning * into v_row;
  return v_row;
exception
  when exclusion_violation then
    raise exception 'WORKFORCE_EXTRA_PERIOD_OVERLAP' using errcode = 'P0001';
  when check_violation then
    raise exception 'WORKFORCE_EXCEPTION_INVALID' using errcode = 'P0001';
end;
$$;

create function workforce.list_exceptions_json(p_employee_id uuid, p_month text, p_audience text)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_start date;
begin
  if p_month is null or p_month !~ '^[0-9]{4}-(0[1-9]|1[0-2])$' then
    raise exception 'WORKFORCE_FIELD_INVALID:month' using errcode = 'P0001';
  end if;
  v_start := (p_month || '-01')::date;
  return coalesce((
    select jsonb_agg(workforce.exception_json(x, p_audience) order by x.event_date, x.reported_start nulls first, x.created_at)
    from workforce.work_exceptions x
    where x.employee_id = p_employee_id
      and x.event_date <= (v_start + interval '1 month - 1 day')::date
      and coalesce(x.event_end_date, x.event_date) >= v_start
  ), '[]'::jsonb);
end;
$$;

-- ---------------------------------------------------------------------------
-- Governed RPCs — employee
-- ---------------------------------------------------------------------------

create function public.service_workforce_employee_start_extra(
  p_actor_admin_id uuid,
  p_idempotency_key uuid,
  p_payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_command constant text := 'EMPLOYEE_START_EXTRA';
  v_employee workforce.employees := workforce.require_employee(p_actor_admin_id);
  v_replay jsonb;
  v_now timestamptz := now();
  v_row workforce.work_exceptions;
begin
  v_replay := workforce.begin_command(p_actor_admin_id, c_command, p_idempotency_key, p_payload);
  if v_replay is not null then
    return v_replay;
  end if;
  perform workforce.assert_payload(p_payload, array['note']);
  -- Serialize per employee so concurrent starts resolve deterministically.
  perform 1 from workforce.employees e where e.id = v_employee.id for update;
  if exists (select 1 from workforce.work_exceptions x where x.employee_id = v_employee.id and x.status = 'OPEN') then
    raise exception 'WORKFORCE_EXTRA_ALREADY_OPEN' using errcode = 'P0001';
  end if;

  insert into workforce.work_exceptions(
    tenant_id, employer_id, employee_id, exception_type, source, status,
    event_date, reported_start, employee_note, recorded_by_admin_id
  ) values (
    v_employee.tenant_id, v_employee.employer_id, v_employee.id, 'EXTRA_WORK', 'EMPLOYEE', 'OPEN',
    (v_now at time zone workforce.employer_timezone(v_employee.employer_id))::date,
    v_now, workforce.payload_text(p_payload, 'note', 1000), p_actor_admin_id
  )
  returning * into v_row;

  perform workforce.audit(v_employee.tenant_id, p_actor_admin_id, 'EMPLOYEE', c_command, 'work_exception', v_row.id,
    null, workforce.exception_audit_json(v_row));
  return workforce.finish_command(p_actor_admin_id, c_command, p_idempotency_key, p_payload, v_employee.tenant_id,
    jsonb_build_object('exception', workforce.exception_json(v_row, 'EMPLOYEE')));
exception
  when unique_violation then
    raise exception 'WORKFORCE_EXTRA_ALREADY_OPEN' using errcode = 'P0001';
  when exclusion_violation then
    raise exception 'WORKFORCE_EXTRA_PERIOD_OVERLAP' using errcode = 'P0001';
end;
$$;

create function public.service_workforce_employee_finish_extra(
  p_actor_admin_id uuid,
  p_idempotency_key uuid,
  p_payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_command constant text := 'EMPLOYEE_FINISH_EXTRA';
  v_employee workforce.employees := workforce.require_employee(p_actor_admin_id);
  v_replay jsonb;
  v_before workforce.work_exceptions;
  v_after workforce.work_exceptions;
  v_now timestamptz := now();
begin
  v_replay := workforce.begin_command(p_actor_admin_id, c_command, p_idempotency_key, p_payload);
  if v_replay is not null then
    return v_replay;
  end if;
  perform workforce.assert_payload(p_payload, array[]::text[]);

  select x.* into v_before
  from workforce.work_exceptions x
  where x.employee_id = v_employee.id and x.status = 'OPEN'
  for update;
  if v_before.id is null then
    raise exception 'WORKFORCE_EXTRA_NOT_OPEN' using errcode = 'P0001';
  end if;
  if v_now <= v_before.reported_start then
    raise exception 'WORKFORCE_PERIOD_INVALID' using errcode = 'P0001';
  end if;
  -- A period left open beyond 24h cannot be closed with the server clock; the
  -- employee finishes it through a correction request (S4) instead.
  if v_now > v_before.reported_start + interval '24 hours' then
    raise exception 'WORKFORCE_EXTRA_OPEN_TOO_LONG' using errcode = 'P0001';
  end if;

  update workforce.work_exceptions x
  set reported_end = v_now, finished_at = v_now, status = 'RECORDED'
  where x.id = v_before.id
  returning * into v_after;

  perform workforce.audit(v_employee.tenant_id, p_actor_admin_id, 'EMPLOYEE', c_command, 'work_exception', v_after.id,
    workforce.exception_audit_json(v_before), workforce.exception_audit_json(v_after));
  return workforce.finish_command(p_actor_admin_id, c_command, p_idempotency_key, p_payload, v_employee.tenant_id,
    jsonb_build_object('exception', workforce.exception_json(v_after, 'EMPLOYEE')));
exception
  when exclusion_violation then
    raise exception 'WORKFORCE_EXTRA_PERIOD_OVERLAP' using errcode = 'P0001';
end;
$$;

create function public.service_workforce_employee_record_exception(
  p_actor_admin_id uuid,
  p_idempotency_key uuid,
  p_payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_command constant text := 'EMPLOYEE_RECORD_EXCEPTION';
  v_employee workforce.employees := workforce.require_employee(p_actor_admin_id);
  v_replay jsonb;
  v_row workforce.work_exceptions;
begin
  v_replay := workforce.begin_command(p_actor_admin_id, c_command, p_idempotency_key, p_payload);
  if v_replay is not null then
    return v_replay;
  end if;
  perform workforce.assert_payload(p_payload,
    array['exception_type', 'start_local', 'end_local', 'all_day', 'event_date', 'event_end_date', 'note'],
    array['exception_type']);
  v_row := workforce.insert_recorded_exception(v_employee, p_actor_admin_id, 'EMPLOYEE', p_payload);

  perform workforce.audit(v_employee.tenant_id, p_actor_admin_id, 'EMPLOYEE', c_command, 'work_exception', v_row.id,
    null, workforce.exception_audit_json(v_row));
  return workforce.finish_command(p_actor_admin_id, c_command, p_idempotency_key, p_payload, v_employee.tenant_id,
    jsonb_build_object('exception', workforce.exception_json(v_row, 'EMPLOYEE')));
end;
$$;

create function public.service_workforce_employee_list_exceptions(p_actor_admin_id uuid, p_month text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_employee workforce.employees := workforce.require_employee(p_actor_admin_id);
begin
  return jsonb_build_object(
    'month', p_month,
    'open_extra', (
      select workforce.exception_json(x, 'EMPLOYEE')
      from workforce.work_exceptions x
      where x.employee_id = v_employee.id and x.status = 'OPEN'
    ),
    'exceptions', workforce.list_exceptions_json(v_employee.id, p_month, 'EMPLOYEE')
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Governed RPCs — owner
-- ---------------------------------------------------------------------------

create function public.service_workforce_owner_record_exception(
  p_actor_admin_id uuid,
  p_idempotency_key uuid,
  p_payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_command constant text := 'OWNER_RECORD_EXCEPTION';
  v_tenant_id uuid := workforce.require_owner(p_actor_admin_id);
  v_replay jsonb;
  v_employee workforce.employees;
  v_row workforce.work_exceptions;
begin
  v_replay := workforce.begin_command(p_actor_admin_id, c_command, p_idempotency_key, p_payload);
  if v_replay is not null then
    return v_replay;
  end if;
  perform workforce.assert_payload(p_payload,
    array['employee_id', 'exception_type', 'start_local', 'end_local', 'all_day', 'event_date', 'event_end_date', 'note'],
    array['employee_id', 'exception_type']);

  select e.* into v_employee
  from workforce.employees e
  where e.id = workforce.payload_uuid(p_payload, 'employee_id')
    and e.tenant_id = v_tenant_id
    and e.active;
  if v_employee.id is null then
    raise exception 'WORKFORCE_EMPLOYEE_NOT_FOUND' using errcode = 'P0001';
  end if;

  v_row := workforce.insert_recorded_exception(v_employee, p_actor_admin_id, 'OWNER', p_payload);

  perform workforce.audit(v_tenant_id, p_actor_admin_id, 'OWNER', c_command, 'work_exception', v_row.id,
    null, workforce.exception_audit_json(v_row));
  return workforce.finish_command(p_actor_admin_id, c_command, p_idempotency_key, p_payload, v_tenant_id,
    jsonb_build_object('exception', workforce.exception_json(v_row, 'OWNER')));
end;
$$;

create function public.service_workforce_owner_list_exceptions(p_actor_admin_id uuid, p_employee_id uuid, p_month text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := workforce.require_owner(p_actor_admin_id);
begin
  if not exists (select 1 from workforce.employees e where e.id = p_employee_id and e.tenant_id = v_tenant_id) then
    raise exception 'WORKFORCE_EMPLOYEE_NOT_FOUND' using errcode = 'P0001';
  end if;
  return jsonb_build_object(
    'month', p_month,
    'employee_id', p_employee_id,
    'exceptions', workforce.list_exceptions_json(p_employee_id, p_month, 'OWNER')
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------------

revoke all on all tables in schema workforce from public, anon, authenticated, service_role;
revoke all on all functions in schema workforce from public, anon, authenticated, service_role;

do $$
declare
  v_identity text;
begin
  foreach v_identity in array array[
    'public.service_workforce_employee_start_extra(uuid,uuid,jsonb)',
    'public.service_workforce_employee_finish_extra(uuid,uuid,jsonb)',
    'public.service_workforce_employee_record_exception(uuid,uuid,jsonb)',
    'public.service_workforce_employee_list_exceptions(uuid,text)',
    'public.service_workforce_owner_record_exception(uuid,uuid,jsonb)',
    'public.service_workforce_owner_list_exceptions(uuid,uuid,text)'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', v_identity);
    execute format('grant execute on function %s to service_role', v_identity);
  end loop;
end
$$;
