
-- BEGIN RC MIGRATION 20260825223000_employee_admin.sql
-- Unified employee administration for service assignments, recurring work hours and exceptions.

alter table public.employees add column if not exists notes text;

create or replace function public.admin_list_employees()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
select coalesce(jsonb_agg(jsonb_build_object(
  'id', e.id,
  'name', e.name,
  'email', e.email,
  'phone', e.phone,
  'notes', e.notes,
  'is_active', e.is_active,
  'resource_id', e.resource_id,
  'service_assignments', coalesce((
    select jsonb_agg(jsonb_build_object(
      'service_employee_id', se.id,
      'service_id', se.service_id,
      'service_name', s.name,
      'operation_scope', s.operation_scope,
      'category_id', s.category_id,
      'is_active', se.is_active,
      'work_hours', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', ar.id, 'weekday', ar.weekday, 'start_local_time', ar.start_local_time,
          'end_local_time', ar.end_local_time, 'slot_interval_minutes', ar.slot_interval_minutes,
          'is_active', ar.is_active
        ) order by ar.weekday, ar.start_local_time, ar.id)
        from public.availability_rules ar where ar.service_employee_id=se.id
      ), '[]'::jsonb),
      'exceptions', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', ax.id, 'exception_type', ax.exception_type, 'start_at', ax.start_at,
          'end_at', ax.end_at, 'reason', ax.reason, 'created_at', ax.created_at
        ) order by ax.start_at, ax.id)
        from public.availability_exceptions ax where ax.service_employee_id=se.id and ax.end_at >= now() - interval '30 days'
      ), '[]'::jsonb),
      'write_calendar', (
        select jsonb_build_object(
          'google_calendar_id', secw.google_calendar_id,
          'calendar_name', gc.name,
          'time_scope', secw.time_scope
        )
        from public.service_employee_calendar_write secw
        join public.google_calendars gc on gc.id=secw.google_calendar_id
        where secw.service_employee_id=se.id
      )
    ) order by s.operation_scope, s.name, se.id)
    from public.service_employees se join public.services s on s.id=se.service_id
    where se.employee_id=e.id
  ), '[]'::jsonb)
) order by e.name,e.id),'[]'::jsonb)
from public.employees e;
$$;

create or replace function public.admin_create_employee_audited(
  p_name text,p_email text,p_phone text,p_notes text,p_admin_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path=public
as $$
declare v_id uuid; v_after jsonb;
begin
  if not public.service_admin_has_permission(p_admin_id,'SERVICES_MANAGE') then raise exception using errcode='P0001',message='ADMIN_PERMISSION_DENIED'; end if;
  if nullif(btrim(p_name),'') is null then raise exception using errcode='P0001',message='EMPLOYEE_NAME_REQUIRED'; end if;
  insert into public.employees(name,email,phone,notes,is_active)
  values(btrim(p_name),nullif(lower(btrim(p_email)),''),nullif(btrim(p_phone),''),nullif(btrim(p_notes),''),true)
  returning id into v_id;
  select item into v_after from jsonb_array_elements(public.admin_list_employees()) item where item->>'id'=v_id::text limit 1;
  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
  values(p_admin_id,'EMPLOYEE',v_id,'EMPLOYEE_CREATED',null,v_after,'ADMIN');
  return v_after;
end;
$$;

create or replace function public.admin_update_employee_audited(
  p_employee_id uuid,p_name text,p_email text,p_phone text,p_notes text,p_is_active boolean,p_admin_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path=public
as $$
declare v_before jsonb; v_after jsonb;
begin
  if not public.service_admin_has_permission(p_admin_id,'SERVICES_MANAGE') then raise exception using errcode='P0001',message='ADMIN_PERMISSION_DENIED'; end if;
  select item into v_before from jsonb_array_elements(public.admin_list_employees()) item where item->>'id'=p_employee_id::text limit 1;
  if v_before is null then raise exception using errcode='P0001',message='EMPLOYEE_NOT_FOUND'; end if;
  if nullif(btrim(p_name),'') is null then raise exception using errcode='P0001',message='EMPLOYEE_NAME_REQUIRED'; end if;
  update public.employees set name=btrim(p_name),email=nullif(lower(btrim(p_email)),''),phone=nullif(btrim(p_phone),''),notes=nullif(btrim(p_notes),''),is_active=coalesce(p_is_active,true),updated_at=now() where id=p_employee_id;
  select item into v_after from jsonb_array_elements(public.admin_list_employees()) item where item->>'id'=p_employee_id::text limit 1;
  if v_before is distinct from v_after then insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin) values(p_admin_id,'EMPLOYEE',p_employee_id,'EMPLOYEE_UPDATED',v_before,v_after,'ADMIN'); end if;
  return v_after;
end;
$$;

create or replace function public.admin_replace_employee_services_audited(
  p_employee_id uuid,p_service_ids uuid[],p_admin_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path=public
as $$
declare v_before jsonb; v_after jsonb; v_service_id uuid;
begin
  if not public.service_admin_has_permission(p_admin_id,'SERVICES_MANAGE') then raise exception using errcode='P0001',message='ADMIN_PERMISSION_DENIED'; end if;
  if not exists(select 1 from public.employees where id=p_employee_id) then raise exception using errcode='P0001',message='EMPLOYEE_NOT_FOUND'; end if;
  if exists(select 1 from unnest(coalesce(p_service_ids,'{}'::uuid[])) sid where not exists(select 1 from public.services s where s.id=sid and s.is_active)) then raise exception using errcode='P0001',message='EMPLOYEE_SERVICE_NOT_AVAILABLE'; end if;
  select item into v_before from jsonb_array_elements(public.admin_list_employees()) item where item->>'id'=p_employee_id::text limit 1;
  update public.service_employees set is_active=false where employee_id=p_employee_id and not (service_id=any(coalesce(p_service_ids,'{}'::uuid[])));
  foreach v_service_id in array coalesce(p_service_ids,'{}'::uuid[]) loop
    insert into public.service_employees(service_id,employee_id,is_active)
    values(v_service_id,p_employee_id,true)
    on conflict(service_id,employee_id) do update set is_active=true;
  end loop;
  select item into v_after from jsonb_array_elements(public.admin_list_employees()) item where item->>'id'=p_employee_id::text limit 1;
  if v_before is distinct from v_after then insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin) values(p_admin_id,'EMPLOYEE',p_employee_id,'EMPLOYEE_SERVICES_UPDATED',v_before,v_after,'ADMIN'); end if;
  return v_after;
end;
$$;

create or replace function public.admin_replace_work_hours_audited(
  p_service_employee_id uuid,p_rules jsonb,p_admin_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path=public
as $$
declare v_before jsonb; v_after jsonb; v_rule jsonb;
begin
  if not public.service_admin_has_permission(p_admin_id,'SERVICES_MANAGE') then raise exception using errcode='P0001',message='ADMIN_PERMISSION_DENIED'; end if;
  if not exists(select 1 from public.service_employees where id=p_service_employee_id) then raise exception using errcode='P0001',message='SERVICE_EMPLOYEE_NOT_FOUND'; end if;
  if jsonb_typeof(coalesce(p_rules,'[]'::jsonb))<>'array' then raise exception using errcode='P0001',message='WORK_HOURS_INVALID'; end if;
  select coalesce(jsonb_agg(to_jsonb(ar) order by ar.weekday,ar.start_local_time,ar.id),'[]'::jsonb) into v_before from public.availability_rules ar where ar.service_employee_id=p_service_employee_id;
  delete from public.availability_rules where service_employee_id=p_service_employee_id;
  for v_rule in select value from jsonb_array_elements(coalesce(p_rules,'[]'::jsonb)) loop
    if (v_rule->>'weekday')::integer not between 0 and 6 or (v_rule->>'end_local_time')::time <= (v_rule->>'start_local_time')::time then raise exception using errcode='P0001',message='WORK_HOURS_INVALID'; end if;
    insert into public.availability_rules(service_employee_id,weekday,start_local_time,end_local_time,slot_interval_minutes,is_active)
    values(p_service_employee_id,(v_rule->>'weekday')::smallint,(v_rule->>'start_local_time')::time,(v_rule->>'end_local_time')::time,coalesce((v_rule->>'slot_interval_minutes')::integer,30),coalesce((v_rule->>'is_active')::boolean,true));
  end loop;
  select coalesce(jsonb_agg(to_jsonb(ar) order by ar.weekday,ar.start_local_time,ar.id),'[]'::jsonb) into v_after from public.availability_rules ar where ar.service_employee_id=p_service_employee_id;
  if v_before is distinct from v_after then insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin) values(p_admin_id,'SERVICE_EMPLOYEE',p_service_employee_id,'WORK_HOURS_UPDATED',v_before,v_after,'ADMIN'); end if;
  return v_after;
end;
$$;

create or replace function public.admin_add_employee_exception_audited(
  p_service_employee_id uuid,p_exception_type text,p_start_at timestamptz,p_end_at timestamptz,p_reason text,p_admin_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path=public
as $$
declare v_id uuid; v_type text:=upper(btrim(coalesce(p_exception_type,''))); v_after jsonb;
begin
  if not public.service_admin_has_permission(p_admin_id,'SERVICES_MANAGE') then raise exception using errcode='P0001',message='ADMIN_PERMISSION_DENIED'; end if;
  if v_type not in ('BLOCK','OPEN') then raise exception using errcode='P0001',message='AVAILABILITY_EXCEPTION_TYPE_INVALID'; end if;
  if p_end_at<=p_start_at then raise exception using errcode='P0001',message='AVAILABILITY_EXCEPTION_RANGE_INVALID'; end if;
  if not exists(select 1 from public.service_employees where id=p_service_employee_id) then raise exception using errcode='P0001',message='SERVICE_EMPLOYEE_NOT_FOUND'; end if;
  insert into public.availability_exceptions(service_employee_id,exception_type,start_at,end_at,reason,created_by)
  values(p_service_employee_id,v_type,p_start_at,p_end_at,nullif(btrim(p_reason),''),p_admin_id) returning id into v_id;
  select to_jsonb(ax) into v_after from public.availability_exceptions ax where ax.id=v_id;
  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin) values(p_admin_id,'AVAILABILITY_EXCEPTION',v_id,'AVAILABILITY_EXCEPTION_CREATED',null,v_after,'ADMIN');
  return v_after;
end;
$$;

create or replace function public.admin_remove_employee_exception_audited(p_exception_id uuid,p_admin_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path=public
as $$
declare v_before jsonb;
begin
  if not public.service_admin_has_permission(p_admin_id,'SERVICES_MANAGE') then raise exception using errcode='P0001',message='ADMIN_PERMISSION_DENIED'; end if;
  select to_jsonb(ax) into v_before from public.availability_exceptions ax where ax.id=p_exception_id for update;
  if v_before is null then raise exception using errcode='P0001',message='AVAILABILITY_EXCEPTION_NOT_FOUND'; end if;
  delete from public.availability_exceptions where id=p_exception_id;
  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin) values(p_admin_id,'AVAILABILITY_EXCEPTION',p_exception_id,'AVAILABILITY_EXCEPTION_DELETED',v_before,null,'ADMIN');
  return jsonb_build_object('exception_id',p_exception_id,'removed',true);
end;
$$;

revoke all on function public.admin_list_employees() from public,anon,authenticated;
revoke all on function public.admin_create_employee_audited(text,text,text,text,uuid) from public,anon,authenticated;
revoke all on function public.admin_update_employee_audited(uuid,text,text,text,text,boolean,uuid) from public,anon,authenticated;
revoke all on function public.admin_replace_employee_services_audited(uuid,uuid[],uuid) from public,anon,authenticated;
revoke all on function public.admin_replace_work_hours_audited(uuid,jsonb,uuid) from public,anon,authenticated;
revoke all on function public.admin_add_employee_exception_audited(uuid,text,timestamptz,timestamptz,text,uuid) from public,anon,authenticated;
revoke all on function public.admin_remove_employee_exception_audited(uuid,uuid) from public,anon,authenticated;
grant execute on function public.admin_list_employees() to service_role;
grant execute on function public.admin_create_employee_audited(text,text,text,text,uuid) to service_role;
grant execute on function public.admin_update_employee_audited(uuid,text,text,text,text,boolean,uuid) to service_role;
grant execute on function public.admin_replace_employee_services_audited(uuid,uuid[],uuid) to service_role;
grant execute on function public.admin_replace_work_hours_audited(uuid,jsonb,uuid) to service_role;
grant execute on function public.admin_add_employee_exception_audited(uuid,text,timestamptz,timestamptz,text,uuid) to service_role;
grant execute on function public.admin_remove_employee_exception_audited(uuid,uuid) to service_role;
-- END RC MIGRATION 20260825223000_employee_admin.sql

-- BEGIN RC MIGRATION 20260825223100_employee_calendar_write_admin.sql
-- Manage where Agenda writes reservations for each service/employee assignment.
-- OAuth/account connection is intentionally outside this RPC; only already-discovered active calendars may be mapped.

create or replace function public.admin_set_service_employee_write_calendar_audited(
  p_service_employee_id uuid,
  p_google_calendar_id uuid,
  p_time_scope text,
  p_admin_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path=public
as $$
declare
  v_before jsonb;
  v_after jsonb;
  v_scope text:=upper(btrim(coalesce(p_time_scope,'')));
begin
  if not public.service_admin_has_permission(p_admin_id,'INTEGRATIONS_MANAGE') then
    raise exception using errcode='P0001',message='ADMIN_PERMISSION_DENIED';
  end if;
  if not exists(select 1 from public.service_employees where id=p_service_employee_id and is_active) then
    raise exception using errcode='P0001',message='SERVICE_EMPLOYEE_NOT_FOUND';
  end if;
  if v_scope not in ('FULL_APPOINTMENT','CORE_ONLY') then
    raise exception using errcode='P0001',message='GOOGLE_WRITE_TIME_SCOPE_INVALID';
  end if;
  if not exists(
    select 1 from public.google_calendars
    where id=p_google_calendar_id and is_active and access_role in ('writer','owner')
  ) then
    raise exception using errcode='P0001',message='GOOGLE_CALENDAR_WRITE_ACCESS_REQUIRED';
  end if;

  select to_jsonb(x) into v_before
  from public.service_employee_calendar_write x
  where x.service_employee_id=p_service_employee_id;

  insert into public.service_employee_calendar_write(service_employee_id,google_calendar_id,time_scope)
  values(p_service_employee_id,p_google_calendar_id,v_scope)
  on conflict(service_employee_id) do update
  set google_calendar_id=excluded.google_calendar_id,time_scope=excluded.time_scope,updated_at=now();

  select to_jsonb(x) into v_after
  from public.service_employee_calendar_write x
  where x.service_employee_id=p_service_employee_id;

  if v_before is distinct from v_after then
    insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
    values(p_admin_id,'SERVICE_EMPLOYEE',p_service_employee_id,'GOOGLE_WRITE_CALENDAR_UPDATED',v_before,v_after,'ADMIN');
  end if;
  return v_after;
end;
$$;

create or replace function public.admin_clear_service_employee_write_calendar_audited(
  p_service_employee_id uuid,
  p_admin_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path=public
as $$
declare v_before jsonb;
begin
  if not public.service_admin_has_permission(p_admin_id,'INTEGRATIONS_MANAGE') then
    raise exception using errcode='P0001',message='ADMIN_PERMISSION_DENIED';
  end if;
  select to_jsonb(x) into v_before
  from public.service_employee_calendar_write x
  where x.service_employee_id=p_service_employee_id for update;
  if v_before is null then return jsonb_build_object('removed',false); end if;
  delete from public.service_employee_calendar_write where service_employee_id=p_service_employee_id;
  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
  values(p_admin_id,'SERVICE_EMPLOYEE',p_service_employee_id,'GOOGLE_WRITE_CALENDAR_CLEARED',v_before,null,'ADMIN');
  return jsonb_build_object('removed',true,'service_employee_id',p_service_employee_id);
end;
$$;

revoke all on function public.admin_set_service_employee_write_calendar_audited(uuid,uuid,text,uuid) from public,anon,authenticated;
revoke all on function public.admin_clear_service_employee_write_calendar_audited(uuid,uuid) from public,anon,authenticated;
grant execute on function public.admin_set_service_employee_write_calendar_audited(uuid,uuid,text,uuid) to service_role;
grant execute on function public.admin_clear_service_employee_write_calendar_audited(uuid,uuid) to service_role;
-- END RC MIGRATION 20260825223100_employee_calendar_write_admin.sql

-- BEGIN RC MIGRATION 20260825231000_preprod_legacy_fk_indexes.sql
-- Pre-production performance hardening for legacy import tables.
-- Add covering indexes for foreign keys reported by Supabase Performance Advisor.

create index if not exists legacy_appointments_batch_id_idx
  on public.legacy_appointments(batch_id);

create index if not exists legacy_appointments_legacy_customer_source_id_idx
  on public.legacy_appointments(legacy_customer_source_id);

create index if not exists legacy_customer_sources_batch_id_idx
  on public.legacy_customer_sources(batch_id);
-- END RC MIGRATION 20260825231000_preprod_legacy_fk_indexes.sql

-- BEGIN RC MIGRATION 20260825232000_preprod_service_type_structure.sql
-- V1 pre-production data preparation only. No runtime behavior may branch on service_type in this phase.
--
-- Taxonomy principle:
-- service_type carries only what changes scheduling logic: block composition,
-- resource requirement, edge positioning, and Google representation.
-- Duration, price, payment mode, checkout requirement, and Kommo mapping are
-- service attributes, not service_type attributes.
--
-- Declared exclusions:
-- EVENTO is commercially out of scope for now and may be inserted later.
-- PARTO is not a service_type: it is on-call availability and does not consume a slot.
-- PACOTE_HORAS is a prepaid commercial modality of LOCACAO, not a type.
-- VISITA is LOCACAO with fixed duration, zero price, and no checkout, not a type.

create table if not exists public.service_type (
  id uuid primary key default gen_random_uuid(),
  key text not null unique,
  created_at timestamptz not null default now(),
  constraint service_type_key_nonempty check (btrim(key) <> '')
);

comment on table public.service_type is
  'Scheduling-semantic service types. V1 pre-production structure only; no behavior branches on this table.';

insert into public.service_type (key)
values ('ENSAIO'), ('LOCACAO')
on conflict (key) do nothing;

alter table public.services
  add column if not exists service_type_id uuid null references public.service_type(id);

create index if not exists services_service_type_id_idx
  on public.services(service_type_id);

-- N:N catalog offer. operation_scope is the existing canonical business-unit key.
-- Exclusivity is data, never code: future offers are changed by row insert/delete.
create table if not exists public.operation_service_types (
  operation_scope text not null,
  service_type_id uuid not null references public.service_type(id) on delete restrict,
  created_at timestamptz not null default now(),
  primary key (operation_scope, service_type_id),
  constraint operation_service_types_scope_check
    check (operation_scope in ('SABRINA', 'BLACKSHEEP'))
);

insert into public.operation_service_types (operation_scope, service_type_id)
select 'SABRINA', id from public.service_type where key = 'ENSAIO'
on conflict do nothing;

insert into public.operation_service_types (operation_scope, service_type_id)
select 'BLACKSHEEP', id from public.service_type where key = 'LOCACAO'
on conflict do nothing;

alter table public.appointments
  add column if not exists service_type_snapshot_id uuid null references public.service_type(id);

create index if not exists appointments_service_type_snapshot_id_idx
  on public.appointments(service_type_snapshot_id);

create or replace function public.capture_appointment_service_type_snapshot()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.status = 'CONFIRMED' and new.service_type_snapshot_id is null then
    select s.service_type_id
      into new.service_type_snapshot_id
    from public.services s
    where s.id = new.service_id;
  end if;
  return new;
end;
$$;

drop trigger if exists appointments_capture_service_type_snapshot on public.appointments;
create trigger appointments_capture_service_type_snapshot
before insert or update of status on public.appointments
for each row
execute function public.capture_appointment_service_type_snapshot();

revoke all on table public.service_type from anon, authenticated;
revoke all on table public.operation_service_types from anon, authenticated;
-- END RC MIGRATION 20260825232000_preprod_service_type_structure.sql

-- BEGIN RC MIGRATION 20260825232100_preprod_feature_flags_structure.sql
-- V1 pre-production data preparation only.
-- No existing behavior is moved behind a feature flag in this phase.

create table if not exists public.feature_flags (
  id uuid primary key default gen_random_uuid(),
  key text not null,
  environment_scope text not null,
  enabled boolean not null default false,
  owner text not null,
  removal_due_at date not null,
  description text null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint feature_flags_key_nonempty check (btrim(key) <> ''),
  constraint feature_flags_owner_nonempty check (btrim(owner) <> ''),
  constraint feature_flags_environment_nonempty check (btrim(environment_scope) <> ''),
  constraint feature_flags_key_environment_unique unique (key, environment_scope)
);

comment on table public.feature_flags is
  'Time-bounded feature flags. Owner and planned removal date are mandatory. V1 pre-production provides read-only consumption only.';

alter table public.feature_flags enable row level security;
revoke all on table public.feature_flags from anon, authenticated;

create or replace function public.read_feature_flag(
  p_key text,
  p_environment_scope text
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((
    select ff.enabled
    from public.feature_flags ff
    where ff.key = p_key
      and ff.environment_scope = p_environment_scope
    limit 1
  ), false);
$$;

revoke all on function public.read_feature_flag(text, text) from public;
grant execute on function public.read_feature_flag(text, text) to service_role;
-- END RC MIGRATION 20260825232100_preprod_feature_flags_structure.sql

-- BEGIN RC MIGRATION 20260825233000_active_service_policy_invariant.sql
-- I-09 / Adendo 1+2: active services must own an explicit change policy.
-- Expand-only schema hardening plus deterministic deactivation of two known sandbox fixtures.
-- No commercial policy value is inferred or backfilled.

-- Deterministic fixture treatment: both rows were inventoried as non-commercial test fixtures.
update public.services s
set is_active = false,
    updated_at = now()
where s.is_active = true
  and s.name in ('[TESTE] Locação BlackSheep Kommo', 'Token Evidence Service')
  and not exists (
    select 1 from public.service_change_policies p where p.service_id = s.id
  );

-- Application-facing creation APIs create a draft. Activation remains an explicit later action
-- and is guarded by the deferred invariant below. Signatures/contracts are unchanged.
create or replace function public.service_admin_create_service_audited(
  p_name text,
  p_slug text,
  p_operation_scope text,
  p_short_description text,
  p_full_description text,
  p_duration_mode text,
  p_base_duration_minutes integer,
  p_base_price numeric,
  p_buffer_before_minutes integer,
  p_buffer_after_minutes integer,
  p_admin_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_scope text := upper(btrim(coalesce(p_operation_scope,'')));
  v_mode text := upper(btrim(coalesce(p_duration_mode,'FIXED')));
begin
  if not public.service_admin_has_permission(p_admin_id, 'SERVICES_MANAGE') then
    raise exception using errcode='P0001', message='ADMIN_PERMISSION_DENIED';
  end if;
  if nullif(btrim(p_name),'') is null then raise exception using errcode='P0001', message='SERVICE_NAME_REQUIRED'; end if;
  if nullif(btrim(p_slug),'') is null or p_slug !~ '^[a-z0-9]+(?:-[a-z0-9]+)*$' then raise exception using errcode='P0001', message='SERVICE_SLUG_INVALID'; end if;
  if v_scope not in ('SABRINA','BLACKSHEEP') then raise exception using errcode='P0001', message='SERVICE_OPERATION_SCOPE_INVALID'; end if;
  if v_mode not in ('FIXED','BLOCKS') then raise exception using errcode='P0001', message='INVALID_DURATION_MODE'; end if;
  if coalesce(p_base_duration_minutes,0) <= 0 then raise exception using errcode='P0001', message='INVALID_BASE_DURATION'; end if;
  if coalesce(p_base_price,-1) < 0 then raise exception using errcode='P0001', message='INVALID_BASE_PRICE'; end if;
  if coalesce(p_buffer_before_minutes,-1) < 0 or coalesce(p_buffer_after_minutes,-1) < 0 then raise exception using errcode='P0001', message='INVALID_BUFFER'; end if;

  insert into public.services(
    category_id,name,slug,short_description,full_description,base_duration_minutes,
    buffer_before_minutes,buffer_after_minutes,base_price,is_active,sort_order,
    duration_mode,operation_scope
  ) values (
    null,btrim(p_name),btrim(p_slug),nullif(btrim(p_short_description),''),nullif(btrim(p_full_description),''),
    p_base_duration_minutes,p_buffer_before_minutes,p_buffer_after_minutes,p_base_price,false,
    coalesce((select max(sort_order)+10 from public.services where operation_scope=v_scope),0),
    v_mode,v_scope
  ) returning id into v_id;

  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
  values(p_admin_id,'SERVICE',v_id,'SERVICE_CREATED',null,public.service_admin_service_snapshot(v_id),'ADMIN');
  return public.service_admin_service_snapshot(v_id);
end;
$$;

create or replace function public.service_admin_create_service_catalog_audited(
  p_category_id uuid, p_name text, p_slug text, p_operation_scope text,
  p_short_description text, p_full_description text,
  p_duration_mode text, p_base_duration_minutes integer, p_base_price numeric,
  p_buffer_before_minutes integer, p_buffer_after_minutes integer,
  p_minimum_people integer, p_maximum_people integer, p_price_per_extra_person numeric,
  p_admin_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_scope text := upper(btrim(coalesce(p_operation_scope,'')));
  v_mode text := upper(btrim(coalesce(p_duration_mode,'FIXED')));
  v_category_scope text;
begin
  if not public.service_admin_has_permission(p_admin_id,'SERVICES_MANAGE') then raise exception using errcode='P0001', message='ADMIN_PERMISSION_DENIED'; end if;
  select operation_scope into v_category_scope from public.categories where id=p_category_id and is_active;
  if not found then raise exception using errcode='P0001', message='CATEGORY_NOT_AVAILABLE'; end if;
  if v_scope not in ('SABRINA','BLACKSHEEP') or v_category_scope<>v_scope then raise exception using errcode='P0001', message='SERVICE_CATEGORY_OPERATION_MISMATCH'; end if;
  if nullif(btrim(p_name),'') is null then raise exception using errcode='P0001', message='SERVICE_NAME_REQUIRED'; end if;
  if nullif(btrim(p_slug),'') is null or p_slug !~ '^[a-z0-9]+(?:-[a-z0-9]+)*$' then raise exception using errcode='P0001', message='SERVICE_SLUG_INVALID'; end if;
  if v_mode not in ('FIXED','BLOCKS') then raise exception using errcode='P0001', message='INVALID_DURATION_MODE'; end if;
  if coalesce(p_base_duration_minutes,0)<=0 then raise exception using errcode='P0001', message='INVALID_BASE_DURATION'; end if;
  if coalesce(p_base_price,-1)<0 or coalesce(p_price_per_extra_person,-1)<0 then raise exception using errcode='P0001', message='INVALID_PRICE'; end if;
  if coalesce(p_minimum_people,0)<1 or coalesce(p_maximum_people,0)<p_minimum_people then raise exception using errcode='P0001', message='INVALID_PEOPLE_RANGE'; end if;
  if coalesce(p_buffer_before_minutes,-1)<0 or coalesce(p_buffer_after_minutes,-1)<0 then raise exception using errcode='P0001', message='INVALID_BUFFER'; end if;

  insert into public.services(category_id,name,slug,short_description,full_description,base_duration_minutes,
    buffer_before_minutes,buffer_after_minutes,base_price,minimum_people,maximum_people,price_per_extra_person,
    is_active,sort_order,duration_mode,operation_scope)
  values(p_category_id,btrim(p_name),btrim(p_slug),nullif(btrim(p_short_description),''),nullif(btrim(p_full_description),''),
    p_base_duration_minutes,p_buffer_before_minutes,p_buffer_after_minutes,p_base_price,p_minimum_people,p_maximum_people,
    p_price_per_extra_person,false,coalesce((select max(sort_order)+10 from public.services where category_id=p_category_id),0),v_mode,v_scope)
  returning id into v_id;

  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
  values(p_admin_id,'SERVICE',v_id,'SERVICE_CREATED',null,(select to_jsonb(s) from public.services s where s.id=v_id),'ADMIN');
  return (select to_jsonb(s) from public.services s where s.id=v_id);
end;
$$;

-- Deferred source-side invariant. It permits service + policy to be created in one transaction,
-- while rejecting commit if the resulting active service has no policy. Reactivation is covered.
create or replace function public.enforce_active_service_has_change_policy()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if exists (
    select 1
    from public.services s
    where s.id = new.id
      and s.is_active = true
      and not exists (
        select 1 from public.service_change_policies p where p.service_id = s.id
      )
  ) then
    raise exception using errcode='23514', message='ACTIVE_SERVICE_CHANGE_POLICY_REQUIRED';
  end if;
  return null;
end;
$$;

drop trigger if exists services_active_change_policy_guard on public.services;
create constraint trigger services_active_change_policy_guard
after insert or update of is_active on public.services
deferrable initially deferred
for each row execute function public.enforce_active_service_has_change_policy();

-- Opposite direction: an active service cannot lose its policy. Deferred so a transaction may
-- deactivate the service and delete its policy atomically.
create or replace function public.prevent_active_service_policy_removal()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if exists (
    select 1 from public.services s
    where s.id = old.service_id and s.is_active = true
  ) and not exists (
    select 1 from public.service_change_policies p where p.service_id = old.service_id
  ) then
    raise exception using errcode='23514', message='ACTIVE_SERVICE_CHANGE_POLICY_CANNOT_BE_REMOVED';
  end if;
  return null;
end;
$$;

drop trigger if exists active_service_policy_delete_guard on public.service_change_policies;
create constraint trigger active_service_policy_delete_guard
after delete on public.service_change_policies
deferrable initially deferred
for each row execute function public.prevent_active_service_policy_removal();
-- END RC MIGRATION 20260825233000_active_service_policy_invariant.sql

-- BEGIN RC MIGRATION 20260826005000_policy_snapshot_fail_loud.sql
-- I-09 / Adendo 1: once every active service is guaranteed to own an explicit
-- change policy, snapshot capture must fail at the point of violation instead
-- of returning silently and deferring the error to a later integrity check.
create or replace function public.capture_current_appointment_change_policy_snapshot()
returns trigger
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_policy public.service_change_policies%rowtype;
  v_effective_at timestamptz;
  v_max_reschedules integer;
  v_policy_json jsonb;
begin
  if new.status not in ('AWAITING_PAYMENT','CONFIRMED') then return new; end if;
  if exists (
    select 1 from public.appointment_change_policy_snapshots s
    where s.appointment_id=new.id
  ) then return new; end if;

  select * into v_policy
  from public.service_change_policies
  where service_id=new.service_id;
  if not found then
    raise exception using
      errcode='23514',
      message='APPOINTMENT_SERVICE_CHANGE_POLICY_MISSING',
      detail='service_id=' || coalesce(new.service_id::text, '<null>');
  end if;

  select coalesce(s.max_reschedules,3)
  into v_max_reschedules
  from public.services s
  where s.id=new.service_id;

  if v_max_reschedules is null then
    raise exception using errcode='P0001',message='SERVICE_RESCHEDULE_CONFIGURATION_MISSING';
  end if;

  v_effective_at := case
    when new.status='AWAITING_PAYMENT' then new.created_at
    else coalesce(new.confirmed_at,new.created_at)
  end;

  v_policy_json := public.normalize_change_policy_snapshot(
    to_jsonb(v_policy) || jsonb_build_object('max_customer_reschedules',v_max_reschedules)
  );

  insert into public.appointment_change_policy_snapshots(
    appointment_id,service_id,policy_json,effective_at,source,
    max_customer_reschedules,policy_timezone,notice_boundary_semantics
  ) values (
    new.id,new.service_id,v_policy_json,v_effective_at,'BOOKING_CAPTURE',
    v_max_reschedules,'America/Sao_Paulo','EXACT_LIMIT_IS_OUTSIDE_WINDOW'
  );

  perform public.capture_appointment_policy_terms_snapshot(new.id,new.service_id,v_effective_at);
  return new;
end;
$$;
-- END RC MIGRATION 20260826005000_policy_snapshot_fail_loud.sql

-- BEGIN RC MIGRATION 20260826005500_index_operation_service_type_fk.sql
-- Supabase Performance Advisor: cover the service_type_id foreign key on the
-- operation_service_types junction table. Additive and behavior-neutral.
create index if not exists operation_service_types_service_type_id_idx
  on public.operation_service_types(service_type_id);
-- END RC MIGRATION 20260826005500_index_operation_service_type_fk.sql

-- BEGIN RC MIGRATION 20260826010000_preprod_confirmation_invariant.sql
-- I-09 final destination invariant.
-- Existing historical rows are intentionally not rewritten: both constraints
-- are introduced NOT VALID and are enforced only for new/updated states.

alter table public.appointments
  add column if not exists change_policy_snapshot_appointment_id uuid;

create or replace function public.mark_confirmed_appointment_policy_snapshot()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.status = 'CONFIRMED' then
    new.change_policy_snapshot_appointment_id := new.id;
  end if;
  return new;
end;
$$;

drop trigger if exists appointments_mark_confirmed_policy_snapshot on public.appointments;
create trigger appointments_mark_confirmed_policy_snapshot
before insert or update of status on public.appointments
for each row execute function public.mark_confirmed_appointment_policy_snapshot();

alter table public.appointments
  drop constraint if exists appointments_confirmed_requires_policy_snapshot_ck;
alter table public.appointments
  add constraint appointments_confirmed_requires_policy_snapshot_ck
  check (
    status <> 'CONFIRMED'
    or (
      confirmed_at is not null
      and change_policy_snapshot_appointment_id is not null
    )
  ) not valid;

alter table public.appointments
  drop constraint if exists appointments_change_policy_snapshot_fk;
alter table public.appointments
  add constraint appointments_change_policy_snapshot_fk
  foreign key (change_policy_snapshot_appointment_id)
  references public.appointment_change_policy_snapshots(appointment_id)
  deferrable initially deferred
  not valid;

create index if not exists appointments_change_policy_snapshot_idx
  on public.appointments(change_policy_snapshot_appointment_id)
  where change_policy_snapshot_appointment_id is not null;

comment on column public.appointments.change_policy_snapshot_appointment_id is
  'I-09 marker/FK: a CONFIRMED appointment must resolve to its immutable change-policy snapshot by transaction commit.';

comment on constraint appointments_confirmed_requires_policy_snapshot_ck on public.appointments is
  'NOT VALID during pre-production closeout: new/updated CONFIRMED states require confirmed_at and a policy-snapshot marker; historical fixtures are not rewritten.';
-- END RC MIGRATION 20260826010000_preprod_confirmation_invariant.sql

-- BEGIN RC MIGRATION 20260826085000_reconcile_token_evidence_and_validate_i09.sql
-- I-09 finalization, phase 1: deterministic fixture repair only.
--
-- The only rows preventing validation in the sandbox are two historical,
-- synthetic action-token fixtures created directly as CONFIRMED before the
-- confirmation invariant existed. Their fixture provenance is authoritative:
-- exact 9700... UUID namespace, service slug token-evidence-service-20260823,
-- @example.com token destination, token-test-* request ids and TEST_ONLY
-- financial-effect evidence.
--
-- Preserve those fixtures instead of deleting them. Reconstruct only the
-- minimum historical confirmation metadata needed by the invariant. No
-- commercial policy is inferred and no active service policy is created.
-- Constraint validation is intentionally a following migration so deferred
-- trigger events from this repair are committed before ALTER TABLE VALIDATE.

do $$
declare
  v_fixture_count integer;
begin
  select count(*)
  into v_fixture_count
  from public.appointments a
  join public.services s on s.id = a.service_id
  where a.id in (
      '97000000-0000-0000-0000-000000000030'::uuid,
      '97000000-0000-0000-0000-000000000031'::uuid
    )
    and a.service_id = '97000000-0000-0000-0000-000000000010'::uuid
    and s.slug = 'token-evidence-service-20260823'
    and s.is_active = false
    and a.status = 'CONFIRMED'
    and a.confirmed_at is null
    and a.change_policy_snapshot_appointment_id is null
    and exists (
      select 1
      from public.appointment_token_events e
      where e.appointment_id = a.id
        and e.event_type = 'ISSUED'
        and e.destination_masked = 't***@example.com'
        and e.request_id in ('token-test-issue', 'token-test-issue-2')
    );

  if v_fixture_count not in (0, 2) then
    raise exception using
      errcode = 'P0001',
      message = 'TOKEN_EVIDENCE_FIXTURE_SET_UNEXPECTED',
      detail = format('expected 0 or 2 exact fixtures, found %s', v_fixture_count);
  end if;

  -- A fresh rebuild has no sandbox-only fixture rows and needs no data repair.
  if v_fixture_count = 2 then
    if not exists (
      select 1
      from public.appointment_token_events e
      where e.appointment_id = '97000000-0000-0000-0000-000000000031'::uuid
        and e.event_type = 'ACTION_EXECUTED'
        and e.request_id = 'consume-ok'
        and e.metadata_json ->> 'financial_effect' = 'TEST_ONLY'
    ) then
      raise exception using
        errcode = 'P0001',
        message = 'TOKEN_EVIDENCE_TEST_ONLY_PROVENANCE_MISSING';
    end if;

    insert into public.appointment_change_policy_snapshots(
      appointment_id,
      service_id,
      policy_json,
      effective_at,
      source,
      max_customer_reschedules,
      policy_timezone,
      notice_boundary_semantics
    )
    select
      a.id,
      a.service_id,
      jsonb_build_object(
        'snapshot_schema_version', 'FIXTURE_RECONSTRUCTION_V1',
        'fixture_only', true,
        'notice_hours', 0,
        'max_customer_reschedules', 0,
        'reschedule_first_early_percent', 0,
        'reschedule_first_late_percent', 0,
        'reschedule_repeat_percent', 0,
        'cancellation_late_percent', 0,
        'policy_timezone', 'America/Sao_Paulo',
        'notice_boundary_semantics', 'EXACT_LIMIT_IS_OUTSIDE_WINDOW',
        'reconstruction_basis', 'DIRECT_CONFIRMED_TOKEN_TEST_FIXTURE'
      ),
      a.created_at,
      'HISTORICAL_RECONSTRUCTION',
      0,
      'America/Sao_Paulo',
      'EXACT_LIMIT_IS_OUTSIDE_WINDOW'
    from public.appointments a
    where a.id in (
      '97000000-0000-0000-0000-000000000030'::uuid,
      '97000000-0000-0000-0000-000000000031'::uuid
    )
    on conflict (appointment_id) do nothing;

    -- These rows were inserted directly already in CONFIRMED state. Their
    -- insertion timestamp is therefore the deterministic historical boundary:
    -- no application confirmation event exists to supply a different value.
    update public.appointments a
    set confirmed_at = a.created_at,
        change_policy_snapshot_appointment_id = a.id,
        updated_at = now()
    where a.id in (
      '97000000-0000-0000-0000-000000000030'::uuid,
      '97000000-0000-0000-0000-000000000031'::uuid
    )
      and a.confirmed_at is null
      and a.change_policy_snapshot_appointment_id is null;
  end if;
end
$$;
-- END RC MIGRATION 20260826085000_reconcile_token_evidence_and_validate_i09.sql

-- BEGIN RC MIGRATION 20260826085100_validate_i09_constraints.sql
-- I-09 finalization, phase 2a: reconcile the two known pre-marker staging
-- confirmations in a transaction that commits before constraint validation.
--
-- These rows were confirmed before the marker column/trigger existed. Both
-- already have confirmed_at and a real appointment_change_policy_snapshots row;
-- this migration only links the marker to that existing snapshot. The exact IDs
-- are synthetic staging reservations. A partial or structurally inconsistent
-- set aborts instead of inferring or fabricating policy data.

do $$
declare
  v_present integer;
  v_ready integer;
begin
  select count(*)
    into v_present
  from public.appointments
  where id in (
    'be5125bc-2725-43e6-a8b0-283ea3a221ed'::uuid,
    'b98aa122-49a9-4f33-a76d-85208069f3d5'::uuid
  );

  if v_present not in (0, 2) then
    raise exception 'I09_STAGING_MARKER_FIXTURE_SET_UNEXPECTED: expected 0 or 2 rows, found %', v_present;
  end if;

  if v_present = 2 then
    select count(*)
      into v_ready
    from public.appointments a
    where a.id in (
      'be5125bc-2725-43e6-a8b0-283ea3a221ed'::uuid,
      'b98aa122-49a9-4f33-a76d-85208069f3d5'::uuid
    )
      and a.status = 'CONFIRMED'
      and a.confirmed_at is not null
      and exists (
        select 1
        from public.appointment_change_policy_snapshots s
        where s.appointment_id = a.id
      );

    if v_ready <> 2 then
      raise exception 'I09_STAGING_MARKER_FIXTURE_EVIDENCE_MISSING: expected 2 confirmed rows with timestamp and real snapshot, found %', v_ready;
    end if;

    update public.appointments
    set change_policy_snapshot_appointment_id = id
    where id in (
      'be5125bc-2725-43e6-a8b0-283ea3a221ed'::uuid,
      'b98aa122-49a9-4f33-a76d-85208069f3d5'::uuid
    )
      and change_policy_snapshot_appointment_id is null;
  end if;
end
$$;
-- END RC MIGRATION 20260826085100_validate_i09_constraints.sql

-- BEGIN RC MIGRATION 20260826085200_validate_i09_constraints.sql
-- I-09 finalization, phase 2b: validate only after the staging marker
-- reconciliation migration has committed, so no deferred trigger events remain.

alter table public.appointments
  validate constraint appointments_confirmed_requires_policy_snapshot_ck;

alter table public.appointments
  validate constraint appointments_change_policy_snapshot_fk;
-- END RC MIGRATION 20260826085200_validate_i09_constraints.sql

-- BEGIN RC MIGRATION 20260826123000_operation_settings_scope_foundation.sql
-- Issue #218 phase 1: per-operation settings foundation.
-- Preserve the existing singleton operation_settings contract while adding
-- explicit scoped overrides for SABRINA and BLACKSHEEP.

create table if not exists public.operation_setting_overrides (
  operation_scope text primary key,
  public_name text,
  public_email text,
  public_phone text,
  public_address text,
  public_site_url text,
  timezone text,
  default_currency text,
  checkout_hold_minutes integer,
  payment_hold_minutes integer,
  agency_hold_minutes integer,
  default_confirmation_percentage numeric,
  pix_discount_percent numeric,
  default_slot_interval_minutes integer,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint operation_setting_overrides_scope_ck
    check (operation_scope in ('SABRINA','BLACKSHEEP')),
  constraint operation_setting_overrides_checkout_hold_ck
    check (checkout_hold_minutes is null or checkout_hold_minutes between 1 and 1440),
  constraint operation_setting_overrides_payment_hold_ck
    check (payment_hold_minutes is null or payment_hold_minutes between 1 and 10080),
  constraint operation_setting_overrides_agency_hold_ck
    check (agency_hold_minutes is null or agency_hold_minutes between 1 and 10080),
  constraint operation_setting_overrides_confirmation_ck
    check (default_confirmation_percentage is null or default_confirmation_percentage between 0 and 100),
  constraint operation_setting_overrides_pix_discount_ck
    check (pix_discount_percent is null or pix_discount_percent between 0 and 100),
  constraint operation_setting_overrides_slot_interval_ck
    check (default_slot_interval_minutes is null or default_slot_interval_minutes between 5 and 1440)
);

alter table public.operation_setting_overrides enable row level security;

revoke all on table public.operation_setting_overrides from public, anon, authenticated;
grant select, insert, update, delete on table public.operation_setting_overrides to service_role;

create or replace function public.service_admin_get_operation_settings_v2(
  p_operation_scope text
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with base as (
    select * from public.operation_settings where id = 1
  ), scoped as (
    select * from public.operation_setting_overrides where operation_scope = p_operation_scope
  )
  select jsonb_build_object(
    'operation_scope', p_operation_scope,
    'public_name', coalesce(s.public_name, b.operation_name),
    'public_email', s.public_email,
    'public_phone', s.public_phone,
    'public_address', s.public_address,
    'public_site_url', s.public_site_url,
    'timezone', coalesce(s.timezone, b.timezone),
    'default_currency', coalesce(s.default_currency, b.default_currency),
    'checkout_hold_minutes', coalesce(s.checkout_hold_minutes, b.checkout_hold_minutes),
    'payment_hold_minutes', coalesce(s.payment_hold_minutes, b.payment_hold_minutes),
    'agency_hold_minutes', coalesce(s.agency_hold_minutes, b.agency_hold_minutes),
    'default_confirmation_percentage', coalesce(s.default_confirmation_percentage, b.default_confirmation_percentage),
    'pix_discount_percent', coalesce(s.pix_discount_percent, b.pix_discount_percent),
    'default_slot_interval_minutes', coalesce(s.default_slot_interval_minutes, b.default_slot_interval_minutes),
    'source', jsonb_build_object(
      'base', 'operation_settings:1',
      'override_present', s.operation_scope is not null
    )
  )
  from base b
  left join scoped s on true
  where p_operation_scope in ('SABRINA','BLACKSHEEP');
$$;

revoke all on function public.service_admin_get_operation_settings_v2(text) from public, anon, authenticated;
grant execute on function public.service_admin_get_operation_settings_v2(text) to service_role;

comment on table public.operation_setting_overrides is
  'Per-operation overrides layered over legacy singleton operation_settings. Null means inherit the global value.';
comment on function public.service_admin_get_operation_settings_v2(text) is
  'Resolved settings read model with precedence global operation_settings -> operation scope override.';
-- END RC MIGRATION 20260826123000_operation_settings_scope_foundation.sql

-- BEGIN RC MIGRATION 20260826140000_operation_settings_audited_mutation.sql
-- Issue #218 phase 2: audited per-operation settings mutation.
-- Keep legacy operation_settings untouched. This RPC updates only scoped overrides,
-- enforces existing admin permissions, and records before/after resolved settings.

alter table public.operation_setting_overrides
  add column if not exists id uuid not null default gen_random_uuid();

create unique index if not exists operation_setting_overrides_id_key
  on public.operation_setting_overrides(id);

create or replace function public.service_admin_update_operation_settings_v2(
  p_operation_scope text,
  p_patch jsonb,
  p_actor_admin_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_before jsonb;
  v_after jsonb;
  v_existing public.operation_setting_overrides%rowtype;
  v_row public.operation_setting_overrides%rowtype;
  v_entity_id uuid;
  v_allowed_keys constant text[] := array[
    'public_name','public_email','public_phone','public_address','public_site_url',
    'timezone','default_currency','checkout_hold_minutes','payment_hold_minutes',
    'agency_hold_minutes','default_confirmation_percentage','pix_discount_percent',
    'default_slot_interval_minutes'
  ];
begin
  if p_operation_scope not in ('SABRINA','BLACKSHEEP') then
    raise exception using errcode='P0001', message='OPERATION_SCOPE_INVALID';
  end if;

  if p_patch is null or jsonb_typeof(p_patch) <> 'object' or p_patch = '{}'::jsonb then
    raise exception using errcode='P0001', message='OPERATION_SETTINGS_PATCH_INVALID';
  end if;

  if exists (
    select 1
    from jsonb_object_keys(p_patch) as k(key)
    where not (k.key = any(v_allowed_keys))
  ) then
    raise exception using errcode='P0001', message='OPERATION_SETTINGS_PATCH_KEY_INVALID';
  end if;

  if not public.service_admin_has_permission(p_actor_admin_id,'SERVICES_MANAGE') then
    raise exception using errcode='P0001', message='ADMIN_PERMISSION_DENIED';
  end if;

  if p_patch ? 'pix_discount_percent'
     and not public.service_admin_has_permission(p_actor_admin_id,'FINANCE_MANAGE') then
    raise exception using errcode='P0001', message='ADMIN_FINANCE_PERMISSION_REQUIRED';
  end if;

  if exists (
    select 1
    from jsonb_each(p_patch) as e(key,value)
    where e.key = any(array['public_name','public_email','public_phone','public_address','public_site_url','timezone','default_currency'])
      and jsonb_typeof(e.value) not in ('string','null')
  ) then
    raise exception using errcode='P0001', message='OPERATION_SETTINGS_TEXT_VALUE_INVALID';
  end if;

  if exists (
    select 1
    from jsonb_each(p_patch) as e(key,value)
    where e.key = any(array['checkout_hold_minutes','payment_hold_minutes','agency_hold_minutes','default_confirmation_percentage','pix_discount_percent','default_slot_interval_minutes'])
      and jsonb_typeof(e.value) not in ('number','null')
  ) then
    raise exception using errcode='P0001', message='OPERATION_SETTINGS_NUMERIC_VALUE_INVALID';
  end if;

  v_before := public.service_admin_get_operation_settings_v2(p_operation_scope);
  select * into v_existing
  from public.operation_setting_overrides
  where operation_scope=p_operation_scope
  for update;

  insert into public.operation_setting_overrides(
    operation_scope,
    public_name,public_email,public_phone,public_address,public_site_url,
    timezone,default_currency,checkout_hold_minutes,payment_hold_minutes,
    agency_hold_minutes,default_confirmation_percentage,pix_discount_percent,
    default_slot_interval_minutes,updated_at
  ) values (
    p_operation_scope,
    case when p_patch ? 'public_name' then p_patch->>'public_name' else v_existing.public_name end,
    case when p_patch ? 'public_email' then p_patch->>'public_email' else v_existing.public_email end,
    case when p_patch ? 'public_phone' then p_patch->>'public_phone' else v_existing.public_phone end,
    case when p_patch ? 'public_address' then p_patch->>'public_address' else v_existing.public_address end,
    case when p_patch ? 'public_site_url' then p_patch->>'public_site_url' else v_existing.public_site_url end,
    case when p_patch ? 'timezone' then p_patch->>'timezone' else v_existing.timezone end,
    case when p_patch ? 'default_currency' then p_patch->>'default_currency' else v_existing.default_currency end,
    case when p_patch ? 'checkout_hold_minutes' then (p_patch->>'checkout_hold_minutes')::integer else v_existing.checkout_hold_minutes end,
    case when p_patch ? 'payment_hold_minutes' then (p_patch->>'payment_hold_minutes')::integer else v_existing.payment_hold_minutes end,
    case when p_patch ? 'agency_hold_minutes' then (p_patch->>'agency_hold_minutes')::integer else v_existing.agency_hold_minutes end,
    case when p_patch ? 'default_confirmation_percentage' then (p_patch->>'default_confirmation_percentage')::numeric else v_existing.default_confirmation_percentage end,
    case when p_patch ? 'pix_discount_percent' then (p_patch->>'pix_discount_percent')::numeric else v_existing.pix_discount_percent end,
    case when p_patch ? 'default_slot_interval_minutes' then (p_patch->>'default_slot_interval_minutes')::integer else v_existing.default_slot_interval_minutes end,
    now()
  )
  on conflict(operation_scope) do update set
    public_name=excluded.public_name,
    public_email=excluded.public_email,
    public_phone=excluded.public_phone,
    public_address=excluded.public_address,
    public_site_url=excluded.public_site_url,
    timezone=excluded.timezone,
    default_currency=excluded.default_currency,
    checkout_hold_minutes=excluded.checkout_hold_minutes,
    payment_hold_minutes=excluded.payment_hold_minutes,
    agency_hold_minutes=excluded.agency_hold_minutes,
    default_confirmation_percentage=excluded.default_confirmation_percentage,
    pix_discount_percent=excluded.pix_discount_percent,
    default_slot_interval_minutes=excluded.default_slot_interval_minutes,
    updated_at=now()
  returning * into v_row;

  v_entity_id := v_row.id;

  if v_row.public_name is null
     and v_row.public_email is null
     and v_row.public_phone is null
     and v_row.public_address is null
     and v_row.public_site_url is null
     and v_row.timezone is null
     and v_row.default_currency is null
     and v_row.checkout_hold_minutes is null
     and v_row.payment_hold_minutes is null
     and v_row.agency_hold_minutes is null
     and v_row.default_confirmation_percentage is null
     and v_row.pix_discount_percent is null
     and v_row.default_slot_interval_minutes is null then
    delete from public.operation_setting_overrides where operation_scope=p_operation_scope;
  end if;

  v_after := public.service_admin_get_operation_settings_v2(p_operation_scope);

  if v_before is distinct from v_after then
    insert into public.audit_logs(
      admin_user_id,entity_type,entity_id,action,before_json,after_json,origin
    ) values (
      p_actor_admin_id,'OPERATION_SETTINGS',v_entity_id,'OPERATION_SETTINGS_CHANGED',
      v_before,v_after,'ADMIN'
    );
  end if;

  return v_after;
end;
$$;

revoke all on function public.service_admin_update_operation_settings_v2(text,jsonb,uuid)
  from public, anon, authenticated;
grant execute on function public.service_admin_update_operation_settings_v2(text,jsonb,uuid)
  to service_role;

comment on function public.service_admin_update_operation_settings_v2(text,jsonb,uuid) is
  'Audited scoped settings mutation. Requires SERVICES_MANAGE; PIX discount additionally requires FINANCE_MANAGE. Null resets a field to global inheritance.';
-- END RC MIGRATION 20260826140000_operation_settings_audited_mutation.sql

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
