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
