-- Workforce S4 — acknowledgement, contest, correction and versioned classification.
-- Nothing is edited silently: the raw record stays untouched and auditable; a
-- correction is a request → review → new interpretation; classifications are
-- append-only (superseded, never overwritten). The owner can never delete or
-- rewrite an employee record — to disagree, the owner contests it with a reason.

-- ---------------------------------------------------------------------------
-- Raw closing provenance (forgotten OPEN periods are closed by an approved correction).
-- ---------------------------------------------------------------------------
alter table workforce.work_exceptions add column reported_end_source text;
update workforce.work_exceptions x
set reported_end_source = case
  when x.reported_end is null then null
  when x.finished_at is not null and x.reported_end = x.finished_at then 'SERVER_CLOCK'
  when x.source in ('MANAGER', 'RETROACTIVE_MANAGER') then 'MANAGER_DECLARED'
  else 'EMPLOYEE_DECLARED'
end;
alter table workforce.work_exceptions add constraint work_exceptions_end_source_valid check (
  (reported_end is null and reported_end_source is null)
  or (reported_end is not null and reported_end_source in ('SERVER_CLOCK', 'EMPLOYEE_DECLARED', 'MANAGER_DECLARED', 'CORRECTION_APPROVED'))
  or (all_day and reported_end is null and reported_end_source is null)
);

create or replace function workforce.guard_work_exception()
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
     or (old.reported_end_source is not null and new.reported_end_source is distinct from old.reported_end_source)
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

-- The S2 commands now record where the end came from.
create function workforce.default_end_source()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.reported_end is not null and new.reported_end_source is null then
    new.reported_end_source := case
      when new.finished_at is not null and new.reported_end = new.finished_at and new.source = 'EMPLOYEE' and new.exception_type = 'EXTRA_WORK'
        and (tg_op = 'UPDATE' and old.status = 'OPEN') then 'SERVER_CLOCK'
      when new.source in ('MANAGER', 'RETROACTIVE_MANAGER') then 'MANAGER_DECLARED'
      else 'EMPLOYEE_DECLARED'
    end;
  end if;
  return new;
end;
$$;
create trigger work_exceptions_end_source before insert or update on workforce.work_exceptions
  for each row execute function workforce.default_end_source();

insert into workforce.work_exception_status_transitions(from_status, to_status) values
  ('OPEN', 'VALIDATED'),
  ('RECORDED', 'VALIDATED'),
  ('PENDING_REVIEW', 'VALIDATED'),
  ('MANAGER_CONTESTED', 'VALIDATED'),
  ('CORRECTION_REQUESTED', 'VALIDATED'),
  ('RECORDED', 'MANAGER_CONTESTED'),
  ('PENDING_REVIEW', 'MANAGER_CONTESTED'),
  ('RECORDED', 'CORRECTION_REQUESTED'),
  ('PENDING_REVIEW', 'CORRECTION_REQUESTED'),
  ('MANAGER_CONTESTED', 'CORRECTION_REQUESTED'),
  ('VALIDATED', 'CORRECTION_REQUESTED'),
  ('CORRECTION_REQUESTED', 'RECORDED'),
  ('CORRECTION_REQUESTED', 'PENDING_REVIEW'),
  ('CORRECTION_REQUESTED', 'MANAGER_CONTESTED'),
  ('RECORDED', 'WITHDRAWN_BY_EMPLOYEE'),
  ('PENDING_REVIEW', 'WITHDRAWN_BY_EMPLOYEE'),
  ('MANAGER_CONTESTED', 'WITHDRAWN_BY_EMPLOYEE');

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

create table workforce.work_exception_acknowledgements (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  exception_id uuid not null,
  employee_id uuid not null,
  actor_admin_id uuid not null references public.admin_users(id) on delete restrict,
  actor_kind text not null,
  kind text not null,
  reason text,
  status text not null,
  resolution text,
  resolution_reason text,
  resolved_by_admin_id uuid references public.admin_users(id) on delete restrict,
  resolved_at timestamptz,
  created_at timestamptz not null default now(),
  constraint work_exception_acks_exception_fkey foreign key (tenant_id, exception_id)
    references workforce.work_exceptions(tenant_id, id) on delete restrict,
  constraint work_exception_acks_actor_kind_valid check (actor_kind in ('EMPLOYEE', 'OWNER')),
  constraint work_exception_acks_kind_valid check (
    (kind = 'ACKNOWLEDGED' and actor_kind = 'EMPLOYEE')
    or (kind = 'CONTESTED' and actor_kind = 'EMPLOYEE')
    or (kind = 'MANAGER_CONTESTED' and actor_kind = 'OWNER')
  ),
  constraint work_exception_acks_reason_valid check (
    (kind = 'ACKNOWLEDGED' and reason is null)
    or (kind <> 'ACKNOWLEDGED' and reason is not null and length(btrim(reason)) between 3 and 1000)
  ),
  constraint work_exception_acks_status_valid check (
    (kind = 'ACKNOWLEDGED' and status = 'CLOSED' and resolution is null)
    or (kind <> 'ACKNOWLEDGED' and status = 'OPEN' and resolution is null and resolved_at is null)
    or (kind <> 'ACKNOWLEDGED' and status = 'RESOLVED' and resolution in ('MAINTAINED', 'ACCEPTED', 'CORRECTED', 'WITHDRAWN')
        and resolved_at is not null and resolved_by_admin_id is not null)
  ),
  constraint work_exception_acks_resolution_reason_valid check (resolution_reason is null or length(resolution_reason) <= 1000)
);
create unique index work_exception_acks_one_open_contest_key
  on workforce.work_exception_acknowledgements(exception_id, kind) where status = 'OPEN';
create index work_exception_acks_employee_idx on workforce.work_exception_acknowledgements(employee_id, created_at);

create table workforce.work_exception_corrections (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  exception_id uuid not null,
  employee_id uuid not null,
  requested_by_admin_id uuid not null references public.admin_users(id) on delete restrict,
  proposed_type text not null,
  proposed_event_date date not null,
  proposed_event_end_date date,
  proposed_all_day boolean not null default false,
  proposed_start timestamptz,
  proposed_end timestamptz,
  reason text not null,
  status text not null default 'PENDING',
  status_before text not null,
  reviewed_by_admin_id uuid references public.admin_users(id) on delete restrict,
  reviewed_at timestamptz,
  review_reason text,
  created_at timestamptz not null default now(),
  constraint work_exception_corrections_exception_fkey foreign key (tenant_id, exception_id)
    references workforce.work_exceptions(tenant_id, id) on delete restrict,
  constraint work_exception_corrections_type_valid check (proposed_type in (
    'EXTRA_WORK', 'EARLY_LEAVE', 'LATE_ARRIVAL', 'ABSENCE', 'MEDICAL_LEAVE', 'OTHER'
  )),
  constraint work_exception_corrections_period_valid check (
    (proposed_all_day and proposed_start is null and proposed_end is null and proposed_type <> 'EXTRA_WORK'
       and proposed_event_end_date is not null and proposed_event_end_date between proposed_event_date and proposed_event_date + 30)
    or (not proposed_all_day and proposed_start is not null and proposed_end is not null and proposed_event_end_date is null
       and proposed_end > proposed_start and proposed_end <= proposed_start + interval '24 hours')
  ),
  constraint work_exception_corrections_reason_valid check (length(btrim(reason)) between 3 and 1000),
  constraint work_exception_corrections_status_valid check (
    (status = 'PENDING' and reviewed_at is null and reviewed_by_admin_id is null)
    or (status in ('APPROVED', 'REJECTED') and reviewed_at is not null and reviewed_by_admin_id is not null)
    or (status = 'WITHDRAWN' and reviewed_at is not null)
  ),
  constraint work_exception_corrections_review_reason_valid check (
    (status <> 'REJECTED' or (review_reason is not null and length(btrim(review_reason)) between 3 and 1000))
    and (review_reason is null or length(review_reason) <= 1000)
  )
);
create unique index work_exception_corrections_one_pending_key
  on workforce.work_exception_corrections(exception_id) where status = 'PENDING';
create index work_exception_corrections_employee_idx on workforce.work_exception_corrections(employee_id, created_at);

create table workforce.work_exception_classifications (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  exception_id uuid not null,
  classification text not null,
  reason text,
  classified_by_admin_id uuid not null references public.admin_users(id) on delete restrict,
  effective_at timestamptz not null default now(),
  superseded_at timestamptz,
  -- Deferred: the superseding row is inserted right after the previous one is released.
  superseded_by uuid references workforce.work_exception_classifications(id) on delete restrict deferrable initially deferred,
  constraint work_exception_classifications_exception_fkey foreign key (tenant_id, exception_id)
    references workforce.work_exceptions(tenant_id, id) on delete restrict,
  constraint work_exception_classifications_value_valid check (classification in (
    'AUTHORIZED', 'EXCUSED', 'DEDUCTIBLE', 'INFORMATIONAL'
  )),
  constraint work_exception_classifications_reason_valid check (reason is null or length(reason) <= 1000),
  constraint work_exception_classifications_superseded_valid check (
    (superseded_at is null and superseded_by is null) or (superseded_at is not null and superseded_by is not null)
  )
);
create unique index work_exception_classifications_current_key
  on workforce.work_exception_classifications(exception_id) where superseded_at is null;

comment on table workforce.work_exception_acknowledgements is
  'Employee acknowledgement/contest and owner contest. Open contests block the monthly closure.';
comment on table workforce.work_exception_corrections is
  'Correction requests (original → request → review). Approved values form the effective interpretation; the raw record is never edited.';
comment on table workforce.work_exception_classifications is
  'Administrative classification history (append-only). Exactly one current row per exception.';

alter table workforce.work_exception_acknowledgements enable row level security;
alter table workforce.work_exception_acknowledgements force row level security;
alter table workforce.work_exception_corrections enable row level security;
alter table workforce.work_exception_corrections force row level security;
alter table workforce.work_exception_classifications enable row level security;
alter table workforce.work_exception_classifications force row level security;
create policy work_exception_acknowledgements_owner_only on workforce.work_exception_acknowledgements
  as permissive for all to postgres using (true) with check (true);
create policy work_exception_corrections_owner_only on workforce.work_exception_corrections
  as permissive for all to postgres using (true) with check (true);
create policy work_exception_classifications_owner_only on workforce.work_exception_classifications
  as permissive for all to postgres using (true) with check (true);

-- Review rows: identity and proposal are immutable; only the single resolution
-- (OPEN→RESOLVED, PENDING→reviewed, current→superseded) may be written once.
create function workforce.guard_review_row()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_old jsonb;
  v_new jsonb;
  v_mutable text[];
begin
  if tg_op = 'DELETE' then
    raise exception 'WORKFORCE_IMMUTABLE:%', tg_table_name using errcode = 'P0001';
  end if;
  v_mutable := case tg_table_name
    when 'work_exception_acknowledgements' then array['status', 'resolution', 'resolution_reason', 'resolved_by_admin_id', 'resolved_at']
    when 'work_exception_corrections' then array['status', 'reviewed_by_admin_id', 'reviewed_at', 'review_reason']
    else array['superseded_at', 'superseded_by']
  end;
  v_old := to_jsonb(old);
  v_new := to_jsonb(new);
  if (v_old - v_mutable) is distinct from (v_new - v_mutable) then
    raise exception 'WORKFORCE_IMMUTABLE:%', tg_table_name using errcode = 'P0001';
  end if;
  if (tg_table_name = 'work_exception_acknowledgements' and v_old ->> 'status' <> 'OPEN')
     or (tg_table_name = 'work_exception_corrections' and v_old ->> 'status' <> 'PENDING')
     or (tg_table_name = 'work_exception_classifications' and (v_old ->> 'superseded_at') is not null) then
    raise exception 'WORKFORCE_IMMUTABLE:%', tg_table_name using errcode = 'P0001';
  end if;
  return new;
end;
$$;

create trigger work_exception_acks_guard before update or delete on workforce.work_exception_acknowledgements
  for each row execute function workforce.guard_review_row();
create trigger work_exception_corrections_guard before update or delete on workforce.work_exception_corrections
  for each row execute function workforce.guard_review_row();
create trigger work_exception_classifications_guard before update or delete on workforce.work_exception_classifications
  for each row execute function workforce.guard_review_row();

-- ---------------------------------------------------------------------------
-- Effective interpretation and recalculation
-- ---------------------------------------------------------------------------

-- Latest approved correction, else the raw record.
create function workforce.effective_exception(p_exception_id uuid)
returns table (
  exception_type text,
  event_date date,
  event_end_date date,
  all_day boolean,
  period_start timestamptz,
  period_end timestamptz,
  correction_id uuid
)
language sql
stable
set search_path = ''
as $$
  select coalesce(c.proposed_type, x.exception_type),
         coalesce(c.proposed_event_date, x.event_date),
         case when c.id is not null then c.proposed_event_end_date else x.event_end_date end,
         coalesce(c.proposed_all_day, x.all_day),
         case when c.id is not null then c.proposed_start else x.reported_start end,
         case when c.id is not null then c.proposed_end else x.reported_end end,
         c.id
  from workforce.work_exceptions x
  left join lateral (
    select wc.*
    from workforce.work_exception_corrections wc
    where wc.exception_id = x.id and wc.status = 'APPROVED'
    order by wc.reviewed_at desc, wc.created_at desc
    limit 1
  ) c on true
  where x.id = p_exception_id;
$$;

create or replace function workforce.recalculate_exception(p_exception_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_exception workforce.work_exceptions;
  v_effective record;
begin
  select x.* into v_exception from workforce.work_exceptions x where x.id = p_exception_id;
  if v_exception.id is null then
    return;
  end if;
  select * into v_effective from workforce.effective_exception(p_exception_id);
  perform set_config('workforce.engine', 'on', true);
  delete from workforce.work_exception_segments s where s.exception_id = v_exception.id;
  if v_effective.period_start is not null
     and v_effective.period_end is not null
     and v_exception.status not in ('WITHDRAWN_BY_EMPLOYEE', 'OPEN') then
    insert into workforce.work_exception_segments(
      tenant_id, exception_id, employee_id, segment_date, day_class, segment_kind, classification,
      segment_start, segment_end, duration_seconds, schedule_id
    )
    select v_exception.tenant_id, v_exception.id, v_exception.employee_id, c.segment_date, c.day_class,
           c.segment_kind, c.classification, c.segment_start, c.segment_end, c.duration_seconds, c.schedule_id
    from workforce.calculate_segments(v_exception.employee_id, v_effective.period_start, v_effective.period_end) c;
  end if;
  perform set_config('workforce.engine', 'off', true);
end;
$$;

-- day_summary must count the effective type (a correction may turn a record into extra work or the opposite).
create or replace function workforce.day_summary(p_employee_id uuid, p_from date, p_to date)
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
    cross join lateral workforce.effective_exception(x.id) ef
    where s.employee_id = p_employee_id
      and s.segment_date between p_from and p_to
      and ef.exception_type = 'EXTRA_WORK'
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

create function workforce.current_classification(p_exception_id uuid)
returns text
language sql
stable
set search_path = ''
as $$
  select c.classification from workforce.work_exception_classifications c
  where c.exception_id = p_exception_id and c.superseded_at is null;
$$;

-- Review state appended to every exception read model.
create function workforce.review_json(p_exception_id uuid, p_audience text)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'effective', (
      select jsonb_build_object(
        'exception_type', ef.exception_type,
        'event_date', ef.event_date,
        'event_end_date', ef.event_end_date,
        'all_day', ef.all_day,
        'start_local', to_char(ef.period_start at time zone er.timezone, 'YYYY-MM-DD"T"HH24:MI'),
        'end_local', to_char(ef.period_end at time zone er.timezone, 'YYYY-MM-DD"T"HH24:MI'),
        'corrected', ef.correction_id is not null
      )
      from workforce.effective_exception(p_exception_id) ef
      join workforce.work_exceptions x on x.id = p_exception_id
      join workforce.employers er on er.id = x.employer_id
    ),
    'classification', workforce.current_classification(p_exception_id),
    'acknowledged', exists (
      select 1 from workforce.work_exception_acknowledgements a
      where a.exception_id = p_exception_id and a.kind = 'ACKNOWLEDGED'
    ),
    'open_contests', coalesce((
      select jsonb_agg(jsonb_build_object(
        'acknowledgement_id', a.id, 'kind', a.kind, 'reason', a.reason, 'created_at', a.created_at
      ) order by a.created_at)
      from workforce.work_exception_acknowledgements a
      where a.exception_id = p_exception_id and a.status = 'OPEN'
    ), '[]'::jsonb),
    'corrections', coalesce((
      select jsonb_agg(jsonb_build_object(
        'correction_id', c.id,
        'status', c.status,
        'proposed_type', c.proposed_type,
        'proposed_event_date', c.proposed_event_date,
        'proposed_all_day', c.proposed_all_day,
        'proposed_start_local', to_char(c.proposed_start at time zone er.timezone, 'YYYY-MM-DD"T"HH24:MI'),
        'proposed_end_local', to_char(c.proposed_end at time zone er.timezone, 'YYYY-MM-DD"T"HH24:MI'),
        'reason', c.reason,
        'review_reason', c.review_reason,
        'created_at', c.created_at,
        'reviewed_at', c.reviewed_at
      ) order by c.created_at)
      from workforce.work_exception_corrections c
      join workforce.work_exceptions x on x.id = c.exception_id
      join workforce.employers er on er.id = x.employer_id
      where c.exception_id = p_exception_id
    ), '[]'::jsonb)
  );
$$;

-- Items that block the monthly closure (S6 consumes this; S5 adds alerts).
create function workforce.review_blockers(p_employee_id uuid, p_from date, p_to date)
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
    and (x.event_date between p_from and p_to or c.proposed_event_date between p_from and p_to);
$$;

-- Loads an exception of the acting employee (never trusts a browser employee_id).
create function workforce.employee_exception_for_update(p_employee workforce.employees, p_exception_id uuid)
returns workforce.work_exceptions
language plpgsql
set search_path = ''
as $$
declare
  v_row workforce.work_exceptions;
begin
  select x.* into v_row from workforce.work_exceptions x
  where x.id = p_exception_id and x.employee_id = p_employee.id and x.tenant_id = p_employee.tenant_id
  for update;
  if v_row.id is null then
    raise exception 'WORKFORCE_EXCEPTION_NOT_FOUND' using errcode = 'P0001';
  end if;
  return v_row;
end;
$$;

create function workforce.owner_exception_for_update(p_tenant_id uuid, p_exception_id uuid)
returns workforce.work_exceptions
language plpgsql
set search_path = ''
as $$
declare
  v_row workforce.work_exceptions;
begin
  select x.* into v_row from workforce.work_exceptions x
  where x.id = p_exception_id and x.tenant_id = p_tenant_id
  for update;
  if v_row.id is null then
    raise exception 'WORKFORCE_EXCEPTION_NOT_FOUND' using errcode = 'P0001';
  end if;
  return v_row;
end;
$$;

create function workforce.require_reason(p_payload jsonb, p_key text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_reason text := workforce.payload_text(p_payload, p_key, 1000);
begin
  if v_reason is null or length(v_reason) < 3 then
    raise exception 'WORKFORCE_REASON_REQUIRED' using errcode = 'P0001';
  end if;
  return v_reason;
end;
$$;

create function workforce.review_audit_json(p_row jsonb)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select p_row - array['reason', 'resolution_reason', 'review_reason']
    || jsonb_build_object('has_reason', p_row ? 'reason' and p_row ->> 'reason' is not null);
$$;

-- ---------------------------------------------------------------------------
-- Governed RPCs — employee
-- ---------------------------------------------------------------------------

create function public.service_workforce_employee_review_exception(
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
  c_command constant text := 'EMPLOYEE_REVIEW_EXCEPTION';
  v_employee workforce.employees := workforce.require_employee(p_actor_admin_id);
  v_replay jsonb;
  v_action text;
  v_exception workforce.work_exceptions;
  v_ack workforce.work_exception_acknowledgements;
  v_correction workforce.work_exception_corrections;
  v_timezone text;
  v_type text;
  v_all_day boolean;
  v_start timestamptz;
  v_end timestamptz;
  v_date date;
  v_end_date date;
  v_status_before text;
  v_entity_type text;
  v_after jsonb;
begin
  v_replay := workforce.begin_command(p_actor_admin_id, c_command, p_idempotency_key, p_payload);
  if v_replay is not null then
    return v_replay;
  end if;
  perform workforce.assert_payload(p_payload, array[
    'action', 'exception_id', 'correction_id', 'reason', 'proposed_type', 'proposed_all_day',
    'proposed_event_date', 'proposed_event_end_date', 'proposed_start_local', 'proposed_end_local'
  ], array['action']);
  v_action := upper(workforce.payload_text(p_payload, 'action', 32));

  if v_action = 'WITHDRAW_CORRECTION' then
    perform workforce.assert_payload(p_payload, array['action', 'correction_id'], array['action', 'correction_id']);
    select c.* into v_correction from workforce.work_exception_corrections c
    where c.id = workforce.payload_uuid(p_payload, 'correction_id') and c.employee_id = v_employee.id and c.status = 'PENDING'
    for update;
    if v_correction.id is null then
      raise exception 'WORKFORCE_CORRECTION_NOT_FOUND' using errcode = 'P0001';
    end if;
    v_exception := workforce.employee_exception_for_update(v_employee, v_correction.exception_id);
    update workforce.work_exception_corrections c set status = 'WITHDRAWN', reviewed_at = now()
    where c.id = v_correction.id returning * into v_correction;
    if v_exception.status = 'CORRECTION_REQUESTED' then
      update workforce.work_exceptions x set status = v_correction.status_before where x.id = v_exception.id;
    end if;
    v_entity_type := 'work_exception_correction';
    v_after := workforce.review_audit_json(to_jsonb(v_correction));
  else
    perform workforce.assert_payload(p_payload, array[
      'action', 'exception_id', 'reason', 'proposed_type', 'proposed_all_day',
      'proposed_event_date', 'proposed_event_end_date', 'proposed_start_local', 'proposed_end_local'
    ], array['action', 'exception_id']);
    v_exception := workforce.employee_exception_for_update(v_employee, workforce.payload_uuid(p_payload, 'exception_id'));

    if v_action = 'ACKNOWLEDGE' then
      perform workforce.assert_payload(p_payload, array['action', 'exception_id']);
      if v_exception.status in ('OPEN', 'WITHDRAWN_BY_EMPLOYEE') then
        raise exception 'WORKFORCE_EXCEPTION_STATE_INVALID' using errcode = 'P0001';
      end if;
      if exists (select 1 from workforce.work_exception_acknowledgements a where a.exception_id = v_exception.id and a.kind = 'ACKNOWLEDGED') then
        raise exception 'WORKFORCE_ALREADY_ACKNOWLEDGED' using errcode = 'P0001';
      end if;
      insert into workforce.work_exception_acknowledgements(tenant_id, exception_id, employee_id, actor_admin_id, actor_kind, kind, status)
      values (v_exception.tenant_id, v_exception.id, v_employee.id, p_actor_admin_id, 'EMPLOYEE', 'ACKNOWLEDGED', 'CLOSED')
      returning * into v_ack;
      v_entity_type := 'work_exception_acknowledgement';
      v_after := workforce.review_audit_json(to_jsonb(v_ack));

    elsif v_action = 'CONTEST' then
      perform workforce.assert_payload(p_payload, array['action', 'exception_id', 'reason'], array['action', 'exception_id', 'reason']);
      -- The employee contests what the owner recorded or decided about her.
      if v_exception.status in ('OPEN', 'WITHDRAWN_BY_EMPLOYEE') then
        raise exception 'WORKFORCE_EXCEPTION_STATE_INVALID' using errcode = 'P0001';
      end if;
      insert into workforce.work_exception_acknowledgements(tenant_id, exception_id, employee_id, actor_admin_id, actor_kind, kind, reason, status)
      values (v_exception.tenant_id, v_exception.id, v_employee.id, p_actor_admin_id, 'EMPLOYEE', 'CONTESTED',
              workforce.require_reason(p_payload, 'reason'), 'OPEN')
      returning * into v_ack;
      v_entity_type := 'work_exception_acknowledgement';
      v_after := workforce.review_audit_json(to_jsonb(v_ack));

    elsif v_action = 'REQUEST_CORRECTION' then
      if v_exception.status = 'WITHDRAWN_BY_EMPLOYEE' then
        raise exception 'WORKFORCE_EXCEPTION_STATE_INVALID' using errcode = 'P0001';
      end if;
      v_timezone := workforce.employer_timezone(v_exception.employer_id);
      v_type := coalesce(upper(workforce.payload_text(p_payload, 'proposed_type', 32)), v_exception.exception_type);
      v_all_day := coalesce(workforce.payload_bool(p_payload, 'proposed_all_day'), false);
      if v_all_day then
        v_date := workforce.payload_date(p_payload, 'proposed_event_date');
        v_end_date := coalesce(workforce.payload_date(p_payload, 'proposed_event_end_date'), v_date);
        if v_date is null then
          raise exception 'WORKFORCE_PAYLOAD_FIELD_REQUIRED:proposed_event_date' using errcode = 'P0001';
        end if;
      else
        v_start := workforce.payload_local_timestamp(p_payload, 'proposed_start_local', v_timezone);
        v_end := workforce.payload_local_timestamp(p_payload, 'proposed_end_local', v_timezone);
        if v_start is null or v_end is null then
          raise exception 'WORKFORCE_PAYLOAD_FIELD_REQUIRED:proposed_period' using errcode = 'P0001';
        end if;
        if v_end <= v_start or v_end > v_start + interval '24 hours' then
          raise exception 'WORKFORCE_PERIOD_INVALID' using errcode = 'P0001';
        end if;
        if v_end > now() then
          raise exception 'WORKFORCE_PERIOD_IN_FUTURE' using errcode = 'P0001';
        end if;
        v_date := (v_start at time zone v_timezone)::date;
        -- The explicit proposed date must agree with the proposed start.
        if workforce.payload_date(p_payload, 'proposed_event_date') is not null
           and workforce.payload_date(p_payload, 'proposed_event_date') <> v_date then
          raise exception 'WORKFORCE_FIELD_INVALID:proposed_event_date' using errcode = 'P0001';
        end if;
      end if;
      v_status_before := v_exception.status;
      insert into workforce.work_exception_corrections(
        tenant_id, exception_id, employee_id, requested_by_admin_id, proposed_type, proposed_event_date,
        proposed_event_end_date, proposed_all_day, proposed_start, proposed_end, reason, status_before
      ) values (
        v_exception.tenant_id, v_exception.id, v_employee.id, p_actor_admin_id, v_type, v_date,
        case when v_all_day then v_end_date end, v_all_day, v_start, v_end,
        workforce.require_reason(p_payload, 'reason'), v_status_before
      )
      returning * into v_correction;
      -- OPEN keeps its shape until the correction is approved (it carries no end yet).
      if v_exception.status <> 'OPEN' then
        update workforce.work_exceptions x set status = 'CORRECTION_REQUESTED' where x.id = v_exception.id;
      end if;
      v_entity_type := 'work_exception_correction';
      v_after := workforce.review_audit_json(to_jsonb(v_correction));

    elsif v_action = 'WITHDRAW_EXCEPTION' then
      perform workforce.assert_payload(p_payload, array['action', 'exception_id']);
      if v_exception.source not in ('EMPLOYEE', 'RETROACTIVE_EMPLOYEE') then
        raise exception 'WORKFORCE_EXCEPTION_NOT_OWNED' using errcode = 'P0001';
      end if;
      if exists (select 1 from workforce.work_exception_corrections c where c.exception_id = v_exception.id and c.status = 'PENDING') then
        raise exception 'WORKFORCE_CORRECTION_PENDING' using errcode = 'P0001';
      end if;
      update workforce.work_exceptions x set status = 'WITHDRAWN_BY_EMPLOYEE' where x.id = v_exception.id;
      update workforce.work_exception_acknowledgements a
      set status = 'RESOLVED', resolution = 'WITHDRAWN', resolved_by_admin_id = p_actor_admin_id, resolved_at = now()
      where a.exception_id = v_exception.id and a.status = 'OPEN';
      v_entity_type := 'work_exception';
      v_after := jsonb_build_object('status', 'WITHDRAWN_BY_EMPLOYEE');
    else
      raise exception 'WORKFORCE_FIELD_INVALID:action' using errcode = 'P0001';
    end if;
  end if;

  perform workforce.audit(v_employee.tenant_id, p_actor_admin_id, 'EMPLOYEE', c_command || ':' || v_action,
    v_entity_type, coalesce(v_ack.id, v_correction.id, v_exception.id), null, v_after);
  select x.* into v_exception from workforce.work_exceptions x where x.id = coalesce(v_exception.id, v_correction.exception_id);
  return workforce.finish_command(p_actor_admin_id, c_command, p_idempotency_key, p_payload, v_employee.tenant_id,
    jsonb_build_object('exception', workforce.exception_json(v_exception, 'EMPLOYEE') || workforce.review_json(v_exception.id, 'EMPLOYEE')));
exception
  when unique_violation then
    raise exception 'WORKFORCE_REVIEW_ALREADY_OPEN' using errcode = 'P0001';
  when check_violation then
    raise exception 'WORKFORCE_REVIEW_INVALID' using errcode = 'P0001';
end;
$$;

-- ---------------------------------------------------------------------------
-- Governed RPCs — owner
-- ---------------------------------------------------------------------------

create function public.service_workforce_owner_review_exception(
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
  c_command constant text := 'OWNER_REVIEW_EXCEPTION';
  v_tenant_id uuid := workforce.require_owner(p_actor_admin_id);
  v_replay jsonb;
  v_action text;
  v_exception workforce.work_exceptions;
  v_ack workforce.work_exception_acknowledgements;
  v_correction workforce.work_exception_corrections;
  v_classification workforce.work_exception_classifications;
  v_previous_classification workforce.work_exception_classifications;
  v_decision text;
  v_value text;
  v_entity_type text;
  v_entity_id uuid;
  v_after jsonb;
begin
  v_replay := workforce.begin_command(p_actor_admin_id, c_command, p_idempotency_key, p_payload);
  if v_replay is not null then
    return v_replay;
  end if;
  perform workforce.assert_payload(p_payload, array[
    'action', 'exception_id', 'acknowledgement_id', 'correction_id', 'decision', 'reason', 'classification'
  ], array['action']);
  v_action := upper(workforce.payload_text(p_payload, 'action', 32));

  if v_action = 'VALIDATE' then
    perform workforce.assert_payload(p_payload, array['action', 'exception_id'], array['action', 'exception_id']);
    v_exception := workforce.owner_exception_for_update(v_tenant_id, workforce.payload_uuid(p_payload, 'exception_id'));
    if v_exception.status not in ('RECORDED', 'PENDING_REVIEW') then
      raise exception 'WORKFORCE_EXCEPTION_STATE_INVALID' using errcode = 'P0001';
    end if;
    update workforce.work_exceptions x set status = 'VALIDATED' where x.id = v_exception.id;
    v_entity_type := 'work_exception';
    v_entity_id := v_exception.id;
    v_after := jsonb_build_object('status', 'VALIDATED');

  elsif v_action = 'CONTEST' then
    perform workforce.assert_payload(p_payload, array['action', 'exception_id', 'reason'], array['action', 'exception_id', 'reason']);
    v_exception := workforce.owner_exception_for_update(v_tenant_id, workforce.payload_uuid(p_payload, 'exception_id'));
    -- The owner contests employee-recorded hours; the record itself is never removed.
    if v_exception.source not in ('EMPLOYEE', 'RETROACTIVE_EMPLOYEE')
       or v_exception.status not in ('RECORDED', 'PENDING_REVIEW') then
      raise exception 'WORKFORCE_EXCEPTION_STATE_INVALID' using errcode = 'P0001';
    end if;
    insert into workforce.work_exception_acknowledgements(tenant_id, exception_id, employee_id, actor_admin_id, actor_kind, kind, reason, status)
    values (v_exception.tenant_id, v_exception.id, v_exception.employee_id, p_actor_admin_id, 'OWNER', 'MANAGER_CONTESTED',
            workforce.require_reason(p_payload, 'reason'), 'OPEN')
    returning * into v_ack;
    update workforce.work_exceptions x set status = 'MANAGER_CONTESTED' where x.id = v_exception.id;
    v_entity_type := 'work_exception_acknowledgement';
    v_entity_id := v_ack.id;
    v_after := workforce.review_audit_json(to_jsonb(v_ack));

  elsif v_action = 'RESOLVE_CONTEST' then
    perform workforce.assert_payload(p_payload, array['action', 'acknowledgement_id', 'decision', 'reason'],
      array['action', 'acknowledgement_id', 'decision', 'reason']);
    select a.* into v_ack from workforce.work_exception_acknowledgements a
    where a.id = workforce.payload_uuid(p_payload, 'acknowledgement_id') and a.tenant_id = v_tenant_id and a.status = 'OPEN'
    for update;
    if v_ack.id is null then
      raise exception 'WORKFORCE_CONTEST_NOT_FOUND' using errcode = 'P0001';
    end if;
    v_decision := upper(workforce.payload_text(p_payload, 'decision', 16));
    -- MAINTAINED: the owner keeps its position after an employee contest.
    -- ACCEPTED: the owner withdraws its own contest and accepts the employee hours.
    if not ((v_ack.kind = 'CONTESTED' and v_decision = 'MAINTAINED')
            or (v_ack.kind = 'MANAGER_CONTESTED' and v_decision = 'ACCEPTED')) then
      raise exception 'WORKFORCE_FIELD_INVALID:decision' using errcode = 'P0001';
    end if;
    v_exception := workforce.owner_exception_for_update(v_tenant_id, v_ack.exception_id);
    update workforce.work_exception_acknowledgements a
    set status = 'RESOLVED', resolution = v_decision, resolution_reason = workforce.require_reason(p_payload, 'reason'),
        resolved_by_admin_id = p_actor_admin_id, resolved_at = now()
    where a.id = v_ack.id
    returning * into v_ack;
    if v_ack.kind = 'MANAGER_CONTESTED' and v_exception.status = 'MANAGER_CONTESTED' then
      update workforce.work_exceptions x set status = 'VALIDATED' where x.id = v_exception.id;
    end if;
    v_entity_type := 'work_exception_acknowledgement';
    v_entity_id := v_ack.id;
    v_after := workforce.review_audit_json(to_jsonb(v_ack));

  elsif v_action = 'REVIEW_CORRECTION' then
    perform workforce.assert_payload(p_payload, array['action', 'correction_id', 'decision', 'reason'],
      array['action', 'correction_id', 'decision']);
    select c.* into v_correction from workforce.work_exception_corrections c
    where c.id = workforce.payload_uuid(p_payload, 'correction_id') and c.tenant_id = v_tenant_id and c.status = 'PENDING'
    for update;
    if v_correction.id is null then
      raise exception 'WORKFORCE_CORRECTION_NOT_FOUND' using errcode = 'P0001';
    end if;
    v_exception := workforce.owner_exception_for_update(v_tenant_id, v_correction.exception_id);
    v_decision := upper(workforce.payload_text(p_payload, 'decision', 16));
    if v_decision = 'APPROVE' then
      if v_correction.proposed_type = 'EXTRA_WORK' and exists (
        select 1
        from workforce.work_exceptions o
        cross join lateral workforce.effective_exception(o.id) ef
        where o.employee_id = v_exception.employee_id
          and o.id <> v_exception.id
          and o.status not in ('WITHDRAWN_BY_EMPLOYEE')
          and ef.exception_type = 'EXTRA_WORK'
          and ef.period_start is not null
          and tstzrange(ef.period_start, coalesce(ef.period_end, 'infinity'::timestamptz), '[)')
              && tstzrange(v_correction.proposed_start, v_correction.proposed_end, '[)')
      ) then
        raise exception 'WORKFORCE_EXTRA_PERIOD_OVERLAP' using errcode = 'P0001';
      end if;
      update workforce.work_exception_corrections c
      set status = 'APPROVED', reviewed_by_admin_id = p_actor_admin_id, reviewed_at = now(),
          review_reason = workforce.payload_text(p_payload, 'reason', 1000)
      where c.id = v_correction.id returning * into v_correction;
      if v_exception.status = 'OPEN' then
        -- A forgotten OPEN period is closed once, with the approved end as provenance.
        update workforce.work_exceptions x
        set reported_end = v_correction.proposed_end, reported_end_source = 'CORRECTION_APPROVED',
            finished_at = now(), status = 'VALIDATED'
        where x.id = v_exception.id;
      else
        update workforce.work_exceptions x set status = 'VALIDATED' where x.id = v_exception.id;
      end if;
      update workforce.work_exception_acknowledgements a
      set status = 'RESOLVED', resolution = 'CORRECTED', resolved_by_admin_id = p_actor_admin_id, resolved_at = now()
      where a.exception_id = v_exception.id and a.status = 'OPEN';
      perform workforce.recalculate_exception(v_exception.id);
    elsif v_decision = 'REJECT' then
      update workforce.work_exception_corrections c
      set status = 'REJECTED', reviewed_by_admin_id = p_actor_admin_id, reviewed_at = now(),
          review_reason = workforce.require_reason(p_payload, 'reason')
      where c.id = v_correction.id returning * into v_correction;
      if v_exception.status = 'CORRECTION_REQUESTED' then
        update workforce.work_exceptions x set status = v_correction.status_before where x.id = v_exception.id;
      end if;
    else
      raise exception 'WORKFORCE_FIELD_INVALID:decision' using errcode = 'P0001';
    end if;
    v_entity_type := 'work_exception_correction';
    v_entity_id := v_correction.id;
    v_after := workforce.review_audit_json(to_jsonb(v_correction));

  elsif v_action = 'CLASSIFY' then
    perform workforce.assert_payload(p_payload, array['action', 'exception_id', 'classification', 'reason'],
      array['action', 'exception_id', 'classification']);
    v_exception := workforce.owner_exception_for_update(v_tenant_id, workforce.payload_uuid(p_payload, 'exception_id'));
    if v_exception.status in ('OPEN', 'WITHDRAWN_BY_EMPLOYEE') then
      raise exception 'WORKFORCE_EXCEPTION_STATE_INVALID' using errcode = 'P0001';
    end if;
    v_value := upper(workforce.payload_text(p_payload, 'classification', 32));
    if v_value is null or v_value not in ('AUTHORIZED', 'EXCUSED', 'DEDUCTIBLE', 'INFORMATIONAL') then
      raise exception 'WORKFORCE_FIELD_INVALID:classification' using errcode = 'P0001';
    end if;
    select c.* into v_previous_classification from workforce.work_exception_classifications c
    where c.exception_id = v_exception.id and c.superseded_at is null
    for update;
    if v_previous_classification.id is not null and v_previous_classification.classification = v_value then
      raise exception 'WORKFORCE_CLASSIFICATION_UNCHANGED' using errcode = 'P0001';
    end if;
    -- Append-only: the previous row is superseded, never overwritten. The current
    -- row is released first so the unique "current" index admits the new one.
    if v_previous_classification.id is not null then
      v_classification.id := gen_random_uuid();
      update workforce.work_exception_classifications c
      set superseded_at = now(), superseded_by = v_classification.id
      where c.id = v_previous_classification.id;
      insert into workforce.work_exception_classifications(id, tenant_id, exception_id, classification, reason, classified_by_admin_id)
      values (v_classification.id, v_exception.tenant_id, v_exception.id, v_value, workforce.payload_text(p_payload, 'reason', 1000), p_actor_admin_id)
      returning * into v_classification;
    else
      insert into workforce.work_exception_classifications(tenant_id, exception_id, classification, reason, classified_by_admin_id)
      values (v_exception.tenant_id, v_exception.id, v_value, workforce.payload_text(p_payload, 'reason', 1000), p_actor_admin_id)
      returning * into v_classification;
    end if;
    v_entity_type := 'work_exception_classification';
    v_entity_id := v_classification.id;
    v_after := jsonb_build_object('classification', v_value, 'previous', v_previous_classification.classification);
  else
    raise exception 'WORKFORCE_FIELD_INVALID:action' using errcode = 'P0001';
  end if;

  perform workforce.audit(v_tenant_id, p_actor_admin_id, 'OWNER', c_command || ':' || v_action,
    v_entity_type, v_entity_id, null, v_after);
  select x.* into v_exception from workforce.work_exceptions x where x.id = v_exception.id;
  return workforce.finish_command(p_actor_admin_id, c_command, p_idempotency_key, p_payload, v_tenant_id,
    jsonb_build_object('exception', workforce.exception_json(v_exception, 'OWNER') || workforce.review_json(v_exception.id, 'OWNER')));
exception
  when unique_violation then
    raise exception 'WORKFORCE_REVIEW_ALREADY_OPEN' using errcode = 'P0001';
  when check_violation then
    raise exception 'WORKFORCE_REVIEW_INVALID' using errcode = 'P0001';
end;
$$;

create function public.service_workforce_owner_list_review_queue(p_actor_admin_id uuid, p_employee_id uuid, p_month text)
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
    'blockers', coalesce((
      select jsonb_agg(jsonb_build_object('blocker', b.blocker, 'exception_id', b.exception_id, 'reference_id', b.reference_id)
        order by b.blocker, b.exception_id)
      from workforce.review_blockers(p_employee_id, v_from, (v_from + interval '1 month - 1 day')::date) b
    ), '[]'::jsonb),
    'exceptions', coalesce((
      select jsonb_agg(workforce.exception_json(x, 'OWNER') || workforce.review_json(x.id, 'OWNER')
        order by x.event_date, x.reported_start nulls first)
      from workforce.work_exceptions x
      where x.employee_id = p_employee_id
        and x.event_date between v_from and (v_from + interval '1 month - 1 day')::date
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on all tables in schema workforce from public, anon, authenticated, service_role;
revoke all on all functions in schema workforce from public, anon, authenticated, service_role;

do $$
declare
  v_identity text;
begin
  foreach v_identity in array array[
    'public.service_workforce_employee_review_exception(uuid,uuid,jsonb)',
    'public.service_workforce_owner_review_exception(uuid,uuid,jsonb)',
    'public.service_workforce_owner_list_review_queue(uuid,uuid,text)'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', v_identity);
    execute format('grant execute on function %s to service_role', v_identity);
  end loop;
end
$$;
