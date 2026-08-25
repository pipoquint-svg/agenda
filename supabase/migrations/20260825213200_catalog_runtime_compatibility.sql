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
