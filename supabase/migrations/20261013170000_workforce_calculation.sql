-- Workforce S3 — exception calculation engine (ADR-017, spec §8).
-- Extra time is the part of a reported period that falls OUTSIDE the habitual
-- schedule valid on each local date; it is never end - start. Periods are cut at
-- local midnight, each date gets a day class (HOLIDAY > SUNDAY > SATURDAY >
-- WEEKDAY) and each piece becomes REGULAR_OVERLAP / EXTRA_BEFORE / EXTRA_AFTER /
-- EXTRA_NON_WORKDAY. Durations are stored in seconds; raw timestamps are never
-- rounded. Tolerance belongs to the aggregation layer (day_summary), not here.

-- Pure, deterministic segmentation of [p_start, p_end) for an employee.
create function workforce.calculate_segments(p_employee_id uuid, p_start timestamptz, p_end timestamptz)
returns table (
  segment_date date,
  day_class text,
  segment_kind text,
  classification text,
  segment_start timestamptz,
  segment_end timestamptz,
  duration_seconds integer,
  schedule_id uuid
)
language plpgsql
stable
set search_path = ''
as $$
declare
  v_employee workforce.employees;
  v_timezone text;
  v_date date;
  v_last_date date;
  v_day_start timestamptz;
  v_day_end timestamptz;
  v_piece_start timestamptz;
  v_piece_end timestamptz;
  v_cursor timestamptz;
  v_block record;
  v_block_start timestamptz;
  v_block_end timestamptz;
  v_has_blocks boolean;
  v_extra_class text;
  v_seen_block boolean;
  v_schedule_id uuid;
begin
  if p_start is null or p_end is null or p_end <= p_start then
    raise exception 'WORKFORCE_PERIOD_INVALID' using errcode = 'P0001';
  end if;
  select e.* into v_employee from workforce.employees e where e.id = p_employee_id;
  if v_employee.id is null then
    raise exception 'WORKFORCE_EMPLOYEE_NOT_FOUND' using errcode = 'P0001';
  end if;
  v_timezone := workforce.employer_timezone(v_employee.employer_id);

  v_date := (p_start at time zone v_timezone)::date;
  v_last_date := ((p_end - interval '1 microsecond') at time zone v_timezone)::date;

  while v_date <= v_last_date loop
    v_day_start := v_date::timestamp at time zone v_timezone;
    v_day_end := (v_date + 1)::timestamp at time zone v_timezone;
    v_piece_start := greatest(p_start, v_day_start);
    v_piece_end := least(p_end, v_day_end);

    day_class := case
      when workforce.is_holiday(v_employee.employer_id, v_date) then 'HOLIDAY'
      when extract(isodow from v_date) = 7 then 'SUNDAY'
      when extract(isodow from v_date) = 6 then 'SATURDAY'
      else 'WEEKDAY'
    end;
    v_extra_class := 'EXTRA_' || day_class;
    segment_date := v_date;
    v_schedule_id := workforce.current_schedule_id(p_employee_id, v_date);
    schedule_id := v_schedule_id;

    -- A holiday has no habitual journey: all work on it is EXTRA_HOLIDAY.
    v_has_blocks := day_class <> 'HOLIDAY' and exists (
      select 1 from workforce.employment_schedule_days d
      where d.schedule_id = v_schedule_id and d.iso_weekday = extract(isodow from v_date)
    );

    if v_piece_end > v_piece_start then
      if not v_has_blocks then
        segment_kind := 'EXTRA_NON_WORKDAY';
        classification := v_extra_class;
        segment_start := v_piece_start;
        segment_end := v_piece_end;
        duration_seconds := extract(epoch from v_piece_end - v_piece_start)::int;
        return next;
      else
        v_cursor := v_piece_start;
        v_seen_block := false;
        for v_block in
          select d.start_time, d.end_time
          from workforce.employment_schedule_days d
          where d.schedule_id = v_schedule_id and d.iso_weekday = extract(isodow from v_date)
          order by d.start_time
        loop
          v_block_start := (v_date + v_block.start_time)::timestamp at time zone v_timezone;
          v_block_end := (v_date + v_block.end_time)::timestamp at time zone v_timezone;
          -- Time before this block (before the first block, or in the gap after a previous one).
          if v_cursor < least(v_block_start, v_piece_end) then
            segment_kind := case when v_seen_block then 'EXTRA_AFTER' else 'EXTRA_BEFORE' end;
            classification := v_extra_class;
            segment_start := v_cursor;
            segment_end := least(v_block_start, v_piece_end);
            duration_seconds := extract(epoch from segment_end - segment_start)::int;
            return next;
            v_cursor := segment_end;
          end if;
          -- Overlap with the habitual block.
          if v_cursor < least(v_block_end, v_piece_end) and greatest(v_cursor, v_block_start) < least(v_block_end, v_piece_end) then
            segment_kind := 'REGULAR_OVERLAP';
            classification := 'REGULAR';
            segment_start := greatest(v_cursor, v_block_start);
            segment_end := least(v_block_end, v_piece_end);
            duration_seconds := extract(epoch from segment_end - segment_start)::int;
            return next;
            v_cursor := segment_end;
          end if;
          v_cursor := greatest(v_cursor, least(v_block_end, v_piece_end));
          v_seen_block := true;
          exit when v_cursor >= v_piece_end;
        end loop;
        if v_cursor < v_piece_end then
          segment_kind := 'EXTRA_AFTER';
          classification := v_extra_class;
          segment_start := v_cursor;
          segment_end := v_piece_end;
          duration_seconds := extract(epoch from v_piece_end - v_cursor)::int;
          return next;
        end if;
      end if;
    end if;
    v_date := v_date + 1;
  end loop;
end;
$$;

create table workforce.work_exception_segments (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  exception_id uuid not null,
  employee_id uuid not null,
  segment_date date not null,
  day_class text not null,
  segment_kind text not null,
  classification text not null,
  segment_start timestamptz not null,
  segment_end timestamptz not null,
  duration_seconds integer not null,
  schedule_id uuid,
  calculated_at timestamptz not null default now(),
  constraint work_exception_segments_exception_fkey foreign key (tenant_id, exception_id)
    references workforce.work_exceptions(tenant_id, id) on delete restrict,
  constraint work_exception_segments_day_class_valid check (day_class in ('WEEKDAY', 'SATURDAY', 'SUNDAY', 'HOLIDAY')),
  constraint work_exception_segments_kind_valid check (segment_kind in ('REGULAR_OVERLAP', 'EXTRA_BEFORE', 'EXTRA_AFTER', 'EXTRA_NON_WORKDAY')),
  constraint work_exception_segments_classification_valid check (classification in (
    'REGULAR', 'EXTRA_WEEKDAY', 'EXTRA_SATURDAY', 'EXTRA_SUNDAY', 'EXTRA_HOLIDAY'
  )),
  constraint work_exception_segments_period_valid check (
    segment_end > segment_start and duration_seconds = extract(epoch from segment_end - segment_start)::int
  )
);
create index work_exception_segments_exception_idx on workforce.work_exception_segments(exception_id);
create index work_exception_segments_employee_date_idx on workforce.work_exception_segments(employee_id, segment_date);
comment on table workforce.work_exception_segments is
  'Derived calculation of each timed exception against the schedule and holidays. Recomputable; the immutable record is the closure snapshot (S6).';

alter table workforce.work_exception_segments enable row level security;
alter table workforce.work_exception_segments force row level security;
create policy work_exception_segments_owner_only on workforce.work_exception_segments
  as permissive for all to postgres using (true) with check (true);

-- Segments are derived data: only the engine replaces them.
create function workforce.guard_segments()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if coalesce(current_setting('workforce.engine', true), '') <> 'on' then
    raise exception 'WORKFORCE_SEGMENTS_ENGINE_ONLY' using errcode = 'P0001';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

create trigger work_exception_segments_guard before insert or update or delete on workforce.work_exception_segments
  for each row execute function workforce.guard_segments();

-- Recalculate one exception. Withdrawn, OPEN and all-day records have no segments.
create function workforce.recalculate_exception(p_exception_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_exception workforce.work_exceptions;
begin
  select x.* into v_exception from workforce.work_exceptions x where x.id = p_exception_id;
  if v_exception.id is null then
    return;
  end if;
  perform set_config('workforce.engine', 'on', true);
  delete from workforce.work_exception_segments s where s.exception_id = v_exception.id;
  if v_exception.reported_start is not null
     and v_exception.reported_end is not null
     and v_exception.status <> 'WITHDRAWN_BY_EMPLOYEE' then
    insert into workforce.work_exception_segments(
      tenant_id, exception_id, employee_id, segment_date, day_class, segment_kind, classification,
      segment_start, segment_end, duration_seconds, schedule_id
    )
    select v_exception.tenant_id, v_exception.id, v_exception.employee_id, c.segment_date, c.day_class,
           c.segment_kind, c.classification, c.segment_start, c.segment_end, c.duration_seconds, c.schedule_id
    from workforce.calculate_segments(v_exception.employee_id, v_exception.reported_start, v_exception.reported_end) c;
  end if;
  perform set_config('workforce.engine', 'off', true);
end;
$$;

create function workforce.recalculate_exception_trigger()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  perform workforce.recalculate_exception(new.id);
  return null;
end;
$$;

create trigger work_exceptions_recalculate after insert or update of reported_end, status on workforce.work_exceptions
  for each row execute function workforce.recalculate_exception_trigger();

-- Calculation with the tolerance layer: per local date, extra minutes outside the
-- schedule on a workday are disregarded when every mark deviation is within
-- tolerance_minutes_per_mark and their sum within tolerance_minutes_daily_max
-- (CLT art. 58 §1, parametrized; defaults are 0 = no tolerance). Non-workday and
-- holiday extra minutes are never subject to tolerance.
create function workforce.day_summary(p_employee_id uuid, p_from date, p_to date)
returns table (
  summary_date date,
  day_class text,
  regular_overlap_seconds integer,
  extra_raw_seconds integer,
  extra_counted_seconds integer,
  tolerance_applied boolean,
  extra_weekday_seconds integer,
  extra_saturday_seconds integer,
  extra_sunday_seconds integer,
  extra_holiday_seconds integer
)
language sql
stable
set search_path = ''
as $$
  with settings as (
    select ps.tolerance_minutes_per_mark * 60 as per_mark, ps.tolerance_minutes_daily_max * 60 as daily_max
    from workforce.employees e
    join workforce.payroll_settings ps on ps.employer_id = e.employer_id
    where e.id = p_employee_id
  ), segs as (
    select s.*
    from workforce.work_exception_segments s
    join workforce.work_exceptions x on x.id = s.exception_id
    where s.employee_id = p_employee_id
      and s.segment_date between p_from and p_to
      and x.exception_type = 'EXTRA_WORK'
      and x.status <> 'WITHDRAWN_BY_EMPLOYEE'
  ), days as (
    select
      s.segment_date,
      min(s.day_class) as day_class,
      coalesce(sum(s.duration_seconds) filter (where s.segment_kind = 'REGULAR_OVERLAP'), 0)::int as regular_overlap_seconds,
      coalesce(sum(s.duration_seconds) filter (where s.segment_kind <> 'REGULAR_OVERLAP'), 0)::int as extra_raw_seconds,
      coalesce(max(s.duration_seconds) filter (where s.segment_kind in ('EXTRA_BEFORE', 'EXTRA_AFTER')), 0) as max_mark_seconds,
      bool_or(s.segment_kind = 'EXTRA_NON_WORKDAY') as has_non_workday
    from segs s
    group by s.segment_date
  )
  select
    d.segment_date,
    d.day_class,
    d.regular_overlap_seconds,
    d.extra_raw_seconds,
    case when t.applies then 0 else d.extra_raw_seconds end,
    t.applies,
    case when d.day_class = 'WEEKDAY' and not t.applies then d.extra_raw_seconds else 0 end,
    case when d.day_class = 'SATURDAY' then d.extra_raw_seconds else 0 end,
    case when d.day_class = 'SUNDAY' then d.extra_raw_seconds else 0 end,
    case when d.day_class = 'HOLIDAY' then d.extra_raw_seconds else 0 end
  from days d
  cross join settings st
  cross join lateral (
    select (
      d.extra_raw_seconds > 0
      and not d.has_non_workday
      and st.per_mark > 0
      and d.max_mark_seconds <= st.per_mark
      and d.extra_raw_seconds <= st.daily_max
    ) as applies
  ) t
  order by d.segment_date;
$$;

-- ---------------------------------------------------------------------------
-- Governed RPCs — previews and summaries
-- ---------------------------------------------------------------------------

create function workforce.segments_json(p_exception_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'segment_date', s.segment_date,
    'day_class', s.day_class,
    'segment_kind', s.segment_kind,
    'classification', s.classification,
    'start_local', to_char(s.segment_start at time zone e.timezone, 'YYYY-MM-DD"T"HH24:MI'),
    'end_local', to_char(s.segment_end at time zone e.timezone, 'YYYY-MM-DD"T"HH24:MI'),
    'minutes', floor(s.duration_seconds / 60.0)::int,
    'duration_seconds', s.duration_seconds
  ) order by s.segment_start), '[]'::jsonb)
  from workforce.work_exception_segments s
  join workforce.work_exceptions x on x.id = s.exception_id
  join workforce.employers e on e.id = x.employer_id
  where s.exception_id = p_exception_id;
$$;

create function workforce.month_summary_json(p_employee_id uuid, p_month text)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_from date;
  v_to date;
begin
  if p_month is null or p_month !~ '^[0-9]{4}-(0[1-9]|1[0-2])$' then
    raise exception 'WORKFORCE_FIELD_INVALID:month' using errcode = 'P0001';
  end if;
  v_from := (p_month || '-01')::date;
  v_to := (v_from + interval '1 month - 1 day')::date;
  return (
    select jsonb_build_object(
      'month', p_month,
      'period_start', v_from,
      'period_end', v_to,
      'extra_weekday_minutes', floor(coalesce(sum(d.extra_weekday_seconds), 0) / 60.0)::int,
      'extra_saturday_minutes', floor(coalesce(sum(d.extra_saturday_seconds), 0) / 60.0)::int,
      'extra_sunday_minutes', floor(coalesce(sum(d.extra_sunday_seconds), 0) / 60.0)::int,
      'extra_holiday_minutes', floor(coalesce(sum(d.extra_holiday_seconds), 0) / 60.0)::int,
      'extra_counted_minutes', floor(coalesce(sum(d.extra_counted_seconds), 0) / 60.0)::int,
      'extra_raw_minutes', floor(coalesce(sum(d.extra_raw_seconds), 0) / 60.0)::int,
      'days', coalesce(jsonb_agg(jsonb_build_object(
        'date', d.summary_date,
        'day_class', d.day_class,
        'extra_raw_minutes', floor(d.extra_raw_seconds / 60.0)::int,
        'extra_counted_minutes', floor(d.extra_counted_seconds / 60.0)::int,
        'tolerance_applied', d.tolerance_applied
      ) order by d.summary_date), '[]'::jsonb)
    )
    from workforce.day_summary(p_employee_id, v_from, v_to) d
  );
end;
$$;

create function public.service_workforce_employee_get_month_summary(p_actor_admin_id uuid, p_month text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_employee workforce.employees := workforce.require_employee(p_actor_admin_id);
begin
  return workforce.month_summary_json(v_employee.id, p_month) || jsonb_build_object(
    'exceptions', (
      select coalesce(jsonb_agg(workforce.exception_json(x, 'EMPLOYEE') || jsonb_build_object('segments', workforce.segments_json(x.id))
        order by x.event_date, x.reported_start nulls first), '[]'::jsonb)
      from workforce.work_exceptions x
      where x.employee_id = v_employee.id
        and x.event_date between (p_month || '-01')::date and ((p_month || '-01')::date + interval '1 month - 1 day')::date
    )
  );
end;
$$;

create function public.service_workforce_owner_get_month_summary(p_actor_admin_id uuid, p_employee_id uuid, p_month text)
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
  return workforce.month_summary_json(p_employee_id, p_month) || jsonb_build_object(
    'employee_id', p_employee_id,
    'exceptions', (
      select coalesce(jsonb_agg(workforce.exception_json(x, 'OWNER') || jsonb_build_object('segments', workforce.segments_json(x.id))
        order by x.event_date, x.reported_start nulls first), '[]'::jsonb)
      from workforce.work_exceptions x
      where x.employee_id = p_employee_id
        and x.event_date between (p_month || '-01')::date and ((p_month || '-01')::date + interval '1 month - 1 day')::date
    )
  );
end;
$$;

-- Owner-triggered recalculation of a month (e.g. after a holiday or schedule
-- change). Idempotent: the result depends only on raw data and configuration.
create function public.service_workforce_owner_recalculate_month(
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
  c_command constant text := 'OWNER_RECALCULATE_MONTH';
  v_tenant_id uuid := workforce.require_owner(p_actor_admin_id);
  v_replay jsonb;
  v_employee_id uuid;
  v_month text;
  v_from date;
  v_count integer := 0;
  v_id uuid;
begin
  v_replay := workforce.begin_command(p_actor_admin_id, c_command, p_idempotency_key, p_payload);
  if v_replay is not null then
    return v_replay;
  end if;
  perform workforce.assert_payload(p_payload, array['employee_id', 'month'], array['employee_id', 'month']);
  v_employee_id := workforce.payload_uuid(p_payload, 'employee_id');
  v_month := workforce.payload_text(p_payload, 'month', 7);
  if v_month !~ '^[0-9]{4}-(0[1-9]|1[0-2])$' then
    raise exception 'WORKFORCE_FIELD_INVALID:month' using errcode = 'P0001';
  end if;
  if not exists (select 1 from workforce.employees e where e.id = v_employee_id and e.tenant_id = v_tenant_id) then
    raise exception 'WORKFORCE_EMPLOYEE_NOT_FOUND' using errcode = 'P0001';
  end if;
  v_from := (v_month || '-01')::date;
  for v_id in
    select x.id from workforce.work_exceptions x
    where x.employee_id = v_employee_id
      and x.event_date between v_from - 1 and (v_from + interval '1 month')::date
  loop
    perform workforce.recalculate_exception(v_id);
    v_count := v_count + 1;
  end loop;
  perform workforce.audit(v_tenant_id, p_actor_admin_id, 'OWNER', c_command, 'employee', v_employee_id,
    null, jsonb_build_object('month', v_month, 'recalculated_exceptions', v_count));
  return workforce.finish_command(p_actor_admin_id, c_command, p_idempotency_key, p_payload, v_tenant_id,
    jsonb_build_object('recalculated_exceptions', v_count, 'summary', workforce.month_summary_json(v_employee_id, v_month)));
end;
$$;

revoke all on all tables in schema workforce from public, anon, authenticated, service_role;
revoke all on all functions in schema workforce from public, anon, authenticated, service_role;

do $$
declare
  v_identity text;
begin
  foreach v_identity in array array[
    'public.service_workforce_employee_get_month_summary(uuid,text)',
    'public.service_workforce_owner_get_month_summary(uuid,uuid,text)',
    'public.service_workforce_owner_recalculate_month(uuid,uuid,jsonb)'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', v_identity);
    execute format('grant execute on function %s to service_role', v_identity);
  end loop;
end
$$;
