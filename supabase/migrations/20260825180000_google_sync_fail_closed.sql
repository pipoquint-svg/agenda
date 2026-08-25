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
