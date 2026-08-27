
-- BEGIN RC MIGRATION 20260826154500_notification_template_admin_foundation.sql
-- Issue #216 — V1 notification/template administration foundation.
-- This migration is expand-only and does not activate any provider or enqueue any notification.

create table if not exists public.notification_template_configs (
  id uuid primary key default gen_random_uuid(),
  event_key text not null check (event_key in (
    'APPOINTMENT_APPROVED',
    'APPOINTMENT_PENDING',
    'APPOINTMENT_REJECTED',
    'APPOINTMENT_CANCELLED',
    'APPOINTMENT_CHANGED',
    'APPOINTMENT_RESCHEDULED',
    'APPOINTMENT_REMINDER',
    'WAITLIST_AVAILABLE',
    'BIRTHDAY',
    'MANUAL'
  )),
  channel text not null check (channel in ('EMAIL', 'GOOGLE_CALENDAR')),
  audience text not null check (audience in ('CUSTOMER', 'EMPLOYEE')),
  operation_scope text null check (operation_scope is null or operation_scope in ('SABRINA', 'BLACKSHEEP')),
  category_id uuid null references public.categories(id) on delete set null,
  title_template text not null,
  body_template text not null default '',
  is_active boolean not null default false,
  variable_schema jsonb not null default '[]'::jsonb check (jsonb_typeof(variable_schema) = 'array'),
  reminder_offset_minutes integer null check (reminder_offset_minutes is null or reminder_offset_minutes >= 0),
  created_by_admin_id uuid null,
  updated_by_admin_id uuid null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.notification_template_services (
  template_id uuid not null references public.notification_template_configs(id) on delete cascade,
  service_id uuid not null references public.services(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (template_id, service_id)
);

create table if not exists public.notification_template_versions (
  id uuid primary key default gen_random_uuid(),
  template_id uuid not null references public.notification_template_configs(id) on delete cascade,
  version_number integer not null check (version_number > 0),
  snapshot jsonb not null check (jsonb_typeof(snapshot) = 'object'),
  changed_by_admin_id uuid null,
  created_at timestamptz not null default now(),
  unique (template_id, version_number)
);

create table if not exists public.notification_delivery_logs (
  id uuid primary key default gen_random_uuid(),
  template_id uuid null references public.notification_template_configs(id) on delete set null,
  event_key text not null,
  channel text not null check (channel in ('EMAIL', 'GOOGLE_CALENDAR')),
  audience text not null check (audience in ('CUSTOMER', 'EMPLOYEE')),
  appointment_id uuid null references public.appointments(id) on delete set null,
  customer_id uuid null references public.customers(id) on delete set null,
  employee_id uuid null references public.employees(id) on delete set null,
  recipient_hash text null,
  status text not null check (status in ('PENDING', 'SENT', 'FAILED', 'SKIPPED')),
  attempt_count integer not null default 0 check (attempt_count >= 0),
  last_error_code text null,
  provider_message_id text null,
  idempotency_key text not null,
  payload_snapshot jsonb not null default '{}'::jsonb check (jsonb_typeof(payload_snapshot) = 'object'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (idempotency_key)
);

create index if not exists idx_notification_template_configs_scope_event
  on public.notification_template_configs(operation_scope, event_key, channel, audience, is_active);
create index if not exists idx_notification_template_configs_category
  on public.notification_template_configs(category_id) where category_id is not null;
create index if not exists idx_notification_template_services_service
  on public.notification_template_services(service_id);
create index if not exists idx_notification_template_versions_template_created
  on public.notification_template_versions(template_id, version_number desc);
create index if not exists idx_notification_delivery_logs_appointment
  on public.notification_delivery_logs(appointment_id) where appointment_id is not null;
create index if not exists idx_notification_delivery_logs_status_created
  on public.notification_delivery_logs(status, created_at desc);

alter table public.notification_template_configs enable row level security;
alter table public.notification_template_services enable row level security;
alter table public.notification_template_versions enable row level security;
alter table public.notification_delivery_logs enable row level security;

revoke all on public.notification_template_configs from public, anon, authenticated;
revoke all on public.notification_template_services from public, anon, authenticated;
revoke all on public.notification_template_versions from public, anon, authenticated;
revoke all on public.notification_delivery_logs from public, anon, authenticated;
grant select, insert, update, delete on public.notification_template_configs to service_role;
grant select, insert, update, delete on public.notification_template_services to service_role;
grant select, insert on public.notification_template_versions to service_role;
grant select, insert, update on public.notification_delivery_logs to service_role;

create or replace function public.service_admin_list_notification_templates()
returns table (
  id uuid,
  event_key text,
  channel text,
  audience text,
  operation_scope text,
  category_id uuid,
  category_name text,
  title_template text,
  body_template text,
  is_active boolean,
  variable_schema jsonb,
  reminder_offset_minutes integer,
  service_ids uuid[],
  version_count bigint,
  updated_at timestamptz
)
language sql
security definer
set search_path = public, pg_temp
as $$
  select
    t.id,
    t.event_key,
    t.channel,
    t.audience,
    t.operation_scope,
    t.category_id,
    c.name as category_name,
    t.title_template,
    t.body_template,
    t.is_active,
    t.variable_schema,
    t.reminder_offset_minutes,
    coalesce(array_agg(distinct ts.service_id) filter (where ts.service_id is not null), '{}'::uuid[]) as service_ids,
    (select count(*) from public.notification_template_versions v where v.template_id = t.id) as version_count,
    t.updated_at
  from public.notification_template_configs t
  left join public.categories c on c.id = t.category_id
  left join public.notification_template_services ts on ts.template_id = t.id
  group by t.id, c.name
  order by t.event_key, t.channel, t.audience, t.updated_at desc;
$$;

create or replace function public.service_admin_upsert_notification_template(
  p_template_id uuid,
  p_event_key text,
  p_channel text,
  p_audience text,
  p_operation_scope text,
  p_category_id uuid,
  p_title_template text,
  p_body_template text,
  p_is_active boolean,
  p_variable_schema jsonb,
  p_reminder_offset_minutes integer,
  p_service_ids uuid[],
  p_actor_admin_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid;
  v_before jsonb;
  v_after jsonb;
  v_version integer;
begin
  if p_event_key not in (
    'APPOINTMENT_APPROVED','APPOINTMENT_PENDING','APPOINTMENT_REJECTED','APPOINTMENT_CANCELLED',
    'APPOINTMENT_CHANGED','APPOINTMENT_RESCHEDULED','APPOINTMENT_REMINDER','WAITLIST_AVAILABLE','BIRTHDAY','MANUAL'
  ) then raise exception 'NOTIFICATION_EVENT_INVALID'; end if;
  if p_channel not in ('EMAIL','GOOGLE_CALENDAR') then raise exception 'NOTIFICATION_CHANNEL_INVALID'; end if;
  if p_audience not in ('CUSTOMER','EMPLOYEE') then raise exception 'NOTIFICATION_AUDIENCE_INVALID'; end if;
  if p_operation_scope is not null and p_operation_scope not in ('SABRINA','BLACKSHEEP') then
    raise exception 'NOTIFICATION_OPERATION_SCOPE_INVALID';
  end if;
  if coalesce(btrim(p_title_template), '') = '' then raise exception 'NOTIFICATION_TITLE_REQUIRED'; end if;
  if p_variable_schema is null or jsonb_typeof(p_variable_schema) <> 'array' then raise exception 'NOTIFICATION_VARIABLE_SCHEMA_INVALID'; end if;
  if p_reminder_offset_minutes is not null and p_reminder_offset_minutes < 0 then raise exception 'NOTIFICATION_REMINDER_OFFSET_INVALID'; end if;

  if p_category_id is not null and not exists (select 1 from public.categories where id = p_category_id) then
    raise exception 'NOTIFICATION_CATEGORY_NOT_FOUND';
  end if;
  if exists (
    select 1 from unnest(coalesce(p_service_ids, '{}'::uuid[])) sid
    where not exists (select 1 from public.services s where s.id = sid)
  ) then raise exception 'NOTIFICATION_SERVICE_NOT_FOUND'; end if;

  if p_template_id is null then
    insert into public.notification_template_configs (
      event_key, channel, audience, operation_scope, category_id, title_template, body_template,
      is_active, variable_schema, reminder_offset_minutes, created_by_admin_id, updated_by_admin_id
    ) values (
      p_event_key, p_channel, p_audience, p_operation_scope, p_category_id, btrim(p_title_template), coalesce(p_body_template,''),
      coalesce(p_is_active,false), p_variable_schema, p_reminder_offset_minutes, p_actor_admin_id, p_actor_admin_id
    ) returning id into v_id;
  else
    select to_jsonb(t) into v_before from public.notification_template_configs t where t.id = p_template_id for update;
    if v_before is null then raise exception 'NOTIFICATION_TEMPLATE_NOT_FOUND'; end if;
    update public.notification_template_configs
      set event_key = p_event_key,
          channel = p_channel,
          audience = p_audience,
          operation_scope = p_operation_scope,
          category_id = p_category_id,
          title_template = btrim(p_title_template),
          body_template = coalesce(p_body_template,''),
          is_active = coalesce(p_is_active,false),
          variable_schema = p_variable_schema,
          reminder_offset_minutes = p_reminder_offset_minutes,
          updated_by_admin_id = p_actor_admin_id,
          updated_at = now()
      where id = p_template_id;
    v_id := p_template_id;
  end if;

  delete from public.notification_template_services where template_id = v_id;
  insert into public.notification_template_services(template_id, service_id)
    select v_id, sid from unnest(coalesce(p_service_ids, '{}'::uuid[])) sid
    on conflict do nothing;

  select to_jsonb(t) || jsonb_build_object(
    'service_ids', coalesce((select jsonb_agg(ts.service_id order by ts.service_id) from public.notification_template_services ts where ts.template_id = v_id), '[]'::jsonb)
  ) into v_after
  from public.notification_template_configs t where t.id = v_id;

  select coalesce(max(version_number),0) + 1 into v_version
  from public.notification_template_versions where template_id = v_id;

  insert into public.notification_template_versions(template_id, version_number, snapshot, changed_by_admin_id)
  values (v_id, v_version, v_after, p_actor_admin_id);

  insert into public.audit_logs(admin_user_id, entity_type, entity_id, action, before_json, after_json, origin)
  values (
    p_actor_admin_id,
    'NOTIFICATION_TEMPLATE',
    v_id,
    case when v_before is null then 'CREATE' else 'UPDATE' end,
    v_before,
    v_after,
    'ADMIN'
  );

  return v_id;
end;
$$;

create or replace function public.service_admin_notification_template_versions(p_template_id uuid)
returns table(version_number integer, snapshot jsonb, changed_by_admin_id uuid, created_at timestamptz)
language sql
security definer
set search_path = public, pg_temp
as $$
  select v.version_number, v.snapshot, v.changed_by_admin_id, v.created_at
  from public.notification_template_versions v
  where v.template_id = p_template_id
  order by v.version_number desc;
$$;

revoke all on function public.service_admin_list_notification_templates() from public, anon, authenticated;
revoke all on function public.service_admin_upsert_notification_template(uuid,text,text,text,text,uuid,text,text,boolean,jsonb,integer,uuid[],uuid) from public, anon, authenticated;
revoke all on function public.service_admin_notification_template_versions(uuid) from public, anon, authenticated;
grant execute on function public.service_admin_list_notification_templates() to service_role;
grant execute on function public.service_admin_upsert_notification_template(uuid,text,text,text,text,uuid,text,text,boolean,jsonb,integer,uuid[],uuid) to service_role;
grant execute on function public.service_admin_notification_template_versions(uuid) to service_role;

comment on table public.notification_template_configs is 'V1 configuration only. Creating a row does not activate any external provider or enqueue delivery.';
comment on table public.notification_delivery_logs is 'Append/update delivery evidence for notification runtime. No provider is activated by this migration.';
-- END RC MIGRATION 20260826154500_notification_template_admin_foundation.sql

-- BEGIN RC MIGRATION 20260826160000_birthday_automation_foundation.sql
-- Issue #217 — birthday automation foundation.
-- Expand-only. No scheduler, notification provider, coupon generation, or real-customer action is activated here.

alter table public.customers
  add column if not exists birth_date date null;

comment on column public.customers.birth_date is
  'Canonical customer birth date for birthday automation. Service custom fields must reconcile explicitly; never overwrite silently.';

create table if not exists public.birthday_automation_settings (
  id uuid primary key default gen_random_uuid(),
  operation_scope text not null check (operation_scope in ('SABRINA','BLACKSHEEP')),
  is_active boolean not null default false,
  send_message boolean not null default false,
  generate_coupon boolean not null default false,
  send_on_birthday boolean not null default true,
  days_before integer null check (days_before is null or days_before >= 0),
  coupon_prefix text null,
  coupon_discount_type text null check (coupon_discount_type is null or coupon_discount_type in ('PERCENT','FIXED')),
  coupon_discount_value numeric(12,2) null check (coupon_discount_value is null or coupon_discount_value >= 0),
  coupon_validity_days integer null check (coupon_validity_days is null or coupon_validity_days > 0),
  coupon_max_uses integer null check (coupon_max_uses is null or coupon_max_uses > 0),
  coupon_max_uses_per_customer integer null check (coupon_max_uses_per_customer is null or coupon_max_uses_per_customer > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (operation_scope),
  check (is_active = false or send_message or generate_coupon),
  check (
    generate_coupon = false
    or (
      coupon_prefix is not null
      and btrim(coupon_prefix) <> ''
      and coupon_discount_type is not null
      and coupon_discount_value is not null
      and coupon_validity_days is not null
    )
  )
);

create table if not exists public.birthday_automation_cycles (
  id uuid primary key default gen_random_uuid(),
  operation_scope text not null check (operation_scope in ('SABRINA','BLACKSHEEP')),
  customer_id uuid not null references public.customers(id) on delete cascade,
  birthday_year integer not null check (birthday_year between 2000 and 2200),
  trigger_kind text not null check (trigger_kind in ('BEFORE','BIRTHDAY')),
  target_date date not null,
  coupon_id uuid null references public.coupons(id) on delete set null,
  message_status text null check (message_status is null or message_status in ('PENDING','SENT','FAILED','SKIPPED')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (operation_scope, customer_id, birthday_year, trigger_kind)
);

create index if not exists idx_customers_birth_date
  on public.customers (extract(month from birth_date), extract(day from birth_date))
  where birth_date is not null;

create index if not exists idx_birthday_cycles_target_date
  on public.birthday_automation_cycles(target_date, operation_scope);

alter table public.birthday_automation_settings enable row level security;
alter table public.birthday_automation_cycles enable row level security;

revoke all on public.birthday_automation_settings from public, anon, authenticated;
revoke all on public.birthday_automation_cycles from public, anon, authenticated;
grant select, insert, update, delete on public.birthday_automation_settings to service_role;
grant select, insert, update on public.birthday_automation_cycles to service_role;

insert into public.birthday_automation_settings(operation_scope)
values ('SABRINA'), ('BLACKSHEEP')
on conflict (operation_scope) do nothing;

comment on table public.birthday_automation_settings is
  'Configuration foundation only. Rows are seeded disabled and no runtime reads them in this migration.';
comment on table public.birthday_automation_cycles is
  'Idempotency ledger for one birthday cycle per operation/customer/year/trigger kind. No scheduler is enabled by this migration.';
-- END RC MIGRATION 20260826160000_birthday_automation_foundation.sql

-- BEGIN RC MIGRATION 20260826173500_notification_runtime_resolution.sql
-- Issue #216 — controlled V1.5 notification runtime resolver.
-- Expand-only. This migration does not enable any provider or enqueue any delivery.
-- Runtime activation remains behind Edge environment gates.

create or replace function public.resolve_notification_template(
  p_event_key text,
  p_channel text,
  p_audience text,
  p_service_id uuid
)
returns table (
  id uuid,
  event_key text,
  channel text,
  audience text,
  operation_scope text,
  category_id uuid,
  title_template text,
  body_template text,
  variable_schema jsonb,
  reminder_offset_minutes integer,
  specificity integer
)
language sql
security definer
set search_path = public, pg_temp
as $$
  with service_context as (
    select s.id as service_id, s.category_id, s.operation_scope
    from public.services s
    where s.id = p_service_id
  ), candidates as (
    select
      t.id,
      t.event_key,
      t.channel,
      t.audience,
      t.operation_scope,
      t.category_id,
      t.title_template,
      t.body_template,
      t.variable_schema,
      t.reminder_offset_minutes,
      t.updated_at,
      case
        when exists (
          select 1 from public.notification_template_services nts
          where nts.template_id = t.id and nts.service_id = sc.service_id
        ) then 400
        when t.category_id is not null and t.category_id = sc.category_id then 300
        when t.operation_scope is not null and t.operation_scope = sc.operation_scope then 200
        else 100
      end as specificity
    from public.notification_template_configs t
    cross join service_context sc
    where t.is_active
      and t.event_key = p_event_key
      and t.channel = p_channel
      and t.audience = p_audience
      and (t.operation_scope is null or t.operation_scope = sc.operation_scope)
      and (t.category_id is null or t.category_id = sc.category_id)
      and (
        not exists (
          select 1 from public.notification_template_services assigned
          where assigned.template_id = t.id
        )
        or exists (
          select 1 from public.notification_template_services matched
          where matched.template_id = t.id and matched.service_id = sc.service_id
        )
      )
  )
  select
    c.id, c.event_key, c.channel, c.audience, c.operation_scope, c.category_id,
    c.title_template, c.body_template, c.variable_schema, c.reminder_offset_minutes,
    c.specificity
  from candidates c
  order by c.specificity desc, c.updated_at desc, c.id
  limit 1;
$$;

revoke all on function public.resolve_notification_template(text,text,text,uuid) from public, anon, authenticated;
grant execute on function public.resolve_notification_template(text,text,text,uuid) to service_role;

comment on function public.resolve_notification_template(text,text,text,uuid) is
  'Deterministic active-template resolution: service > category > operation > global. Service-scoped templates never leak to other services. Provider activation is external to this function.';
-- END RC MIGRATION 20260826173500_notification_runtime_resolution.sql

-- BEGIN RC MIGRATION 20260826190000_birthday_automation_admin_settings.sql
-- Issue #217 — administrative management for birthday automation settings.
-- This remains configuration-only: no scheduler, coupon generation, notification enqueue or provider call is introduced.

create or replace function public.service_admin_list_birthday_automation_settings()
returns table (
  id uuid,
  operation_scope text,
  is_active boolean,
  send_message boolean,
  generate_coupon boolean,
  send_on_birthday boolean,
  days_before integer,
  coupon_prefix text,
  coupon_discount_type text,
  coupon_discount_value numeric,
  coupon_validity_days integer,
  coupon_max_uses integer,
  coupon_max_uses_per_customer integer,
  updated_at timestamptz
)
language sql
security definer
set search_path = public, pg_temp
as $$
  select
    s.id,
    s.operation_scope,
    s.is_active,
    s.send_message,
    s.generate_coupon,
    s.send_on_birthday,
    s.days_before,
    s.coupon_prefix,
    s.coupon_discount_type,
    s.coupon_discount_value,
    s.coupon_validity_days,
    s.coupon_max_uses,
    s.coupon_max_uses_per_customer,
    s.updated_at
  from public.birthday_automation_settings s
  order by s.operation_scope;
$$;

create or replace function public.service_admin_update_birthday_automation_settings(
  p_operation_scope text,
  p_is_active boolean,
  p_send_message boolean,
  p_generate_coupon boolean,
  p_send_on_birthday boolean,
  p_days_before integer,
  p_coupon_prefix text,
  p_coupon_discount_type text,
  p_coupon_discount_value numeric,
  p_coupon_validity_days integer,
  p_coupon_max_uses integer,
  p_coupon_max_uses_per_customer integer,
  p_actor_admin_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row public.birthday_automation_settings%rowtype;
  v_before jsonb;
  v_after jsonb;
  v_financial_change boolean;
begin
  if p_operation_scope not in ('SABRINA','BLACKSHEEP') then
    raise exception 'BIRTHDAY_OPERATION_SCOPE_INVALID';
  end if;
  if p_actor_admin_id is null then
    raise exception 'ADMIN_ACTOR_REQUIRED';
  end if;
  if not public.service_admin_has_permission(p_actor_admin_id, 'SERVICES_MANAGE') then
    raise exception 'ADMIN_PERMISSION_DENIED';
  end if;

  select * into v_row
  from public.birthday_automation_settings
  where operation_scope = p_operation_scope
  for update;
  if not found then raise exception 'BIRTHDAY_SETTINGS_NOT_FOUND'; end if;

  v_before := to_jsonb(v_row);
  v_financial_change :=
       v_row.generate_coupon is distinct from coalesce(p_generate_coupon, false)
    or v_row.coupon_prefix is distinct from nullif(btrim(p_coupon_prefix), '')
    or v_row.coupon_discount_type is distinct from nullif(upper(btrim(p_coupon_discount_type)), '')
    or v_row.coupon_discount_value is distinct from p_coupon_discount_value
    or v_row.coupon_validity_days is distinct from p_coupon_validity_days
    or v_row.coupon_max_uses is distinct from p_coupon_max_uses
    or v_row.coupon_max_uses_per_customer is distinct from p_coupon_max_uses_per_customer;

  if v_financial_change and not public.service_admin_has_permission(p_actor_admin_id, 'FINANCE_MANAGE') then
    raise exception 'ADMIN_FINANCE_PERMISSION_REQUIRED';
  end if;

  update public.birthday_automation_settings
  set is_active = coalesce(p_is_active, false),
      send_message = coalesce(p_send_message, false),
      generate_coupon = coalesce(p_generate_coupon, false),
      send_on_birthday = coalesce(p_send_on_birthday, false),
      days_before = p_days_before,
      coupon_prefix = nullif(btrim(p_coupon_prefix), ''),
      coupon_discount_type = nullif(upper(btrim(p_coupon_discount_type)), ''),
      coupon_discount_value = p_coupon_discount_value,
      coupon_validity_days = p_coupon_validity_days,
      coupon_max_uses = p_coupon_max_uses,
      coupon_max_uses_per_customer = p_coupon_max_uses_per_customer,
      updated_at = now()
  where operation_scope = p_operation_scope
  returning to_jsonb(birthday_automation_settings.*) into v_after;

  insert into public.audit_logs(admin_user_id, entity_type, entity_id, action, before_json, after_json, origin)
  values (
    p_actor_admin_id,
    'BIRTHDAY_AUTOMATION_SETTINGS',
    v_row.id,
    'UPDATE',
    v_before,
    v_after,
    'ADMIN'
  );

  return v_row.id;
end;
$$;

revoke all on function public.service_admin_list_birthday_automation_settings() from public, anon, authenticated;
revoke all on function public.service_admin_update_birthday_automation_settings(text,boolean,boolean,boolean,boolean,integer,text,text,numeric,integer,integer,integer,uuid) from public, anon, authenticated;
grant execute on function public.service_admin_list_birthday_automation_settings() to service_role;
grant execute on function public.service_admin_update_birthday_automation_settings(text,boolean,boolean,boolean,boolean,integer,text,text,numeric,integer,integer,integer,uuid) to service_role;

comment on function public.service_admin_update_birthday_automation_settings(text,boolean,boolean,boolean,boolean,integer,text,text,numeric,integer,integer,integer,uuid) is
  'Audited administrative settings mutation only. It does not execute birthday cycles, generate coupons or enqueue notifications.';
-- END RC MIGRATION 20260826190000_birthday_automation_admin_settings.sql

-- BEGIN RC MIGRATION 20260826201500_birthday_daily_runtime.sql
-- Issue #217 / V1.5 #257 — deterministic birthday cycle runtime.
-- This migration creates internal data effects only. It does not create a scheduler and does not call an external provider.

-- Birthday coupons must be distinguishable from manual/promotional coupons.
alter table public.coupons drop constraint if exists coupons_source_check;
alter table public.coupons add constraint coupons_source_check
  check (source in ('PROMOTION', 'BIRTHDAY'));

create or replace function public.run_birthday_automation(
  p_run_date date default ((now() at time zone 'America/Sao_Paulo')::date)
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_setting public.birthday_automation_settings%rowtype;
  v_customer record;
  v_trigger_kind text;
  v_birthday_date date;
  v_trigger_date date;
  v_cycle_id uuid;
  v_coupon_id uuid;
  v_coupon_code text;
  v_template_id uuid;
  v_recipient_hash text;
  v_created_cycles integer := 0;
  v_created_coupons integer := 0;
  v_queued_messages integer := 0;
  v_skipped_existing integer := 0;
  v_service_count integer;
  v_year integer;
  v_is_leap boolean;
  v_feb28 date;
  v_mar01 date;
begin
  if p_run_date is null then
    raise exception using errcode = 'P0001', message = 'BIRTHDAY_RUN_DATE_REQUIRED';
  end if;

  v_year := extract(year from p_run_date)::integer;
  v_is_leap := (v_year % 400 = 0) or (v_year % 4 = 0 and v_year % 100 <> 0);

  for v_setting in
    select *
    from public.birthday_automation_settings
    where is_active
    order by operation_scope
  loop
    for v_customer in
      select distinct c.id, c.name, c.email, c.birth_date
      from public.customers c
      where c.birth_date is not null
        and exists (
          select 1
          from public.appointments a
          join public.services s on s.id = a.service_id
          where a.primary_customer_id = c.id
            and s.operation_scope = v_setting.operation_scope
        )
      order by c.id
    loop
      -- Feb 29 in a non-leap year has two plausible business interpretations (Feb 28 or Mar 1).
      -- Do not choose one. Only fail on dates where either interpretation could trigger; unrelated days keep running.
      if extract(month from v_customer.birth_date)::integer = 2
         and extract(day from v_customer.birth_date)::integer = 29
         and not v_is_leap then
        v_feb28 := make_date(v_year, 2, 28);
        v_mar01 := make_date(v_year, 3, 1);
        if (v_setting.send_on_birthday and p_run_date in (v_feb28, v_mar01))
           or (v_setting.days_before is not null and v_setting.days_before > 0
               and p_run_date in (v_feb28 - v_setting.days_before, v_mar01 - v_setting.days_before)) then
          raise exception using errcode = 'P0001', message = 'BIRTHDAY_LEAP_DAY_POLICY_REQUIRED';
        end if;
        continue;
      end if;

      v_birthday_date := make_date(
        v_year,
        extract(month from v_customer.birth_date)::integer,
        extract(day from v_customer.birth_date)::integer
      );

      for v_trigger_kind in
        select trigger_kind
        from (
          values
            ('BIRTHDAY'::text, v_setting.send_on_birthday),
            ('BEFORE'::text, v_setting.days_before is not null and v_setting.days_before > 0)
        ) q(trigger_kind, enabled)
        where enabled
      loop
        v_trigger_date := case
          when v_trigger_kind = 'BEFORE' then v_birthday_date - v_setting.days_before
          else v_birthday_date
        end;

        -- No retroactive catch-up: a cycle is eligible only on its exact configured date.
        if v_trigger_date <> p_run_date then
          continue;
        end if;

        v_cycle_id := null;
        insert into public.birthday_automation_cycles(
          operation_scope, customer_id, birthday_year, trigger_kind, target_date, message_status
        ) values (
          v_setting.operation_scope,
          v_customer.id,
          extract(year from v_birthday_date)::integer,
          v_trigger_kind,
          v_trigger_date,
          case when v_setting.send_message then 'PENDING' else null end
        )
        on conflict (operation_scope, customer_id, birthday_year, trigger_kind) do nothing
        returning id into v_cycle_id;

        if v_cycle_id is null then
          v_skipped_existing := v_skipped_existing + 1;
          continue;
        end if;

        v_created_cycles := v_created_cycles + 1;

        if v_setting.generate_coupon then
          select count(*) into v_service_count
          from public.services s
          where s.is_active and s.operation_scope = v_setting.operation_scope;

          if v_service_count = 0 then
            raise exception using errcode = 'P0001', message = 'BIRTHDAY_COUPON_OPERATION_HAS_NO_ACTIVE_SERVICES';
          end if;

          v_coupon_code := upper(left(v_setting.coupon_prefix, 16))
            || '-' || extract(year from v_birthday_date)::integer::text
            || '-' || case when v_trigger_kind = 'BEFORE' then 'P' else 'D' end
            || '-' || upper(left(replace(v_customer.id::text, '-', ''), 8));

          insert into public.coupons(
            code, discount_type, discount_value, valid_from, valid_until, is_active,
            source, customer_id, max_uses, max_uses_per_customer, used_count
          ) values (
            v_coupon_code,
            v_setting.coupon_discount_type,
            v_setting.coupon_discount_value,
            (p_run_date::timestamp at time zone 'America/Sao_Paulo'),
            ((p_run_date + v_setting.coupon_validity_days)::timestamp at time zone 'America/Sao_Paulo'),
            true,
            'BIRTHDAY',
            v_customer.id,
            v_setting.coupon_max_uses,
            v_setting.coupon_max_uses_per_customer,
            0
          )
          returning id into v_coupon_id;

          insert into public.coupon_services(coupon_id, service_id)
          select v_coupon_id, s.id
          from public.services s
          where s.is_active and s.operation_scope = v_setting.operation_scope
          on conflict do nothing;

          update public.birthday_automation_cycles
          set coupon_id = v_coupon_id, updated_at = now()
          where id = v_cycle_id;

          insert into public.audit_logs(entity_type, entity_id, action, before_json, after_json, origin)
          values (
            'BIRTHDAY_AUTOMATION', v_cycle_id, 'BIRTHDAY_COUPON_CREATED', null,
            jsonb_build_object(
              'coupon_id', v_coupon_id,
              'customer_id', v_customer.id,
              'operation_scope', v_setting.operation_scope,
              'birthday_year', extract(year from v_birthday_date)::integer,
              'trigger_kind', v_trigger_kind
            ),
            'SYSTEM'
          );

          v_created_coupons := v_created_coupons + 1;
        else
          v_coupon_id := null;
        end if;

        if v_setting.send_message then
          select t.id into v_template_id
          from public.notification_template_configs t
          where t.is_active
            and t.event_key = 'BIRTHDAY'
            and t.channel = 'EMAIL'
            and t.audience = 'CUSTOMER'
            and t.category_id is null
            and not exists (
              select 1 from public.notification_template_services nts where nts.template_id = t.id
            )
            and (t.operation_scope = v_setting.operation_scope or t.operation_scope is null)
          order by case when t.operation_scope = v_setting.operation_scope then 2 else 1 end desc,
                   t.updated_at desc,
                   t.id
          limit 1;

          if v_template_id is null then
            raise exception using errcode = 'P0001', message = 'BIRTHDAY_EMAIL_TEMPLATE_REQUIRED';
          end if;

          v_recipient_hash := case
            when nullif(lower(btrim(v_customer.email)), '') is null then null
            else encode(extensions.digest(lower(btrim(v_customer.email)), 'sha256'), 'hex')
          end;

          if v_recipient_hash is null then
            raise exception using errcode = 'P0001', message = 'BIRTHDAY_CUSTOMER_EMAIL_REQUIRED';
          end if;

          insert into public.notification_delivery_logs(
            template_id, event_key, channel, audience, customer_id, recipient_hash,
            status, idempotency_key, payload_snapshot
          ) values (
            v_template_id,
            'BIRTHDAY',
            'EMAIL',
            'CUSTOMER',
            v_customer.id,
            v_recipient_hash,
            'PENDING',
            'birthday:' || v_setting.operation_scope || ':' || v_customer.id::text || ':'
              || extract(year from v_birthday_date)::integer::text || ':' || v_trigger_kind,
            jsonb_build_object(
              'birthday_cycle_id', v_cycle_id,
              'operation_scope', v_setting.operation_scope,
              'trigger_kind', v_trigger_kind,
              'coupon_id', v_coupon_id
            )
          )
          on conflict (idempotency_key) do nothing;

          insert into public.audit_logs(entity_type, entity_id, action, before_json, after_json, origin)
          values (
            'BIRTHDAY_AUTOMATION', v_cycle_id, 'BIRTHDAY_MESSAGE_QUEUED', null,
            jsonb_build_object(
              'customer_id', v_customer.id,
              'operation_scope', v_setting.operation_scope,
              'template_id', v_template_id,
              'trigger_kind', v_trigger_kind
            ),
            'SYSTEM'
          );

          v_queued_messages := v_queued_messages + 1;
        end if;
      end loop;
    end loop;
  end loop;

  return jsonb_build_object(
    'run_date', p_run_date,
    'created_cycles', v_created_cycles,
    'created_coupons', v_created_coupons,
    'queued_messages', v_queued_messages,
    'skipped_existing', v_skipped_existing
  );
end;
$$;

revoke all on function public.run_birthday_automation(date) from public, anon, authenticated;
grant execute on function public.run_birthday_automation(date) to service_role;

comment on function public.run_birthday_automation(date) is
  'Internal idempotent birthday-cycle runtime. Exact-date only; creates BIRTHDAY coupons and pending notification evidence. Does not call providers or schedule itself.';
-- END RC MIGRATION 20260826201500_birthday_daily_runtime.sql

-- BEGIN RC MIGRATION 20260826214000_black_sheep_birthday_campaign.sql
-- Issue #217 / V1.5 #257 — approved BlackSheep birthday campaign.
-- Configuration is prepared but remains disabled until the controlled delivery consumer is merged and smoke-tested.
-- No customer, coupon, delivery log, scheduler invocation, or external provider call is produced by this migration.

-- Sabrina stays explicitly disabled.
update public.birthday_automation_settings
set is_active = false,
    send_message = false,
    generate_coupon = false,
    updated_at = now()
where operation_scope = 'SABRINA';

-- BlackSheep approved commercial policy:
-- 7 days before birthday, email + 50% single-use coupon for the operation catalog,
-- valid 30 days from issue. No second send on the birthday itself.
update public.birthday_automation_settings
set is_active = false,
    send_message = true,
    generate_coupon = true,
    send_on_birthday = false,
    days_before = 7,
    coupon_prefix = 'NIVER50',
    coupon_discount_type = 'PERCENT',
    coupon_discount_value = 50,
    coupon_validity_days = 30,
    coupon_max_uses = 1,
    coupon_max_uses_per_customer = 1,
    updated_at = now()
where operation_scope = 'BLACKSHEEP';

-- Seed the approved BlackSheep customer email if no operation-level birthday template exists.
-- The template is active as configuration, but it cannot enqueue anything while the birthday
-- automation setting above remains disabled.
insert into public.notification_template_configs (
  event_key,
  channel,
  audience,
  operation_scope,
  category_id,
  title_template,
  body_template,
  is_active,
  variable_schema,
  reminder_offset_minutes,
  created_by_admin_id,
  updated_by_admin_id
)
select
  'BIRTHDAY',
  'EMAIL',
  'CUSTOMER',
  'BLACKSHEEP',
  null,
  '🎂 Seu aniversário merece um presente da BlackSheep',
  E'Olá, {{customer.name}}!\n\nSeu aniversário está chegando e a BlackSheep resolveu começar a comemoração um pouquinho antes.\n\nPreparamos um presente para você: 50% de desconto em uma locação na BlackSheep.\n\nUse seu cupom exclusivo na hora de fazer a reserva. Ele é de uso único e fica disponível por 30 dias.\n\nSeu cupom: {{coupon.code}}\nVálido até {{coupon.expires_at}}\n\nUsar meu presente: {{operation.site_url}}\n\nEscolha seu horário, prepare suas ideias e venha criar com a gente. 🖤\n\nFeliz aniversário adiantado!\nEquipe BlackSheep',
  true,
  '["customer.name","coupon.code","coupon.expires_at","operation.site_url"]'::jsonb,
  null,
  null,
  null
where not exists (
  select 1
  from public.notification_template_configs t
  where t.event_key = 'BIRTHDAY'
    and t.channel = 'EMAIL'
    and t.audience = 'CUSTOMER'
    and t.operation_scope = 'BLACKSHEEP'
    and t.category_id is null
    and not exists (
      select 1 from public.notification_template_services nts where nts.template_id = t.id
    )
);

-- Snapshot the seeded configuration in the same version ledger used by admin edits.
insert into public.notification_template_versions(template_id, version_number, snapshot, changed_by_admin_id)
select
  t.id,
  1,
  to_jsonb(t) || jsonb_build_object('service_ids', '[]'::jsonb),
  null
from public.notification_template_configs t
where t.event_key = 'BIRTHDAY'
  and t.channel = 'EMAIL'
  and t.audience = 'CUSTOMER'
  and t.operation_scope = 'BLACKSHEEP'
  and t.category_id is null
  and t.title_template = '🎂 Seu aniversário merece um presente da BlackSheep'
  and not exists (
    select 1 from public.notification_template_versions v where v.template_id = t.id
  );
-- END RC MIGRATION 20260826214000_black_sheep_birthday_campaign.sql
