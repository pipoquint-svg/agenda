
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
