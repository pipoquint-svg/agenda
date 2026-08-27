
-- BEGIN RC MIGRATION 20260825154800_remove_kommo_guard_drift.sql
-- Remove the isolated Kommo Guard drift from Agenda databases.
--
-- Safety contract:
-- - fresh/rebuilt databases where the drift never existed: no-op;
-- - drifted sandbox: only remove the exact audited object set;
-- - abort if inventory, row counts, or cross-subsystem foreign keys differ;
-- - no CASCADE.

DO $$
DECLARE
  v_tables text[];
  v_external_fk_count integer;
  v_function_count integer;
BEGIN
  SELECT coalesce(array_agg(table_name ORDER BY table_name), ARRAY[]::text[])
    INTO v_tables
  FROM information_schema.tables
  WHERE table_schema = 'public'
    AND table_name LIKE 'kommo_guard_%';

  SELECT count(*)
    INTO v_function_count
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'kommo_guard_adjust_due';

  -- Authoritative clean rebuilds have neither the drift tables nor helper.
  IF cardinality(v_tables) = 0 AND v_function_count = 0 THEN
    RETURN;
  END IF;

  IF v_tables <> ARRAY[
    'kommo_guard_audit_log',
    'kommo_guard_discovery_cache',
    'kommo_guard_lead_state',
    'kommo_guard_outgoing_messages',
    'kommo_guard_reconciliation_runs',
    'kommo_guard_rules',
    'kommo_guard_schedules',
    'kommo_guard_settings',
    'kommo_guard_talks',
    'kommo_guard_webhook_inbox'
  ]::text[] THEN
    RAISE EXCEPTION 'KOMMO_GUARD_CLEANUP_INVENTORY_MISMATCH: %', v_tables;
  END IF;

  IF v_function_count <> 1 THEN
    RAISE EXCEPTION 'KOMMO_GUARD_CLEANUP_FUNCTION_INVENTORY_MISMATCH: %', v_function_count;
  END IF;

  -- Refuse cleanup if any FK crosses the Kommo Guard boundary.
  SELECT count(*)
    INTO v_external_fk_count
  FROM pg_constraint con
  JOIN pg_class child ON child.oid = con.conrelid
  JOIN pg_namespace child_ns ON child_ns.oid = child.relnamespace
  JOIN pg_class parent ON parent.oid = con.confrelid
  JOIN pg_namespace parent_ns ON parent_ns.oid = parent.relnamespace
  WHERE con.contype = 'f'
    AND child_ns.nspname = 'public'
    AND parent_ns.nspname = 'public'
    AND ((child.relname LIKE 'kommo_guard_%') <> (parent.relname LIKE 'kommo_guard_%'));

  IF v_external_fk_count <> 0 THEN
    RAISE EXCEPTION 'KOMMO_GUARD_CLEANUP_EXTERNAL_FK_DEPENDENCY: %', v_external_fk_count;
  END IF;

  -- The sanitized snapshot in docs/qa/kommo-guard/ is authoritative for the
  -- only persisted drift data. Abort rather than discard anything newer.
  IF (SELECT count(*) FROM public.kommo_guard_audit_log) <> 0
     OR (SELECT count(*) FROM public.kommo_guard_lead_state) <> 0
     OR (SELECT count(*) FROM public.kommo_guard_outgoing_messages) <> 0
     OR (SELECT count(*) FROM public.kommo_guard_reconciliation_runs) <> 0
     OR (SELECT count(*) FROM public.kommo_guard_schedules) <> 0
     OR (SELECT count(*) FROM public.kommo_guard_talks) <> 0
     OR (SELECT count(*) FROM public.kommo_guard_webhook_inbox) <> 0
     OR (SELECT count(*) FROM public.kommo_guard_discovery_cache) <> 1
     OR (SELECT count(*) FROM public.kommo_guard_rules) <> 18
     OR (SELECT count(*) FROM public.kommo_guard_settings) <> 1 THEN
    RAISE EXCEPTION 'KOMMO_GUARD_CLEANUP_DATA_DRIFT_DETECTED';
  END IF;
END
$$;

-- Drop the only helper before its settings table. Exact signature, no CASCADE.
DROP FUNCTION IF EXISTS public.kommo_guard_adjust_due(timestamptz);

-- Child tables before referenced parents; every drop is explicit and non-CASCADE.
DROP TABLE IF EXISTS public.kommo_guard_audit_log;
DROP TABLE IF EXISTS public.kommo_guard_outgoing_messages;
DROP TABLE IF EXISTS public.kommo_guard_schedules;
DROP TABLE IF EXISTS public.kommo_guard_rules;
DROP TABLE IF EXISTS public.kommo_guard_discovery_cache;
DROP TABLE IF EXISTS public.kommo_guard_lead_state;
DROP TABLE IF EXISTS public.kommo_guard_reconciliation_runs;
DROP TABLE IF EXISTS public.kommo_guard_talks;
DROP TABLE IF EXISTS public.kommo_guard_webhook_inbox;
DROP TABLE IF EXISTS public.kommo_guard_settings;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name LIKE 'kommo_guard_%'
  ) OR EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname LIKE 'kommo_guard_%'
  ) THEN
    RAISE EXCEPTION 'KOMMO_GUARD_CLEANUP_INCOMPLETE';
  END IF;
END
$$;
-- END RC MIGRATION 20260825154800_remove_kommo_guard_drift.sql

-- BEGIN RC MIGRATION 20260825180000_google_sync_fail_closed.sql
-- Google Calendar is authoritative for external busy blocks only when its mirror is
-- verifiably fresh. The integration worker reconciles every five minutes; allow two
-- worker cycles (10 minutes) before failing closed to absorb one delayed runner while
-- preventing bookings against an unverifiable Google state.

create or replace function public.google_resource_sync_is_ready(
  p_resource_id uuid,
  p_max_age_seconds integer default 600
)
returns boolean
language sql
stable
set search_path = public
as $$
  select not exists (
    select 1
    from public.google_calendar_resources gcr
    join public.google_calendars gc on gc.id = gcr.google_calendar_id
    join public.google_connections gconn on gconn.id = gc.google_connection_id
    where gcr.resource_id = p_resource_id
      and gc.is_active
      and (
        gconn.status <> 'ACTIVE'
        or not public.google_sync_is_fresh(gc.id, p_max_age_seconds)
      )
  );
$$;

comment on function public.google_resource_sync_is_ready(uuid,integer) is
  'Fail-closed Google health gate for booking resources. Mapped active calendars must have ACTIVE connection and HEALTHY sync fresher than the supplied threshold; resources without Google mappings remain available.';

revoke all on function public.google_resource_sync_is_ready(uuid,integer) from public, anon, authenticated;
grant execute on function public.google_resource_sync_is_ready(uuid,integer) to service_role;

-- Preserve the mature slot engines and wrap them with one health filter instead of
-- duplicating their scheduling rules. Existing PL/pgSQL callers resolve the original
-- function name at execution time and therefore receive the health-gated wrapper.
alter function public.list_available_slots(uuid,uuid,jsonb,integer,date,text)
  rename to list_available_slots_without_google_sync_gate;

create function public.list_available_slots(
  p_service_id uuid,
  p_service_employee_id uuid,
  p_extra_selections jsonb default '[]'::jsonb,
  p_people_count integer default 1,
  p_local_date date default current_date,
  p_coupon_code text default null
)
returns table(
  slot_start_at timestamptz,
  slot_end_at timestamptz,
  core_start_at timestamptz,
  core_end_at timestamptz,
  pre_service_minutes integer,
  post_service_minutes integer,
  duration_minutes integer,
  commercial_value numeric
)
language sql
stable
set search_path = public, extensions
as $$
  select s.*
  from public.list_available_slots_without_google_sync_gate(
    p_service_id,
    p_service_employee_id,
    p_extra_selections,
    p_people_count,
    p_local_date,
    p_coupon_code
  ) s
  where not exists (
    select 1
    from public.calculate_booking_resource_ranges(
      p_service_id,
      p_extra_selections,
      s.core_start_at
    ) r
    where not public.google_resource_sync_is_ready(r.resource_id, 600)
  );
$$;

-- PostgreSQL grants EXECUTE on newly created functions to PUBLIC by default. Keep the
-- core availability engine private exactly as before this wrapper was introduced;
-- public traffic must continue through page-scoped booking RPCs only.
revoke all on function public.list_available_slots(uuid,uuid,jsonb,integer,date,text)
  from public, anon, authenticated;
grant execute on function public.list_available_slots(uuid,uuid,jsonb,integer,date,text)
  to service_role;

alter function public.list_available_slots_for_duration(uuid,uuid,integer,jsonb,integer,date,text)
  rename to list_available_slots_for_duration_without_google_sync_gate;

create function public.list_available_slots_for_duration(
  p_service_id uuid,
  p_service_employee_id uuid,
  p_duration_blocks integer default null,
  p_extra_selections jsonb default '[]'::jsonb,
  p_people_count integer default 1,
  p_local_date date default current_date,
  p_coupon_code text default null
)
returns table(
  slot_start_at timestamptz,
  slot_end_at timestamptz,
  core_start_at timestamptz,
  core_end_at timestamptz,
  pre_service_minutes integer,
  post_service_minutes integer,
  duration_minutes integer,
  commercial_value numeric
)
language sql
stable
set search_path = public, extensions
as $$
  select s.*
  from public.list_available_slots_for_duration_without_google_sync_gate(
    p_service_id,
    p_service_employee_id,
    p_duration_blocks,
    p_extra_selections,
    p_people_count,
    p_local_date,
    p_coupon_code
  ) s
  where not exists (
    select 1
    from public.calculate_booking_resource_ranges_for_duration(
      p_service_id,
      p_extra_selections,
      s.core_start_at,
      p_duration_blocks
    ) r
    where not public.google_resource_sync_is_ready(r.resource_id, 600)
  );
$$;

-- The duration core is likewise an internal scheduling primitive. Duration-specific
-- public APIs already expose their own page-scoped wrappers and must not inherit the
-- default PUBLIC grant from this re-creation.
revoke all on function public.list_available_slots_for_duration(uuid,uuid,integer,jsonb,integer,date,text)
  from public, anon, authenticated;
grant execute on function public.list_available_slots_for_duration(uuid,uuid,integer,jsonb,integer,date,text)
  to service_role;

-- Defense in depth: even a caller that bypasses the slot-listing wrappers cannot
-- create a fresh checkout/pre-reservation allocation while Google state is stale.
-- APPOINTMENT promotion is intentionally excluded: a previously acquired safe hold
-- must still be allowed to complete payment/confirmation if Google becomes stale
-- after the hold was obtained.
create or replace function public.enforce_google_sync_ready_for_new_hold_allocation()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.allocation_type in ('CHECKOUT_HOLD', 'PRE_RESERVATION')
     and new.status in ('HELD', 'AWAITING_PAYMENT', 'BLOCKED')
     and not public.google_resource_sync_is_ready(new.resource_id, 600)
  then
    raise exception using errcode = 'P0001', message = 'GOOGLE_SYNC_NOT_FRESH';
  end if;
  return new;
end;
$$;

revoke all on function public.enforce_google_sync_ready_for_new_hold_allocation() from public, anon, authenticated;

drop trigger if exists resource_allocations_google_sync_health_guard on public.resource_allocations;
create trigger resource_allocations_google_sync_health_guard
before insert on public.resource_allocations
for each row execute function public.enforce_google_sync_ready_for_new_hold_allocation();
-- END RC MIGRATION 20260825180000_google_sync_fail_closed.sql

-- BEGIN RC MIGRATION 20260825183000_google_admin_mapping.sql
create or replace function public.service_admin_add_google_calendar_resource_mapping(
  p_google_calendar_id uuid,
  p_resource_id uuid,
  p_admin_user_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_calendar record;
  v_resource public.resources%rowtype;
  v_exists boolean;
begin
  select gc.id, gc.name, gc.access_role, gc.is_active, gconn.status as connection_status
  into v_calendar
  from public.google_calendars gc
  join public.google_connections gconn on gconn.id = gc.google_connection_id
  where gc.id = p_google_calendar_id
  for update of gc;

  if not found or not v_calendar.is_active then
    raise exception using errcode = 'P0001', message = 'GOOGLE_CALENDAR_NOT_ACTIVE';
  end if;
  if v_calendar.connection_status <> 'ACTIVE' then
    raise exception using errcode = 'P0001', message = 'GOOGLE_CONNECTION_NOT_ACTIVE';
  end if;
  if coalesce(v_calendar.access_role, '') not in ('writer', 'owner') then
    raise exception using errcode = 'P0001', message = 'GOOGLE_CALENDAR_WRITE_ACCESS_REQUIRED';
  end if;

  select * into v_resource
  from public.resources
  where id = p_resource_id
    and is_active
  for update;
  if not found then
    raise exception using errcode = 'P0001', message = 'RESOURCE_NOT_ACTIVE';
  end if;

  select exists(
    select 1 from public.google_calendar_resources
    where google_calendar_id = p_google_calendar_id
      and resource_id = p_resource_id
  ) into v_exists;

  insert into public.google_calendar_resources (google_calendar_id, resource_id)
  values (p_google_calendar_id, p_resource_id)
  on conflict do nothing;

  insert into public.audit_logs (
    admin_user_id, entity_type, entity_id, action, before_json, after_json, origin
  ) values (
    p_admin_user_id,
    'RESOURCE',
    p_resource_id,
    case when v_exists then 'GOOGLE_CALENDAR_RESOURCE_MAPPING_RECONFIRMED' else 'GOOGLE_CALENDAR_RESOURCE_MAPPED' end,
    jsonb_build_object('mapped', v_exists),
    jsonb_build_object(
      'mapped', true,
      'google_calendar_id', p_google_calendar_id,
      'calendar_name', v_calendar.name,
      'resource_name', v_resource.name
    ),
    'ADMIN'
  );

  return jsonb_build_object(
    'google_calendar_id', p_google_calendar_id,
    'resource_id', p_resource_id,
    'mapped', true,
    'already_mapped', v_exists
  );
end;
$$;

revoke all on function public.service_admin_add_google_calendar_resource_mapping(uuid,uuid,uuid) from public, anon, authenticated;
grant execute on function public.service_admin_add_google_calendar_resource_mapping(uuid,uuid,uuid) to service_role;

create or replace function public.service_admin_remove_google_calendar_resource_mapping(
  p_google_calendar_id uuid,
  p_resource_id uuid,
  p_admin_user_id uuid,
  p_reason text default 'ADMIN_UNMAP'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_calendar_name text;
  v_resource_name text;
  v_released integer := 0;
  v_deleted integer := 0;
begin
  if coalesce(btrim(p_reason), '') = '' then
    raise exception using errcode = 'P0001', message = 'UNMAP_REASON_REQUIRED';
  end if;

  select name into v_calendar_name
  from public.google_calendars
  where id = p_google_calendar_id;
  select name into v_resource_name
  from public.resources
  where id = p_resource_id;

  update public.resource_allocations ra
  set status = 'RELEASED',
      updated_at = now()
  where ra.resource_id = p_resource_id
    and ra.allocation_type = 'EXTERNAL_BLOCK'
    and ra.status in ('EXTERNAL_ACTIVE', 'IGNORED_BY_ADMIN')
    and exists (
      select 1
      from public.google_calendar_events gce
      where gce.id = ra.google_calendar_event_id
        and gce.google_calendar_id = p_google_calendar_id
    );
  get diagnostics v_released = row_count;

  update public.schedule_divergences sd
  set status = 'RESOLVED',
      resolved_at = now(),
      resolution_notes = coalesce(sd.resolution_notes || E'\n', '') || 'Google calendar resource mapping removed by admin.',
      updated_at = now()
  where sd.resource_id = p_resource_id
    and sd.status = 'OPEN'
    and exists (
      select 1
      from public.google_calendar_events gce
      where gce.id = sd.google_calendar_event_id
        and gce.google_calendar_id = p_google_calendar_id
    );

  delete from public.google_calendar_resources
  where google_calendar_id = p_google_calendar_id
    and resource_id = p_resource_id;
  get diagnostics v_deleted = row_count;

  insert into public.audit_logs (
    admin_user_id, entity_type, entity_id, action, before_json, after_json, origin
  ) values (
    p_admin_user_id,
    'RESOURCE',
    p_resource_id,
    'GOOGLE_CALENDAR_RESOURCE_UNMAPPED',
    jsonb_build_object(
      'mapped', v_deleted > 0,
      'google_calendar_id', p_google_calendar_id,
      'calendar_name', v_calendar_name,
      'resource_name', v_resource_name
    ),
    jsonb_build_object('mapped', false, 'released_external_blocks', v_released, 'reason', p_reason),
    'ADMIN'
  );

  return jsonb_build_object(
    'google_calendar_id', p_google_calendar_id,
    'resource_id', p_resource_id,
    'mapped', false,
    'mapping_removed', v_deleted > 0,
    'released_external_blocks', v_released
  );
end;
$$;

revoke all on function public.service_admin_remove_google_calendar_resource_mapping(uuid,uuid,uuid,text) from public, anon, authenticated;
grant execute on function public.service_admin_remove_google_calendar_resource_mapping(uuid,uuid,uuid,text) to service_role;
-- END RC MIGRATION 20260825183000_google_admin_mapping.sql

-- BEGIN RC MIGRATION 20260825205500_amelia_legacy_import_foundation.sql
create table if not exists public.legacy_import_batches (
  id uuid primary key default gen_random_uuid(),
  source text not null,
  source_label text,
  customer_rows integer not null default 0 check (customer_rows >= 0),
  appointment_rows integer not null default 0 check (appointment_rows >= 0),
  source_fingerprint text,
  status text not null default 'PREPARED' check (status in ('PREPARED','IMPORTED','PARTIAL','FAILED')),
  notes text,
  created_at timestamptz not null default now(),
  completed_at timestamptz
);

create unique index if not exists legacy_import_batches_source_fingerprint_uidx
  on public.legacy_import_batches(source, source_fingerprint)
  where source_fingerprint is not null;

create table if not exists public.legacy_customer_sources (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references public.legacy_import_batches(id) on delete restrict,
  source text not null,
  source_key text not null,
  source_row_number integer,
  customer_id uuid references public.customers(id) on delete set null,
  match_method text not null default 'UNMATCHED' check (match_method in ('EMAIL','PHONE','EMAIL_PHONE','CREATED','MANUAL','UNMATCHED','CONFLICT')),
  match_confidence text not null default 'NONE' check (match_confidence in ('HIGH','MEDIUM','LOW','NONE')),
  conflict_code text,
  raw_snapshot jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (source, source_key)
);

create index if not exists legacy_customer_sources_customer_idx
  on public.legacy_customer_sources(customer_id);

create table if not exists public.legacy_appointments (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references public.legacy_import_batches(id) on delete restrict,
  source text not null,
  source_appointment_id text not null,
  legacy_customer_source_id uuid references public.legacy_customer_sources(id) on delete set null,
  customer_id uuid references public.customers(id) on delete set null,
  source_order_id text,
  service_name text,
  starts_at timestamptz,
  ends_at timestamptz,
  duration_minutes integer check (duration_minutes is null or duration_minutes >= 0),
  appointment_status text,
  payment_status text,
  payment_method text,
  total_amount numeric(12,2),
  paid_amount numeric(12,2),
  financially_actionable boolean not null default false,
  reviewed_for_collection boolean not null default false,
  review_notes text,
  raw_payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (source, source_appointment_id),
  check (not financially_actionable or reviewed_for_collection)
);

create index if not exists legacy_appointments_customer_idx
  on public.legacy_appointments(customer_id);
create index if not exists legacy_appointments_starts_at_idx
  on public.legacy_appointments(starts_at);
create index if not exists legacy_appointments_order_idx
  on public.legacy_appointments(source_order_id)
  where source_order_id is not null;

alter table public.legacy_import_batches enable row level security;
alter table public.legacy_customer_sources enable row level security;
alter table public.legacy_appointments enable row level security;

revoke all on public.legacy_import_batches from anon, authenticated;
revoke all on public.legacy_customer_sources from anon, authenticated;
revoke all on public.legacy_appointments from anon, authenticated;

grant all on public.legacy_import_batches to service_role;
grant all on public.legacy_customer_sources to service_role;
grant all on public.legacy_appointments to service_role;

comment on table public.legacy_appointments is
  'Read-only historical appointments imported from legacy systems. Financial data is non-actionable unless explicitly reviewed.';
comment on column public.legacy_appointments.financially_actionable is
  'Must remain false for bulk legacy imports. May only become true after explicit operational review.';
-- END RC MIGRATION 20260825205500_amelia_legacy_import_foundation.sql

-- BEGIN RC MIGRATION 20260825211500_service_crud_custom_fields.sql
-- Service catalog management by operation, without category as an admin concept.
-- Keeps category_id only as legacy compatibility while all new admin writes are operation-scoped.

alter table public.service_fields drop constraint if exists service_fields_field_type_check;
alter table public.service_fields add constraint service_fields_field_type_check
  check (field_type in ('TEXT','TEXTAREA','NUMBER','DATE','SELECT','MULTISELECT','BOOLEAN'));

create or replace function public.service_admin_list_service_settings()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
select coalesce(jsonb_agg(jsonb_build_object(
  'id', s.id,
  'name', s.name,
  'slug', s.slug,
  'short_description', s.short_description,
  'full_description', s.full_description,
  'operation_scope', s.operation_scope,
  'is_active', s.is_active,
  'sort_order', s.sort_order,
  'duration_mode', s.duration_mode,
  'base_duration_minutes', s.base_duration_minutes,
  'booking_block_minutes', s.booking_block_minutes,
  'minimum_booking_blocks', s.minimum_booking_blocks,
  'maximum_booking_blocks', s.maximum_booking_blocks,
  'price_per_block', s.price_per_block,
  'base_price', s.base_price,
  'buffer_before_minutes', s.buffer_before_minutes,
  'buffer_after_minutes', s.buffer_after_minutes,
  'custom_fields', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', f.id,
      'field_key', f.field_key,
      'label', f.label,
      'field_type', f.field_type,
      'help_text', f.help_text,
      'placeholder', f.placeholder,
      'is_required', f.is_required,
      'sort_order', f.sort_order,
      'options_json', f.options_json,
      'is_active', f.is_active
    ) order by f.sort_order, f.label, f.id)
    from public.service_fields f
    where f.service_id = s.id
  ), '[]'::jsonb),
  'pricing_tiers', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', t.id,
      'min_blocks', t.min_blocks,
      'max_blocks', t.max_blocks,
      'price_per_block', t.price_per_block,
      'is_active', t.is_active,
      'sort_order', t.sort_order
    ) order by t.sort_order, t.min_blocks, t.id)
    from public.service_duration_pricing_tiers t where t.service_id = s.id
  ), '[]'::jsonb),
  'duration_presets', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', p.id,
      'block_count', p.block_count,
      'title', p.title,
      'description', p.description,
      'badge', p.badge,
      'is_featured', p.is_featured,
      'is_active', p.is_active,
      'sort_order', p.sort_order
    ) order by p.sort_order, p.block_count, p.id)
    from public.service_duration_presets p where p.service_id = s.id
  ), '[]'::jsonb),
  'change_policy', (
    select to_jsonb(cp) - 'service_id' - 'created_at' - 'updated_at'
    from public.service_change_policies cp where cp.service_id = s.id
  )
) order by case s.operation_scope when 'SABRINA' then 0 when 'BLACKSHEEP' then 1 else 2 end, s.sort_order, s.name), '[]'::jsonb)
from public.services s;
$$;

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
    p_base_duration_minutes,p_buffer_before_minutes,p_buffer_after_minutes,p_base_price,true,
    coalesce((select max(sort_order)+10 from public.services where operation_scope=v_scope),0),
    v_mode,v_scope
  ) returning id into v_id;

  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
  values(p_admin_id,'SERVICE',v_id,'SERVICE_CREATED',null,public.service_admin_service_snapshot(v_id),'ADMIN');
  return public.service_admin_service_snapshot(v_id);
end;
$$;

create or replace function public.service_admin_update_catalog_audited(
  p_service_id uuid,
  p_name text,
  p_slug text,
  p_operation_scope text,
  p_short_description text,
  p_full_description text,
  p_is_active boolean,
  p_sort_order integer,
  p_admin_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_before jsonb;
  v_after jsonb;
  v_scope text := upper(btrim(coalesce(p_operation_scope,'')));
begin
  if not public.service_admin_has_permission(p_admin_id, 'SERVICES_MANAGE') then
    raise exception using errcode='P0001', message='ADMIN_PERMISSION_DENIED';
  end if;
  if v_scope not in ('SABRINA','BLACKSHEEP') then raise exception using errcode='P0001', message='SERVICE_OPERATION_SCOPE_INVALID'; end if;
  if nullif(btrim(p_name),'') is null then raise exception using errcode='P0001', message='SERVICE_NAME_REQUIRED'; end if;
  if nullif(btrim(p_slug),'') is null or p_slug !~ '^[a-z0-9]+(?:-[a-z0-9]+)*$' then raise exception using errcode='P0001', message='SERVICE_SLUG_INVALID'; end if;

  v_before := public.service_admin_service_snapshot(p_service_id);
  if v_before is null then raise exception using errcode='P0001', message='SERVICE_NOT_FOUND'; end if;

  update public.services set
    name=btrim(p_name),slug=btrim(p_slug),operation_scope=v_scope,
    short_description=nullif(btrim(p_short_description),''),full_description=nullif(btrim(p_full_description),''),
    is_active=coalesce(p_is_active,true),sort_order=coalesce(p_sort_order,0),updated_at=now()
  where id=p_service_id;

  v_after := public.service_admin_service_snapshot(p_service_id);
  if v_before is distinct from v_after then
    insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
    values(p_admin_id,'SERVICE',p_service_id,'SERVICE_CATALOG_UPDATED',v_before,v_after,'ADMIN');
  end if;
  return v_after;
end;
$$;

create or replace function public.service_admin_remove_service_audited(p_service_id uuid,p_admin_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_before jsonb;
  v_has_history boolean;
begin
  if not public.service_admin_has_permission(p_admin_id, 'SERVICES_MANAGE') then
    raise exception using errcode='P0001', message='ADMIN_PERMISSION_DENIED';
  end if;
  v_before := public.service_admin_service_snapshot(p_service_id);
  if v_before is null then raise exception using errcode='P0001', message='SERVICE_NOT_FOUND'; end if;

  select exists(select 1 from public.appointments where service_id=p_service_id)
      or exists(select 1 from public.checkout_holds where service_id=p_service_id)
      or exists(select 1 from public.pre_reservations where service_id=p_service_id)
    into v_has_history;

  if v_has_history then
    update public.services set is_active=false,updated_at=now() where id=p_service_id;
    insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
    values(p_admin_id,'SERVICE',p_service_id,'SERVICE_ARCHIVED',v_before,public.service_admin_service_snapshot(p_service_id),'ADMIN');
    return jsonb_build_object('service_id',p_service_id,'removed',false,'archived',true);
  end if;

  delete from public.services where id=p_service_id;
  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
  values(p_admin_id,'SERVICE',p_service_id,'SERVICE_DELETED',v_before,null,'ADMIN');
  return jsonb_build_object('service_id',p_service_id,'removed',true,'archived',false);
end;
$$;

create or replace function public.service_admin_replace_custom_fields_audited(
  p_service_id uuid,
  p_fields jsonb,
  p_admin_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_before jsonb;
  v_after jsonb;
  v_field jsonb;
  v_type text;
  v_key text;
  v_index integer := 0;
begin
  if not public.service_admin_has_permission(p_admin_id, 'SERVICES_MANAGE') then
    raise exception using errcode='P0001', message='ADMIN_PERMISSION_DENIED';
  end if;
  if jsonb_typeof(coalesce(p_fields,'[]'::jsonb)) <> 'array' then raise exception using errcode='P0001', message='SERVICE_FIELDS_INVALID'; end if;
  v_before := public.service_admin_service_snapshot(p_service_id);
  if v_before is null then raise exception using errcode='P0001', message='SERVICE_NOT_FOUND'; end if;

  delete from public.service_fields where service_id=p_service_id;
  for v_field in select value from jsonb_array_elements(coalesce(p_fields,'[]'::jsonb)) loop
    v_key := lower(btrim(coalesce(v_field->>'field_key','')));
    v_type := upper(btrim(coalesce(v_field->>'field_type','')));
    if v_key !~ '^[a-z][a-z0-9_]{1,63}$' then raise exception using errcode='P0001', message='SERVICE_FIELD_KEY_INVALID'; end if;
    if nullif(btrim(v_field->>'label'),'') is null then raise exception using errcode='P0001', message='SERVICE_FIELD_LABEL_REQUIRED'; end if;
    if v_type not in ('TEXT','TEXTAREA','NUMBER','DATE','SELECT','MULTISELECT','BOOLEAN') then raise exception using errcode='P0001', message='SERVICE_FIELD_TYPE_INVALID'; end if;
    if v_type in ('SELECT','MULTISELECT') and jsonb_typeof(coalesce(v_field->'options_json','[]'::jsonb)) <> 'array' then raise exception using errcode='P0001', message='SERVICE_FIELD_OPTIONS_INVALID'; end if;

    insert into public.service_fields(service_id,field_key,label,field_type,help_text,placeholder,is_required,sort_order,options_json,is_active)
    values(
      p_service_id,v_key,btrim(v_field->>'label'),v_type,nullif(btrim(v_field->>'help_text'),''),nullif(btrim(v_field->>'placeholder'),''),
      coalesce((v_field->>'is_required')::boolean,false),coalesce((v_field->>'sort_order')::integer,v_index*10),
      case when v_type in ('SELECT','MULTISELECT') then coalesce(v_field->'options_json','[]'::jsonb) else null end,
      coalesce((v_field->>'is_active')::boolean,true)
    );
    v_index := v_index + 1;
  end loop;

  v_after := public.service_admin_service_snapshot(p_service_id);
  if v_before is distinct from v_after then
    insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
    values(p_admin_id,'SERVICE',p_service_id,'SERVICE_CUSTOM_FIELDS_UPDATED',v_before,v_after,'ADMIN');
  end if;
  return v_after;
end;
$$;

revoke all on function public.service_admin_create_service_audited(text,text,text,text,text,text,integer,numeric,integer,integer,uuid) from public,anon,authenticated;
revoke all on function public.service_admin_update_catalog_audited(uuid,text,text,text,text,text,boolean,integer,uuid) from public,anon,authenticated;
revoke all on function public.service_admin_remove_service_audited(uuid,uuid) from public,anon,authenticated;
revoke all on function public.service_admin_replace_custom_fields_audited(uuid,jsonb,uuid) from public,anon,authenticated;
grant execute on function public.service_admin_create_service_audited(text,text,text,text,text,text,integer,numeric,integer,integer,uuid) to service_role;
grant execute on function public.service_admin_update_catalog_audited(uuid,text,text,text,text,text,boolean,integer,uuid) to service_role;
grant execute on function public.service_admin_remove_service_audited(uuid,uuid) to service_role;
grant execute on function public.service_admin_replace_custom_fields_audited(uuid,jsonb,uuid) to service_role;
-- END RC MIGRATION 20260825211500_service_crud_custom_fields.sql

-- BEGIN RC MIGRATION 20260825213000_catalog_categories_pricing_extras.sql
-- Complete the administrative catalog: operation -> category -> service.
-- Categories remain first-class. Services expose people pricing, day/time rules and extras.

alter table public.categories
  add column if not exists operation_scope text;

alter table public.categories drop constraint if exists categories_operation_scope_check;
alter table public.categories add constraint categories_operation_scope_check
  check (operation_scope is null or operation_scope in ('SABRINA','BLACKSHEEP'));

alter table public.services
  add column if not exists price_per_extra_person numeric(12,2) not null default 0;

alter table public.services drop constraint if exists services_price_per_extra_person_check;
alter table public.services add constraint services_price_per_extra_person_check
  check (price_per_extra_person >= 0);

-- Safe backfill only when every classified service inside a category agrees on one operation.
update public.categories c
set operation_scope = x.operation_scope,
    updated_at = now()
from (
  select category_id, min(operation_scope) as operation_scope
  from public.services
  where category_id is not null and operation_scope is not null
  group by category_id
  having count(distinct operation_scope) = 1
) x
where c.id = x.category_id
  and c.operation_scope is null;

create or replace function public.enforce_service_category_operation()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_category_scope text;
begin
  if new.category_id is null then
    return new;
  end if;

  select operation_scope into v_category_scope
  from public.categories
  where id = new.category_id;

  if not found then
    raise exception using errcode='P0001', message='CATEGORY_NOT_FOUND';
  end if;
  if v_category_scope is null then
    raise exception using errcode='P0001', message='CATEGORY_OPERATION_SCOPE_REQUIRED';
  end if;
  if new.operation_scope is null or new.operation_scope <> v_category_scope then
    raise exception using errcode='P0001', message='SERVICE_CATEGORY_OPERATION_MISMATCH';
  end if;
  return new;
end;
$$;

drop trigger if exists services_category_operation_guard on public.services;
create trigger services_category_operation_guard
before insert or update of category_id, operation_scope on public.services
for each row execute function public.enforce_service_category_operation();

create or replace function public.enforce_category_operation_change()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if old.operation_scope is distinct from new.operation_scope
     and exists (
       select 1 from public.services s
       where s.category_id = new.id
         and s.operation_scope is distinct from new.operation_scope
     ) then
    raise exception using errcode='P0001', message='CATEGORY_OPERATION_HAS_CONFLICTING_SERVICES';
  end if;
  return new;
end;
$$;

drop trigger if exists categories_operation_guard on public.categories;
create trigger categories_operation_guard
before update of operation_scope on public.categories
for each row execute function public.enforce_category_operation_change();

create or replace function public.service_admin_list_categories()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', c.id,
    'name', c.name,
    'slug', c.slug,
    'operation_scope', c.operation_scope,
    'sort_order', c.sort_order,
    'is_active', c.is_active,
    'service_count', (select count(*) from public.services s where s.category_id=c.id)
  ) order by case c.operation_scope when 'SABRINA' then 0 when 'BLACKSHEEP' then 1 else 2 end, c.sort_order, c.name), '[]'::jsonb)
  from public.categories c;
$$;

create or replace function public.service_admin_list_extras()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', e.id,
    'name', e.name,
    'description', e.description,
    'price', e.price,
    'duration_delta_minutes', e.duration_delta_minutes,
    'is_active', e.is_active,
    'service_count', (select count(*) from public.service_extras se where se.extra_id=e.id)
  ) order by e.name, e.id), '[]'::jsonb)
  from public.extras e;
$$;

create or replace function public.service_admin_list_service_settings()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
select coalesce(jsonb_agg(jsonb_build_object(
  'id', s.id,
  'name', s.name,
  'slug', s.slug,
  'short_description', s.short_description,
  'full_description', s.full_description,
  'category_id', s.category_id,
  'category_name', c.name,
  'operation_scope', s.operation_scope,
  'is_active', s.is_active,
  'sort_order', s.sort_order,
  'duration_mode', s.duration_mode,
  'base_duration_minutes', s.base_duration_minutes,
  'booking_block_minutes', s.booking_block_minutes,
  'minimum_booking_blocks', s.minimum_booking_blocks,
  'maximum_booking_blocks', s.maximum_booking_blocks,
  'price_per_block', s.price_per_block,
  'base_price', s.base_price,
  'minimum_people', s.minimum_people,
  'maximum_people', s.maximum_people,
  'price_per_extra_person', s.price_per_extra_person,
  'buffer_before_minutes', s.buffer_before_minutes,
  'buffer_after_minutes', s.buffer_after_minutes,
  'custom_fields', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', f.id, 'field_key', f.field_key, 'label', f.label, 'field_type', f.field_type,
      'help_text', f.help_text, 'placeholder', f.placeholder, 'is_required', f.is_required,
      'sort_order', f.sort_order, 'options_json', f.options_json, 'is_active', f.is_active
    ) order by f.sort_order, f.label, f.id)
    from public.service_fields f where f.service_id=s.id
  ), '[]'::jsonb),
  'day_time_pricing_rules', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', pr.id, 'name', pr.name, 'days_of_week', pr.days_of_week,
      'start_local_time', pr.start_local_time, 'end_local_time', pr.end_local_time,
      'valid_from_date', pr.valid_from_date, 'valid_until_date', pr.valid_until_date,
      'action_type', pr.action_type, 'amount', pr.amount, 'percentage', pr.percentage,
      'priority', pr.priority, 'is_active', pr.is_active
    ) order by pr.priority, pr.id)
    from public.pricing_rules pr
    where pr.service_id=s.id and pr.rule_scope='DAY_TIME'
  ), '[]'::jsonb),
  'service_extras', coalesce((
    select jsonb_agg(jsonb_build_object(
      'extra_id', e.id, 'name', e.name, 'description', e.description, 'price', e.price,
      'duration_delta_minutes', e.duration_delta_minutes, 'is_active', e.is_active,
      'sort_order', se.sort_order, 'is_required', se.is_required, 'max_quantity', se.max_quantity,
      'schedule_placement', se.schedule_placement,
      'default_schedule_minutes', coalesce(se.default_schedule_minutes, e.duration_delta_minutes)
    ) order by se.sort_order, e.name, e.id)
    from public.service_extras se join public.extras e on e.id=se.extra_id
    where se.service_id=s.id
  ), '[]'::jsonb),
  'pricing_tiers', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', t.id, 'min_blocks', t.min_blocks, 'max_blocks', t.max_blocks,
      'price_per_block', t.price_per_block, 'is_active', t.is_active, 'sort_order', t.sort_order
    ) order by t.sort_order, t.min_blocks, t.id)
    from public.service_duration_pricing_tiers t where t.service_id=s.id
  ), '[]'::jsonb),
  'duration_presets', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', p.id, 'block_count', p.block_count, 'title', p.title, 'description', p.description,
      'badge', p.badge, 'is_featured', p.is_featured, 'is_active', p.is_active, 'sort_order', p.sort_order
    ) order by p.sort_order, p.block_count, p.id)
    from public.service_duration_presets p where p.service_id=s.id
  ), '[]'::jsonb),
  'change_policy', (
    select to_jsonb(cp)-'service_id'-'created_at'-'updated_at'
    from public.service_change_policies cp where cp.service_id=s.id
  )
) order by case s.operation_scope when 'SABRINA' then 0 when 'BLACKSHEEP' then 1 else 2 end,
           coalesce(c.sort_order, 2147483647), s.sort_order, s.name), '[]'::jsonb)
from public.services s
left join public.categories c on c.id=s.category_id;
$$;

create or replace function public.service_admin_create_category_audited(
  p_name text, p_slug text, p_operation_scope text, p_admin_id uuid
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
begin
  if not public.service_admin_has_permission(p_admin_id,'SERVICES_MANAGE') then
    raise exception using errcode='P0001', message='ADMIN_PERMISSION_DENIED';
  end if;
  if v_scope not in ('SABRINA','BLACKSHEEP') then raise exception using errcode='P0001', message='CATEGORY_OPERATION_SCOPE_INVALID'; end if;
  if nullif(btrim(p_name),'') is null then raise exception using errcode='P0001', message='CATEGORY_NAME_REQUIRED'; end if;
  if nullif(btrim(p_slug),'') is null or p_slug !~ '^[a-z0-9]+(?:-[a-z0-9]+)*$' then raise exception using errcode='P0001', message='CATEGORY_SLUG_INVALID'; end if;

  insert into public.categories(name,slug,operation_scope,sort_order,is_active)
  values(btrim(p_name),btrim(p_slug),v_scope,
    coalesce((select max(sort_order)+10 from public.categories where operation_scope=v_scope),0),true)
  returning id into v_id;

  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
  values(p_admin_id,'CATEGORY',v_id,'CATEGORY_CREATED',null,
    (select to_jsonb(c) from public.categories c where c.id=v_id),'ADMIN');

  return (select to_jsonb(c) from public.categories c where c.id=v_id);
end;
$$;

create or replace function public.service_admin_update_category_audited(
  p_category_id uuid, p_name text, p_slug text, p_operation_scope text,
  p_sort_order integer, p_is_active boolean, p_admin_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_before jsonb;
  v_after jsonb;
  v_scope text := upper(btrim(coalesce(p_operation_scope,'')));
begin
  if not public.service_admin_has_permission(p_admin_id,'SERVICES_MANAGE') then
    raise exception using errcode='P0001', message='ADMIN_PERMISSION_DENIED';
  end if;
  if v_scope not in ('SABRINA','BLACKSHEEP') then raise exception using errcode='P0001', message='CATEGORY_OPERATION_SCOPE_INVALID'; end if;
  if nullif(btrim(p_name),'') is null then raise exception using errcode='P0001', message='CATEGORY_NAME_REQUIRED'; end if;
  if nullif(btrim(p_slug),'') is null or p_slug !~ '^[a-z0-9]+(?:-[a-z0-9]+)*$' then raise exception using errcode='P0001', message='CATEGORY_SLUG_INVALID'; end if;

  select to_jsonb(c) into v_before from public.categories c where c.id=p_category_id for update;
  if v_before is null then raise exception using errcode='P0001', message='CATEGORY_NOT_FOUND'; end if;

  update public.categories set name=btrim(p_name),slug=btrim(p_slug),operation_scope=v_scope,
    sort_order=coalesce(p_sort_order,0),is_active=coalesce(p_is_active,true),updated_at=now()
  where id=p_category_id;
  select to_jsonb(c) into v_after from public.categories c where c.id=p_category_id;

  if v_before is distinct from v_after then
    insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
    values(p_admin_id,'CATEGORY',p_category_id,'CATEGORY_UPDATED',v_before,v_after,'ADMIN');
  end if;
  return v_after;
end;
$$;

create or replace function public.service_admin_remove_category_audited(p_category_id uuid,p_admin_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_before jsonb;
  v_has_services boolean;
begin
  if not public.service_admin_has_permission(p_admin_id,'SERVICES_MANAGE') then
    raise exception using errcode='P0001', message='ADMIN_PERMISSION_DENIED';
  end if;
  select to_jsonb(c) into v_before from public.categories c where c.id=p_category_id for update;
  if v_before is null then raise exception using errcode='P0001', message='CATEGORY_NOT_FOUND'; end if;
  select exists(select 1 from public.services where category_id=p_category_id) into v_has_services;
  if v_has_services then
    update public.categories set is_active=false,updated_at=now() where id=p_category_id;
    insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
    values(p_admin_id,'CATEGORY',p_category_id,'CATEGORY_ARCHIVED',v_before,
      (select to_jsonb(c) from public.categories c where c.id=p_category_id),'ADMIN');
    return jsonb_build_object('category_id',p_category_id,'removed',false,'archived',true);
  end if;
  delete from public.categories where id=p_category_id;
  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
  values(p_admin_id,'CATEGORY',p_category_id,'CATEGORY_DELETED',v_before,null,'ADMIN');
  return jsonb_build_object('category_id',p_category_id,'removed',true,'archived',false);
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
    p_price_per_extra_person,true,coalesce((select max(sort_order)+10 from public.services where category_id=p_category_id),0),v_mode,v_scope)
  returning id into v_id;

  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
  values(p_admin_id,'SERVICE',v_id,'SERVICE_CREATED',null,(select to_jsonb(s) from public.services s where s.id=v_id),'ADMIN');
  return (select to_jsonb(s) from public.services s where s.id=v_id);
end;
$$;

create or replace function public.service_admin_update_service_catalog_audited(
  p_service_id uuid, p_category_id uuid, p_name text, p_slug text, p_operation_scope text,
  p_short_description text, p_full_description text, p_minimum_people integer,
  p_maximum_people integer, p_price_per_extra_person numeric, p_is_active boolean,
  p_sort_order integer, p_admin_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_before jsonb;
  v_after jsonb;
  v_scope text := upper(btrim(coalesce(p_operation_scope,'')));
  v_category_scope text;
begin
  if not public.service_admin_has_permission(p_admin_id,'SERVICES_MANAGE') then raise exception using errcode='P0001', message='ADMIN_PERMISSION_DENIED'; end if;
  select operation_scope into v_category_scope from public.categories where id=p_category_id and is_active;
  if not found then raise exception using errcode='P0001', message='CATEGORY_NOT_AVAILABLE'; end if;
  if v_scope not in ('SABRINA','BLACKSHEEP') or v_category_scope<>v_scope then raise exception using errcode='P0001', message='SERVICE_CATEGORY_OPERATION_MISMATCH'; end if;
  if nullif(btrim(p_name),'') is null then raise exception using errcode='P0001', message='SERVICE_NAME_REQUIRED'; end if;
  if nullif(btrim(p_slug),'') is null or p_slug !~ '^[a-z0-9]+(?:-[a-z0-9]+)*$' then raise exception using errcode='P0001', message='SERVICE_SLUG_INVALID'; end if;
  if coalesce(p_minimum_people,0)<1 or coalesce(p_maximum_people,0)<p_minimum_people then raise exception using errcode='P0001', message='INVALID_PEOPLE_RANGE'; end if;
  if coalesce(p_price_per_extra_person,-1)<0 then raise exception using errcode='P0001', message='INVALID_PRICE'; end if;

  select to_jsonb(s) into v_before from public.services s where s.id=p_service_id for update;
  if v_before is null then raise exception using errcode='P0001', message='SERVICE_NOT_FOUND'; end if;
  update public.services set category_id=p_category_id,name=btrim(p_name),slug=btrim(p_slug),operation_scope=v_scope,
    short_description=nullif(btrim(p_short_description),''),full_description=nullif(btrim(p_full_description),''),
    minimum_people=p_minimum_people,maximum_people=p_maximum_people,price_per_extra_person=p_price_per_extra_person,
    is_active=coalesce(p_is_active,true),sort_order=coalesce(p_sort_order,0),updated_at=now()
  where id=p_service_id;
  select to_jsonb(s) into v_after from public.services s where s.id=p_service_id;
  if v_before is distinct from v_after then
    insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
    values(p_admin_id,'SERVICE',p_service_id,'SERVICE_CATALOG_UPDATED',v_before,v_after,'ADMIN');
  end if;
  return v_after;
end;
$$;

create or replace function public.service_admin_replace_day_time_pricing_audited(
  p_service_id uuid, p_rules jsonb, p_admin_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_before jsonb;
  v_after jsonb;
  v_rule jsonb;
  v_action text;
  v_days smallint[];
  v_idx integer := 0;
begin
  if not public.service_admin_has_permission(p_admin_id,'FINANCE_MANAGE') then raise exception using errcode='P0001', message='ADMIN_PERMISSION_DENIED'; end if;
  if not exists(select 1 from public.services where id=p_service_id) then raise exception using errcode='P0001', message='SERVICE_NOT_FOUND'; end if;
  if jsonb_typeof(coalesce(p_rules,'[]'::jsonb))<>'array' then raise exception using errcode='P0001', message='PRICING_RULES_INVALID'; end if;
  select coalesce(jsonb_agg(to_jsonb(pr) order by pr.priority,pr.id),'[]'::jsonb) into v_before
  from public.pricing_rules pr where pr.service_id=p_service_id and pr.rule_scope='DAY_TIME';
  delete from public.pricing_rules where service_id=p_service_id and rule_scope='DAY_TIME';

  for v_rule in select value from jsonb_array_elements(coalesce(p_rules,'[]'::jsonb)) loop
    v_action := upper(btrim(coalesce(v_rule->>'action_type','')));
    if v_action not in ('REPLACE_PRICE','ADD_AMOUNT','ADD_PERCENT') then raise exception using errcode='P0001', message='PRICING_ACTION_INVALID'; end if;
    if nullif(btrim(v_rule->>'name'),'') is null then raise exception using errcode='P0001', message='PRICING_RULE_NAME_REQUIRED'; end if;
    if jsonb_typeof(coalesce(v_rule->'days_of_week','[]'::jsonb))<>'array' then raise exception using errcode='P0001', message='PRICING_DAYS_INVALID'; end if;
    select coalesce(array_agg(value::smallint order by value::smallint),'{}'::smallint[]) into v_days
    from jsonb_array_elements_text(coalesce(v_rule->'days_of_week','[]'::jsonb));
    if exists(select 1 from unnest(v_days) d where d<0 or d>6) then raise exception using errcode='P0001', message='PRICING_DAYS_INVALID'; end if;

    insert into public.pricing_rules(service_id,name,rule_scope,days_of_week,start_local_time,end_local_time,
      valid_from_date,valid_until_date,action_type,amount,percentage,priority,is_active)
    values(p_service_id,btrim(v_rule->>'name'),'DAY_TIME',case when cardinality(v_days)=0 then null else v_days end,
      case when nullif(v_rule->>'start_local_time','') is null then null else (v_rule->>'start_local_time')::time end,
      case when nullif(v_rule->>'end_local_time','') is null then null else (v_rule->>'end_local_time')::time end,
      case when nullif(v_rule->>'valid_from_date','') is null then null else (v_rule->>'valid_from_date')::date end,
      case when nullif(v_rule->>'valid_until_date','') is null then null else (v_rule->>'valid_until_date')::date end,
      v_action,
      case when v_action in ('REPLACE_PRICE','ADD_AMOUNT') then (v_rule->>'amount')::numeric else null end,
      case when v_action='ADD_PERCENT' then (v_rule->>'percentage')::numeric else null end,
      coalesce((v_rule->>'priority')::integer,100+v_idx),coalesce((v_rule->>'is_active')::boolean,true));
    v_idx := v_idx+1;
  end loop;
  select coalesce(jsonb_agg(to_jsonb(pr) order by pr.priority,pr.id),'[]'::jsonb) into v_after
  from public.pricing_rules pr where pr.service_id=p_service_id and pr.rule_scope='DAY_TIME';
  if v_before is distinct from v_after then
    insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
    values(p_admin_id,'SERVICE',p_service_id,'SERVICE_DAY_TIME_PRICING_UPDATED',v_before,v_after,'ADMIN');
  end if;
  return v_after;
end;
$$;

create or replace function public.service_admin_create_extra_audited(
  p_name text,p_description text,p_price numeric,p_duration_delta_minutes integer,p_admin_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare v_id uuid;
begin
  if not public.service_admin_has_permission(p_admin_id,'SERVICES_MANAGE') then raise exception using errcode='P0001', message='ADMIN_PERMISSION_DENIED'; end if;
  if nullif(btrim(p_name),'') is null then raise exception using errcode='P0001', message='EXTRA_NAME_REQUIRED'; end if;
  if coalesce(p_price,-1)<0 or coalesce(p_duration_delta_minutes,-1)<0 then raise exception using errcode='P0001', message='EXTRA_VALUE_INVALID'; end if;
  insert into public.extras(name,description,price,duration_delta_minutes,is_active)
  values(btrim(p_name),nullif(btrim(p_description),''),p_price,p_duration_delta_minutes,true) returning id into v_id;
  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
  values(p_admin_id,'EXTRA',v_id,'EXTRA_CREATED',null,(select to_jsonb(e) from public.extras e where e.id=v_id),'ADMIN');
  return (select to_jsonb(e) from public.extras e where e.id=v_id);
end;
$$;

create or replace function public.service_admin_update_extra_audited(
  p_extra_id uuid,p_name text,p_description text,p_price numeric,p_duration_delta_minutes integer,p_is_active boolean,p_admin_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare v_before jsonb; v_after jsonb;
begin
  if not public.service_admin_has_permission(p_admin_id,'SERVICES_MANAGE') then raise exception using errcode='P0001', message='ADMIN_PERMISSION_DENIED'; end if;
  if nullif(btrim(p_name),'') is null then raise exception using errcode='P0001', message='EXTRA_NAME_REQUIRED'; end if;
  if coalesce(p_price,-1)<0 or coalesce(p_duration_delta_minutes,-1)<0 then raise exception using errcode='P0001', message='EXTRA_VALUE_INVALID'; end if;
  select to_jsonb(e) into v_before from public.extras e where e.id=p_extra_id for update;
  if v_before is null then raise exception using errcode='P0001', message='EXTRA_NOT_FOUND'; end if;
  update public.extras set name=btrim(p_name),description=nullif(btrim(p_description),''),price=p_price,
    duration_delta_minutes=p_duration_delta_minutes,is_active=coalesce(p_is_active,true),updated_at=now() where id=p_extra_id;
  select to_jsonb(e) into v_after from public.extras e where e.id=p_extra_id;
  if v_before is distinct from v_after then
    insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
    values(p_admin_id,'EXTRA',p_extra_id,'EXTRA_UPDATED',v_before,v_after,'ADMIN');
  end if;
  return v_after;
end;
$$;

create or replace function public.service_admin_remove_extra_audited(p_extra_id uuid,p_admin_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare v_before jsonb; v_in_use boolean;
begin
  if not public.service_admin_has_permission(p_admin_id,'SERVICES_MANAGE') then raise exception using errcode='P0001', message='ADMIN_PERMISSION_DENIED'; end if;
  select to_jsonb(e) into v_before from public.extras e where e.id=p_extra_id for update;
  if v_before is null then raise exception using errcode='P0001', message='EXTRA_NOT_FOUND'; end if;
  select exists(select 1 from public.service_extras where extra_id=p_extra_id)
      or exists(select 1 from public.appointment_extras where extra_id=p_extra_id) into v_in_use;
  if v_in_use then
    update public.extras set is_active=false,updated_at=now() where id=p_extra_id;
    insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
    values(p_admin_id,'EXTRA',p_extra_id,'EXTRA_ARCHIVED',v_before,(select to_jsonb(e) from public.extras e where e.id=p_extra_id),'ADMIN');
    return jsonb_build_object('extra_id',p_extra_id,'removed',false,'archived',true);
  end if;
  delete from public.extras where id=p_extra_id;
  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
  values(p_admin_id,'EXTRA',p_extra_id,'EXTRA_DELETED',v_before,null,'ADMIN');
  return jsonb_build_object('extra_id',p_extra_id,'removed',true,'archived',false);
end;
$$;

create or replace function public.service_admin_replace_service_extras_audited(
  p_service_id uuid,p_extras jsonb,p_admin_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare v_before jsonb; v_after jsonb; v_item jsonb; v_extra_id uuid; v_placement text; v_idx integer:=0;
begin
  if not public.service_admin_has_permission(p_admin_id,'SERVICES_MANAGE') then raise exception using errcode='P0001', message='ADMIN_PERMISSION_DENIED'; end if;
  if not exists(select 1 from public.services where id=p_service_id) then raise exception using errcode='P0001', message='SERVICE_NOT_FOUND'; end if;
  if jsonb_typeof(coalesce(p_extras,'[]'::jsonb))<>'array' then raise exception using errcode='P0001', message='SERVICE_EXTRAS_INVALID'; end if;
  select coalesce(jsonb_agg(to_jsonb(se) order by se.sort_order,se.extra_id),'[]'::jsonb) into v_before from public.service_extras se where se.service_id=p_service_id;
  delete from public.service_extras where service_id=p_service_id;
  for v_item in select value from jsonb_array_elements(coalesce(p_extras,'[]'::jsonb)) loop
    v_extra_id := (v_item->>'extra_id')::uuid;
    v_placement := upper(btrim(coalesce(v_item->>'schedule_placement','APPEND')));
    if v_placement not in ('PREPEND','APPEND') then raise exception using errcode='P0001', message='EXTRA_SCHEDULE_PLACEMENT_INVALID'; end if;
    if not exists(select 1 from public.extras where id=v_extra_id and is_active) then raise exception using errcode='P0001', message='EXTRA_NOT_AVAILABLE'; end if;
    insert into public.service_extras(service_id,extra_id,sort_order,is_required,max_quantity,schedule_placement,default_schedule_minutes,schedule_updated_at)
    values(p_service_id,v_extra_id,coalesce((v_item->>'sort_order')::integer,v_idx*10),
      coalesce((v_item->>'is_required')::boolean,false),coalesce((v_item->>'max_quantity')::integer,1),v_placement,
      case when nullif(v_item->>'default_schedule_minutes','') is null then null else (v_item->>'default_schedule_minutes')::integer end,now());
    v_idx:=v_idx+1;
  end loop;
  select coalesce(jsonb_agg(to_jsonb(se) order by se.sort_order,se.extra_id),'[]'::jsonb) into v_after from public.service_extras se where se.service_id=p_service_id;
  if v_before is distinct from v_after then
    insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
    values(p_admin_id,'SERVICE',p_service_id,'SERVICE_EXTRAS_UPDATED',v_before,v_after,'ADMIN');
  end if;
  return v_after;
end;
$$;

-- Simple per-extra-person pricing is applied after day/time pricing and before optional legacy PEOPLE rules.
create or replace function public.calculate_booking_quote(
  p_service_id uuid,
  p_service_employee_id uuid,
  p_extra_selections jsonb default '[]'::jsonb,
  p_people_count integer default 1,
  p_requested_start_at timestamptz default null,
  p_coupon_code text default null
)
returns jsonb
language plpgsql
stable
set search_path = public, extensions
as $$
declare
  v_service public.services%rowtype;
  v_timezone text;
  v_price numeric := 0;
  v_after_day_time numeric := 0;
  v_after_people numeric := 0;
  v_day_time_adjustment numeric := 0;
  v_people_adjustment numeric := 0;
  v_extras_total numeric := 0;
  v_extra_duration integer := 0;
  v_duration integer := 0;
  v_subtotal numeric := 0;
  v_coupon_discount numeric := 0;
  v_commercial_value numeric := 0;
  v_coupon public.coupons%rowtype;
  v_local_ts timestamp without time zone;
  v_local_date date;
  v_local_time time without time zone;
  v_dow smallint;
  v_processed_extras integer := 0;
  v_requested_extras integer := 0;
  v_resource_ids uuid[] := '{}'::uuid[];
  v_pricing_version text;
  r record;
begin
  select s.* into v_service from public.services s where s.id=p_service_id and s.is_active;
  if not found then raise exception using errcode='P0001', message='SERVICE_NOT_AVAILABLE'; end if;
  if not exists(select 1 from public.service_employees se where se.id=p_service_employee_id and se.service_id=p_service_id and se.is_active) then
    raise exception using errcode='P0001', message='EMPLOYEE_NOT_AVAILABLE_FOR_SERVICE';
  end if;
  if p_people_count<v_service.minimum_people then raise exception using errcode='P0001', message='PEOPLE_BELOW_MINIMUM'; end if;
  if p_people_count>v_service.maximum_people then raise exception using errcode='P0001', message='PEOPLE_ABOVE_MAXIMUM'; end if;
  if jsonb_typeof(coalesce(p_extra_selections,'[]'::jsonb))<>'array' then raise exception using errcode='P0001', message='INVALID_EXTRA'; end if;
  select count(*) into v_requested_extras from jsonb_array_elements(coalesce(p_extra_selections,'[]'::jsonb));
  if exists(select 1 from jsonb_to_recordset(coalesce(p_extra_selections,'[]'::jsonb)) as x(extra_id uuid,quantity integer) group by x.extra_id having count(*)>1) then
    raise exception using errcode='P0001', message='INVALID_EXTRA';
  end if;

  v_price:=v_service.base_price;
  v_duration:=v_service.base_duration_minutes;
  for r in
    select e.id extra_id,e.price,e.duration_delta_minutes,x.quantity,se.max_quantity
    from jsonb_to_recordset(coalesce(p_extra_selections,'[]'::jsonb)) as x(extra_id uuid,quantity integer)
    join public.service_extras se on se.service_id=p_service_id and se.extra_id=x.extra_id
    join public.extras e on e.id=x.extra_id and e.is_active
  loop
    if r.quantity is null or r.quantity<1 or r.quantity>r.max_quantity then raise exception using errcode='P0001', message='INVALID_EXTRA_QUANTITY'; end if;
    v_processed_extras:=v_processed_extras+1;
    v_extras_total:=v_extras_total+(r.price*r.quantity);
    v_extra_duration:=v_extra_duration+(r.duration_delta_minutes*r.quantity);
  end loop;
  if v_processed_extras<>v_requested_extras then raise exception using errcode='P0001', message='INVALID_EXTRA'; end if;

  select os.timezone into v_timezone from public.operation_settings os where os.id=1;
  if p_requested_start_at is not null then
    v_local_ts:=p_requested_start_at at time zone v_timezone;
    v_local_date:=v_local_ts::date; v_local_time:=v_local_ts::time; v_dow:=extract(dow from v_local_ts)::smallint;
    for r in select pr.* from public.pricing_rules pr where pr.service_id=p_service_id and pr.is_active and pr.rule_scope='DAY_TIME'
      and (pr.valid_from_date is null or v_local_date>=pr.valid_from_date)
      and (pr.valid_until_date is null or v_local_date<=pr.valid_until_date)
      and (pr.days_of_week is null or v_dow=any(pr.days_of_week))
      and (pr.start_local_time is null or v_local_time>=pr.start_local_time)
      and (pr.end_local_time is null or v_local_time<pr.end_local_time)
      order by pr.priority asc,pr.id asc
    loop
      if r.action_type='REPLACE_PRICE' then v_price:=r.amount;
      elsif r.action_type='ADD_AMOUNT' then v_price:=v_price+r.amount;
      elsif r.action_type='ADD_PERCENT' then v_price:=v_price*(1+(r.percentage/100)); end if;
    end loop;
  end if;
  v_after_day_time:=round(greatest(v_price,0),2);
  v_day_time_adjustment:=v_after_day_time-v_service.base_price;
  v_price:=v_after_day_time + greatest(p_people_count-v_service.minimum_people,0)*v_service.price_per_extra_person;

  for r in select pr.* from public.pricing_rules pr where pr.service_id=p_service_id and pr.is_active and pr.rule_scope='PEOPLE'
    and p_people_count between pr.min_people and pr.max_people
    and (pr.valid_from_date is null or coalesce(v_local_date,current_date)>=pr.valid_from_date)
    and (pr.valid_until_date is null or coalesce(v_local_date,current_date)<=pr.valid_until_date)
    order by pr.priority asc,pr.id asc
  loop
    if r.action_type='REPLACE_PRICE' then v_price:=r.amount;
    elsif r.action_type='ADD_AMOUNT' then v_price:=v_price+r.amount;
    elsif r.action_type='ADD_PERCENT' then v_price:=v_price*(1+(r.percentage/100)); end if;
  end loop;
  v_after_people:=round(greatest(v_price,0),2);
  v_people_adjustment:=v_after_people-v_after_day_time;
  v_extras_total:=round(v_extras_total,2);
  v_duration:=v_duration+v_extra_duration;
  v_subtotal:=round(greatest(v_after_people+v_extras_total,0),2);

  if p_coupon_code is not null and btrim(p_coupon_code)<>'' then
    select c.* into v_coupon from public.coupons c where lower(c.code)=lower(btrim(p_coupon_code)) and c.is_active
      and (c.valid_from is null or coalesce(p_requested_start_at,now())>=c.valid_from)
      and (c.valid_until is null or coalesce(p_requested_start_at,now())<=c.valid_until)
      and (not exists(select 1 from public.coupon_services cs where cs.coupon_id=c.id)
        or exists(select 1 from public.coupon_services cs where cs.coupon_id=c.id and cs.service_id=p_service_id)) limit 1;
    if not found then raise exception using errcode='P0001', message='INVALID_COUPON'; end if;
    if v_coupon.discount_type='FIXED' then v_coupon_discount:=least(v_coupon.discount_value,v_subtotal);
    else v_coupon_discount:=round(v_subtotal*(v_coupon.discount_value/100),2); end if;
  end if;
  v_coupon_discount:=round(v_coupon_discount,2);
  v_commercial_value:=round(greatest(v_subtotal-v_coupon_discount,0),2);

  select coalesce(array_agg(distinct resource_id order by resource_id),'{}'::uuid[]) into v_resource_ids
  from (
    select sr.resource_id from public.service_resources sr where sr.service_id=p_service_id and sr.is_required
    union
    select er.resource_id from jsonb_to_recordset(coalesce(p_extra_selections,'[]'::jsonb)) as x(extra_id uuid,quantity integer)
      join public.extra_resources er on er.extra_id=x.extra_id and er.is_required
  ) required_resources;

  select md5(concat_ws('|',v_service.updated_at::text,
    coalesce((select max(updated_at)::text from public.pricing_rules where service_id=p_service_id),''),
    coalesce((select max(e.updated_at)::text from jsonb_to_recordset(coalesce(p_extra_selections,'[]'::jsonb)) as x(extra_id uuid,quantity integer) join public.extras e on e.id=x.extra_id),''),
    coalesce(v_coupon.updated_at::text,''))) into v_pricing_version;

  return jsonb_build_object('service_id',p_service_id,'service_employee_id',p_service_employee_id,'duration_minutes',v_duration,
    'buffer_before_minutes',v_service.buffer_before_minutes,'buffer_after_minutes',v_service.buffer_after_minutes,
    'resource_ids',to_jsonb(v_resource_ids),'base_price',round(v_service.base_price,2),
    'day_time_adjustment',round(v_day_time_adjustment,2),'people_adjustment',round(v_people_adjustment,2),
    'extras_total',v_extras_total,'coupon_discount',v_coupon_discount,'commercial_value',v_commercial_value,'pricing_version',v_pricing_version);
end;
$$;

revoke all on function public.service_admin_list_categories() from public,anon,authenticated;
revoke all on function public.service_admin_list_extras() from public,anon,authenticated;
revoke all on function public.service_admin_create_category_audited(text,text,text,uuid) from public,anon,authenticated;
revoke all on function public.service_admin_update_category_audited(uuid,text,text,text,integer,boolean,uuid) from public,anon,authenticated;
revoke all on function public.service_admin_remove_category_audited(uuid,uuid) from public,anon,authenticated;
revoke all on function public.service_admin_create_service_catalog_audited(uuid,text,text,text,text,text,text,integer,numeric,integer,integer,integer,integer,numeric,uuid) from public,anon,authenticated;
revoke all on function public.service_admin_update_service_catalog_audited(uuid,uuid,text,text,text,text,text,integer,integer,numeric,boolean,integer,uuid) from public,anon,authenticated;
revoke all on function public.service_admin_replace_day_time_pricing_audited(uuid,jsonb,uuid) from public,anon,authenticated;
revoke all on function public.service_admin_create_extra_audited(text,text,numeric,integer,uuid) from public,anon,authenticated;
revoke all on function public.service_admin_update_extra_audited(uuid,text,text,numeric,integer,boolean,uuid) from public,anon,authenticated;
revoke all on function public.service_admin_remove_extra_audited(uuid,uuid) from public,anon,authenticated;
revoke all on function public.service_admin_replace_service_extras_audited(uuid,jsonb,uuid) from public,anon,authenticated;

grant execute on function public.service_admin_list_categories() to service_role;
grant execute on function public.service_admin_list_extras() to service_role;
grant execute on function public.service_admin_create_category_audited(text,text,text,uuid) to service_role;
grant execute on function public.service_admin_update_category_audited(uuid,text,text,text,integer,boolean,uuid) to service_role;
grant execute on function public.service_admin_remove_category_audited(uuid,uuid) to service_role;
grant execute on function public.service_admin_create_service_catalog_audited(uuid,text,text,text,text,text,text,integer,numeric,integer,integer,integer,integer,numeric,uuid) to service_role;
grant execute on function public.service_admin_update_service_catalog_audited(uuid,uuid,text,text,text,text,text,integer,integer,numeric,boolean,integer,uuid) to service_role;
grant execute on function public.service_admin_replace_day_time_pricing_audited(uuid,jsonb,uuid) to service_role;
grant execute on function public.service_admin_create_extra_audited(text,text,numeric,integer,uuid) to service_role;
grant execute on function public.service_admin_update_extra_audited(uuid,text,text,numeric,integer,boolean,uuid) to service_role;
grant execute on function public.service_admin_remove_extra_audited(uuid,uuid) to service_role;
grant execute on function public.service_admin_replace_service_extras_audited(uuid,jsonb,uuid) to service_role;
-- END RC MIGRATION 20260825213000_catalog_categories_pricing_extras.sql

-- BEGIN RC MIGRATION 20260825213100_catalog_operation_legacy_bridge.sql
-- Preserve historical/unclassified catalog rows while enforcing operation integrity
-- whenever either side is explicitly classified. Admin RPCs still require a classified
-- category and operation for all new catalog writes.

create or replace function public.enforce_service_category_operation()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_category_scope text;
begin
  if new.category_id is null then
    return new;
  end if;

  select operation_scope into v_category_scope
  from public.categories
  where id = new.category_id;

  if not found then
    raise exception using errcode='P0001', message='CATEGORY_NOT_FOUND';
  end if;

  -- Legacy rows created before operation scoping may remain unclassified together.
  -- Once either side is classified, both must agree.
  if v_category_scope is null and new.operation_scope is null then
    return new;
  end if;

  if v_category_scope is null or new.operation_scope is null or new.operation_scope <> v_category_scope then
    raise exception using errcode='P0001', message='SERVICE_CATEGORY_OPERATION_MISMATCH';
  end if;

  return new;
end;
$$;
-- END RC MIGRATION 20260825213100_catalog_operation_legacy_bridge.sql

-- BEGIN RC MIGRATION 20260825213200_catalog_runtime_compatibility.sql
-- Restore runtime compatibility after the catalog administration expansion.
-- New admin writes still require classified categories, but historical/direct fixtures may
-- legitimately reference an unclassified category while the service itself is classified.

create or replace function public.enforce_service_category_operation()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_category_scope text;
begin
  if new.category_id is null then
    return new;
  end if;

  select operation_scope into v_category_scope
  from public.categories
  where id = new.category_id;

  if not found then
    raise exception using errcode='P0001', message='CATEGORY_NOT_FOUND';
  end if;

  -- Unclassified categories are legacy-compatible. The audited admin catalog RPCs reject
  -- them for new writes, so this exception does not weaken the managed admin surface.
  if v_category_scope is null then
    return new;
  end if;

  if new.operation_scope is null or new.operation_scope <> v_category_scope then
    raise exception using errcode='P0001', message='SERVICE_CATEGORY_OPERATION_MISMATCH';
  end if;

  return new;
end;
$$;

-- 20260825213000 intentionally extended the base pricing calculation with simple
-- per-extra-person pricing. It replaced calculate_booking_quote(), which at this point in
-- the migration chain is already the schedule-aware wrapper introduced in
-- 20260821191000. Keep that enhanced calculation as the catalog base and restore the
-- schedule-aware public contract on top of it.
alter function public.calculate_booking_quote(uuid, uuid, jsonb, integer, timestamptz, text)
  rename to calculate_booking_quote_catalog_base;

create or replace function public.calculate_booking_quote(
  p_service_id uuid,
  p_service_employee_id uuid,
  p_extra_selections jsonb default '[]'::jsonb,
  p_people_count integer default 1,
  p_requested_start_at timestamptz default null,
  p_coupon_code text default null
)
returns jsonb
language plpgsql
stable
set search_path = public
as $$
declare
  v_quote jsonb;
  v_profile jsonb;
  v_core_duration integer;
  v_pre integer;
  v_post integer;
  v_schedule_version text;
  v_pricing_version text;
begin
  v_quote := public.calculate_booking_quote_catalog_base(
    p_service_id,
    p_service_employee_id,
    p_extra_selections,
    p_people_count,
    p_requested_start_at,
    p_coupon_code
  );

  select base_duration_minutes into v_core_duration
  from public.services
  where id = p_service_id;

  v_profile := public.resolve_extra_schedule_profile(
    p_service_id,
    p_extra_selections,
    p_requested_start_at
  );

  v_pre := coalesce((v_profile->>'pre_service_minutes')::integer, 0);
  v_post := coalesce((v_profile->>'post_service_minutes')::integer, 0);
  v_schedule_version := coalesce(v_profile->>'schedule_version', '');
  v_pricing_version := md5(coalesce(v_quote->>'pricing_version', '') || '|' || v_schedule_version);

  return v_quote || jsonb_build_object(
    'core_duration_minutes', v_core_duration,
    'pre_service_minutes', v_pre,
    'post_service_minutes', v_post,
    'duration_minutes', v_core_duration + v_pre + v_post,
    'schedule_profile', v_profile,
    'pricing_version', v_pricing_version
  );
end;
$$;

-- Creating a new function after renaming the protected core quote restores PostgreSQL's
-- default PUBLIC EXECUTE grant. Re-apply the public-booking boundary explicitly: browser
-- roles may quote only through the page-scoped wrappers, while service_role retains the
-- internal core capability.
revoke all on function public.calculate_booking_quote(uuid,uuid,jsonb,integer,timestamptz,text)
  from public, anon, authenticated;
grant execute on function public.calculate_booking_quote(uuid,uuid,jsonb,integer,timestamptz,text)
  to service_role;

-- The renamed implementation is an internal helper too; do not expose it accidentally.
revoke all on function public.calculate_booking_quote_catalog_base(uuid,uuid,jsonb,integer,timestamptz,text)
  from public, anon, authenticated;
grant execute on function public.calculate_booking_quote_catalog_base(uuid,uuid,jsonb,integer,timestamptz,text)
  to service_role;
-- END RC MIGRATION 20260825213200_catalog_runtime_compatibility.sql

-- BEGIN RC MIGRATION 20260825220000_coupon_admin_limits.sql
-- Administrative coupon management and transactional per-customer usage limit.

alter table public.coupons
  add column if not exists max_uses_per_customer integer;

alter table public.coupons drop constraint if exists coupons_max_uses_per_customer_check;
alter table public.coupons add constraint coupons_max_uses_per_customer_check
  check (max_uses_per_customer is null or max_uses_per_customer > 0);

create index if not exists appointment_discounts_coupon_idx
  on public.appointment_discounts(coupon_id)
  where coupon_id is not null;

create or replace function public.enforce_coupon_customer_usage_limit()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_limit integer;
  v_customer_id uuid;
  v_used integer;
begin
  if new.coupon_id is null then return new; end if;
  select c.max_uses_per_customer into v_limit from public.coupons c where c.id = new.coupon_id for update;
  if v_limit is null then return new; end if;
  select a.primary_customer_id into v_customer_id from public.appointments a where a.id = new.appointment_id;
  if v_customer_id is null then raise exception using errcode='P0001', message='COUPON_CUSTOMER_REQUIRED'; end if;
  select count(*)::integer into v_used from public.appointment_discounts ad join public.appointments a on a.id=ad.appointment_id where ad.coupon_id=new.coupon_id and a.primary_customer_id=v_customer_id;
  if v_used >= v_limit then raise exception using errcode='P0001', message='COUPON_CUSTOMER_USAGE_LIMIT_REACHED'; end if;
  return new;
end;
$$;

drop trigger if exists appointment_discounts_coupon_customer_limit on public.appointment_discounts;
create trigger appointment_discounts_coupon_customer_limit before insert on public.appointment_discounts for each row execute function public.enforce_coupon_customer_usage_limit();

create or replace function public.admin_list_coupons()
returns jsonb language sql stable security definer set search_path=public as $$
select coalesce(jsonb_agg(jsonb_build_object(
'id',c.id,'code',c.code,'discount_type',c.discount_type,'discount_value',c.discount_value,'valid_from',c.valid_from,'valid_until',c.valid_until,'is_active',c.is_active,'source',c.source,'customer_id',c.customer_id,'customer_name',customer.name,'source_appointment_id',c.source_appointment_id,'max_uses',c.max_uses,'max_uses_per_customer',c.max_uses_per_customer,'used_count',c.used_count,
'actual_used_count',(select count(*) from public.appointment_discounts ad where ad.coupon_id=c.id),
'status',case when not c.is_active then 'INACTIVE' when c.valid_from is not null and now()<c.valid_from then 'SCHEDULED' when c.valid_until is not null and now()>c.valid_until then 'EXPIRED' when c.max_uses is not null and c.used_count>=c.max_uses then 'EXHAUSTED' else 'ACTIVE' end,
'service_ids',coalesce((select jsonb_agg(cs.service_id order by cs.service_id) from public.coupon_services cs where cs.coupon_id=c.id),'[]'::jsonb)
) order by c.created_at desc,c.code),'[]'::jsonb)
from public.coupons c left join public.customers customer on customer.id=c.customer_id;
$$;

create or replace function public.admin_coupon_metrics()
returns jsonb language sql stable security definer set search_path=public as $$
with usage as (
  select c.id,c.code,count(ad.appointment_id)::integer as uses,coalesce(sum(ad.calculated_discount_amount),0)::numeric(12,2) as discount_total
  from public.coupons c left join public.appointment_discounts ad on ad.coupon_id=c.id group by c.id,c.code
), ranked as (select * from usage order by uses desc,code asc)
select jsonb_build_object(
  'total_uses',(select coalesce(sum(uses),0) from usage),
  'coupons_used',(select count(*) from usage where uses>0),
  'active_coupons',(select count(*) from public.coupons where is_active and (valid_from is null or valid_from<=now()) and (valid_until is null or valid_until>=now()) and (max_uses is null or used_count<max_uses)),
  'most_used',(select to_jsonb(r) from ranked r where uses>0 limit 1),
  'ranking',coalesce((select jsonb_agg(to_jsonb(r)) from (select * from ranked where uses>0 limit 20) r),'[]'::jsonb)
);
$$;

create or replace function public.admin_coupon_usage(p_coupon_id uuid)
returns jsonb language sql stable security definer set search_path=public as $$
select coalesce(jsonb_agg(jsonb_build_object('appointment_id',a.id,'public_code',a.public_code,'start_at',a.start_at,'customer_id',a.primary_customer_id,'customer_name',c.name,'customer_email',c.email,'discount_amount',ad.calculated_discount_amount,'final_value',a.commercial_value) order by a.created_at desc),'[]'::jsonb)
from public.appointment_discounts ad join public.appointments a on a.id=ad.appointment_id left join public.customers c on c.id=a.primary_customer_id where ad.coupon_id=p_coupon_id;
$$;

create or replace function public.admin_create_coupon_audited(p_code text,p_discount_type text,p_discount_value numeric,p_valid_from timestamptz,p_valid_until timestamptz,p_max_uses integer,p_max_uses_per_customer integer,p_customer_id uuid,p_service_ids uuid[],p_admin_id uuid)
returns jsonb language plpgsql volatile security definer set search_path=public as $$
declare v_id uuid; v_code text:=upper(btrim(coalesce(p_code,''))); v_type text:=upper(btrim(coalesce(p_discount_type,'')));
begin
 if not public.service_admin_has_permission(p_admin_id,'FINANCE_MANAGE') then raise exception using errcode='P0001',message='ADMIN_PERMISSION_DENIED'; end if;
 if v_code !~ '^[A-Z0-9][A-Z0-9_-]{2,39}$' then raise exception using errcode='P0001',message='COUPON_CODE_INVALID'; end if;
 if v_type not in ('FIXED','PERCENT') then raise exception using errcode='P0001',message='COUPON_DISCOUNT_TYPE_INVALID'; end if;
 if coalesce(p_discount_value,0)<=0 or (v_type='PERCENT' and p_discount_value>100) then raise exception using errcode='P0001',message='COUPON_DISCOUNT_VALUE_INVALID'; end if;
 if p_valid_from is not null and p_valid_until is not null and p_valid_until<p_valid_from then raise exception using errcode='P0001',message='COUPON_VALIDITY_INVALID'; end if;
 if p_max_uses is not null and p_max_uses<=0 then raise exception using errcode='P0001',message='COUPON_MAX_USES_INVALID'; end if;
 if p_max_uses_per_customer is not null and p_max_uses_per_customer<=0 then raise exception using errcode='P0001',message='COUPON_CUSTOMER_LIMIT_INVALID'; end if;
 if p_customer_id is not null and not exists(select 1 from public.customers where id=p_customer_id) then raise exception using errcode='P0001',message='COUPON_CUSTOMER_NOT_FOUND'; end if;
 if exists(select 1 from unnest(coalesce(p_service_ids,'{}'::uuid[])) x(id) where not exists(select 1 from public.services s where s.id=x.id)) then raise exception using errcode='P0001',message='COUPON_SERVICE_NOT_FOUND'; end if;
 insert into public.coupons(code,discount_type,discount_value,valid_from,valid_until,is_active,source,customer_id,max_uses,max_uses_per_customer,used_count) values(v_code,v_type,p_discount_value,p_valid_from,p_valid_until,true,'PROMOTION',p_customer_id,p_max_uses,p_max_uses_per_customer,0) returning id into v_id;
 insert into public.coupon_services(coupon_id,service_id) select v_id,x.id from unnest(coalesce(p_service_ids,'{}'::uuid[])) x(id);
 insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin) values(p_admin_id,'COUPON',v_id,'COUPON_CREATED',null,(select item from jsonb_array_elements(public.admin_list_coupons()) item where item->>'id'=v_id::text limit 1),'ADMIN');
 return (select item from jsonb_array_elements(public.admin_list_coupons()) item where item->>'id'=v_id::text limit 1);
end;$$;

create or replace function public.admin_update_coupon_audited(p_coupon_id uuid,p_code text,p_discount_type text,p_discount_value numeric,p_valid_from timestamptz,p_valid_until timestamptz,p_max_uses integer,p_max_uses_per_customer integer,p_customer_id uuid,p_service_ids uuid[],p_is_active boolean,p_admin_id uuid)
returns jsonb language plpgsql volatile security definer set search_path=public as $$
declare v_before jsonb;v_after jsonb;v_used integer;v_code text:=upper(btrim(coalesce(p_code,'')));v_type text:=upper(btrim(coalesce(p_discount_type,'')));
begin
 if not public.service_admin_has_permission(p_admin_id,'FINANCE_MANAGE') then raise exception using errcode='P0001',message='ADMIN_PERMISSION_DENIED'; end if;
 select item into v_before from jsonb_array_elements(public.admin_list_coupons()) item where item->>'id'=p_coupon_id::text limit 1; if v_before is null then raise exception using errcode='P0001',message='COUPON_NOT_FOUND'; end if;
 select used_count into v_used from public.coupons where id=p_coupon_id for update;
 if v_code !~ '^[A-Z0-9][A-Z0-9_-]{2,39}$' then raise exception using errcode='P0001',message='COUPON_CODE_INVALID'; end if;
 if v_type not in ('FIXED','PERCENT') or coalesce(p_discount_value,0)<=0 or (v_type='PERCENT' and p_discount_value>100) then raise exception using errcode='P0001',message='COUPON_DISCOUNT_VALUE_INVALID'; end if;
 if p_valid_from is not null and p_valid_until is not null and p_valid_until<p_valid_from then raise exception using errcode='P0001',message='COUPON_VALIDITY_INVALID'; end if;
 if p_max_uses is not null and p_max_uses<greatest(v_used,1) then raise exception using errcode='P0001',message='COUPON_MAX_USES_BELOW_USAGE'; end if;
 if p_max_uses_per_customer is not null and p_max_uses_per_customer<=0 then raise exception using errcode='P0001',message='COUPON_CUSTOMER_LIMIT_INVALID'; end if;
 update public.coupons set code=v_code,discount_type=v_type,discount_value=p_discount_value,valid_from=p_valid_from,valid_until=p_valid_until,max_uses=p_max_uses,max_uses_per_customer=p_max_uses_per_customer,customer_id=p_customer_id,is_active=coalesce(p_is_active,true),updated_at=now() where id=p_coupon_id;
 delete from public.coupon_services where coupon_id=p_coupon_id; insert into public.coupon_services(coupon_id,service_id) select p_coupon_id,x.id from unnest(coalesce(p_service_ids,'{}'::uuid[])) x(id);
 select item into v_after from jsonb_array_elements(public.admin_list_coupons()) item where item->>'id'=p_coupon_id::text limit 1;
 if v_before is distinct from v_after then insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin) values(p_admin_id,'COUPON',p_coupon_id,'COUPON_UPDATED',v_before,v_after,'ADMIN'); end if; return v_after;
end;$$;

create or replace function public.admin_remove_coupon_audited(p_coupon_id uuid,p_admin_id uuid)
returns jsonb language plpgsql volatile security definer set search_path=public as $$
declare v_before jsonb;v_used boolean;begin
 if not public.service_admin_has_permission(p_admin_id,'FINANCE_MANAGE') then raise exception using errcode='P0001',message='ADMIN_PERMISSION_DENIED'; end if;
 select item into v_before from jsonb_array_elements(public.admin_list_coupons()) item where item->>'id'=p_coupon_id::text limit 1;if v_before is null then raise exception using errcode='P0001',message='COUPON_NOT_FOUND';end if;
 perform 1 from public.coupons where id=p_coupon_id for update;select exists(select 1 from public.appointment_discounts where coupon_id=p_coupon_id) into v_used;
 if v_used then update public.coupons set is_active=false,updated_at=now() where id=p_coupon_id;insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin) values(p_admin_id,'COUPON',p_coupon_id,'COUPON_ARCHIVED',v_before,(select item from jsonb_array_elements(public.admin_list_coupons()) item where item->>'id'=p_coupon_id::text limit 1),'ADMIN');return jsonb_build_object('coupon_id',p_coupon_id,'removed',false,'archived',true);end if;
 delete from public.coupons where id=p_coupon_id;insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin) values(p_admin_id,'COUPON',p_coupon_id,'COUPON_DELETED',v_before,null,'ADMIN');return jsonb_build_object('coupon_id',p_coupon_id,'removed',true,'archived',false);
end;$$;

revoke all on function public.admin_list_coupons() from public,anon,authenticated;
revoke all on function public.admin_coupon_metrics() from public,anon,authenticated;
revoke all on function public.admin_coupon_usage(uuid) from public,anon,authenticated;
revoke all on function public.admin_create_coupon_audited(text,text,numeric,timestamptz,timestamptz,integer,integer,uuid,uuid[],uuid) from public,anon,authenticated;
revoke all on function public.admin_update_coupon_audited(uuid,text,text,numeric,timestamptz,timestamptz,integer,integer,uuid,uuid[],boolean,uuid) from public,anon,authenticated;
revoke all on function public.admin_remove_coupon_audited(uuid,uuid) from public,anon,authenticated;
grant execute on function public.admin_list_coupons(),public.admin_coupon_metrics(),public.admin_coupon_usage(uuid),public.admin_create_coupon_audited(text,text,numeric,timestamptz,timestamptz,integer,integer,uuid,uuid[],uuid),public.admin_update_coupon_audited(uuid,text,text,numeric,timestamptz,timestamptz,integer,integer,uuid,uuid[],boolean,uuid),public.admin_remove_coupon_audited(uuid,uuid) to service_role;
-- END RC MIGRATION 20260825220000_coupon_admin_limits.sql

-- BEGIN RC MIGRATION 20260825221000_checkout_coupon_confirmation.sql
-- Coupon selection belongs to the reservation confirmation step, before customer identity and payment.
-- The browser never writes money: these RPCs recalculate the authoritative quote and persist a coupon snapshot on the hold.

alter table public.checkout_holds add column if not exists applied_coupon_id uuid references public.coupons(id) on delete restrict;
alter table public.checkout_holds add column if not exists coupon_code_snapshot text;
alter table public.checkout_holds add column if not exists coupon_discount numeric(12,2) not null default 0 check (coupon_discount >= 0);
alter table public.checkout_holds add column if not exists pre_discount_value numeric(12,2) check (pre_discount_value is null or pre_discount_value >= 0);
create index if not exists checkout_holds_applied_coupon_idx on public.checkout_holds(applied_coupon_id) where applied_coupon_id is not null;

create or replace function public.checkout_hold_quote_with_coupon(p_hold public.checkout_holds,p_coupon_code text)
returns jsonb language plpgsql stable security definer set search_path=public as $$
begin
  if p_hold.duration_blocks is not null then
    return public.calculate_booking_quote_for_duration(p_hold.service_id,p_hold.service_employee_id,p_hold.duration_blocks,p_hold.extra_selections,p_hold.people_count,p_hold.core_start_at,p_coupon_code);
  end if;
  return public.calculate_booking_quote(p_hold.service_id,p_hold.service_employee_id,p_hold.extra_selections,p_hold.people_count,p_hold.core_start_at,p_coupon_code);
end;$$;

create or replace function public.apply_checkout_coupon(p_checkout_hold_token text,p_coupon_code text)
returns jsonb language plpgsql volatile security definer set search_path=public,extensions as $$
declare v_hash text;v_hold public.checkout_holds%rowtype;v_coupon public.coupons%rowtype;v_quote jsonb;v_code text:=upper(btrim(coalesce(p_coupon_code,'')));v_subtotal numeric;v_discount numeric;v_total numeric;
begin
 if p_checkout_hold_token is null or length(p_checkout_hold_token)<16 then raise exception using errcode='P0001',message='INVALID_HOLD_TOKEN';end if;
 if v_code='' then raise exception using errcode='P0001',message='INVALID_COUPON';end if;
 v_hash:=encode(digest(p_checkout_hold_token,'sha256'),'hex');
 select * into v_hold from public.checkout_holds where public_token_hash=v_hash for update;
 if not found then raise exception using errcode='P0001',message='HOLD_NOT_FOUND';end if;
 if v_hold.status<>'ACTIVE' or v_hold.expires_at<=now() then raise exception using errcode='P0001',message='HOLD_EXPIRED';end if;
 if exists(select 1 from public.checkout_hour_package_reservations ph where ph.checkout_hold_id=v_hold.id and ph.status='HELD') then raise exception using errcode='P0001',message='COUPON_PACKAGE_POLICY_REQUIRES_DECISION';end if;
 select * into v_coupon from public.coupons c where upper(c.code)=v_code for update;
 if not found or not v_coupon.is_active or (v_coupon.valid_from is not null and now()<v_coupon.valid_from) or (v_coupon.valid_until is not null and now()>v_coupon.valid_until) then raise exception using errcode='P0001',message='INVALID_COUPON';end if;
 if v_coupon.max_uses is not null and v_coupon.used_count>=v_coupon.max_uses then raise exception using errcode='P0001',message='COUPON_USAGE_LIMIT_REACHED';end if;
 if exists(select 1 from public.coupon_services cs where cs.coupon_id=v_coupon.id) and not exists(select 1 from public.coupon_services cs where cs.coupon_id=v_coupon.id and cs.service_id=v_hold.service_id) then raise exception using errcode='P0001',message='INVALID_COUPON';end if;
 v_quote:=public.checkout_hold_quote_with_coupon(v_hold,v_code);
 v_discount:=coalesce((v_quote->>'coupon_discount')::numeric,0);v_total:=(v_quote->>'commercial_value')::numeric;v_subtotal:=v_total+v_discount;
 update public.checkout_holds set applied_coupon_id=v_coupon.id,coupon_code_snapshot=v_coupon.code,coupon_discount=v_discount,pre_discount_value=v_subtotal,commercial_value=v_total,pricing_version=v_quote->>'pricing_version',quote_snapshot=v_quote,updated_at=now() where id=v_hold.id;
 return jsonb_build_object('coupon_code',v_coupon.code,'subtotal',v_subtotal,'coupon_discount',v_discount,'commercial_value',v_total,'customer_validation_pending',v_coupon.customer_id is not null or v_coupon.max_uses_per_customer is not null);
end;$$;

create or replace function public.clear_checkout_coupon(p_checkout_hold_token text)
returns jsonb language plpgsql volatile security definer set search_path=public,extensions as $$
declare v_hash text;v_hold public.checkout_holds%rowtype;v_quote jsonb;v_total numeric;
begin
 if p_checkout_hold_token is null or length(p_checkout_hold_token)<16 then raise exception using errcode='P0001',message='INVALID_HOLD_TOKEN';end if;
 v_hash:=encode(digest(p_checkout_hold_token,'sha256'),'hex');select * into v_hold from public.checkout_holds where public_token_hash=v_hash for update;
 if not found then raise exception using errcode='P0001',message='HOLD_NOT_FOUND';end if;if v_hold.status<>'ACTIVE' or v_hold.expires_at<=now() then raise exception using errcode='P0001',message='HOLD_EXPIRED';end if;
 v_quote:=public.checkout_hold_quote_with_coupon(v_hold,null);v_total:=(v_quote->>'commercial_value')::numeric;
 update public.checkout_holds set applied_coupon_id=null,coupon_code_snapshot=null,coupon_discount=0,pre_discount_value=null,commercial_value=v_total,pricing_version=v_quote->>'pricing_version',quote_snapshot=v_quote,updated_at=now() where id=v_hold.id;
 return jsonb_build_object('coupon_code',null,'subtotal',v_total,'coupon_discount',0,'commercial_value',v_total,'customer_validation_pending',false);
end;$$;

create or replace function public.get_checkout_coupon_state(p_checkout_hold_token text)
returns jsonb language plpgsql stable security definer set search_path=public,extensions as $$
declare v_hash text;v_hold public.checkout_holds%rowtype;begin
 if p_checkout_hold_token is null or length(p_checkout_hold_token)<16 then raise exception using errcode='P0001',message='INVALID_HOLD_TOKEN';end if;
 v_hash:=encode(digest(p_checkout_hold_token,'sha256'),'hex');select * into v_hold from public.checkout_holds where public_token_hash=v_hash;
 if not found then raise exception using errcode='P0001',message='HOLD_NOT_FOUND';end if;
 return jsonb_build_object('coupon_code',v_hold.coupon_code_snapshot,'subtotal',coalesce(v_hold.pre_discount_value,v_hold.commercial_value+v_hold.coupon_discount),'coupon_discount',v_hold.coupon_discount,'commercial_value',v_hold.commercial_value);
end;$$;

create or replace function public.enforce_checkout_coupon_customer()
returns trigger language plpgsql set search_path=public as $$
declare v_coupon public.coupons%rowtype;v_used integer;
begin
 if new.applied_coupon_id is null or new.primary_customer_id is null then return new;end if;
 select * into v_coupon from public.coupons where id=new.applied_coupon_id for update;
 if not found or not v_coupon.is_active or (v_coupon.valid_from is not null and now()<v_coupon.valid_from) or (v_coupon.valid_until is not null and now()>v_coupon.valid_until) then raise exception using errcode='P0001',message='INVALID_COUPON';end if;
 if v_coupon.customer_id is not null and v_coupon.customer_id<>new.primary_customer_id then raise exception using errcode='P0001',message='COUPON_CUSTOMER_MISMATCH';end if;
 if v_coupon.max_uses is not null and v_coupon.used_count>=v_coupon.max_uses then raise exception using errcode='P0001',message='COUPON_USAGE_LIMIT_REACHED';end if;
 if v_coupon.max_uses_per_customer is not null then select count(*)::integer into v_used from public.appointment_discounts ad join public.appointments a on a.id=ad.appointment_id where ad.coupon_id=v_coupon.id and a.primary_customer_id=new.primary_customer_id;if v_used>=v_coupon.max_uses_per_customer then raise exception using errcode='P0001',message='COUPON_CUSTOMER_USAGE_LIMIT_REACHED';end if;end if;
 return new;
end;$$;
drop trigger if exists checkout_holds_coupon_customer_guard on public.checkout_holds;
create trigger checkout_holds_coupon_customer_guard before update of primary_customer_id,applied_coupon_id on public.checkout_holds for each row when (new.applied_coupon_id is not null and new.primary_customer_id is not null) execute function public.enforce_checkout_coupon_customer();

create or replace function public.get_checkout_applied_coupon_code(p_checkout_hold_token text)
returns text language plpgsql stable security definer set search_path=public,extensions as $$ declare v_hash text;v_code text;begin v_hash:=encode(digest(p_checkout_hold_token,'sha256'),'hex');select coupon_code_snapshot into v_code from public.checkout_holds where public_token_hash=v_hash and status='ACTIVE' and expires_at>now();return v_code;end;$$;

revoke all on function public.checkout_hold_quote_with_coupon(public.checkout_holds,text),public.apply_checkout_coupon(text,text),public.clear_checkout_coupon(text),public.get_checkout_coupon_state(text),public.get_checkout_applied_coupon_code(text) from public,anon,authenticated;
grant execute on function public.checkout_hold_quote_with_coupon(public.checkout_holds,text),public.apply_checkout_coupon(text,text),public.clear_checkout_coupon(text),public.get_checkout_coupon_state(text),public.get_checkout_applied_coupon_code(text) to service_role;
-- END RC MIGRATION 20260825221000_checkout_coupon_confirmation.sql

-- BEGIN RC MIGRATION 20260825221100_admin_appointment_coupon_detail.sql
-- Preserve the existing appointment detail contract and add the coupon snapshot used by this reservation.
-- Coupon information lives inside the existing `financial` envelope so admin-agenda's FINANCE_VIEW
-- redaction removes the entire object for operators without financial access.

alter function public.service_admin_get_appointment(uuid)
  rename to service_admin_get_appointment_base;

create or replace function public.service_admin_get_appointment(p_appointment_id uuid)
returns jsonb
language sql
stable
security definer
set search_path=public
as $$
with base as (
  select public.service_admin_get_appointment_base(p_appointment_id) as payload
), coupon_snapshot as (
  select jsonb_build_object(
    'coupon_id', ad.coupon_id,
    'code', ad.code_snapshot,
    'discount_type', ad.discount_type_snapshot,
    'discount_value', ad.discount_value_snapshot,
    'discount_amount', ad.calculated_discount_amount,
    'final_value', a.commercial_value
  ) as coupon
  from public.appointment_discounts ad
  join public.appointments a on a.id=ad.appointment_id
  where ad.appointment_id=p_appointment_id
  order by ad.created_at
  limit 1
)
select base.payload || jsonb_build_object(
  'financial', coalesce(base.payload->'financial','{}'::jsonb)
    || jsonb_build_object('coupon',(select coupon from coupon_snapshot))
)
from base;
$$;

revoke all on function public.service_admin_get_appointment_base(uuid) from public,anon,authenticated;
revoke all on function public.service_admin_get_appointment(uuid) from public,anon,authenticated;
grant execute on function public.service_admin_get_appointment_base(uuid) to service_role;
grant execute on function public.service_admin_get_appointment(uuid) to service_role;
-- END RC MIGRATION 20260825221100_admin_appointment_coupon_detail.sql
