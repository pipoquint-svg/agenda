-- Workforce S1 — Jornada por Exceção foundation.
-- Employer, employee, versioned schedule, payroll settings, territorial holidays,
-- append-only audit and idempotent command receipts.
--
-- Security model (docs/architecture/WORKFORCE-EXCEPTION-JOURNEY-V1.md §5):
-- * tables live in the unexposed schema `workforce`; no role other than the
--   owner (postgres) has any privilege on the schema, its tables or functions;
-- * RLS is enabled and forced with no policies as defense in depth;
-- * every read/mutation goes through public.service_workforce_* SECURITY DEFINER
--   RPCs executable only by service_role, called by the workforce Edge Functions
--   with a server-resolved actor. Tenant, employer and employee are derived and
--   revalidated inside the RPC; browser-supplied identity/state fields are rejected.

create schema if not exists workforce;
revoke all on schema workforce from public, anon, authenticated, service_role;
alter default privileges in schema workforce revoke all on tables from public, anon, authenticated, service_role;
alter default privileges in schema workforce revoke all on sequences from public, anon, authenticated, service_role;
alter default privileges in schema workforce revoke execute on functions from public, anon, authenticated, service_role;
comment on schema workforce is
  'Jornada por Exceção (ADR-017). Not exposed by PostgREST; reachable only through public.service_workforce_* service-role RPCs.';

-- ---------------------------------------------------------------------------
-- Pure helpers
-- ---------------------------------------------------------------------------

-- CNPJ check digits. Supports the numeric format and the alphanumeric format
-- (IN RFB 2.229/2024): 12 alphanumeric characters + 2 numeric check digits,
-- each character valued as ascii(c) - 48.
create function workforce.cnpj_is_valid(p_cnpj text)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_weights1 constant int[] := array[5,4,3,2,9,8,7,6,5,4,3,2];
  v_weights2 constant int[] := array[6,5,4,3,2,9,8,7,6,5,4,3,2];
  v_sum int;
  v_dv1 int;
  v_dv2 int;
  i int;
begin
  if p_cnpj is null or p_cnpj !~ '^[0-9A-Z]{12}[0-9]{2}$' then
    return false;
  end if;
  if p_cnpj ~ '^([0-9])\1{13}$' then
    return false;
  end if;
  v_sum := 0;
  for i in 1..12 loop
    v_sum := v_sum + (ascii(substr(p_cnpj, i, 1)) - 48) * v_weights1[i];
  end loop;
  v_dv1 := case when v_sum % 11 < 2 then 0 else 11 - v_sum % 11 end;
  v_sum := 0;
  for i in 1..12 loop
    v_sum := v_sum + (ascii(substr(p_cnpj, i, 1)) - 48) * v_weights2[i];
  end loop;
  v_sum := v_sum + v_dv1 * v_weights2[13];
  v_dv2 := case when v_sum % 11 < 2 then 0 else 11 - v_sum % 11 end;
  return substr(p_cnpj, 13, 1)::int = v_dv1 and substr(p_cnpj, 14, 1)::int = v_dv2;
end;
$$;

-- Gregorian Easter Sunday (anonymous Gregorian algorithm).
create function workforce.easter_sunday(p_year int)
returns date
language plpgsql
immutable
set search_path = ''
as $$
declare
  a int := p_year % 19;
  b int := p_year / 100;
  c int := p_year % 100;
  d int := b / 4;
  e int := b % 4;
  f int := (b + 8) / 25;
  g int := (b - f + 1) / 3;
  h int := (19 * a + b - d - g + 15) % 30;
  i int := c / 4;
  k int := c % 4;
  l int := (32 + 2 * e + 2 * i - h - k) % 7;
  m int := (a + 11 * h + 22 * l) / 451;
  v_month int := (h + l - 7 * m + 114) / 31;
  v_day int := ((h + l - 7 * m + 114) % 31) + 1;
begin
  if p_year is null or p_year < 1583 or p_year > 9999 then
    raise exception 'WORKFORCE_YEAR_INVALID' using errcode = 'P0001';
  end if;
  return make_date(p_year, v_month, v_day);
end;
$$;

create function workforce.assert_payload(p_payload jsonb, p_allowed text[], p_required text[] default '{}'::text[])
returns void
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_key text;
begin
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    raise exception 'WORKFORCE_PAYLOAD_INVALID' using errcode = 'P0001';
  end if;
  for v_key in select jsonb_object_keys(p_payload) loop
    if not (v_key = any(p_allowed)) then
      raise exception 'WORKFORCE_PAYLOAD_FIELD_FORBIDDEN:%', v_key using errcode = 'P0001';
    end if;
  end loop;
  foreach v_key in array p_required loop
    if not (p_payload ? v_key) or jsonb_typeof(p_payload -> v_key) = 'null' then
      raise exception 'WORKFORCE_PAYLOAD_FIELD_REQUIRED:%', v_key using errcode = 'P0001';
    end if;
  end loop;
end;
$$;

create function workforce.payload_text(p_payload jsonb, p_key text, p_max_length int default 200)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_value text;
begin
  if not (p_payload ? p_key) or jsonb_typeof(p_payload -> p_key) = 'null' then
    return null;
  end if;
  if jsonb_typeof(p_payload -> p_key) <> 'string' then
    raise exception 'WORKFORCE_FIELD_INVALID:%', p_key using errcode = 'P0001';
  end if;
  v_value := nullif(btrim(p_payload ->> p_key), '');
  if v_value is not null and length(v_value) > p_max_length then
    raise exception 'WORKFORCE_FIELD_TOO_LONG:%', p_key using errcode = 'P0001';
  end if;
  return v_value;
end;
$$;

create function workforce.payload_uuid(p_payload jsonb, p_key text)
returns uuid
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_value text := workforce.payload_text(p_payload, p_key, 36);
begin
  if v_value is null then
    return null;
  end if;
  if v_value !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    raise exception 'WORKFORCE_FIELD_INVALID:%', p_key using errcode = 'P0001';
  end if;
  return v_value::uuid;
end;
$$;

create function workforce.payload_date(p_payload jsonb, p_key text)
returns date
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_value text := workforce.payload_text(p_payload, p_key, 10);
begin
  if v_value is null then
    return null;
  end if;
  if v_value !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
    raise exception 'WORKFORCE_FIELD_INVALID:%', p_key using errcode = 'P0001';
  end if;
  begin
    return v_value::date;
  exception when others then
    raise exception 'WORKFORCE_FIELD_INVALID:%', p_key using errcode = 'P0001';
  end;
end;
$$;

create function workforce.payload_time(p_payload jsonb, p_key text)
returns time
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_value text := workforce.payload_text(p_payload, p_key, 5);
begin
  if v_value is null then
    return null;
  end if;
  if v_value !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then
    raise exception 'WORKFORCE_FIELD_INVALID:%', p_key using errcode = 'P0001';
  end if;
  return v_value::time;
end;
$$;

create function workforce.payload_int(p_payload jsonb, p_key text, p_min int, p_max int)
returns int
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_value numeric;
begin
  if not (p_payload ? p_key) or jsonb_typeof(p_payload -> p_key) = 'null' then
    return null;
  end if;
  if jsonb_typeof(p_payload -> p_key) <> 'number' then
    raise exception 'WORKFORCE_FIELD_INVALID:%', p_key using errcode = 'P0001';
  end if;
  v_value := (p_payload ->> p_key)::numeric;
  if v_value <> trunc(v_value) or v_value < p_min or v_value > p_max then
    raise exception 'WORKFORCE_FIELD_OUT_OF_RANGE:%', p_key using errcode = 'P0001';
  end if;
  return v_value::int;
end;
$$;

create function workforce.payload_bool(p_payload jsonb, p_key text)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
begin
  if not (p_payload ? p_key) or jsonb_typeof(p_payload -> p_key) = 'null' then
    return null;
  end if;
  if jsonb_typeof(p_payload -> p_key) <> 'boolean' then
    raise exception 'WORKFORCE_FIELD_INVALID:%', p_key using errcode = 'P0001';
  end if;
  return (p_payload ->> p_key)::boolean;
end;
$$;

create function workforce.normalize_email(p_payload jsonb, p_key text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_value text := lower(workforce.payload_text(p_payload, p_key, 254));
begin
  if v_value is not null and v_value !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'WORKFORCE_EMAIL_INVALID:%', p_key using errcode = 'P0001';
  end if;
  return v_value;
end;
$$;

-- Validates and normalizes a weekly schedule: array of
-- {iso_weekday 1..7, start_time "HH:MM", end_time "HH:MM"}. Blocks of the same
-- day may not overlap; overnight blocks are not supported in V1 (end > start).
-- Returns the canonical array ordered by weekday/start with block_index.
create function workforce.normalize_weekly_schedule(p_days jsonb)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_item jsonb;
  v_result jsonb := '[]'::jsonb;
  v_row record;
  v_prev_day int := null;
  v_prev_end time := null;
  v_block int := 0;
begin
  if p_days is null or jsonb_typeof(p_days) <> 'array' then
    raise exception 'WORKFORCE_SCHEDULE_DAYS_INVALID' using errcode = 'P0001';
  end if;
  if jsonb_array_length(p_days) > 28 then
    raise exception 'WORKFORCE_SCHEDULE_DAYS_INVALID' using errcode = 'P0001';
  end if;
  for v_item in select value from jsonb_array_elements(p_days) loop
    perform workforce.assert_payload(v_item, array['iso_weekday', 'start_time', 'end_time'], array['iso_weekday', 'start_time', 'end_time']);
    perform workforce.payload_int(v_item, 'iso_weekday', 1, 7);
    if workforce.payload_time(v_item, 'end_time') <= workforce.payload_time(v_item, 'start_time') then
      raise exception 'WORKFORCE_SCHEDULE_BLOCK_INVALID' using errcode = 'P0001';
    end if;
  end loop;

  for v_row in
    select workforce.payload_int(value, 'iso_weekday', 1, 7) as iso_weekday,
           workforce.payload_time(value, 'start_time') as start_time,
           workforce.payload_time(value, 'end_time') as end_time
    from jsonb_array_elements(p_days)
    order by 1, 2
  loop
    if v_prev_day is distinct from v_row.iso_weekday then
      v_block := 0;
      v_prev_end := null;
    end if;
    if v_prev_end is not null and v_row.start_time < v_prev_end then
      raise exception 'WORKFORCE_SCHEDULE_BLOCK_OVERLAP' using errcode = 'P0001';
    end if;
    v_block := v_block + 1;
    if v_block > 4 then
      raise exception 'WORKFORCE_SCHEDULE_DAYS_INVALID' using errcode = 'P0001';
    end if;
    v_result := v_result || jsonb_build_array(jsonb_build_object(
      'iso_weekday', v_row.iso_weekday,
      'block_index', v_block,
      'start_time', to_char(v_row.start_time, 'HH24:MI'),
      'end_time', to_char(v_row.end_time, 'HH24:MI')
    ));
    v_prev_day := v_row.iso_weekday;
    v_prev_end := v_row.end_time;
  end loop;
  return v_result;
end;
$$;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

create table workforce.employers (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete restrict,
  legal_name text not null,
  trade_name text,
  cnpj text,
  workplace_city text not null,
  workplace_state text not null,
  workplace_city_ibge_code text,
  timezone text not null default 'America/Sao_Paulo',
  active boolean not null default true,
  created_by_admin_id uuid references public.admin_users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint employers_tenant_id_key unique (tenant_id, id),
  constraint employers_legal_name_valid check (length(btrim(legal_name)) between 2 and 200),
  constraint employers_trade_name_valid check (trade_name is null or length(btrim(trade_name)) between 1 and 200),
  constraint employers_cnpj_valid check (cnpj is null or workforce.cnpj_is_valid(cnpj)),
  constraint employers_workplace_city_valid check (length(btrim(workplace_city)) between 2 and 120),
  constraint employers_workplace_state_valid check (workplace_state ~ '^[A-Z]{2}$'),
  constraint employers_ibge_code_valid check (workplace_city_ibge_code is null or workplace_city_ibge_code ~ '^[0-9]{7}$')
);
create unique index employers_tenant_cnpj_key on workforce.employers(tenant_id, cnpj) where cnpj is not null;
comment on table workforce.employers is
  'Legal employer (razão social + CNPJ). tenant != employer: one Agenda tenant may hold several employers.';

create table workforce.payroll_settings (
  employer_id uuid primary key,
  tenant_id uuid not null,
  accountant_name text,
  accountant_email text,
  accountant_email_secondary text,
  report_business_day_ordinal smallint not null default 2,
  report_local_time time not null default '16:00',
  auto_send_enabled boolean not null default false,
  tolerance_minutes_per_mark smallint not null default 0,
  tolerance_minutes_daily_max smallint not null default 0,
  max_extra_minutes_per_day integer not null default 120,
  minimum_interjourney_rest_minutes integer not null default 660,
  minimum_weekly_rest_minutes integer not null default 1440,
  minimum_long_interval_minutes integer not null default 60,
  split_shift_review_threshold_minutes integer not null default 120,
  default_weekly_schedule jsonb not null default '[]'::jsonb,
  updated_by_admin_id uuid references public.admin_users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint payroll_settings_employer_fkey foreign key (tenant_id, employer_id)
    references workforce.employers(tenant_id, id) on delete cascade,
  constraint payroll_settings_accountant_name_valid check (accountant_name is null or length(btrim(accountant_name)) between 2 and 200),
  constraint payroll_settings_accountant_email_valid check (accountant_email is null or accountant_email = lower(accountant_email)),
  constraint payroll_settings_accountant_secondary_valid check (
    accountant_email_secondary is null
    or (accountant_email_secondary = lower(accountant_email_secondary)
        and accountant_email is not null
        and accountant_email_secondary <> accountant_email)
  ),
  constraint payroll_settings_report_day_valid check (report_business_day_ordinal between 1 and 10),
  constraint payroll_settings_tolerance_valid check (
    tolerance_minutes_per_mark between 0 and 60
    and tolerance_minutes_daily_max between 0 and 120
  ),
  constraint payroll_settings_limits_valid check (
    max_extra_minutes_per_day between 0 and 1440
    and minimum_interjourney_rest_minutes between 0 and 2880
    and minimum_weekly_rest_minutes between 0 and 10080
    and minimum_long_interval_minutes between 0 and 600
    and split_shift_review_threshold_minutes between 0 and 1440
  ),
  constraint payroll_settings_default_schedule_array check (jsonb_typeof(default_weekly_schedule) = 'array')
);
comment on table workforce.payroll_settings is
  'Per-employer accountant contact, monthly report rule (Nth business day at local time), tolerance and compliance review parameters. Civil-month competência only.';

create table workforce.employees (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  employer_id uuid not null,
  admin_user_id uuid not null references public.admin_users(id) on delete restrict,
  display_name text not null,
  active boolean not null default true,
  hired_on date,
  terminated_on date,
  created_by_admin_id uuid references public.admin_users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint employees_tenant_id_key unique (tenant_id, id),
  constraint employees_employer_fkey foreign key (tenant_id, employer_id)
    references workforce.employers(tenant_id, id) on delete restrict,
  constraint employees_display_name_valid check (length(btrim(display_name)) between 2 and 120),
  constraint employees_dates_valid check (terminated_on is null or hired_on is null or terminated_on >= hired_on)
);
-- One active employment per existing login: the employee is bound to the
-- Agenda's own auth identity, never a parallel credential.
create unique index employees_active_admin_user_key on workforce.employees(admin_user_id) where active;
create index employees_employer_idx on workforce.employees(tenant_id, employer_id);

create table workforce.employment_schedules (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  employee_id uuid not null,
  effective_from date not null,
  effective_to date,
  validity daterange generated always as (daterange(effective_from, effective_to, '[)')) stored,
  reason text,
  created_by_admin_id uuid references public.admin_users(id) on delete set null,
  created_at timestamptz not null default now(),
  constraint employment_schedules_tenant_id_key unique (tenant_id, id),
  constraint employment_schedules_employee_fkey foreign key (tenant_id, employee_id)
    references workforce.employees(tenant_id, id) on delete restrict,
  constraint employment_schedules_range_valid check (effective_to is null or effective_to > effective_from),
  constraint employment_schedules_reason_valid check (reason is null or length(reason) <= 500),
  constraint employment_schedules_no_overlap exclude using gist (employee_id with =, validity with &&)
);
comment on table workforce.employment_schedules is
  'Versioned habitual schedule. [effective_from, effective_to) in the employer local calendar; versions never overlap.';

create table workforce.employment_schedule_days (
  schedule_id uuid not null,
  tenant_id uuid not null,
  iso_weekday smallint not null,
  block_index smallint not null default 1,
  start_time time not null,
  end_time time not null,
  primary key (schedule_id, iso_weekday, block_index),
  constraint employment_schedule_days_schedule_fkey foreign key (tenant_id, schedule_id)
    references workforce.employment_schedules(tenant_id, id) on delete restrict,
  constraint employment_schedule_days_weekday_valid check (iso_weekday between 1 and 7),
  constraint employment_schedule_days_block_valid check (block_index between 1 and 4),
  constraint employment_schedule_days_time_valid check (end_time > start_time)
);

create table workforce.holidays (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid references public.tenants(id) on delete restrict,
  employer_id uuid,
  scope text not null,
  name text not null,
  rule_kind text not null,
  holiday_date date,
  month smallint,
  day smallint,
  easter_offset_days smallint,
  valid_from_year smallint not null default 1900,
  valid_to_year smallint,
  source text not null,
  legal_reference text,
  active boolean not null default true,
  created_by_admin_id uuid references public.admin_users(id) on delete set null,
  created_at timestamptz not null default now(),
  deactivated_at timestamptz,
  deactivated_by_admin_id uuid references public.admin_users(id) on delete set null,
  constraint holidays_employer_fkey foreign key (tenant_id, employer_id)
    references workforce.employers(tenant_id, id) on delete restrict,
  constraint holidays_scope_valid check (scope in ('NATIONAL', 'STATE', 'MUNICIPAL')),
  constraint holidays_rule_kind_valid check (rule_kind in ('DATE', 'FIXED_DATE', 'EASTER_OFFSET')),
  constraint holidays_source_valid check (source in ('FEDERAL_LAW_SEED', 'OWNER')),
  constraint holidays_owner_scope check (
    (source = 'FEDERAL_LAW_SEED' and scope = 'NATIONAL' and tenant_id is null and employer_id is null)
    or (source = 'OWNER' and tenant_id is not null and employer_id is not null)
  ),
  constraint holidays_rule_fields check (
    (rule_kind = 'DATE' and holiday_date is not null and month is null and day is null and easter_offset_days is null)
    or (rule_kind = 'FIXED_DATE' and holiday_date is null and easter_offset_days is null
        and month between 1 and 12 and day between 1 and 31
        and day <= extract(day from (make_date(2000, month, 1) + interval '1 month - 1 day'))::int)
    or (rule_kind = 'EASTER_OFFSET' and holiday_date is null and month is null and day is null
        and easter_offset_days between -100 and 100)
  ),
  constraint holidays_years_valid check (
    valid_from_year between 1900 and 9999
    and (valid_to_year is null or valid_to_year >= valid_from_year)
  ),
  constraint holidays_name_valid check (length(btrim(name)) between 2 and 120),
  constraint holidays_legal_reference_valid check (legal_reference is null or length(legal_reference) <= 200),
  constraint holidays_deactivation_consistent check ((active and deactivated_at is null) or (not active and deactivated_at is not null))
);
create index holidays_employer_idx on workforce.holidays(employer_id) where active;
comment on table workforce.holidays is
  'National holidays from federal law (seed, rule-based, no per-year hardcoding) plus owner-confirmed state/municipal holidays of the employer establishment.';

create table workforce.audit_log (
  id bigint generated always as identity primary key,
  tenant_id uuid not null references public.tenants(id) on delete restrict,
  actor_admin_id uuid references public.admin_users(id) on delete set null,
  actor_kind text not null,
  command text not null,
  entity_type text not null,
  entity_id uuid,
  before_state jsonb,
  after_state jsonb,
  created_at timestamptz not null default now(),
  constraint audit_log_actor_kind_valid check (actor_kind in ('OWNER', 'EMPLOYEE', 'SYSTEM'))
);
create index audit_log_tenant_created_idx on workforce.audit_log(tenant_id, created_at desc);
create index audit_log_entity_idx on workforce.audit_log(entity_type, entity_id);
comment on table workforce.audit_log is
  'Append-only workforce audit trail. Free-text notes and sensitive reasons are never copied here.';

create table workforce.command_receipts (
  actor_admin_id uuid not null references public.admin_users(id) on delete cascade,
  command text not null,
  idempotency_key uuid not null,
  tenant_id uuid not null references public.tenants(id) on delete restrict,
  request_hash text not null,
  response jsonb not null,
  created_at timestamptz not null default now(),
  primary key (actor_admin_id, command, idempotency_key)
);

alter table workforce.employers enable row level security;
alter table workforce.employers force row level security;
alter table workforce.payroll_settings enable row level security;
alter table workforce.payroll_settings force row level security;
alter table workforce.employees enable row level security;
alter table workforce.employees force row level security;
alter table workforce.employment_schedules enable row level security;
alter table workforce.employment_schedules force row level security;
alter table workforce.employment_schedule_days enable row level security;
alter table workforce.employment_schedule_days force row level security;
alter table workforce.holidays enable row level security;
alter table workforce.holidays force row level security;
alter table workforce.audit_log enable row level security;
alter table workforce.audit_log force row level security;
alter table workforce.command_receipts enable row level security;
alter table workforce.command_receipts force row level security;

-- On Supabase both postgres and service_role carry BYPASSRLS, so the security
-- boundary is the absence of grants, not policies. RLS is enabled and forced as
-- defense in depth; the owner-only policy keeps the governed RPCs (which run as
-- postgres) working on any setup where postgres does not bypass RLS.
do $$
declare
  v_table text;
begin
  foreach v_table in array array[
    'employers', 'payroll_settings', 'employees', 'employment_schedules',
    'employment_schedule_days', 'holidays', 'audit_log', 'command_receipts'
  ] loop
    execute format(
      'create policy %I on workforce.%I as permissive for all to postgres using (true) with check (true)',
      v_table || '_owner_only', v_table
    );
  end loop;
end
$$;

-- ---------------------------------------------------------------------------
-- Integrity triggers
-- ---------------------------------------------------------------------------

create function workforce.touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger employers_touch before update on workforce.employers
  for each row execute function workforce.touch_updated_at();
create trigger payroll_settings_touch before update on workforce.payroll_settings
  for each row execute function workforce.touch_updated_at();
create trigger employees_touch before update on workforce.employees
  for each row execute function workforce.touch_updated_at();

create function workforce.reject_mutation()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'WORKFORCE_IMMUTABLE:%', tg_table_name using errcode = 'P0001';
end;
$$;

create trigger audit_log_append_only before update or delete on workforce.audit_log
  for each row execute function workforce.reject_mutation();
create trigger command_receipts_append_only before update on workforce.command_receipts
  for each row execute function workforce.reject_mutation();
create trigger schedule_days_immutable before update or delete on workforce.employment_schedule_days
  for each row execute function workforce.reject_mutation();
create trigger audit_log_no_truncate before truncate on workforce.audit_log
  for each statement execute function workforce.reject_mutation();

-- A schedule version is immutable except for closing it once (effective_to null -> date).
create function workforce.guard_schedule_version()
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
     or new.effective_from is distinct from old.effective_from
     or new.reason is distinct from old.reason
     or new.created_by_admin_id is distinct from old.created_by_admin_id
     or new.created_at is distinct from old.created_at
     or old.effective_to is not null
     or new.effective_to is null then
    raise exception 'WORKFORCE_IMMUTABLE:%', tg_table_name using errcode = 'P0001';
  end if;
  return new;
end;
$$;

create trigger employment_schedules_guard before update or delete on workforce.employment_schedules
  for each row execute function workforce.guard_schedule_version();

-- Holiday rules are immutable; they can only be deactivated once.
create function workforce.guard_holiday()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'WORKFORCE_IMMUTABLE:%', tg_table_name using errcode = 'P0001';
  end if;
  if (to_jsonb(new) - array['active', 'deactivated_at', 'deactivated_by_admin_id'])
       is distinct from (to_jsonb(old) - array['active', 'deactivated_at', 'deactivated_by_admin_id'])
     or not old.active
     or new.active then
    raise exception 'WORKFORCE_IMMUTABLE:%', tg_table_name using errcode = 'P0001';
  end if;
  return new;
end;
$$;

create trigger holidays_guard before update or delete on workforce.holidays
  for each row execute function workforce.guard_holiday();

-- Employer and admin binding of an employee never change; a new employment is a new row.
create function workforce.guard_employee()
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
     or new.admin_user_id is distinct from old.admin_user_id
     or new.created_at is distinct from old.created_at
     or new.created_by_admin_id is distinct from old.created_by_admin_id then
    raise exception 'WORKFORCE_IMMUTABLE:%', tg_table_name using errcode = 'P0001';
  end if;
  return new;
end;
$$;

create trigger employees_guard before update or delete on workforce.employees
  for each row execute function workforce.guard_employee();

create function workforce.guard_employer()
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
     or new.created_at is distinct from old.created_at
     or new.created_by_admin_id is distinct from old.created_by_admin_id then
    raise exception 'WORKFORCE_IMMUTABLE:%', tg_table_name using errcode = 'P0001';
  end if;
  return new;
end;
$$;

create trigger employers_guard before update or delete on workforce.employers
  for each row execute function workforce.guard_employer();

-- ---------------------------------------------------------------------------
-- Calendar
-- ---------------------------------------------------------------------------

create function workforce.holidays_on(p_employer_id uuid, p_date date)
returns table (name text, scope text, source text)
language sql
stable
set search_path = ''
as $$
  select h.name, h.scope, h.source
  from workforce.holidays h
  where h.active
    and (h.employer_id is null or h.employer_id = p_employer_id)
    and extract(year from p_date)::int between h.valid_from_year and coalesce(h.valid_to_year, 9999)
    and (
      (h.rule_kind = 'DATE' and h.holiday_date = p_date)
      or (h.rule_kind = 'FIXED_DATE'
          and h.month = extract(month from p_date)::int
          and h.day = extract(day from p_date)::int)
      or (h.rule_kind = 'EASTER_OFFSET'
          and p_date = workforce.easter_sunday(extract(year from p_date)::int) + h.easter_offset_days)
    )
  order by case h.scope when 'NATIONAL' then 1 when 'STATE' then 2 else 3 end, h.name;
$$;

create function workforce.is_holiday(p_employer_id uuid, p_date date)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (select 1 from workforce.holidays_on(p_employer_id, p_date));
$$;

create function workforce.holiday_calendar(p_employer_id uuid, p_year int)
returns table (holiday_date date, name text, scope text, source text)
language sql
stable
set search_path = ''
as $$
  select d::date, h.name, h.scope, h.source
  from generate_series(make_date(p_year, 1, 1), make_date(p_year, 12, 31), interval '1 day') d
  cross join lateral workforce.holidays_on(p_employer_id, d::date) h
  order by 1, 2;
$$;

-- ---------------------------------------------------------------------------
-- Actor resolution, idempotency and audit
-- ---------------------------------------------------------------------------

-- Owner actions require role OWNER and an ACTIVE OWNER membership in exactly
-- one ACTIVE tenant. ADMIN/OPERATION/FINANCE never inherit workforce owner rights.
create function workforce.require_owner(p_actor_admin_id uuid)
returns uuid
language plpgsql
stable
set search_path = ''
as $$
declare
  v_auth_user_id uuid;
  v_tenant_ids uuid[];
begin
  select au.auth_user_id into v_auth_user_id
  from public.admin_users au
  where au.id = p_actor_admin_id
    and au.is_active
    and au.role = 'OWNER';
  if v_auth_user_id is null then
    raise exception 'WORKFORCE_OWNER_REQUIRED' using errcode = 'P0001';
  end if;

  select array_agg(tm.tenant_id order by tm.tenant_id) into v_tenant_ids
  from public.tenant_members tm
  join public.tenants t on t.id = tm.tenant_id
  where tm.user_id = v_auth_user_id
    and tm.role = 'OWNER'
    and tm.status = 'ACTIVE'
    and t.status = 'ACTIVE';

  if coalesce(cardinality(v_tenant_ids), 0) = 0 then
    raise exception 'WORKFORCE_OWNER_REQUIRED' using errcode = 'P0001';
  end if;
  if cardinality(v_tenant_ids) > 1 then
    raise exception 'WORKFORCE_TENANT_AMBIGUOUS' using errcode = 'P0001';
  end if;
  return v_tenant_ids[1];
end;
$$;

-- The employee is derived exclusively from the authenticated login binding.
create function workforce.require_employee(p_actor_admin_id uuid)
returns workforce.employees
language plpgsql
stable
set search_path = ''
as $$
declare
  v_employee workforce.employees;
begin
  select e.* into v_employee
  from workforce.employees e
  join public.admin_users au on au.id = e.admin_user_id
  join workforce.employers er on er.tenant_id = e.tenant_id and er.id = e.employer_id
  join public.tenants t on t.id = e.tenant_id
  where e.admin_user_id = p_actor_admin_id
    and e.active
    and au.is_active
    and er.active
    and t.status = 'ACTIVE';
  if v_employee.id is null then
    raise exception 'WORKFORCE_EMPLOYEE_REQUIRED' using errcode = 'P0001';
  end if;
  return v_employee;
end;
$$;

create function workforce.begin_command(p_actor_admin_id uuid, p_command text, p_idempotency_key uuid, p_payload jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_receipt workforce.command_receipts;
begin
  if p_idempotency_key is null then
    raise exception 'WORKFORCE_IDEMPOTENCY_KEY_REQUIRED' using errcode = 'P0001';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_actor_admin_id::text || ':' || p_command || ':' || p_idempotency_key::text, 0));
  select * into v_receipt
  from workforce.command_receipts r
  where r.actor_admin_id = p_actor_admin_id
    and r.command = p_command
    and r.idempotency_key = p_idempotency_key;
  if v_receipt.actor_admin_id is null then
    return null;
  end if;
  if v_receipt.request_hash <> md5(coalesce(p_payload, 'null'::jsonb)::text) then
    raise exception 'WORKFORCE_IDEMPOTENCY_KEY_REUSED' using errcode = 'P0001';
  end if;
  return v_receipt.response || jsonb_build_object('replayed', true);
end;
$$;

create function workforce.finish_command(
  p_actor_admin_id uuid,
  p_command text,
  p_idempotency_key uuid,
  p_payload jsonb,
  p_tenant_id uuid,
  p_response jsonb
)
returns jsonb
language plpgsql
set search_path = ''
as $$
begin
  insert into workforce.command_receipts(actor_admin_id, command, idempotency_key, tenant_id, request_hash, response)
  values (p_actor_admin_id, p_command, p_idempotency_key, p_tenant_id, md5(coalesce(p_payload, 'null'::jsonb)::text), p_response);
  return p_response || jsonb_build_object('replayed', false);
end;
$$;

create function workforce.audit(
  p_tenant_id uuid,
  p_actor_admin_id uuid,
  p_actor_kind text,
  p_command text,
  p_entity_type text,
  p_entity_id uuid,
  p_before jsonb,
  p_after jsonb
)
returns void
language sql
set search_path = ''
as $$
  insert into workforce.audit_log(tenant_id, actor_admin_id, actor_kind, command, entity_type, entity_id, before_state, after_state)
  values (p_tenant_id, p_actor_admin_id, p_actor_kind, p_command, p_entity_type, p_entity_id, p_before, p_after);
$$;

-- ---------------------------------------------------------------------------
-- Read models
-- ---------------------------------------------------------------------------

create function workforce.schedule_json(p_schedule_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'schedule_id', s.id,
    'effective_from', s.effective_from,
    'effective_to', s.effective_to,
    'days', coalesce((
      select jsonb_agg(jsonb_build_object(
        'iso_weekday', d.iso_weekday,
        'block_index', d.block_index,
        'start_time', to_char(d.start_time, 'HH24:MI'),
        'end_time', to_char(d.end_time, 'HH24:MI')
      ) order by d.iso_weekday, d.block_index)
      from workforce.employment_schedule_days d
      where d.schedule_id = s.id
    ), '[]'::jsonb)
  )
  from workforce.employment_schedules s
  where s.id = p_schedule_id;
$$;

create function workforce.current_schedule_id(p_employee_id uuid, p_on date)
returns uuid
language sql
stable
set search_path = ''
as $$
  select s.id
  from workforce.employment_schedules s
  where s.employee_id = p_employee_id
    and s.validity @> p_on;
$$;

create function workforce.employer_json(p_employer_id uuid)
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

create function workforce.employee_json(p_employee_id uuid, p_on date)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'employee_id', e.id,
    'employer_id', e.employer_id,
    'admin_user_id', e.admin_user_id,
    'display_name', e.display_name,
    'active', e.active,
    'hired_on', e.hired_on,
    'terminated_on', e.terminated_on,
    'current_schedule', workforce.schedule_json(workforce.current_schedule_id(e.id, p_on)),
    'schedule_versions', coalesce((
      select jsonb_agg(workforce.schedule_json(s.id) order by s.effective_from desc)
      from workforce.employment_schedules s
      where s.employee_id = e.id
    ), '[]'::jsonb)
  )
  from workforce.employees e
  where e.id = p_employee_id;
$$;

create function workforce.local_today(p_employer_id uuid)
returns date
language sql
stable
set search_path = ''
as $$
  select (now() at time zone e.timezone)::date
  from workforce.employers e
  where e.id = p_employer_id;
$$;

-- ---------------------------------------------------------------------------
-- Governed RPCs — owner
-- ---------------------------------------------------------------------------

create function public.service_workforce_owner_get_setup(p_actor_admin_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := workforce.require_owner(p_actor_admin_id);
begin
  return jsonb_build_object(
    'employers', coalesce((
      select jsonb_agg(
        workforce.employer_json(er.id) || jsonb_build_object(
          'employees', coalesce((
            select jsonb_agg(workforce.employee_json(e.id, workforce.local_today(er.id)) order by e.display_name)
            from workforce.employees e
            where e.tenant_id = v_tenant_id and e.employer_id = er.id
          ), '[]'::jsonb),
          'holidays', coalesce((
            select jsonb_agg(jsonb_build_object(
              'holiday_id', h.id,
              'scope', h.scope,
              'name', h.name,
              'rule_kind', h.rule_kind,
              'holiday_date', h.holiday_date,
              'month', h.month,
              'day', h.day,
              'easter_offset_days', h.easter_offset_days,
              'valid_from_year', h.valid_from_year,
              'valid_to_year', h.valid_to_year,
              'source', h.source,
              'legal_reference', h.legal_reference,
              'editable', h.source = 'OWNER'
            ) order by h.source, h.scope, h.name)
            from workforce.holidays h
            where h.active and (h.employer_id is null or h.employer_id = er.id)
          ), '[]'::jsonb)
        )
        order by er.legal_name
      )
      from workforce.employers er
      where er.tenant_id = v_tenant_id
    ), '[]'::jsonb),
    'employee_candidates', coalesce((
      select jsonb_agg(jsonb_build_object(
        'admin_user_id', au.id,
        'display_name', au.display_name,
        'role', au.role
      ) order by au.display_name)
      from public.admin_users au
      where au.is_active
        and au.role <> 'OWNER'
        and not exists (select 1 from workforce.employees e where e.admin_user_id = au.id and e.active)
        and workforce.admin_user_belongs_to_tenant(au.id, v_tenant_id)
    ), '[]'::jsonb)
  );
end;
$$;

-- admin_users is not tenant-scoped yet (PR-06/07). Until then a login is
-- eligible for a tenant unless it is a member of other tenants only.
create function workforce.admin_user_belongs_to_tenant(p_admin_user_id uuid, p_tenant_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (
    select 1
    from public.admin_users au
    where au.id = p_admin_user_id
      and (
        exists (
          select 1 from public.tenant_members tm
          where tm.user_id = au.auth_user_id and tm.tenant_id = p_tenant_id and tm.status = 'ACTIVE'
        )
        or not exists (
          select 1 from public.tenant_members tm
          where tm.user_id = au.auth_user_id and tm.tenant_id <> p_tenant_id
        )
      )
  );
$$;

create function public.service_workforce_owner_save_employer(
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
  c_command constant text := 'OWNER_SAVE_EMPLOYER';
  v_tenant_id uuid := workforce.require_owner(p_actor_admin_id);
  v_replay jsonb;
  v_employer_id uuid;
  v_before workforce.employers;
  v_after workforce.employers;
  v_cnpj text;
  v_state text;
  v_timezone text;
begin
  v_replay := workforce.begin_command(p_actor_admin_id, c_command, p_idempotency_key, p_payload);
  if v_replay is not null then
    return v_replay;
  end if;

  perform workforce.assert_payload(p_payload, array[
    'employer_id', 'legal_name', 'trade_name', 'cnpj', 'workplace_city',
    'workplace_state', 'workplace_city_ibge_code', 'timezone', 'active'
  ]);
  v_employer_id := workforce.payload_uuid(p_payload, 'employer_id');
  v_cnpj := nullif(upper(regexp_replace(coalesce(workforce.payload_text(p_payload, 'cnpj', 32), ''), '[[:space:]./-]', '', 'g')), '');
  if v_cnpj is not null and not workforce.cnpj_is_valid(v_cnpj) then
    raise exception 'WORKFORCE_CNPJ_INVALID' using errcode = 'P0001';
  end if;
  v_state := upper(workforce.payload_text(p_payload, 'workplace_state', 2));
  v_timezone := workforce.payload_text(p_payload, 'timezone', 64);
  if v_timezone is not null and not exists (select 1 from pg_catalog.pg_timezone_names z where z.name = v_timezone) then
    raise exception 'WORKFORCE_TIMEZONE_INVALID' using errcode = 'P0001';
  end if;

  if v_employer_id is null then
    perform workforce.assert_payload(p_payload, array[
      'legal_name', 'trade_name', 'cnpj', 'workplace_city', 'workplace_state',
      'workplace_city_ibge_code', 'timezone', 'active'
    ], array['legal_name', 'workplace_city', 'workplace_state']);
    insert into workforce.employers(
      tenant_id, legal_name, trade_name, cnpj, workplace_city, workplace_state,
      workplace_city_ibge_code, timezone, active, created_by_admin_id
    ) values (
      v_tenant_id,
      workforce.payload_text(p_payload, 'legal_name', 200),
      workforce.payload_text(p_payload, 'trade_name', 200),
      v_cnpj,
      workforce.payload_text(p_payload, 'workplace_city', 120),
      v_state,
      workforce.payload_text(p_payload, 'workplace_city_ibge_code', 7),
      coalesce(v_timezone, 'America/Sao_Paulo'),
      coalesce(workforce.payload_bool(p_payload, 'active'), true),
      p_actor_admin_id
    )
    returning * into v_after;
    insert into workforce.payroll_settings(employer_id, tenant_id, updated_by_admin_id)
    values (v_after.id, v_tenant_id, p_actor_admin_id);
  else
    select * into v_before
    from workforce.employers e
    where e.id = v_employer_id and e.tenant_id = v_tenant_id
    for update;
    if v_before.id is null then
      raise exception 'WORKFORCE_EMPLOYER_NOT_FOUND' using errcode = 'P0001';
    end if;
    if (p_payload ? 'legal_name' and workforce.payload_text(p_payload, 'legal_name', 200) is null)
       or (p_payload ? 'workplace_city' and workforce.payload_text(p_payload, 'workplace_city', 120) is null)
       or (p_payload ? 'workplace_state' and v_state is null)
       or (p_payload ? 'timezone' and v_timezone is null)
       or (p_payload ? 'active' and workforce.payload_bool(p_payload, 'active') is null) then
      raise exception 'WORKFORCE_FIELD_REQUIRED' using errcode = 'P0001';
    end if;
    update workforce.employers e set
      legal_name = case when p_payload ? 'legal_name' then workforce.payload_text(p_payload, 'legal_name', 200) else e.legal_name end,
      trade_name = case when p_payload ? 'trade_name' then workforce.payload_text(p_payload, 'trade_name', 200) else e.trade_name end,
      cnpj = case when p_payload ? 'cnpj' then v_cnpj else e.cnpj end,
      workplace_city = case when p_payload ? 'workplace_city' then workforce.payload_text(p_payload, 'workplace_city', 120) else e.workplace_city end,
      workplace_state = case when p_payload ? 'workplace_state' then v_state else e.workplace_state end,
      workplace_city_ibge_code = case when p_payload ? 'workplace_city_ibge_code' then workforce.payload_text(p_payload, 'workplace_city_ibge_code', 7) else e.workplace_city_ibge_code end,
      timezone = case when p_payload ? 'timezone' then v_timezone else e.timezone end,
      active = case when p_payload ? 'active' then workforce.payload_bool(p_payload, 'active') else e.active end
    where e.id = v_before.id
    returning * into v_after;
  end if;

  perform workforce.audit(v_tenant_id, p_actor_admin_id, 'OWNER', c_command, 'employer', v_after.id,
    case when v_before.id is null then null else to_jsonb(v_before) end, to_jsonb(v_after));

  return workforce.finish_command(p_actor_admin_id, c_command, p_idempotency_key, p_payload, v_tenant_id,
    jsonb_build_object('employer', workforce.employer_json(v_after.id)));
exception
  when unique_violation then
    raise exception 'WORKFORCE_EMPLOYER_CNPJ_DUPLICATE' using errcode = 'P0001';
  when check_violation then
    raise exception 'WORKFORCE_EMPLOYER_INVALID' using errcode = 'P0001';
end;
$$;

create function public.service_workforce_owner_save_payroll_settings(
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
    'default_weekly_schedule'
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

create function public.service_workforce_owner_save_employee(
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
  c_command constant text := 'OWNER_SAVE_EMPLOYEE';
  v_tenant_id uuid := workforce.require_owner(p_actor_admin_id);
  v_replay jsonb;
  v_employee_id uuid;
  v_employer_id uuid;
  v_admin_user_id uuid;
  v_target public.admin_users;
  v_before workforce.employees;
  v_after workforce.employees;
begin
  v_replay := workforce.begin_command(p_actor_admin_id, c_command, p_idempotency_key, p_payload);
  if v_replay is not null then
    return v_replay;
  end if;

  perform workforce.assert_payload(p_payload, array[
    'employee_id', 'employer_id', 'admin_user_id', 'display_name', 'active', 'hired_on', 'terminated_on'
  ]);
  v_employee_id := workforce.payload_uuid(p_payload, 'employee_id');

  if v_employee_id is null then
    perform workforce.assert_payload(p_payload, array[
      'employer_id', 'admin_user_id', 'display_name', 'active', 'hired_on', 'terminated_on'
    ], array['employer_id', 'admin_user_id']);
    v_employer_id := workforce.payload_uuid(p_payload, 'employer_id');
    v_admin_user_id := workforce.payload_uuid(p_payload, 'admin_user_id');

    if not exists (
      select 1 from workforce.employers er
      where er.id = v_employer_id and er.tenant_id = v_tenant_id and er.active
    ) then
      raise exception 'WORKFORCE_EMPLOYER_NOT_FOUND' using errcode = 'P0001';
    end if;

    select au.* into v_target from public.admin_users au where au.id = v_admin_user_id;
    if v_target.id is null
       or not v_target.is_active
       or not workforce.admin_user_belongs_to_tenant(v_target.id, v_tenant_id) then
      raise exception 'WORKFORCE_LOGIN_NOT_FOUND' using errcode = 'P0001';
    end if;
    if v_target.role = 'OWNER' then
      raise exception 'WORKFORCE_OWNER_CANNOT_BE_EMPLOYEE' using errcode = 'P0001';
    end if;

    insert into workforce.employees(
      tenant_id, employer_id, admin_user_id, display_name, active, hired_on, terminated_on, created_by_admin_id
    ) values (
      v_tenant_id,
      v_employer_id,
      v_target.id,
      coalesce(workforce.payload_text(p_payload, 'display_name', 120), nullif(btrim(v_target.display_name), ''), 'Funcionário'),
      coalesce(workforce.payload_bool(p_payload, 'active'), true),
      workforce.payload_date(p_payload, 'hired_on'),
      workforce.payload_date(p_payload, 'terminated_on'),
      p_actor_admin_id
    )
    returning * into v_after;
  else
    -- employer_id and admin_user_id are immutable after binding.
    perform workforce.assert_payload(p_payload, array[
      'employee_id', 'display_name', 'active', 'hired_on', 'terminated_on'
    ]);
    select e.* into v_before
    from workforce.employees e
    where e.id = v_employee_id and e.tenant_id = v_tenant_id
    for update;
    if v_before.id is null then
      raise exception 'WORKFORCE_EMPLOYEE_NOT_FOUND' using errcode = 'P0001';
    end if;
    if (p_payload ? 'display_name' and workforce.payload_text(p_payload, 'display_name', 120) is null)
       or (p_payload ? 'active' and workforce.payload_bool(p_payload, 'active') is null) then
      raise exception 'WORKFORCE_FIELD_REQUIRED' using errcode = 'P0001';
    end if;
    update workforce.employees e set
      display_name = case when p_payload ? 'display_name' then workforce.payload_text(p_payload, 'display_name', 120) else e.display_name end,
      active = case when p_payload ? 'active' then workforce.payload_bool(p_payload, 'active') else e.active end,
      hired_on = case when p_payload ? 'hired_on' then workforce.payload_date(p_payload, 'hired_on') else e.hired_on end,
      terminated_on = case when p_payload ? 'terminated_on' then workforce.payload_date(p_payload, 'terminated_on') else e.terminated_on end
    where e.id = v_before.id
    returning * into v_after;
  end if;

  perform workforce.audit(v_tenant_id, p_actor_admin_id, 'OWNER', c_command, 'employee', v_after.id,
    case when v_before.id is null then null else to_jsonb(v_before) end, to_jsonb(v_after));

  return workforce.finish_command(p_actor_admin_id, c_command, p_idempotency_key, p_payload, v_tenant_id,
    jsonb_build_object('employee', workforce.employee_json(v_after.id, workforce.local_today(v_after.employer_id))));
exception
  when unique_violation then
    raise exception 'WORKFORCE_LOGIN_ALREADY_BOUND' using errcode = 'P0001';
  when check_violation then
    raise exception 'WORKFORCE_EMPLOYEE_INVALID' using errcode = 'P0001';
end;
$$;

-- New schedule version. The open version is closed at effective_from; versions
-- starting on/after the new one are not rewritten (WORKFORCE_SCHEDULE_VERSION_NOT_LATEST).
create function public.service_workforce_owner_create_schedule_version(
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
  c_command constant text := 'OWNER_CREATE_SCHEDULE_VERSION';
  v_tenant_id uuid := workforce.require_owner(p_actor_admin_id);
  v_replay jsonb;
  v_employee workforce.employees;
  v_effective_from date;
  v_days jsonb;
  v_previous workforce.employment_schedules;
  v_schedule workforce.employment_schedules;
begin
  v_replay := workforce.begin_command(p_actor_admin_id, c_command, p_idempotency_key, p_payload);
  if v_replay is not null then
    return v_replay;
  end if;

  perform workforce.assert_payload(p_payload, array['employee_id', 'effective_from', 'days', 'reason'],
    array['employee_id', 'effective_from', 'days']);
  v_effective_from := workforce.payload_date(p_payload, 'effective_from');
  v_days := workforce.normalize_weekly_schedule(p_payload -> 'days');

  select e.* into v_employee
  from workforce.employees e
  where e.id = workforce.payload_uuid(p_payload, 'employee_id') and e.tenant_id = v_tenant_id
  for update;
  if v_employee.id is null then
    raise exception 'WORKFORCE_EMPLOYEE_NOT_FOUND' using errcode = 'P0001';
  end if;

  if exists (
    select 1 from workforce.employment_schedules s
    where s.employee_id = v_employee.id and s.effective_from >= v_effective_from
  ) then
    raise exception 'WORKFORCE_SCHEDULE_VERSION_NOT_LATEST' using errcode = 'P0001';
  end if;

  select s.* into v_previous
  from workforce.employment_schedules s
  where s.employee_id = v_employee.id and s.effective_to is null;
  if v_previous.id is not null then
    update workforce.employment_schedules s
    set effective_to = v_effective_from
    where s.id = v_previous.id;
  end if;

  insert into workforce.employment_schedules(tenant_id, employee_id, effective_from, reason, created_by_admin_id)
  values (v_tenant_id, v_employee.id, v_effective_from, workforce.payload_text(p_payload, 'reason', 500), p_actor_admin_id)
  returning * into v_schedule;

  insert into workforce.employment_schedule_days(schedule_id, tenant_id, iso_weekday, block_index, start_time, end_time)
  select v_schedule.id, v_tenant_id,
         (d ->> 'iso_weekday')::smallint, (d ->> 'block_index')::smallint,
         (d ->> 'start_time')::time, (d ->> 'end_time')::time
  from jsonb_array_elements(v_days) d;

  perform workforce.audit(v_tenant_id, p_actor_admin_id, 'OWNER', c_command, 'employment_schedule', v_schedule.id,
    case when v_previous.id is null then null else workforce.schedule_json(v_previous.id) end,
    workforce.schedule_json(v_schedule.id));

  return workforce.finish_command(p_actor_admin_id, c_command, p_idempotency_key, p_payload, v_tenant_id,
    jsonb_build_object('employee', workforce.employee_json(v_employee.id, workforce.local_today(v_employee.employer_id))));
end;
$$;

create function public.service_workforce_owner_manage_holiday(
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
  c_command constant text := 'OWNER_MANAGE_HOLIDAY';
  v_tenant_id uuid := workforce.require_owner(p_actor_admin_id);
  v_replay jsonb;
  v_action text;
  v_employer_id uuid;
  v_before workforce.holidays;
  v_after workforce.holidays;
  v_rule_kind text;
  v_scope text;
begin
  v_replay := workforce.begin_command(p_actor_admin_id, c_command, p_idempotency_key, p_payload);
  if v_replay is not null then
    return v_replay;
  end if;

  perform workforce.assert_payload(p_payload, array[
    'action', 'holiday_id', 'employer_id', 'scope', 'name', 'rule_kind', 'holiday_date',
    'month', 'day', 'easter_offset_days', 'valid_from_year', 'valid_to_year', 'legal_reference'
  ], array['action']);
  v_action := upper(workforce.payload_text(p_payload, 'action', 16));

  if v_action = 'ADD' then
    perform workforce.assert_payload(p_payload, array[
      'action', 'employer_id', 'scope', 'name', 'rule_kind', 'holiday_date',
      'month', 'day', 'easter_offset_days', 'valid_from_year', 'valid_to_year', 'legal_reference'
    ], array['action', 'employer_id', 'scope', 'name', 'rule_kind']);
    v_employer_id := workforce.payload_uuid(p_payload, 'employer_id');
    if not exists (select 1 from workforce.employers er where er.id = v_employer_id and er.tenant_id = v_tenant_id) then
      raise exception 'WORKFORCE_EMPLOYER_NOT_FOUND' using errcode = 'P0001';
    end if;
    v_scope := upper(workforce.payload_text(p_payload, 'scope', 16));
    v_rule_kind := upper(workforce.payload_text(p_payload, 'rule_kind', 16));
    insert into workforce.holidays(
      tenant_id, employer_id, scope, name, rule_kind, holiday_date, month, day, easter_offset_days,
      valid_from_year, valid_to_year, source, legal_reference, created_by_admin_id
    ) values (
      v_tenant_id, v_employer_id, v_scope,
      workforce.payload_text(p_payload, 'name', 120),
      v_rule_kind,
      workforce.payload_date(p_payload, 'holiday_date'),
      workforce.payload_int(p_payload, 'month', 1, 12),
      workforce.payload_int(p_payload, 'day', 1, 31),
      workforce.payload_int(p_payload, 'easter_offset_days', -100, 100),
      coalesce(workforce.payload_int(p_payload, 'valid_from_year', 1900, 9999), 1900),
      workforce.payload_int(p_payload, 'valid_to_year', 1900, 9999),
      'OWNER',
      workforce.payload_text(p_payload, 'legal_reference', 200),
      p_actor_admin_id
    )
    returning * into v_after;
  elsif v_action = 'DEACTIVATE' then
    perform workforce.assert_payload(p_payload, array['action', 'holiday_id'], array['action', 'holiday_id']);
    select h.* into v_before
    from workforce.holidays h
    where h.id = workforce.payload_uuid(p_payload, 'holiday_id')
      and h.tenant_id = v_tenant_id
      and h.source = 'OWNER'
    for update;
    if v_before.id is null then
      raise exception 'WORKFORCE_HOLIDAY_NOT_FOUND' using errcode = 'P0001';
    end if;
    if not v_before.active then
      raise exception 'WORKFORCE_HOLIDAY_ALREADY_INACTIVE' using errcode = 'P0001';
    end if;
    update workforce.holidays h
    set active = false, deactivated_at = now(), deactivated_by_admin_id = p_actor_admin_id
    where h.id = v_before.id
    returning * into v_after;
  else
    raise exception 'WORKFORCE_FIELD_INVALID:action' using errcode = 'P0001';
  end if;

  perform workforce.audit(v_tenant_id, p_actor_admin_id, 'OWNER', c_command, 'holiday', v_after.id,
    case when v_before.id is null then null else to_jsonb(v_before) end, to_jsonb(v_after));

  return workforce.finish_command(p_actor_admin_id, c_command, p_idempotency_key, p_payload, v_tenant_id,
    jsonb_build_object('holiday_id', v_after.id, 'active', v_after.active));
exception
  when check_violation then
    raise exception 'WORKFORCE_HOLIDAY_INVALID' using errcode = 'P0001';
end;
$$;

-- ---------------------------------------------------------------------------
-- Governed RPCs — employee (read-only in S1)
-- ---------------------------------------------------------------------------

create function public.service_workforce_employee_get_profile(p_actor_admin_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_employee workforce.employees := workforce.require_employee(p_actor_admin_id);
  v_today date := workforce.local_today(v_employee.employer_id);
begin
  return jsonb_build_object(
    'employee', jsonb_build_object(
      'display_name', v_employee.display_name,
      'hired_on', v_employee.hired_on
    ),
    'employer', (
      select jsonb_build_object('legal_name', er.legal_name, 'trade_name', er.trade_name, 'timezone', er.timezone)
      from workforce.employers er
      where er.id = v_employee.employer_id
    ),
    'today', v_today,
    'current_schedule', workforce.schedule_json(workforce.current_schedule_id(v_employee.id, v_today))
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Seeds: national holidays (federal law, rule-based) and the BlackSheep employer
-- ---------------------------------------------------------------------------

insert into workforce.holidays(scope, name, rule_kind, month, day, valid_from_year, source, legal_reference)
values
  ('NATIONAL', 'Confraternização Universal', 'FIXED_DATE', 1, 1, 1949, 'FEDERAL_LAW_SEED', 'Lei 662/1949; Lei 10.607/2002'),
  ('NATIONAL', 'Tiradentes', 'FIXED_DATE', 4, 21, 1949, 'FEDERAL_LAW_SEED', 'Lei 662/1949; Lei 10.607/2002'),
  ('NATIONAL', 'Dia do Trabalho', 'FIXED_DATE', 5, 1, 1949, 'FEDERAL_LAW_SEED', 'Lei 662/1949; Lei 10.607/2002'),
  ('NATIONAL', 'Independência do Brasil', 'FIXED_DATE', 9, 7, 1949, 'FEDERAL_LAW_SEED', 'Lei 662/1949; Lei 10.607/2002'),
  ('NATIONAL', 'Nossa Senhora Aparecida', 'FIXED_DATE', 10, 12, 1980, 'FEDERAL_LAW_SEED', 'Lei 6.802/1980'),
  ('NATIONAL', 'Finados', 'FIXED_DATE', 11, 2, 1949, 'FEDERAL_LAW_SEED', 'Lei 662/1949; Lei 10.607/2002'),
  ('NATIONAL', 'Proclamação da República', 'FIXED_DATE', 11, 15, 1949, 'FEDERAL_LAW_SEED', 'Lei 662/1949; Lei 10.607/2002'),
  ('NATIONAL', 'Dia Nacional de Zumbi e da Consciência Negra', 'FIXED_DATE', 11, 20, 2024, 'FEDERAL_LAW_SEED', 'Lei 14.759/2023'),
  ('NATIONAL', 'Natal', 'FIXED_DATE', 12, 25, 1949, 'FEDERAL_LAW_SEED', 'Lei 662/1949; Lei 10.607/2002');

-- Initial configurable data for the BlackSheep tenant. CNPJ stays empty until the
-- owner fills in the real value; no user identity is hardcoded.
with tenant as (
  select t.id from public.tenants t where t.slug = 'blacksheep'
), employer as (
  insert into workforce.employers(tenant_id, legal_name, trade_name, workplace_city, workplace_state, timezone)
  select tenant.id, 'Pierri Quint Produções', 'BlackSheep Estúdio Criativo', 'Palhoça', 'SC', 'America/Sao_Paulo'
  from tenant
  where not exists (select 1 from workforce.employers er where er.tenant_id = tenant.id)
  returning id, tenant_id
)
insert into workforce.payroll_settings(employer_id, tenant_id, default_weekly_schedule)
select employer.id, employer.tenant_id, workforce.normalize_weekly_schedule(jsonb_build_array(
  jsonb_build_object('iso_weekday', 1, 'start_time', '13:15', 'end_time', '19:15'),
  jsonb_build_object('iso_weekday', 2, 'start_time', '13:15', 'end_time', '19:15'),
  jsonb_build_object('iso_weekday', 3, 'start_time', '13:15', 'end_time', '19:15'),
  jsonb_build_object('iso_weekday', 4, 'start_time', '13:15', 'end_time', '19:15'),
  jsonb_build_object('iso_weekday', 5, 'start_time', '13:15', 'end_time', '19:15')
))
from employer;

-- ---------------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------------

revoke all on all tables in schema workforce from public, anon, authenticated, service_role;
revoke all on all sequences in schema workforce from public, anon, authenticated, service_role;
revoke all on all functions in schema workforce from public, anon, authenticated, service_role;

do $$
declare
  v_identity text;
begin
  foreach v_identity in array array[
    'public.service_workforce_owner_get_setup(uuid)',
    'public.service_workforce_owner_save_employer(uuid,uuid,jsonb)',
    'public.service_workforce_owner_save_payroll_settings(uuid,uuid,jsonb)',
    'public.service_workforce_owner_save_employee(uuid,uuid,jsonb)',
    'public.service_workforce_owner_create_schedule_version(uuid,uuid,jsonb)',
    'public.service_workforce_owner_manage_holiday(uuid,uuid,jsonb)',
    'public.service_workforce_employee_get_profile(uuid)'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', v_identity);
    execute format('grant execute on function %s to service_role', v_identity);
  end loop;
end
$$;
