
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
