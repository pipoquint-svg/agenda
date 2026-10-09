-- Workforce S6 — monthly closure, immutable snapshots, versions and diff
-- (ADR-017, spec §11–12). Competência is always the civil month. Closing writes
-- an immutable snapshot plus the accountant-safe report payload (no free text,
-- no reasons, no medical detail); reopening requires a reason and the next
-- closure is version + 1. No e-mail is sent in this slice.

create table workforce.work_periods (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  employer_id uuid not null,
  employee_id uuid not null,
  period_start date not null,
  period_end date not null,
  status text not null default 'OPEN',
  current_version integer not null default 0,
  blockers jsonb not null default '[]'::jsonb,
  last_evaluated_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint work_periods_tenant_id_key unique (tenant_id, id),
  constraint work_periods_employee_month_key unique (employee_id, period_start),
  constraint work_periods_employee_fkey foreign key (tenant_id, employee_id)
    references workforce.employees(tenant_id, id) on delete restrict,
  constraint work_periods_employer_fkey foreign key (tenant_id, employer_id)
    references workforce.employers(tenant_id, id) on delete restrict,
  constraint work_periods_civil_month check (
    period_start = date_trunc('month', period_start)::date
    and period_end = (period_start + interval '1 month - 1 day')::date
  ),
  constraint work_periods_status_valid check (status in ('OPEN', 'READY_TO_CLOSE', 'BLOCKED', 'CLOSED', 'REOPENED')),
  constraint work_periods_version_valid check (current_version >= 0 and (status <> 'CLOSED' or current_version >= 1)),
  constraint work_periods_blockers_array check (jsonb_typeof(blockers) = 'array')
);
comment on table workforce.work_periods is
  'One competência (civil month) per employee. No configurable payroll start/end day exists by design.';

create table workforce.work_period_closures (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  period_id uuid not null,
  version integer not null,
  report_payload jsonb not null,
  snapshot jsonb not null,
  snapshot_sha256 text not null,
  diff_from_previous jsonb,
  closed_by_kind text not null,
  closed_by_admin_id uuid references public.admin_users(id) on delete restrict,
  closed_at timestamptz not null default now(),
  reopened_at timestamptz,
  reopened_by_admin_id uuid references public.admin_users(id) on delete restrict,
  reopen_reason text,
  constraint work_period_closures_tenant_id_key unique (tenant_id, id),
  constraint work_period_closures_version_key unique (period_id, version),
  constraint work_period_closures_period_fkey foreign key (tenant_id, period_id)
    references workforce.work_periods(tenant_id, id) on delete restrict,
  constraint work_period_closures_version_valid check (version >= 1),
  constraint work_period_closures_closed_by_valid check (
    (closed_by_kind = 'OWNER' and closed_by_admin_id is not null)
    or (closed_by_kind = 'SYSTEM' and closed_by_admin_id is null)
  ),
  constraint work_period_closures_reopen_valid check (
    (reopened_at is null and reopened_by_admin_id is null and reopen_reason is null)
    or (reopened_at is not null and reopened_by_admin_id is not null
        and reopen_reason is not null and length(btrim(reopen_reason)) between 3 and 1000)
  ),
  constraint work_period_closures_sha_valid check (snapshot_sha256 ~ '^[0-9a-f]{64}$')
);

create table workforce.work_period_reports (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  closure_id uuid not null,
  report_kind text not null,
  payload jsonb not null,
  payload_sha256 text not null,
  generated_at timestamptz not null default now(),
  constraint work_period_reports_closure_fkey foreign key (tenant_id, closure_id)
    references workforce.work_period_closures(tenant_id, id) on delete restrict,
  constraint work_period_reports_kind_valid check (report_kind in ('ACCOUNTANT_MIRROR', 'EMPLOYEE_MIRROR')),
  constraint work_period_reports_kind_key unique (closure_id, report_kind),
  constraint work_period_reports_sha_valid check (payload_sha256 ~ '^[0-9a-f]{64}$')
);

create table workforce.work_period_acknowledgements (
  closure_id uuid not null,
  tenant_id uuid not null,
  employee_id uuid not null,
  acknowledged_by_admin_id uuid not null references public.admin_users(id) on delete restrict,
  acknowledged_at timestamptz not null default now(),
  primary key (closure_id, employee_id),
  constraint work_period_acknowledgements_closure_fkey foreign key (tenant_id, closure_id)
    references workforce.work_period_closures(tenant_id, id) on delete restrict
);

alter table workforce.work_periods enable row level security;
alter table workforce.work_periods force row level security;
alter table workforce.work_period_closures enable row level security;
alter table workforce.work_period_closures force row level security;
alter table workforce.work_period_reports enable row level security;
alter table workforce.work_period_reports force row level security;
alter table workforce.work_period_acknowledgements enable row level security;
alter table workforce.work_period_acknowledgements force row level security;
create policy work_periods_owner_only on workforce.work_periods as permissive for all to postgres using (true) with check (true);
create policy work_period_closures_owner_only on workforce.work_period_closures as permissive for all to postgres using (true) with check (true);
create policy work_period_reports_owner_only on workforce.work_period_reports as permissive for all to postgres using (true) with check (true);
create policy work_period_acknowledgements_owner_only on workforce.work_period_acknowledgements as permissive for all to postgres using (true) with check (true);

create trigger work_periods_touch before update on workforce.work_periods
  for each row execute function workforce.touch_updated_at();

-- Snapshot immutability: content never changes; reopen metadata is written once.
create function workforce.guard_closure()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'WORKFORCE_IMMUTABLE:%', tg_table_name using errcode = 'P0001';
  end if;
  if (to_jsonb(new) - array['reopened_at', 'reopened_by_admin_id', 'reopen_reason'])
       is distinct from (to_jsonb(old) - array['reopened_at', 'reopened_by_admin_id', 'reopen_reason'])
     or old.reopened_at is not null then
    raise exception 'WORKFORCE_IMMUTABLE:%', tg_table_name using errcode = 'P0001';
  end if;
  return new;
end;
$$;
create trigger work_period_closures_guard before update or delete on workforce.work_period_closures
  for each row execute function workforce.guard_closure();
create trigger work_period_reports_immutable before update or delete on workforce.work_period_reports
  for each row execute function workforce.reject_mutation();
create trigger work_period_acknowledgements_immutable before update or delete on workforce.work_period_acknowledgements
  for each row execute function workforce.reject_mutation();

-- ---------------------------------------------------------------------------
-- Closed-period guard: nothing that changes a CLOSED competência is accepted.
-- ---------------------------------------------------------------------------

create function workforce.period_is_closed(p_employee_id uuid, p_date date)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (
    select 1 from workforce.work_periods wp
    where wp.employee_id = p_employee_id
      and wp.period_start = date_trunc('month', p_date)::date
      and wp.status = 'CLOSED'
  );
$$;

create function workforce.guard_closed_period_exception()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if workforce.period_is_closed(new.employee_id, new.event_date)
     or (new.event_end_date is not null and workforce.period_is_closed(new.employee_id, new.event_end_date)) then
    raise exception 'WORKFORCE_PERIOD_CLOSED' using errcode = 'P0001';
  end if;
  return new;
end;
$$;
create trigger work_exceptions_closed_period before insert or update on workforce.work_exceptions
  for each row execute function workforce.guard_closed_period_exception();

create function workforce.guard_closed_period_correction()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if workforce.period_is_closed(new.employee_id, new.proposed_event_date)
     or workforce.period_is_closed(new.employee_id, (select x.event_date from workforce.work_exceptions x where x.id = new.exception_id)) then
    raise exception 'WORKFORCE_PERIOD_CLOSED' using errcode = 'P0001';
  end if;
  return new;
end;
$$;
create trigger work_exception_corrections_closed_period before insert or update on workforce.work_exception_corrections
  for each row execute function workforce.guard_closed_period_correction();

-- Administrative classification changes the reported content: blocked while
-- CLOSED. Employee acknowledgements/contests stay possible after closure (her
-- right to disagree is preserved; the owner reopens to act on it).
create function workforce.guard_closed_period_classification()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if exists (
    select 1 from workforce.work_exceptions x
    where x.id = new.exception_id
      and (workforce.period_is_closed(x.employee_id, x.event_date)
           or (x.event_end_date is not null and workforce.period_is_closed(x.employee_id, x.event_end_date)))
  ) then
    raise exception 'WORKFORCE_PERIOD_CLOSED' using errcode = 'P0001';
  end if;
  return new;
end;
$$;
create trigger work_exception_classifications_closed_period before insert or update on workforce.work_exception_classifications
  for each row execute function workforce.guard_closed_period_classification();

create function workforce.guard_closed_period_schedule()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' and exists (
    select 1 from workforce.work_periods wp
    where wp.employee_id = new.employee_id and wp.status = 'CLOSED' and wp.period_end >= new.effective_from
  ) then
    raise exception 'WORKFORCE_PERIOD_CLOSED' using errcode = 'P0001';
  end if;
  return new;
end;
$$;
create trigger employment_schedules_closed_period before insert on workforce.employment_schedules
  for each row execute function workforce.guard_closed_period_schedule();

-- ---------------------------------------------------------------------------
-- Report payload (accountant-safe) and snapshot
-- ---------------------------------------------------------------------------

create function workforce.weekday_pt(p_date date)
returns text
language sql
immutable
set search_path = ''
as $$
  select (array['segunda-feira', 'terça-feira', 'quarta-feira', 'quinta-feira', 'sexta-feira', 'sábado', 'domingo'])[extract(isodow from p_date)::int];
$$;

-- Rows and totals exactly as reported. Free-text notes, reasons, contest text
-- and medical detail are never read here.
create function workforce.build_report_payload(p_period_id uuid)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_period workforce.work_periods;
  v_employer workforce.employers;
  v_employee workforce.employees;
  v_rows jsonb;
  v_totals jsonb;
  v_schedules jsonb;
begin
  select * into v_period from workforce.work_periods where id = p_period_id;
  select * into v_employer from workforce.employers where id = v_period.employer_id;
  select * into v_employee from workforce.employees where id = v_period.employee_id;

  select coalesce(jsonb_agg(row_value order by sort_key), '[]'::jsonb) into v_rows
  from (
    -- Extra work: one row per exception and local date (midnight split).
    select
      (s.segment_date::text || to_char(min(s.segment_start), 'HH24MISS') || x.id::text) as sort_key,
      jsonb_build_object(
        'row_key', x.id::text || ':' || s.segment_date::text,
        'date', s.segment_date,
        'weekday', workforce.weekday_pt(s.segment_date),
        'period', to_char(min(s.segment_start) at time zone v_employer.timezone, 'HH24:MI')
                  || '–' || to_char(max(s.segment_end) at time zone v_employer.timezone, 'HH24:MI'),
        'type', 'EXTRA_WORK',
        'classification', min(s.classification) filter (where s.classification <> 'REGULAR'),
        'administrative_classification', workforce.current_classification(x.id),
        'minutes', (case when coalesce(ds.tolerance_applied, false) then 0
                    else floor(coalesce(sum(s.duration_seconds) filter (where s.segment_kind <> 'REGULAR_OVERLAP'), 0) / 60.0) end)::int,
        'tolerance_applied', coalesce(ds.tolerance_applied, false),
        'status', x.status
      ) as row_value
    from workforce.work_exceptions x
    cross join lateral workforce.effective_exception(x.id) ef
    join workforce.work_exception_segments s on s.exception_id = x.id
    left join lateral workforce.day_summary(v_employee.id, s.segment_date, s.segment_date) ds on true
    where x.employee_id = v_employee.id
      and x.status not in ('WITHDRAWN_BY_EMPLOYEE', 'OPEN')
      and ef.exception_type = 'EXTRA_WORK'
      and s.segment_date between v_period.period_start and v_period.period_end
    group by x.id, x.status, s.segment_date, ds.tolerance_applied
    having coalesce(sum(s.duration_seconds) filter (where s.segment_kind <> 'REGULAR_OVERLAP'), 0) > 0
    union all
    -- Occurrences (late arrival, early leave, absence, medical leave, other):
    -- duration is the habitual time affected; no negative balance is derived.
    select
      (ef.event_date::text || coalesce(to_char(ef.period_start, 'HH24MISS'), '000000') || x.id::text),
      jsonb_build_object(
        'row_key', x.id::text || ':' || ef.event_date::text,
        'date', ef.event_date,
        'end_date', ef.event_end_date,
        'weekday', workforce.weekday_pt(ef.event_date),
        'period', case when ef.all_day then 'dia inteiro'
                       else to_char(ef.period_start at time zone v_employer.timezone, 'HH24:MI')
                            || '–' || to_char(ef.period_end at time zone v_employer.timezone, 'HH24:MI') end,
        'type', ef.exception_type,
        'classification', ef.exception_type,
        'administrative_classification', workforce.current_classification(x.id),
        'minutes', case when ef.all_day then null else (
          select floor(coalesce(sum(s.duration_seconds) filter (where s.segment_kind = 'REGULAR_OVERLAP'), 0) / 60.0)::int
          from workforce.work_exception_segments s where s.exception_id = x.id) end,
        'tolerance_applied', false,
        'status', x.status
      )
    from workforce.work_exceptions x
    cross join lateral workforce.effective_exception(x.id) ef
    where x.employee_id = v_employee.id
      and x.status not in ('WITHDRAWN_BY_EMPLOYEE', 'OPEN')
      and ef.exception_type <> 'EXTRA_WORK'
      and ef.event_date between v_period.period_start and v_period.period_end
  ) r;

  select jsonb_build_object(
    'extra_weekday_minutes', floor(coalesce(sum(d.extra_weekday_seconds), 0) / 60.0)::int,
    'extra_saturday_minutes', floor(coalesce(sum(d.extra_saturday_seconds), 0) / 60.0)::int,
    'extra_sunday_minutes', floor(coalesce(sum(d.extra_sunday_seconds), 0) / 60.0)::int,
    'extra_holiday_minutes', floor(coalesce(sum(d.extra_holiday_seconds), 0) / 60.0)::int
  ) into v_totals
  from workforce.day_summary(v_employee.id, v_period.period_start, v_period.period_end) d;

  select coalesce(jsonb_agg(workforce.schedule_json(s.id) order by s.effective_from), '[]'::jsonb) into v_schedules
  from workforce.employment_schedules s
  where s.employee_id = v_employee.id
    and s.validity && daterange(v_period.period_start, v_period.period_end + 1, '[)');

  return jsonb_build_object(
    'format', 'WORKFORCE_MONTHLY_REPORT_V1',
    'employer', jsonb_build_object(
      'legal_name', v_employer.legal_name,
      'trade_name', v_employer.trade_name,
      'cnpj', v_employer.cnpj,
      'workplace_city', v_employer.workplace_city,
      'workplace_state', v_employer.workplace_state
    ),
    'competencia', to_char(v_period.period_start, 'YYYY-MM'),
    'period_start', v_period.period_start,
    'period_end', v_period.period_end,
    'employee', jsonb_build_object('display_name', v_employee.display_name),
    'habitual_schedules', v_schedules,
    'rows', v_rows,
    'totals', v_totals
  );
end;
$$;

create function workforce.payload_diff(p_previous jsonb, p_current jsonb)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  with prev as (
    select r ->> 'row_key' as k, r from jsonb_array_elements(coalesce(p_previous -> 'rows', '[]'::jsonb)) r
  ), cur as (
    select r ->> 'row_key' as k, r from jsonb_array_elements(coalesce(p_current -> 'rows', '[]'::jsonb)) r
  )
  select jsonb_build_object(
    'added', coalesce((select jsonb_agg(c.r order by c.k) from cur c where not exists (select 1 from prev p where p.k = c.k)), '[]'::jsonb),
    'removed', coalesce((select jsonb_agg(p.r order by p.k) from prev p where not exists (select 1 from cur c where c.k = p.k)), '[]'::jsonb),
    'changed', coalesce((
      select jsonb_agg(jsonb_build_object(
        'row_key', c.k,
        'date', c.r -> 'date',
        'fields', (
          select jsonb_object_agg(f, jsonb_build_object('from', p.r -> f, 'to', c.r -> f))
          from unnest(array['period', 'type', 'classification', 'administrative_classification', 'minutes', 'status', 'tolerance_applied']) f
          where p.r -> f is distinct from c.r -> f
        )
      ) order by c.k)
      from cur c join prev p on p.k = c.k
      where p.r is distinct from c.r
    ), '[]'::jsonb),
    'totals', jsonb_build_object('from', p_previous -> 'totals', 'to', p_current -> 'totals')
  );
$$;

-- ---------------------------------------------------------------------------
-- Period lifecycle
-- ---------------------------------------------------------------------------

create function workforce.parse_month(p_month text)
returns date
language plpgsql
immutable
set search_path = ''
as $$
begin
  if p_month is null or p_month !~ '^[0-9]{4}-(0[1-9]|1[0-2])$' then
    raise exception 'WORKFORCE_FIELD_INVALID:month' using errcode = 'P0001';
  end if;
  return (p_month || '-01')::date;
end;
$$;

create function workforce.ensure_period(p_employee_id uuid, p_period_start date)
returns workforce.work_periods
language plpgsql
set search_path = ''
as $$
declare
  v_employee workforce.employees;
  v_period workforce.work_periods;
begin
  select e.* into v_employee from workforce.employees e where e.id = p_employee_id;
  insert into workforce.work_periods(tenant_id, employer_id, employee_id, period_start, period_end)
  values (v_employee.tenant_id, v_employee.employer_id, v_employee.id, p_period_start,
          (p_period_start + interval '1 month - 1 day')::date)
  on conflict (employee_id, period_start) do nothing;
  select wp.* into v_period from workforce.work_periods wp
  where wp.employee_id = p_employee_id and wp.period_start = p_period_start
  for update;
  return v_period;
end;
$$;

-- Recalculate and classify a period: OPEN while the month is running,
-- BLOCKED with explicit blockers, READY_TO_CLOSE otherwise. CLOSED stays CLOSED.
create function workforce.evaluate_period(p_period_id uuid)
returns workforce.work_periods
language plpgsql
set search_path = ''
as $$
declare
  v_period workforce.work_periods;
  v_employer workforce.employers;
  v_id uuid;
  v_blockers jsonb;
  v_status text;
begin
  select wp.* into v_period from workforce.work_periods wp where wp.id = p_period_id for update;
  if v_period.status = 'CLOSED' then
    return v_period;
  end if;
  select er.* into v_employer from workforce.employers er where er.id = v_period.employer_id;

  for v_id in
    select x.id from workforce.work_exceptions x
    where x.employee_id = v_period.employee_id
      and x.event_date between v_period.period_start - 1 and v_period.period_end
  loop
    perform workforce.recalculate_exception(v_id);
  end loop;
  perform workforce.evaluate_compliance(v_period.employee_id, v_period.period_start, v_period.period_end);

  select coalesce(jsonb_agg(jsonb_build_object('blocker', b.blocker, 'exception_id', b.exception_id, 'reference_id', b.reference_id)
           order by b.blocker, b.exception_id), '[]'::jsonb)
    into v_blockers
  from workforce.review_blockers(v_period.employee_id, v_period.period_start, v_period.period_end) b;

  -- Critical inconsistencies: the accountant report needs razão social + CNPJ
  -- and a habitual schedule for the whole competência.
  if v_employer.cnpj is null then
    v_blockers := v_blockers || jsonb_build_array(jsonb_build_object('blocker', 'EMPLOYER_CNPJ_MISSING'));
  end if;
  if exists (
    select 1 from generate_series(v_period.period_start, v_period.period_end, interval '1 day') d
    where workforce.current_schedule_id(v_period.employee_id, d::date) is null
  ) then
    v_blockers := v_blockers || jsonb_build_array(jsonb_build_object('blocker', 'SCHEDULE_MISSING'));
  end if;

  v_status := case
    when v_period.period_end >= workforce.local_today(v_period.employer_id) then
      case when v_period.status = 'REOPENED' then 'REOPENED' else 'OPEN' end
    when jsonb_array_length(v_blockers) > 0 then 'BLOCKED'
    else 'READY_TO_CLOSE'
  end;

  update workforce.work_periods wp
  set status = v_status, blockers = v_blockers, last_evaluated_at = now()
  where wp.id = v_period.id
  returning * into v_period;
  return v_period;
end;
$$;

-- Close one period (OWNER or SYSTEM). Requires READY_TO_CLOSE after a fresh evaluation.
create function workforce.close_period(p_period_id uuid, p_actor_admin_id uuid, p_actor_kind text)
returns workforce.work_period_closures
language plpgsql
set search_path = ''
as $$
declare
  v_period workforce.work_periods;
  v_previous workforce.work_period_closures;
  v_closure workforce.work_period_closures;
  v_payload jsonb;
  v_snapshot jsonb;
  v_employee_payload jsonb;
begin
  v_period := workforce.evaluate_period(p_period_id);
  if v_period.status = 'CLOSED' then
    raise exception 'WORKFORCE_PERIOD_ALREADY_CLOSED' using errcode = 'P0001';
  end if;
  if v_period.status <> 'READY_TO_CLOSE' then
    raise exception 'WORKFORCE_PERIOD_NOT_READY:%', lower(v_period.status) using errcode = 'P0001';
  end if;

  select c.* into v_previous from workforce.work_period_closures c
  where c.period_id = v_period.id order by c.version desc limit 1;

  v_payload := workforce.build_report_payload(v_period.id);
  v_snapshot := jsonb_build_object(
    'report', v_payload,
    'exceptions', coalesce((
      select jsonb_agg(jsonb_build_object(
        'exception_id', x.id,
        'status', x.status,
        'source', x.source,
        'raw_start', x.reported_start,
        'raw_end', x.reported_end,
        'effective', (select to_jsonb(ef) from workforce.effective_exception(x.id) ef),
        'segments', workforce.segments_json(x.id)
      ) order by x.event_date, x.created_at)
      from workforce.work_exceptions x
      where x.employee_id = v_period.employee_id
        and x.event_date between v_period.period_start - 1 and v_period.period_end
    ), '[]'::jsonb),
    'acknowledged_alerts', coalesce((
      select jsonb_agg(jsonb_build_object('alert_type', a.alert_type, 'reference_date', a.reference_date,
        'measured_minutes', a.measured_minutes, 'threshold_minutes', a.threshold_minutes, 'status', a.status)
        order by a.reference_date, a.alert_type)
      from workforce.compliance_alerts a
      where a.employee_id = v_period.employee_id
        and a.reference_date between v_period.period_start and v_period.period_end
        and a.status <> 'RESOLVED'
    ), '[]'::jsonb),
    'version', v_period.current_version + 1
  );

  insert into workforce.work_period_closures(
    tenant_id, period_id, version, report_payload, snapshot, snapshot_sha256, diff_from_previous,
    closed_by_kind, closed_by_admin_id
  ) values (
    v_period.tenant_id, v_period.id, v_period.current_version + 1, v_payload, v_snapshot,
    encode(sha256(convert_to((v_snapshot)::text, 'UTF8')), 'hex'),
    case when v_previous.id is null then null else workforce.payload_diff(v_previous.report_payload, v_payload) end,
    p_actor_kind, case when p_actor_kind = 'OWNER' then p_actor_admin_id end
  )
  returning * into v_closure;

  v_employee_payload := v_payload || jsonb_build_object('audience', 'EMPLOYEE', 'version', v_closure.version);
  insert into workforce.work_period_reports(tenant_id, closure_id, report_kind, payload, payload_sha256)
  values
    (v_period.tenant_id, v_closure.id, 'ACCOUNTANT_MIRROR',
     v_payload || jsonb_build_object('audience', 'ACCOUNTANT', 'version', v_closure.version),
     encode(sha256(convert_to(((v_payload || jsonb_build_object('audience', 'ACCOUNTANT', 'version', v_closure.version)))::text, 'UTF8')), 'hex')),
    (v_period.tenant_id, v_closure.id, 'EMPLOYEE_MIRROR', v_employee_payload,
     encode(sha256(convert_to((v_employee_payload)::text, 'UTF8')), 'hex'));

  update workforce.work_periods wp
  set status = 'CLOSED', current_version = v_closure.version, blockers = '[]'::jsonb
  where wp.id = v_period.id;

  perform workforce.audit(v_period.tenant_id, p_actor_admin_id, p_actor_kind, 'CLOSE_PERIOD', 'work_period', v_period.id,
    null, jsonb_build_object('version', v_closure.version, 'closure_id', v_closure.id, 'snapshot_sha256', v_closure.snapshot_sha256));
  return v_closure;
end;
$$;

create function workforce.period_json(p_period workforce.work_periods, p_audience text)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'period_id', p_period.id,
    'competencia', to_char(p_period.period_start, 'YYYY-MM'),
    'period_start', p_period.period_start,
    'period_end', p_period.period_end,
    'status', p_period.status,
    'current_version', p_period.current_version,
    'is_reopened', exists (
      select 1 from workforce.work_period_closures c
      where c.period_id = p_period.id and c.version = p_period.current_version and c.reopened_at is not null
    ),
    'blockers', case when p_audience = 'OWNER' then p_period.blockers
                     else to_jsonb(coalesce((select array_agg(distinct b ->> 'blocker') from jsonb_array_elements(p_period.blockers) b), '{}'::text[])) end,
    'last_evaluated_at', p_period.last_evaluated_at,
    'closures', coalesce((
      select jsonb_agg(jsonb_build_object(
        'closure_id', c.id,
        'version', c.version,
        'closed_by_kind', c.closed_by_kind,
        'closed_at', c.closed_at,
        'reopened_at', c.reopened_at,
        'snapshot_sha256', c.snapshot_sha256,
        'diff_from_previous', c.diff_from_previous,
        'acknowledged_by_employee', exists (select 1 from workforce.work_period_acknowledgements a where a.closure_id = c.id)
      ) || case when p_audience = 'OWNER' then jsonb_build_object('reopen_reason', c.reopen_reason) else '{}'::jsonb end
      order by c.version desc)
      from workforce.work_period_closures c where c.period_id = p_period.id
    ), '[]'::jsonb)
  );
$$;

-- ---------------------------------------------------------------------------
-- Governed RPCs
-- ---------------------------------------------------------------------------

create function public.service_workforce_owner_manage_period(
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
  c_command constant text := 'OWNER_MANAGE_PERIOD';
  v_tenant_id uuid := workforce.require_owner(p_actor_admin_id);
  v_replay jsonb;
  v_action text;
  v_employee workforce.employees;
  v_period workforce.work_periods;
  v_closure workforce.work_period_closures;
  v_reason text;
begin
  v_replay := workforce.begin_command(p_actor_admin_id, c_command, p_idempotency_key, p_payload);
  if v_replay is not null then
    return v_replay;
  end if;
  perform workforce.assert_payload(p_payload, array['action', 'employee_id', 'month', 'reason'],
    array['action', 'employee_id', 'month']);
  v_action := upper(workforce.payload_text(p_payload, 'action', 16));
  select e.* into v_employee from workforce.employees e
  where e.id = workforce.payload_uuid(p_payload, 'employee_id') and e.tenant_id = v_tenant_id;
  if v_employee.id is null then
    raise exception 'WORKFORCE_EMPLOYEE_NOT_FOUND' using errcode = 'P0001';
  end if;
  v_period := workforce.ensure_period(v_employee.id, workforce.parse_month(workforce.payload_text(p_payload, 'month', 7)));

  if v_action = 'EVALUATE' then
    v_period := workforce.evaluate_period(v_period.id);
  elsif v_action = 'CLOSE' then
    v_closure := workforce.close_period(v_period.id, p_actor_admin_id, 'OWNER');
  elsif v_action = 'REOPEN' then
    v_reason := workforce.require_reason(p_payload, 'reason');
    if v_period.status <> 'CLOSED' then
      raise exception 'WORKFORCE_PERIOD_NOT_CLOSED' using errcode = 'P0001';
    end if;
    update workforce.work_period_closures c
    set reopened_at = now(), reopened_by_admin_id = p_actor_admin_id, reopen_reason = v_reason
    where c.period_id = v_period.id and c.version = v_period.current_version;
    update workforce.work_periods wp set status = 'REOPENED' where wp.id = v_period.id;
    perform workforce.audit(v_tenant_id, p_actor_admin_id, 'OWNER', c_command || ':REOPEN', 'work_period', v_period.id,
      null, jsonb_build_object('version', v_period.current_version));
    v_period := workforce.evaluate_period(v_period.id);
  else
    raise exception 'WORKFORCE_FIELD_INVALID:action' using errcode = 'P0001';
  end if;

  select wp.* into v_period from workforce.work_periods wp where wp.id = v_period.id;
  return workforce.finish_command(p_actor_admin_id, c_command, p_idempotency_key, p_payload, v_tenant_id,
    jsonb_build_object('period', workforce.period_json(v_period, 'OWNER')));
end;
$$;

create function public.service_workforce_owner_get_period(p_actor_admin_id uuid, p_employee_id uuid, p_month text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := workforce.require_owner(p_actor_admin_id);
  v_period workforce.work_periods;
begin
  if not exists (select 1 from workforce.employees e where e.id = p_employee_id and e.tenant_id = v_tenant_id) then
    raise exception 'WORKFORCE_EMPLOYEE_NOT_FOUND' using errcode = 'P0001';
  end if;
  select wp.* into v_period from workforce.work_periods wp
  where wp.employee_id = p_employee_id and wp.period_start = workforce.parse_month(p_month);
  return jsonb_build_object(
    'period', case when v_period.id is null then null else workforce.period_json(v_period, 'OWNER') end,
    'preview', case when v_period.id is null then null else workforce.build_report_payload(v_period.id) end,
    'latest_report', (
      select r.payload from workforce.work_period_reports r
      join workforce.work_period_closures c on c.id = r.closure_id
      where c.period_id = v_period.id and r.report_kind = 'ACCOUNTANT_MIRROR'
      order by c.version desc limit 1
    )
  );
end;
$$;

create function public.service_workforce_employee_get_mirror(p_actor_admin_id uuid, p_month text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_employee workforce.employees := workforce.require_employee(p_actor_admin_id);
  v_period workforce.work_periods;
begin
  select wp.* into v_period from workforce.work_periods wp
  where wp.employee_id = v_employee.id and wp.period_start = workforce.parse_month(p_month);
  return jsonb_build_object(
    'period', case when v_period.id is null then null else workforce.period_json(v_period, 'EMPLOYEE') - 'blockers' end,
    'mirror', (
      select r.payload || jsonb_build_object('closure_id', c.id)
      from workforce.work_period_reports r
      join workforce.work_period_closures c on c.id = r.closure_id
      where c.period_id = v_period.id and r.report_kind = 'EMPLOYEE_MIRROR' and c.reopened_at is null
      order by c.version desc limit 1
    )
  );
end;
$$;

create function public.service_workforce_employee_acknowledge_mirror(
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
  c_command constant text := 'EMPLOYEE_ACKNOWLEDGE_MIRROR';
  v_employee workforce.employees := workforce.require_employee(p_actor_admin_id);
  v_replay jsonb;
  v_closure workforce.work_period_closures;
begin
  v_replay := workforce.begin_command(p_actor_admin_id, c_command, p_idempotency_key, p_payload);
  if v_replay is not null then
    return v_replay;
  end if;
  perform workforce.assert_payload(p_payload, array['closure_id'], array['closure_id']);
  select c.* into v_closure
  from workforce.work_period_closures c
  join workforce.work_periods wp on wp.id = c.period_id
  where c.id = workforce.payload_uuid(p_payload, 'closure_id') and wp.employee_id = v_employee.id;
  if v_closure.id is null then
    raise exception 'WORKFORCE_CLOSURE_NOT_FOUND' using errcode = 'P0001';
  end if;
  insert into workforce.work_period_acknowledgements(closure_id, tenant_id, employee_id, acknowledged_by_admin_id)
  values (v_closure.id, v_closure.tenant_id, v_employee.id, p_actor_admin_id)
  on conflict do nothing;
  perform workforce.audit(v_employee.tenant_id, p_actor_admin_id, 'EMPLOYEE', c_command, 'work_period_closure', v_closure.id, null,
    jsonb_build_object('version', v_closure.version));
  return workforce.finish_command(p_actor_admin_id, c_command, p_idempotency_key, p_payload, v_employee.tenant_id,
    jsonb_build_object('closure_id', v_closure.id, 'acknowledged', true));
end;
$$;

revoke all on all tables in schema workforce from public, anon, authenticated, service_role;
revoke all on all functions in schema workforce from public, anon, authenticated, service_role;

do $$
declare
  v_identity text;
begin
  foreach v_identity in array array[
    'public.service_workforce_owner_manage_period(uuid,uuid,jsonb)',
    'public.service_workforce_owner_get_period(uuid,uuid,text)',
    'public.service_workforce_employee_get_mirror(uuid,text)',
    'public.service_workforce_employee_acknowledge_mirror(uuid,uuid,jsonb)'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', v_identity);
    execute format('grant execute on function %s to service_role', v_identity);
  end loop;
end
$$;
