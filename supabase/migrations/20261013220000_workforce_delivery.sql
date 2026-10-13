-- Workforce S8 — accountant and employee delivery (ADR-017, spec §13).
-- Closure and delivery are independent states: a delivery failure never
-- reopens a competência. Deliveries are idempotent by (closure, version,
-- recipient, kind) and retried at most 3 times. Automatic closing/sending is
-- governed per employer by payroll_settings.auto_send_enabled (default false);
-- the schedule that drives the worker is activated separately from this
-- migration and only runs from main.

-- ---------------------------------------------------------------------------
-- Calendar: Nth business day and due instant.
-- ---------------------------------------------------------------------------

create function workforce.nth_business_day(p_employer_id uuid, p_month_start date, p_n integer)
returns date
language plpgsql
stable
set search_path = ''
as $$
declare
  v_date date := date_trunc('month', p_month_start)::date;
  v_end date := (date_trunc('month', p_month_start) + interval '1 month - 1 day')::date;
  v_count integer := 0;
begin
  if p_n is null or p_n < 1 or p_n > 23 then
    raise exception 'WORKFORCE_FIELD_INVALID:business_day' using errcode = 'P0001';
  end if;
  while v_date <= v_end loop
    if extract(isodow from v_date) < 6 and not workforce.is_holiday(p_employer_id, v_date) then
      v_count := v_count + 1;
      if v_count = p_n then
        return v_date;
      end if;
    end if;
    v_date := v_date + 1;
  end loop;
  raise exception 'WORKFORCE_BUSINESS_DAY_NOT_FOUND' using errcode = 'P0001';
end;
$$;

-- report_local_time (16:00) on the Nth (2nd) business day of the month after
-- the competência, in the employer timezone.
create function workforce.report_due_at(p_employer_id uuid, p_period_start date)
returns timestamptz
language sql
stable
set search_path = ''
as $$
  select (workforce.nth_business_day(e.id, (p_period_start + interval '1 month')::date, ps.report_business_day_ordinal)
          + ps.report_local_time)::timestamp at time zone e.timezone
  from workforce.employers e
  join workforce.payroll_settings ps on ps.employer_id = e.id
  where e.id = p_employer_id;
$$;

-- ---------------------------------------------------------------------------
-- Delivery ledger and employee receipt queue
-- ---------------------------------------------------------------------------

alter table workforce.payroll_settings
  add column employee_receipts_enabled boolean not null default false;

create table workforce.work_report_deliveries (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  closure_id uuid not null,
  version integer not null,
  report_kind text not null,
  recipient_kind text not null,
  recipient_email text not null,
  status text not null default 'PENDING',
  attempts integer not null default 0,
  max_attempts integer not null default 3,
  next_attempt_at timestamptz not null default now(),
  locked_until timestamptz,
  last_error_code text,
  provider_message_id text,
  sent_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint work_report_deliveries_closure_fkey foreign key (tenant_id, closure_id)
    references workforce.work_period_closures(tenant_id, id) on delete restrict,
  -- Conceptual idempotency key: closure + version + recipient (+ report kind).
  constraint work_report_deliveries_idempotency_key unique (closure_id, version, recipient_email, report_kind),
  constraint work_report_deliveries_kind_valid check (
    (report_kind = 'ACCOUNTANT_MIRROR' and recipient_kind in ('ACCOUNTANT', 'ACCOUNTANT_SECONDARY'))
    or (report_kind = 'EMPLOYEE_MIRROR' and recipient_kind = 'EMPLOYEE')
  ),
  constraint work_report_deliveries_status_valid check (status in ('PENDING', 'SENDING', 'SENT', 'FAILED')),
  constraint work_report_deliveries_attempts_valid check (attempts between 0 and max_attempts and max_attempts between 1 and 10),
  constraint work_report_deliveries_email_valid check (recipient_email = lower(recipient_email) and recipient_email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
  constraint work_report_deliveries_error_valid check (last_error_code is null or last_error_code ~ '^[A-Z0-9_]{1,80}$'),
  constraint work_report_deliveries_sent_valid check ((status = 'SENT') = (sent_at is not null))
);
create index work_report_deliveries_due_idx on workforce.work_report_deliveries(next_attempt_at) where status in ('PENDING', 'FAILED', 'SENDING');

create table workforce.work_notifications (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  employee_id uuid not null,
  event_kind text not null,
  entity_id uuid not null,
  dedupe_key text not null,
  payload jsonb not null,
  recipient_email text not null,
  status text not null default 'PENDING',
  attempts integer not null default 0,
  max_attempts integer not null default 3,
  next_attempt_at timestamptz not null default now(),
  locked_until timestamptz,
  last_error_code text,
  provider_message_id text,
  sent_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint work_notifications_employee_fkey foreign key (tenant_id, employee_id)
    references workforce.employees(tenant_id, id) on delete restrict,
  constraint work_notifications_dedupe_key unique (dedupe_key),
  constraint work_notifications_kind_valid check (event_kind in (
    'RECORD_COMPLETED', 'OWNER_OCCURRENCE', 'CORRECTION_REVIEWED', 'OWNER_CONTESTED'
  )),
  constraint work_notifications_status_valid check (status in ('PENDING', 'SENDING', 'SENT', 'FAILED')),
  constraint work_notifications_attempts_valid check (attempts between 0 and max_attempts and max_attempts between 1 and 10),
  constraint work_notifications_payload_object check (jsonb_typeof(payload) = 'object'),
  constraint work_notifications_error_valid check (last_error_code is null or last_error_code ~ '^[A-Z0-9_]{1,80}$'),
  constraint work_notifications_sent_valid check ((status = 'SENT') = (sent_at is not null))
);
create index work_notifications_due_idx on workforce.work_notifications(next_attempt_at) where status in ('PENDING', 'FAILED', 'SENDING');

comment on table workforce.work_report_deliveries is
  'Monthly report deliveries (accountant + employee mirror). Independent from the closure: FAILED never reopens the competência.';
comment on table workforce.work_notifications is
  'Employee receipts for completed records, owner occurrences, reviewed corrections and owner contests. Payload carries no free text.';

alter table workforce.work_report_deliveries enable row level security;
alter table workforce.work_report_deliveries force row level security;
alter table workforce.work_notifications enable row level security;
alter table workforce.work_notifications force row level security;
create policy work_report_deliveries_owner_only on workforce.work_report_deliveries as permissive for all to postgres using (true) with check (true);
create policy work_notifications_owner_only on workforce.work_notifications as permissive for all to postgres using (true) with check (true);

create trigger work_report_deliveries_touch before update on workforce.work_report_deliveries
  for each row execute function workforce.touch_updated_at();
create trigger work_notifications_touch before update on workforce.work_notifications
  for each row execute function workforce.touch_updated_at();

-- A SENT delivery is final; identity and recipient never change; nothing is deleted.
create function workforce.guard_delivery()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'WORKFORCE_IMMUTABLE:%', tg_table_name using errcode = 'P0001';
  end if;
  if old.status = 'SENT'
     or new.id is distinct from old.id
     or new.tenant_id is distinct from old.tenant_id
     or new.recipient_email is distinct from old.recipient_email
     or new.created_at is distinct from old.created_at
     or (to_jsonb(new) ? 'closure_id' and (to_jsonb(new) ->> 'closure_id') is distinct from (to_jsonb(old) ->> 'closure_id'))
     or (to_jsonb(new) ? 'dedupe_key' and (to_jsonb(new) ->> 'dedupe_key') is distinct from (to_jsonb(old) ->> 'dedupe_key')) then
    raise exception 'WORKFORCE_IMMUTABLE:%', tg_table_name using errcode = 'P0001';
  end if;
  return new;
end;
$$;
create trigger work_report_deliveries_guard before update or delete on workforce.work_report_deliveries
  for each row execute function workforce.guard_delivery();
create trigger work_notifications_guard before update or delete on workforce.work_notifications
  for each row execute function workforce.guard_delivery();

-- The owner read model exposes the receipts switch.
create or replace function workforce.employer_json(p_employer_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'employer_id', e.id,
    'legal_name', e.legal_name,
    'trade_name', e.trade_name,
    'cnpj', e.cnpj,
    'workplace_city', e.workplace_city,
    'workplace_state', e.workplace_state,
    'workplace_city_ibge_code', e.workplace_city_ibge_code,
    'timezone', e.timezone,
    'active', e.active,
    'payroll_settings', (
      select jsonb_build_object(
        'accountant_name', ps.accountant_name,
        'accountant_email', ps.accountant_email,
        'accountant_email_secondary', ps.accountant_email_secondary,
        'report_business_day_ordinal', ps.report_business_day_ordinal,
        'report_local_time', to_char(ps.report_local_time, 'HH24:MI'),
        'auto_send_enabled', ps.auto_send_enabled,
        'employee_receipts_enabled', ps.employee_receipts_enabled,
        'tolerance_minutes_per_mark', ps.tolerance_minutes_per_mark,
        'tolerance_minutes_daily_max', ps.tolerance_minutes_daily_max,
        'max_extra_minutes_per_day', ps.max_extra_minutes_per_day,
        'minimum_interjourney_rest_minutes', ps.minimum_interjourney_rest_minutes,
        'minimum_weekly_rest_minutes', ps.minimum_weekly_rest_minutes,
        'minimum_long_interval_minutes', ps.minimum_long_interval_minutes,
        'split_shift_review_threshold_minutes', ps.split_shift_review_threshold_minutes,
        'default_weekly_schedule', ps.default_weekly_schedule
      )
      from workforce.payroll_settings ps
      where ps.employer_id = e.id
    )
  )
  from workforce.employers e
  where e.id = p_employer_id;
$$;

-- ---------------------------------------------------------------------------
-- Enqueue
-- ---------------------------------------------------------------------------

create function workforce.employee_email(p_employee_id uuid)
returns text
language sql
stable
set search_path = ''
as $$
  select lower(u.email)
  from workforce.employees e
  join public.admin_users au on au.id = e.admin_user_id
  join auth.users u on u.id = au.auth_user_id
  where e.id = p_employee_id;
$$;

-- Every closure (owner or system, any version) is delivered when the employer
-- enabled automatic delivery: accountant mirror to the configured accountant
-- (and secondary) and the employee mirror as her receipt.
create function workforce.enqueue_closure_deliveries()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_period workforce.work_periods;
  v_settings workforce.payroll_settings;
  v_employee_email text;
begin
  select wp.* into v_period from workforce.work_periods wp where wp.id = new.period_id;
  select ps.* into v_settings from workforce.payroll_settings ps where ps.employer_id = v_period.employer_id;
  if not v_settings.auto_send_enabled then
    return null;
  end if;
  if v_settings.accountant_email is not null then
    insert into workforce.work_report_deliveries(tenant_id, closure_id, version, report_kind, recipient_kind, recipient_email)
    values (new.tenant_id, new.id, new.version, 'ACCOUNTANT_MIRROR', 'ACCOUNTANT', v_settings.accountant_email)
    on conflict do nothing;
  end if;
  if v_settings.accountant_email_secondary is not null then
    insert into workforce.work_report_deliveries(tenant_id, closure_id, version, report_kind, recipient_kind, recipient_email)
    values (new.tenant_id, new.id, new.version, 'ACCOUNTANT_MIRROR', 'ACCOUNTANT_SECONDARY', v_settings.accountant_email_secondary)
    on conflict do nothing;
  end if;
  v_employee_email := workforce.employee_email(v_period.employee_id);
  if v_employee_email is not null then
    insert into workforce.work_report_deliveries(tenant_id, closure_id, version, report_kind, recipient_kind, recipient_email)
    values (new.tenant_id, new.id, new.version, 'EMPLOYEE_MIRROR', 'EMPLOYEE', v_employee_email)
    on conflict do nothing;
  end if;
  return null;
end;
$$;
create trigger work_period_closures_enqueue_deliveries after insert on workforce.work_period_closures
  for each row execute function workforce.enqueue_closure_deliveries();

create function workforce.enqueue_notification(
  p_employee_id uuid,
  p_event_kind text,
  p_entity_id uuid,
  p_dedupe_suffix text,
  p_payload jsonb
)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_employee workforce.employees;
  v_enabled boolean;
  v_email text;
begin
  select e.* into v_employee from workforce.employees e where e.id = p_employee_id;
  select ps.employee_receipts_enabled into v_enabled from workforce.payroll_settings ps where ps.employer_id = v_employee.employer_id;
  v_email := workforce.employee_email(p_employee_id);
  if not coalesce(v_enabled, false) or v_email is null then
    return;
  end if;
  insert into workforce.work_notifications(tenant_id, employee_id, event_kind, entity_id, dedupe_key, payload, recipient_email)
  values (v_employee.tenant_id, v_employee.id, p_event_kind, p_entity_id,
          p_event_kind || ':' || p_entity_id::text || ':' || p_dedupe_suffix, p_payload, v_email)
  on conflict (dedupe_key) do nothing;
end;
$$;

-- Safe receipt payload: dates, local period, type and status only.
create function workforce.receipt_payload(p_exception_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'exception_type', ef.exception_type,
    'event_date', ef.event_date,
    'all_day', ef.all_day,
    'start_local', to_char(ef.period_start at time zone er.timezone, 'YYYY-MM-DD"T"HH24:MI'),
    'end_local', to_char(ef.period_end at time zone er.timezone, 'YYYY-MM-DD"T"HH24:MI'),
    'status', x.status,
    'source', x.source
  )
  from workforce.work_exceptions x
  join workforce.employers er on er.id = x.employer_id
  cross join lateral workforce.effective_exception(x.id) ef
  where x.id = p_exception_id;
$$;

-- Receipts only for concluded events, never for intermediate clicks:
-- a live start (OPEN) sends nothing; its finish does.
create function workforce.enqueue_exception_receipt()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.status = 'OPEN' then
    return null;
  end if;
  if tg_op = 'INSERT' or (old.status = 'OPEN' and new.status <> 'OPEN') then
    perform workforce.enqueue_notification(
      new.employee_id,
      case when new.source in ('MANAGER', 'RETROACTIVE_MANAGER') then 'OWNER_OCCURRENCE' else 'RECORD_COMPLETED' end,
      new.id, 'v1', workforce.receipt_payload(new.id));
  end if;
  return null;
end;
$$;
create trigger work_exceptions_enqueue_receipt after insert or update of status on workforce.work_exceptions
  for each row execute function workforce.enqueue_exception_receipt();

create function workforce.enqueue_correction_receipt()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.status in ('APPROVED', 'REJECTED') and old.status = 'PENDING' then
    perform workforce.enqueue_notification(new.employee_id, 'CORRECTION_REVIEWED', new.id, new.status,
      workforce.receipt_payload(new.exception_id) || jsonb_build_object('decision', new.status));
  end if;
  return null;
end;
$$;
create trigger work_exception_corrections_enqueue_receipt after update of status on workforce.work_exception_corrections
  for each row execute function workforce.enqueue_correction_receipt();

create function workforce.enqueue_contest_receipt()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.kind = 'MANAGER_CONTESTED' then
    perform workforce.enqueue_notification(new.employee_id, 'OWNER_CONTESTED', new.id, 'v1',
      workforce.receipt_payload(new.exception_id));
  end if;
  return null;
end;
$$;
create trigger work_exception_acknowledgements_enqueue_receipt after insert on workforce.work_exception_acknowledgements
  for each row execute function workforce.enqueue_contest_receipt();

-- With automatic delivery on, the report cannot go out without an accountant.
create or replace function workforce.evaluate_period(p_period_id uuid)
returns workforce.work_periods
language plpgsql
set search_path = ''
as $$
declare
  v_period workforce.work_periods;
  v_employer workforce.employers;
  v_settings workforce.payroll_settings;
  v_id uuid;
  v_blockers jsonb;
  v_status text;
begin
  select wp.* into v_period from workforce.work_periods wp where wp.id = p_period_id for update;
  if v_period.status = 'CLOSED' then
    return v_period;
  end if;
  select er.* into v_employer from workforce.employers er where er.id = v_period.employer_id;
  select ps.* into v_settings from workforce.payroll_settings ps where ps.employer_id = v_period.employer_id;

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

  if v_employer.cnpj is null then
    v_blockers := v_blockers || jsonb_build_array(jsonb_build_object('blocker', 'EMPLOYER_CNPJ_MISSING'));
  end if;
  if v_settings.auto_send_enabled and v_settings.accountant_email is null then
    v_blockers := v_blockers || jsonb_build_array(jsonb_build_object('blocker', 'ACCOUNTANT_EMAIL_MISSING'));
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

-- ---------------------------------------------------------------------------
-- Worker cycle
-- ---------------------------------------------------------------------------

-- One scheduler cycle at instant p_now:
--  1. for employers with automatic delivery, every never-closed competência
--     whose due instant (16:00 of the 2nd business day of the next month) has
--     passed is evaluated; READY ones are closed by SYSTEM (enqueueing the
--     deliveries), BLOCKED ones stay blocked and are retried on the next cycle —
--     so a month unblocked after the due time goes out on the next cycle.
--     Reopened competências are never auto-closed (the owner re-closes them).
--  2. due deliveries and receipts are claimed (locked) for the sender.
create function workforce.run_cycle(p_now timestamptz, p_claim_limit integer default 25)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_employee record;
  v_month date;
  v_period workforce.work_periods;
  v_closed integer := 0;
  v_blocked integer := 0;
  v_deliveries jsonb;
  v_notifications jsonb;
begin
  for v_employee in
    select e.id, e.employer_id, e.hired_on, e.created_at, er.timezone
    from workforce.employees e
    join workforce.employers er on er.id = e.employer_id and er.active
    join workforce.payroll_settings ps on ps.employer_id = er.id and ps.auto_send_enabled
    join public.tenants t on t.id = e.tenant_id and t.status = 'ACTIVE'
    where e.active
  loop
    for v_month in
      select m::date
      from generate_series(
        date_trunc('month', coalesce(v_employee.hired_on, (v_employee.created_at at time zone v_employee.timezone)::date)),
        date_trunc('month', (p_now at time zone v_employee.timezone)::date) - interval '1 month',
        interval '1 month') m
    loop
      if p_now < workforce.report_due_at(v_employee.employer_id, v_month) then
        continue;
      end if;
      select wp.* into v_period from workforce.work_periods wp
      where wp.employee_id = v_employee.id and wp.period_start = v_month;
      if v_period.id is not null and (v_period.status = 'CLOSED' or v_period.current_version > 0) then
        continue;
      end if;
      v_period := workforce.ensure_period(v_employee.id, v_month);
      v_period := workforce.evaluate_period(v_period.id);
      if v_period.status = 'READY_TO_CLOSE' then
        perform workforce.close_period(v_period.id, null, 'SYSTEM');
        v_closed := v_closed + 1;
      elsif v_period.status = 'BLOCKED' then
        v_blocked := v_blocked + 1;
      end if;
    end loop;
  end loop;

  -- Claim due deliveries: PENDING, FAILED with attempts left, or SENDING whose
  -- lock expired (crashed sender). Each claim consumes one attempt.
  with due as (
    select d.id from workforce.work_report_deliveries d
    where d.next_attempt_at <= p_now
      and d.attempts < d.max_attempts
      and (d.status in ('PENDING', 'FAILED') or (d.status = 'SENDING' and d.locked_until < p_now))
    order by d.next_attempt_at, d.created_at
    limit p_claim_limit
    for update skip locked
  ), claimed as (
    update workforce.work_report_deliveries d
    set status = 'SENDING', attempts = d.attempts + 1, locked_until = p_now + interval '10 minutes'
    from due where d.id = due.id
    returning d.*
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'delivery_id', c.id,
    'idempotency_key', 'workforce-report:' || c.closure_id || ':' || c.version || ':' || c.recipient_email || ':' || c.report_kind,
    'recipient_email', c.recipient_email,
    'recipient_kind', c.recipient_kind,
    'report_kind', c.report_kind,
    'version', c.version,
    'attempt', c.attempts,
    'report', r.payload
  ) order by c.created_at), '[]'::jsonb) into v_deliveries
  from claimed c
  join workforce.work_period_reports r on r.closure_id = c.closure_id and r.report_kind = c.report_kind;

  with due as (
    select n.id from workforce.work_notifications n
    where n.next_attempt_at <= p_now
      and n.attempts < n.max_attempts
      and (n.status in ('PENDING', 'FAILED') or (n.status = 'SENDING' and n.locked_until < p_now))
    order by n.next_attempt_at, n.created_at
    limit p_claim_limit
    for update skip locked
  ), claimed as (
    update workforce.work_notifications n
    set status = 'SENDING', attempts = n.attempts + 1, locked_until = p_now + interval '10 minutes'
    from due where n.id = due.id
    returning n.*
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'notification_id', c.id,
    'idempotency_key', 'workforce-receipt:' || c.dedupe_key,
    'recipient_email', c.recipient_email,
    'event_kind', c.event_kind,
    'attempt', c.attempts,
    'employer_legal_name', er.legal_name,
    'employee_display_name', e.display_name,
    'payload', c.payload
  ) order by c.created_at), '[]'::jsonb) into v_notifications
  from claimed c
  join workforce.employees e on e.id = c.employee_id
  join workforce.employers er on er.id = e.employer_id;

  return jsonb_build_object(
    'closed_periods', v_closed,
    'blocked_periods', v_blocked,
    'deliveries', v_deliveries,
    'notifications', v_notifications
  );
end;
$$;

-- Record a send result. Failure keeps the closure CLOSED and schedules a retry
-- (15 min × attempt) until max_attempts; the error code is a shaped token only.
create function workforce.record_send_result(
  p_kind text,
  p_id uuid,
  p_success boolean,
  p_provider_message_id text,
  p_error_code text,
  p_now timestamptz
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_error text := case when p_error_code ~ '^[A-Z0-9_]{1,80}$' then p_error_code else 'SEND_FAILED' end;
  v_status text;
begin
  if p_kind = 'DELIVERY' then
    update workforce.work_report_deliveries d
    set status = case when p_success then 'SENT' else 'FAILED' end,
        sent_at = case when p_success then p_now end,
        provider_message_id = case when p_success then left(p_provider_message_id, 200) else d.provider_message_id end,
        last_error_code = case when p_success then null else v_error end,
        next_attempt_at = case when p_success then d.next_attempt_at else p_now + make_interval(mins => 15 * d.attempts) end,
        locked_until = null
    where d.id = p_id and d.status = 'SENDING'
    returning d.status into v_status;
  elsif p_kind = 'NOTIFICATION' then
    update workforce.work_notifications n
    set status = case when p_success then 'SENT' else 'FAILED' end,
        sent_at = case when p_success then p_now end,
        provider_message_id = case when p_success then left(p_provider_message_id, 200) else n.provider_message_id end,
        last_error_code = case when p_success then null else v_error end,
        next_attempt_at = case when p_success then n.next_attempt_at else p_now + make_interval(mins => 15 * n.attempts) end,
        locked_until = null
    where n.id = p_id and n.status = 'SENDING'
    returning n.status into v_status;
  else
    raise exception 'WORKFORCE_FIELD_INVALID:kind' using errcode = 'P0001';
  end if;
  if v_status is null then
    raise exception 'WORKFORCE_SEND_NOT_CLAIMED' using errcode = 'P0001';
  end if;
  return jsonb_build_object('id', p_id, 'status', v_status);
end;
$$;

-- ---------------------------------------------------------------------------
-- Governed RPCs
-- ---------------------------------------------------------------------------

-- Scheduler entrypoint (service_role only; called by the OIDC-verified trigger).
create function public.service_workforce_system_run_cycle()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  return workforce.run_cycle(now());
end;
$$;

create function public.service_workforce_system_record_send_result(
  p_kind text,
  p_id uuid,
  p_success boolean,
  p_provider_message_id text,
  p_error_code text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  return workforce.record_send_result(p_kind, p_id, p_success, p_provider_message_id, p_error_code, now());
end;
$$;

create function public.service_workforce_owner_manage_delivery(
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
  c_command constant text := 'OWNER_MANAGE_DELIVERY';
  v_tenant_id uuid := workforce.require_owner(p_actor_admin_id);
  v_replay jsonb;
  v_action text;
  v_employer_id uuid;
  v_delivery workforce.work_report_deliveries;
  v_response jsonb;
begin
  v_replay := workforce.begin_command(p_actor_admin_id, c_command, p_idempotency_key, p_payload);
  if v_replay is not null then
    return v_replay;
  end if;
  perform workforce.assert_payload(p_payload, array['action', 'employer_id', 'enabled', 'delivery_id'], array['action']);
  v_action := upper(workforce.payload_text(p_payload, 'action', 32));

  if v_action in ('SET_AUTO_SEND', 'SET_EMPLOYEE_RECEIPTS') then
    perform workforce.assert_payload(p_payload, array['action', 'employer_id', 'enabled'], array['action', 'employer_id', 'enabled']);
    v_employer_id := workforce.payload_uuid(p_payload, 'employer_id');
    if not exists (select 1 from workforce.employers er where er.id = v_employer_id and er.tenant_id = v_tenant_id) then
      raise exception 'WORKFORCE_EMPLOYER_NOT_FOUND' using errcode = 'P0001';
    end if;
    if v_action = 'SET_AUTO_SEND' and workforce.payload_bool(p_payload, 'enabled') and exists (
      select 1 from workforce.payroll_settings ps join workforce.employers er on er.id = ps.employer_id
      where ps.employer_id = v_employer_id and (ps.accountant_email is null or er.cnpj is null)
    ) then
      raise exception 'WORKFORCE_AUTO_SEND_REQUIRES_ACCOUNTANT_AND_CNPJ' using errcode = 'P0001';
    end if;
    update workforce.payroll_settings ps
    set auto_send_enabled = case when v_action = 'SET_AUTO_SEND' then workforce.payload_bool(p_payload, 'enabled') else ps.auto_send_enabled end,
        employee_receipts_enabled = case when v_action = 'SET_EMPLOYEE_RECEIPTS' then workforce.payload_bool(p_payload, 'enabled') else ps.employee_receipts_enabled end,
        updated_by_admin_id = p_actor_admin_id
    where ps.employer_id = v_employer_id;
    perform workforce.audit(v_tenant_id, p_actor_admin_id, 'OWNER', c_command || ':' || v_action, 'payroll_settings', v_employer_id,
      null, jsonb_build_object('enabled', workforce.payload_bool(p_payload, 'enabled')));
    v_response := jsonb_build_object('employer', workforce.employer_json(v_employer_id));

  elsif v_action = 'RETRY' then
    -- Manual retry of a delivery that exhausted its automatic attempts: grants
    -- one more attempt; the idempotency key is unchanged, so a send the provider
    -- already accepted is not duplicated.
    perform workforce.assert_payload(p_payload, array['action', 'delivery_id'], array['action', 'delivery_id']);
    select d.* into v_delivery from workforce.work_report_deliveries d
    where d.id = workforce.payload_uuid(p_payload, 'delivery_id') and d.tenant_id = v_tenant_id
    for update;
    if v_delivery.id is null then
      raise exception 'WORKFORCE_DELIVERY_NOT_FOUND' using errcode = 'P0001';
    end if;
    if v_delivery.status <> 'FAILED' or v_delivery.attempts < v_delivery.max_attempts then
      raise exception 'WORKFORCE_DELIVERY_NOT_RETRYABLE' using errcode = 'P0001';
    end if;
    update workforce.work_report_deliveries d
    set max_attempts = least(d.max_attempts + 1, 10), next_attempt_at = now()
    where d.id = v_delivery.id
    returning * into v_delivery;
    perform workforce.audit(v_tenant_id, p_actor_admin_id, 'OWNER', c_command || ':RETRY', 'work_report_delivery', v_delivery.id,
      null, jsonb_build_object('max_attempts', v_delivery.max_attempts));
    v_response := jsonb_build_object('delivery_id', v_delivery.id, 'status', v_delivery.status);
  else
    raise exception 'WORKFORCE_FIELD_INVALID:action' using errcode = 'P0001';
  end if;

  return workforce.finish_command(p_actor_admin_id, c_command, p_idempotency_key, p_payload, v_tenant_id, v_response);
end;
$$;

create function public.service_workforce_owner_list_deliveries(p_actor_admin_id uuid, p_employee_id uuid, p_month text)
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
    'due_at', (
      select workforce.report_due_at(e.employer_id, workforce.parse_month(p_month))
      from workforce.employees e where e.id = p_employee_id
    ),
    'deliveries', coalesce((
      select jsonb_agg(jsonb_build_object(
        'delivery_id', d.id,
        'version', d.version,
        'report_kind', d.report_kind,
        'recipient_kind', d.recipient_kind,
        'recipient_email', d.recipient_email,
        'status', d.status,
        'attempts', d.attempts,
        'max_attempts', d.max_attempts,
        'last_error_code', d.last_error_code,
        'sent_at', d.sent_at,
        'created_at', d.created_at
      ) order by d.version desc, d.report_kind, d.recipient_kind)
      from workforce.work_report_deliveries d
      join workforce.work_period_closures c on c.id = d.closure_id
      join workforce.work_periods wp on wp.id = c.period_id
      where wp.employee_id = p_employee_id and wp.period_start = workforce.parse_month(p_month)
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
    'public.service_workforce_system_run_cycle()',
    'public.service_workforce_system_record_send_result(text,uuid,boolean,text,text)',
    'public.service_workforce_owner_manage_delivery(uuid,uuid,jsonb)',
    'public.service_workforce_owner_list_deliveries(uuid,uuid,text)'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', v_identity);
    execute format('grant execute on function %s to service_role', v_identity);
  end loop;
end
$$;
