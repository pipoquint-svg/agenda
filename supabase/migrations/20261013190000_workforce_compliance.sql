-- Workforce S5 — compliance review engine (ADR-017, spec §10).
-- Alerts are REVIEW items, never legal verdicts. Every limit is a per-employer
-- parameter (CLT arts. 59, 66, 67 and 71, contract/CCT). Súmula 437 is not used.
-- Evaluation is deterministic and idempotent: one row per (employee, type,
-- reference date); identical data never creates or reopens alerts.

alter table workforce.payroll_settings
  add column intrajourney_long_work_threshold_minutes integer not null default 360,
  add column intrajourney_short_work_threshold_minutes integer not null default 240,
  add column minimum_short_interval_minutes integer not null default 15,
  add constraint payroll_settings_intrajourney_valid check (
    intrajourney_long_work_threshold_minutes between 0 and 1440
    and intrajourney_short_work_threshold_minutes between 0 and intrajourney_long_work_threshold_minutes
    and minimum_short_interval_minutes between 0 and 600
  );

comment on column workforce.payroll_settings.minimum_long_interval_minutes is
  'Minimum interval when work exceeds intrajourney_long_work_threshold_minutes (CLT art. 71 caput, or contract/CCT).';
comment on column workforce.payroll_settings.minimum_short_interval_minutes is
  'Minimum interval when work exceeds intrajourney_short_work_threshold_minutes (CLT art. 71 §1, or contract/CCT).';
comment on column workforce.payroll_settings.split_shift_review_threshold_minutes is
  'A gap inside one journey longer than this is flagged SPLIT_SHIFT_REVIEW (review, not a violation).';

create table workforce.compliance_alerts (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  employee_id uuid not null,
  alert_type text not null,
  reference_date date not null,
  measured_minutes integer not null,
  threshold_minutes integer not null,
  details jsonb not null default '{}'::jsonb,
  status text not null default 'OPEN',
  detected_at timestamptz not null default now(),
  last_evaluated_at timestamptz not null default now(),
  acknowledged_by_admin_id uuid references public.admin_users(id) on delete restrict,
  acknowledged_at timestamptz,
  acknowledgement_note text,
  resolved_at timestamptz,
  constraint compliance_alerts_employee_fkey foreign key (tenant_id, employee_id)
    references workforce.employees(tenant_id, id) on delete restrict,
  constraint compliance_alerts_type_valid check (alert_type in (
    'EXTRA_DAILY_LIMIT_REVIEW', 'INTERJOURNEY_REST_REVIEW', 'INTRAJOURNEY_INTERVAL_REVIEW',
    'SPLIT_SHIFT_REVIEW', 'WEEKLY_REST_REVIEW'
  )),
  constraint compliance_alerts_status_valid check (
    (status = 'OPEN' and acknowledged_at is null and resolved_at is null)
    or (status = 'ACKNOWLEDGED' and acknowledged_at is not null and acknowledged_by_admin_id is not null and resolved_at is null)
    or (status = 'RESOLVED' and resolved_at is not null)
  ),
  constraint compliance_alerts_note_valid check (acknowledgement_note is null or length(acknowledgement_note) <= 1000),
  constraint compliance_alerts_details_object check (jsonb_typeof(details) = 'object'),
  constraint compliance_alerts_natural_key unique (employee_id, alert_type, reference_date)
);
create index compliance_alerts_open_idx on workforce.compliance_alerts(employee_id, reference_date) where status = 'OPEN';
comment on table workforce.compliance_alerts is
  'Parametrized compliance REVIEW alerts. OPEN alerts require owner acknowledgement before the monthly closure.';

alter table workforce.compliance_alerts enable row level security;
alter table workforce.compliance_alerts force row level security;
create policy compliance_alerts_owner_only on workforce.compliance_alerts
  as permissive for all to postgres using (true) with check (true);

create function workforce.guard_compliance_alert()
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
     or new.employee_id is distinct from old.employee_id
     or new.alert_type is distinct from old.alert_type
     or new.reference_date is distinct from old.reference_date
     or new.detected_at is distinct from old.detected_at then
    raise exception 'WORKFORCE_IMMUTABLE:%', tg_table_name using errcode = 'P0001';
  end if;
  return new;
end;
$$;
create trigger compliance_alerts_guard before update or delete on workforce.compliance_alerts
  for each row execute function workforce.guard_compliance_alert();

-- ---------------------------------------------------------------------------
-- Worked time model
-- ---------------------------------------------------------------------------

-- Worked time of a local date: habitual blocks (not on holidays nor all-day
-- absences) ∪ effective extra periods starting that date − timed absences.
create function workforce.worked_time(p_employee_id uuid, p_date date)
returns tstzmultirange
language plpgsql
stable
set search_path = ''
as $$
declare
  v_employee workforce.employees;
  v_timezone text;
  v_habitual tstzmultirange := '{}'::tstzmultirange;
  v_extra tstzmultirange := '{}'::tstzmultirange;
  v_missing tstzmultirange := '{}'::tstzmultirange;
begin
  select e.* into v_employee from workforce.employees e where e.id = p_employee_id;
  v_timezone := workforce.employer_timezone(v_employee.employer_id);

  if not workforce.is_holiday(v_employee.employer_id, p_date)
     and not exists (
       select 1
       from workforce.work_exceptions x
       cross join lateral workforce.effective_exception(x.id) ef
       where x.employee_id = p_employee_id
         and x.status <> 'WITHDRAWN_BY_EMPLOYEE'
         and ef.all_day
         and p_date between ef.event_date and coalesce(ef.event_end_date, ef.event_date)
     ) then
    select coalesce(range_agg(tstzrange(
             (p_date + d.start_time)::timestamp at time zone v_timezone,
             (p_date + d.end_time)::timestamp at time zone v_timezone, '[)')), '{}'::tstzmultirange)
      into v_habitual
    from workforce.employment_schedule_days d
    where d.schedule_id = workforce.current_schedule_id(p_employee_id, p_date)
      and d.iso_weekday = extract(isodow from p_date);
  end if;

  select coalesce(range_agg(tstzrange(ef.period_start, ef.period_end, '[)')), '{}'::tstzmultirange)
    into v_extra
  from workforce.work_exceptions x
  cross join lateral workforce.effective_exception(x.id) ef
  where x.employee_id = p_employee_id
    and x.status not in ('WITHDRAWN_BY_EMPLOYEE', 'OPEN')
    and ef.exception_type = 'EXTRA_WORK'
    and ef.period_start is not null and ef.period_end is not null
    and (ef.period_start at time zone v_timezone)::date = p_date;

  select coalesce(range_agg(tstzrange(ef.period_start, ef.period_end, '[)')), '{}'::tstzmultirange)
    into v_missing
  from workforce.work_exceptions x
  cross join lateral workforce.effective_exception(x.id) ef
  where x.employee_id = p_employee_id
    and x.status <> 'WITHDRAWN_BY_EMPLOYEE'
    and ef.exception_type in ('LATE_ARRIVAL', 'EARLY_LEAVE', 'ABSENCE', 'MEDICAL_LEAVE', 'OTHER')
    and ef.period_start is not null and ef.period_end is not null
    and (ef.period_start at time zone v_timezone)::date = p_date;

  return (v_habitual - v_missing) + v_extra;
end;
$$;

create function workforce.multirange_minutes(p_value tstzmultirange)
returns integer
language sql
immutable
set search_path = ''
as $$
  select coalesce(sum(extract(epoch from upper(r) - lower(r))), 0)::int / 60
  from unnest(p_value) r;
$$;

-- Candidate alerts for [p_from, p_to]. Writes nothing persistent.
create function workforce.compliance_candidates(p_employee_id uuid, p_from date, p_to date)
returns table (alert_type text, reference_date date, measured_minutes integer, threshold_minutes integer, details jsonb)
language plpgsql
-- volatile: builds a transaction-local working table of worked time per date.
set search_path = ''
as $$
declare
  v_settings workforce.payroll_settings;
  v_timezone text;
  v_day record;
  v_prev_date date;
  v_prev_end timestamptz;
  v_prev_has_extra boolean;
  v_gap record;
  v_week date;
  v_week_start timestamptz;
  v_week_end timestamptz;
  v_max_rest integer;
  v_worked integer;
  v_largest_gap integer;
  v_required integer;
begin
  select ps.* into v_settings
  from workforce.employees e join workforce.payroll_settings ps on ps.employer_id = e.employer_id
  where e.id = p_employee_id;
  select workforce.employer_timezone(e.employer_id) into v_timezone from workforce.employees e where e.id = p_employee_id;

  if to_regclass('pg_temp.wf_days') is null then
    create temporary table wf_days (
      work_date date primary key,
      worked tstzmultirange not null,
      has_extra boolean not null
    ) on commit drop;
  end if;
  truncate pg_temp.wf_days;
  insert into pg_temp.wf_days(work_date, worked, has_extra)
  select d::date, workforce.worked_time(p_employee_id, d::date),
         exists (
           select 1 from workforce.work_exception_segments s
           join workforce.work_exceptions x on x.id = s.exception_id
           cross join lateral workforce.effective_exception(x.id) ef
           where s.employee_id = p_employee_id and s.segment_date = d::date
             and s.segment_kind <> 'REGULAR_OVERLAP' and ef.exception_type = 'EXTRA_WORK'
             and x.status <> 'WITHDRAWN_BY_EMPLOYEE'
         )
  from generate_series(p_from - 8, p_to + 8, interval '1 day') d;

  -- EXTRA_DAILY_LIMIT_REVIEW (CLT art. 59, parametrized).
  return query
  select 'EXTRA_DAILY_LIMIT_REVIEW', ds.summary_date, ds.extra_counted_seconds / 60, v_settings.max_extra_minutes_per_day,
         jsonb_build_object('day_class', ds.day_class)
  from workforce.day_summary(p_employee_id, p_from, p_to) ds
  where ds.extra_counted_seconds / 60 > v_settings.max_extra_minutes_per_day;

  -- Intrajourney interval and split shift (only on days with an exception: by
  -- exception premise, a habitual day is assumed compliant).
  for v_day in
    select w.work_date, w.worked from pg_temp.wf_days w
    where w.work_date between p_from and p_to and w.has_extra and not isempty(w.worked)
  loop
    v_worked := workforce.multirange_minutes(v_day.worked);
    select coalesce(max(extract(epoch from lower(n) - upper(r))::int / 60), 0) into v_largest_gap
    from (
      select r, lead(r) over (order by lower(r)) as n from unnest(v_day.worked) r
    ) g
    where n is not null;

    v_required := case
      when v_worked > v_settings.intrajourney_long_work_threshold_minutes then v_settings.minimum_long_interval_minutes
      when v_worked > v_settings.intrajourney_short_work_threshold_minutes then v_settings.minimum_short_interval_minutes
      else 0
    end;
    if v_required > 0 and v_largest_gap < v_required then
      alert_type := 'INTRAJOURNEY_INTERVAL_REVIEW';
      reference_date := v_day.work_date;
      measured_minutes := v_largest_gap;
      threshold_minutes := v_required;
      details := jsonb_build_object('worked_minutes', v_worked);
      return next;
    end if;
    if v_largest_gap > v_settings.split_shift_review_threshold_minutes then
      alert_type := 'SPLIT_SHIFT_REVIEW';
      reference_date := v_day.work_date;
      measured_minutes := v_largest_gap;
      threshold_minutes := v_settings.split_shift_review_threshold_minutes;
      details := jsonb_build_object('worked_minutes', v_worked);
      return next;
    end if;
  end loop;

  -- INTERJOURNEY_REST_REVIEW (CLT art. 66): last end of a journey date to the
  -- first start of the next worked date, when the later journey has an exception.
  v_prev_date := null;
  for v_day in
    select w.work_date, w.has_extra, lower(w.worked) as first_start, upper(w.worked) as last_end
    from pg_temp.wf_days w
    where not isempty(w.worked)
    order by w.work_date
  loop
    if v_prev_date is not null
       and v_day.work_date between p_from and p_to
       and (v_day.has_extra or v_prev_has_extra) then
      measured_minutes := greatest(0, extract(epoch from v_day.first_start - v_prev_end)::int / 60);
      if measured_minutes < v_settings.minimum_interjourney_rest_minutes then
        alert_type := 'INTERJOURNEY_REST_REVIEW';
        reference_date := v_day.work_date;
        threshold_minutes := v_settings.minimum_interjourney_rest_minutes;
        details := jsonb_build_object('previous_date', v_prev_date);
        return next;
      end if;
    end if;
    v_prev_date := v_day.work_date;
    v_prev_end := v_day.last_end;
    v_prev_has_extra := v_day.has_extra;
  end loop;

  -- WEEKLY_REST_REVIEW (CLT art. 67): no continuous rest ≥ the parameter
  -- overlapping the ISO week. Every week starting in the range is evaluated on
  -- its full seven days (the working window spans ±8 days), and only when the
  -- week holds an exception — so the result never depends on the range cut.
  for v_week in
    select distinct date_trunc('week', w.work_date)::date
    from pg_temp.wf_days w
    where w.has_extra
      and date_trunc('week', w.work_date)::date between p_from and p_to
  loop
    v_week_start := v_week::timestamp at time zone v_timezone;
    v_week_end := (v_week + 7)::timestamp at time zone v_timezone;
    select coalesce(max(extract(epoch from least(gap_end, v_week_end + interval '2 days') - greatest(gap_start, v_week_start - interval '2 days'))::int / 60), 0)
      into v_max_rest
    from (
      select upper(r) as gap_start, lead(lower(r)) over (order by lower(r)) as gap_end
      from (
        select unnest(range_agg(x.r)) as r
        from (select unnest(w.worked) as r from pg_temp.wf_days w) x
      ) m
    ) g
    where gap_end is not null
      and tstzrange(gap_start, gap_end, '[)') && tstzrange(v_week_start, v_week_end, '[)');
    if v_max_rest < v_settings.minimum_weekly_rest_minutes then
      alert_type := 'WEEKLY_REST_REVIEW';
      reference_date := v_week;
      measured_minutes := v_max_rest;
      threshold_minutes := v_settings.minimum_weekly_rest_minutes;
      details := jsonb_build_object('week_start', v_week);
      return next;
    end if;
  end loop;
end;
$$;

-- Idempotent persistence of the candidates for [p_from, p_to].
create function workforce.evaluate_compliance(p_employee_id uuid, p_from date, p_to date)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_employee workforce.employees;
  v_changes integer := 0;
  v_count integer;
begin
  select e.* into v_employee from workforce.employees e where e.id = p_employee_id;
  if v_employee.id is null then
    return 0;
  end if;

  if to_regclass('pg_temp.wf_candidates') is null then
    create temporary table wf_candidates (
      alert_type text, reference_date date, measured_minutes integer, threshold_minutes integer, details jsonb
    ) on commit drop;
  end if;
  truncate pg_temp.wf_candidates;
  insert into pg_temp.wf_candidates select * from workforce.compliance_candidates(p_employee_id, p_from, p_to);

  -- New alerts.
  insert into workforce.compliance_alerts(tenant_id, employee_id, alert_type, reference_date, measured_minutes, threshold_minutes, details)
  select v_employee.tenant_id, p_employee_id, c.alert_type, c.reference_date, c.measured_minutes, c.threshold_minutes, c.details
  from pg_temp.wf_candidates c
  on conflict (employee_id, alert_type, reference_date) do nothing;
  get diagnostics v_count = row_count;
  v_changes := v_changes + v_count;

  -- Changed measurement (or a resolved condition that came back) reopens the alert.
  update workforce.compliance_alerts a
  set measured_minutes = c.measured_minutes, threshold_minutes = c.threshold_minutes, details = c.details,
      status = 'OPEN', acknowledged_at = null, acknowledged_by_admin_id = null, acknowledgement_note = null,
      resolved_at = null, last_evaluated_at = now()
  from pg_temp.wf_candidates c
  where a.employee_id = p_employee_id and a.alert_type = c.alert_type and a.reference_date = c.reference_date
    and (a.status = 'RESOLVED'
         or a.measured_minutes is distinct from c.measured_minutes
         or a.threshold_minutes is distinct from c.threshold_minutes);
  get diagnostics v_count = row_count;
  v_changes := v_changes + v_count;

  -- Conditions that disappeared resolve automatically.
  update workforce.compliance_alerts a
  set status = 'RESOLVED', resolved_at = now(), last_evaluated_at = now()
  where a.employee_id = p_employee_id
    and a.reference_date between p_from and p_to
    and a.status <> 'RESOLVED'
    and not exists (
      select 1 from pg_temp.wf_candidates c
      where c.alert_type = a.alert_type and c.reference_date = a.reference_date
    );
  get diagnostics v_count = row_count;
  v_changes := v_changes + v_count;
  return v_changes;
end;
$$;

-- Re-evaluate around every recalculated exception (± one week covers
-- interjourney and weekly rest windows).
create or replace function workforce.recalculate_exception_trigger()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  perform workforce.recalculate_exception(new.id);
  perform workforce.evaluate_compliance(new.employee_id, new.event_date - 7, coalesce(new.event_end_date, new.event_date) + 7);
  return null;
end;
$$;

create function workforce.recalculate_after_correction()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.status = 'APPROVED' and old.status is distinct from 'APPROVED' then
    perform workforce.evaluate_compliance(new.employee_id,
      least(new.proposed_event_date, (select x.event_date from workforce.work_exceptions x where x.id = new.exception_id)) - 7,
      greatest(coalesce(new.proposed_event_end_date, new.proposed_event_date), (select x.event_date from workforce.work_exceptions x where x.id = new.exception_id)) + 7);
  end if;
  return null;
end;
$$;
create trigger work_exception_corrections_compliance after update of status on workforce.work_exception_corrections
  for each row execute function workforce.recalculate_after_correction();

create or replace function workforce.review_blockers(p_employee_id uuid, p_from date, p_to date)
returns table (blocker text, exception_id uuid, reference_id uuid)
language sql
stable
set search_path = ''
as $$
  select 'OPEN_EXTRA', x.id, null::uuid
  from workforce.work_exceptions x
  where x.employee_id = p_employee_id and x.status = 'OPEN' and x.event_date <= p_to
  union all
  select 'PENDING_REVIEW', x.id, null
  from workforce.work_exceptions x
  where x.employee_id = p_employee_id and x.status = 'PENDING_REVIEW' and x.event_date between p_from and p_to
  union all
  select 'MANAGER_CONTESTED', x.id, a.id
  from workforce.work_exceptions x
  join workforce.work_exception_acknowledgements a on a.exception_id = x.id and a.kind = 'MANAGER_CONTESTED' and a.status = 'OPEN'
  where x.employee_id = p_employee_id and x.event_date between p_from and p_to
  union all
  select 'EMPLOYEE_CONTESTED', x.id, a.id
  from workforce.work_exceptions x
  join workforce.work_exception_acknowledgements a on a.exception_id = x.id and a.kind = 'CONTESTED' and a.status = 'OPEN'
  where x.employee_id = p_employee_id and x.event_date between p_from and p_to
  union all
  select 'CORRECTION_PENDING', x.id, c.id
  from workforce.work_exceptions x
  join workforce.work_exception_corrections c on c.exception_id = x.id and c.status = 'PENDING'
  where x.employee_id = p_employee_id
    and (x.event_date between p_from and p_to or c.proposed_event_date between p_from and p_to)
  union all
  select 'COMPLIANCE_ALERT_OPEN', null::uuid, a.id
  from workforce.compliance_alerts a
  where a.employee_id = p_employee_id and a.status = 'OPEN' and a.reference_date between p_from and p_to;
$$;

create function workforce.alert_json(p_alert workforce.compliance_alerts)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'alert_id', p_alert.id,
    'employee_id', p_alert.employee_id,
    'alert_type', p_alert.alert_type,
    'reference_date', p_alert.reference_date,
    'measured_minutes', p_alert.measured_minutes,
    'threshold_minutes', p_alert.threshold_minutes,
    'details', p_alert.details,
    'status', p_alert.status,
    'detected_at', p_alert.detected_at,
    'acknowledged_at', p_alert.acknowledged_at,
    'acknowledgement_note', p_alert.acknowledgement_note,
    'resolved_at', p_alert.resolved_at
  );
$$;

-- ---------------------------------------------------------------------------
-- Governed RPCs — owner
-- ---------------------------------------------------------------------------

create function public.service_workforce_owner_list_compliance_alerts(p_actor_admin_id uuid, p_employee_id uuid, p_month text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := workforce.require_owner(p_actor_admin_id);
  v_from date;
begin
  if not exists (select 1 from workforce.employees e where e.id = p_employee_id and e.tenant_id = v_tenant_id) then
    raise exception 'WORKFORCE_EMPLOYEE_NOT_FOUND' using errcode = 'P0001';
  end if;
  if p_month is null or p_month !~ '^[0-9]{4}-(0[1-9]|1[0-2])$' then
    raise exception 'WORKFORCE_FIELD_INVALID:month' using errcode = 'P0001';
  end if;
  v_from := (p_month || '-01')::date;
  return jsonb_build_object(
    'month', p_month,
    'alerts', coalesce((
      select jsonb_agg(workforce.alert_json(a) order by a.reference_date, a.alert_type)
      from workforce.compliance_alerts a
      where a.employee_id = p_employee_id
        and a.reference_date between v_from and (v_from + interval '1 month - 1 day')::date
    ), '[]'::jsonb)
  );
end;
$$;

create function public.service_workforce_owner_manage_compliance(
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
  c_command constant text := 'OWNER_MANAGE_COMPLIANCE';
  v_tenant_id uuid := workforce.require_owner(p_actor_admin_id);
  v_replay jsonb;
  v_action text;
  v_alert workforce.compliance_alerts;
  v_employee_id uuid;
  v_month text;
  v_from date;
  v_changes integer;
  v_response jsonb;
begin
  v_replay := workforce.begin_command(p_actor_admin_id, c_command, p_idempotency_key, p_payload);
  if v_replay is not null then
    return v_replay;
  end if;
  perform workforce.assert_payload(p_payload, array['action', 'alert_id', 'note', 'employee_id', 'month'], array['action']);
  v_action := upper(workforce.payload_text(p_payload, 'action', 32));

  if v_action = 'ACKNOWLEDGE' then
    perform workforce.assert_payload(p_payload, array['action', 'alert_id', 'note'], array['action', 'alert_id']);
    select a.* into v_alert from workforce.compliance_alerts a
    where a.id = workforce.payload_uuid(p_payload, 'alert_id') and a.tenant_id = v_tenant_id
    for update;
    if v_alert.id is null then
      raise exception 'WORKFORCE_ALERT_NOT_FOUND' using errcode = 'P0001';
    end if;
    if v_alert.status <> 'OPEN' then
      raise exception 'WORKFORCE_ALERT_NOT_OPEN' using errcode = 'P0001';
    end if;
    update workforce.compliance_alerts a
    set status = 'ACKNOWLEDGED', acknowledged_at = now(), acknowledged_by_admin_id = p_actor_admin_id,
        acknowledgement_note = workforce.payload_text(p_payload, 'note', 1000)
    where a.id = v_alert.id
    returning * into v_alert;
    perform workforce.audit(v_tenant_id, p_actor_admin_id, 'OWNER', c_command || ':ACKNOWLEDGE', 'compliance_alert', v_alert.id,
      null, workforce.alert_json(v_alert) - 'acknowledgement_note');
    v_response := jsonb_build_object('alert', workforce.alert_json(v_alert));

  elsif v_action = 'EVALUATE' then
    perform workforce.assert_payload(p_payload, array['action', 'employee_id', 'month'], array['action', 'employee_id', 'month']);
    v_employee_id := workforce.payload_uuid(p_payload, 'employee_id');
    v_month := workforce.payload_text(p_payload, 'month', 7);
    if v_month !~ '^[0-9]{4}-(0[1-9]|1[0-2])$' then
      raise exception 'WORKFORCE_FIELD_INVALID:month' using errcode = 'P0001';
    end if;
    if not exists (select 1 from workforce.employees e where e.id = v_employee_id and e.tenant_id = v_tenant_id) then
      raise exception 'WORKFORCE_EMPLOYEE_NOT_FOUND' using errcode = 'P0001';
    end if;
    v_from := (v_month || '-01')::date;
    v_changes := workforce.evaluate_compliance(v_employee_id, v_from, (v_from + interval '1 month - 1 day')::date);
    perform workforce.audit(v_tenant_id, p_actor_admin_id, 'OWNER', c_command || ':EVALUATE', 'employee', v_employee_id,
      null, jsonb_build_object('month', v_month, 'changes', v_changes));
    v_response := jsonb_build_object('changes', v_changes);
  else
    raise exception 'WORKFORCE_FIELD_INVALID:action' using errcode = 'P0001';
  end if;

  return workforce.finish_command(p_actor_admin_id, c_command, p_idempotency_key, p_payload, v_tenant_id, v_response);
end;
$$;

-- Owner compliance parameters (new intrajourney parameters included).
create or replace function public.service_workforce_owner_save_payroll_settings(
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
  c_command constant text := 'OWNER_SAVE_PAYROLL_SETTINGS';
  v_tenant_id uuid := workforce.require_owner(p_actor_admin_id);
  v_replay jsonb;
  v_employer_id uuid;
  v_before workforce.payroll_settings;
  v_after workforce.payroll_settings;
  v_primary text;
  v_secondary text;
begin
  v_replay := workforce.begin_command(p_actor_admin_id, c_command, p_idempotency_key, p_payload);
  if v_replay is not null then
    return v_replay;
  end if;

  perform workforce.assert_payload(p_payload, array[
    'employer_id', 'accountant_name', 'accountant_email', 'accountant_email_secondary',
    'tolerance_minutes_per_mark', 'tolerance_minutes_daily_max', 'max_extra_minutes_per_day',
    'minimum_interjourney_rest_minutes', 'minimum_weekly_rest_minutes',
    'minimum_long_interval_minutes', 'split_shift_review_threshold_minutes',
    'intrajourney_long_work_threshold_minutes', 'intrajourney_short_work_threshold_minutes',
    'minimum_short_interval_minutes', 'default_weekly_schedule'
  ], array['employer_id']);
  v_employer_id := workforce.payload_uuid(p_payload, 'employer_id');

  select ps.* into v_before
  from workforce.payroll_settings ps
  where ps.employer_id = v_employer_id and ps.tenant_id = v_tenant_id
  for update;
  if v_before.employer_id is null then
    raise exception 'WORKFORCE_EMPLOYER_NOT_FOUND' using errcode = 'P0001';
  end if;

  v_primary := case when p_payload ? 'accountant_email' then workforce.normalize_email(p_payload, 'accountant_email') else v_before.accountant_email end;
  v_secondary := case when p_payload ? 'accountant_email_secondary' then workforce.normalize_email(p_payload, 'accountant_email_secondary') else v_before.accountant_email_secondary end;
  if v_secondary is not null and (v_primary is null or v_secondary = v_primary) then
    raise exception 'WORKFORCE_ACCOUNTANT_SECONDARY_INVALID' using errcode = 'P0001';
  end if;

  update workforce.payroll_settings ps set
    accountant_name = case when p_payload ? 'accountant_name' then workforce.payload_text(p_payload, 'accountant_name', 200) else ps.accountant_name end,
    accountant_email = v_primary,
    accountant_email_secondary = v_secondary,
    tolerance_minutes_per_mark = coalesce(workforce.payload_int(p_payload, 'tolerance_minutes_per_mark', 0, 60), ps.tolerance_minutes_per_mark),
    tolerance_minutes_daily_max = coalesce(workforce.payload_int(p_payload, 'tolerance_minutes_daily_max', 0, 120), ps.tolerance_minutes_daily_max),
    max_extra_minutes_per_day = coalesce(workforce.payload_int(p_payload, 'max_extra_minutes_per_day', 0, 1440), ps.max_extra_minutes_per_day),
    minimum_interjourney_rest_minutes = coalesce(workforce.payload_int(p_payload, 'minimum_interjourney_rest_minutes', 0, 2880), ps.minimum_interjourney_rest_minutes),
    minimum_weekly_rest_minutes = coalesce(workforce.payload_int(p_payload, 'minimum_weekly_rest_minutes', 0, 10080), ps.minimum_weekly_rest_minutes),
    minimum_long_interval_minutes = coalesce(workforce.payload_int(p_payload, 'minimum_long_interval_minutes', 0, 600), ps.minimum_long_interval_minutes),
    split_shift_review_threshold_minutes = coalesce(workforce.payload_int(p_payload, 'split_shift_review_threshold_minutes', 0, 1440), ps.split_shift_review_threshold_minutes),
    intrajourney_long_work_threshold_minutes = coalesce(workforce.payload_int(p_payload, 'intrajourney_long_work_threshold_minutes', 0, 1440), ps.intrajourney_long_work_threshold_minutes),
    intrajourney_short_work_threshold_minutes = coalesce(workforce.payload_int(p_payload, 'intrajourney_short_work_threshold_minutes', 0, 1440), ps.intrajourney_short_work_threshold_minutes),
    minimum_short_interval_minutes = coalesce(workforce.payload_int(p_payload, 'minimum_short_interval_minutes', 0, 600), ps.minimum_short_interval_minutes),
    default_weekly_schedule = case when p_payload ? 'default_weekly_schedule'
      then workforce.normalize_weekly_schedule(p_payload -> 'default_weekly_schedule')
      else ps.default_weekly_schedule end,
    updated_by_admin_id = p_actor_admin_id
  where ps.employer_id = v_before.employer_id
  returning * into v_after;

  perform workforce.audit(v_tenant_id, p_actor_admin_id, 'OWNER', c_command, 'payroll_settings', v_after.employer_id,
    to_jsonb(v_before), to_jsonb(v_after));

  return workforce.finish_command(p_actor_admin_id, c_command, p_idempotency_key, p_payload, v_tenant_id,
    jsonb_build_object('employer', workforce.employer_json(v_after.employer_id)));
exception
  when check_violation then
    raise exception 'WORKFORCE_PAYROLL_SETTINGS_INVALID' using errcode = 'P0001';
end;
$$;

revoke all on all tables in schema workforce from public, anon, authenticated, service_role;
revoke all on all functions in schema workforce from public, anon, authenticated, service_role;

do $$
declare
  v_identity text;
begin
  foreach v_identity in array array[
    'public.service_workforce_owner_list_compliance_alerts(uuid,uuid,text)',
    'public.service_workforce_owner_manage_compliance(uuid,uuid,jsonb)',
    'public.service_workforce_owner_save_payroll_settings(uuid,uuid,jsonb)'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', v_identity);
    execute format('grant execute on function %s to service_role', v_identity);
  end loop;
end
$$;
