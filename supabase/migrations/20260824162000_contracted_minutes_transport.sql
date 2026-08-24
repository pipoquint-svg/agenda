-- Commercial duration boundary: blocks are selection/pricing internals only.
-- Legacy duration_blocks transport is accepted temporarily by booking-hold until 2026-09-07.

create table if not exists public.booking_contract_legacy_usage (
  id bigint generated always as identity primary key,
  occurred_at timestamptz not null default now(),
  surface text not null,
  booking_page_slug text,
  service_id uuid,
  duration_blocks integer,
  user_agent text,
  constraint booking_contract_legacy_usage_surface_check check (surface in ('BOOKING_HOLD'))
);

revoke all on table public.booking_contract_legacy_usage from public, anon, authenticated;
grant insert, select on table public.booking_contract_legacy_usage to service_role;

create or replace function public.resolve_service_duration_blocks_from_minutes(
  p_service_id uuid,
  p_contracted_minutes integer
)
returns integer
language plpgsql
stable
set search_path = public
as $$
declare
  v_service public.services%rowtype;
  v_blocks integer;
begin
  if p_contracted_minutes is null or p_contracted_minutes <= 0 then
    raise exception using errcode='P0001', message='INVALID_CONTRACTED_MINUTES';
  end if;

  select * into v_service from public.services where id=p_service_id and is_active;
  if not found then raise exception using errcode='P0001', message='SERVICE_NOT_AVAILABLE'; end if;

  if v_service.duration_mode='FIXED' then
    if p_contracted_minutes <> v_service.base_duration_minutes then
      raise exception using errcode='P0001', message='INVALID_CONTRACTED_MINUTES';
    end if;
    return null;
  end if;

  if v_service.booking_block_minutes is null or v_service.booking_block_minutes <= 0 then
    raise exception using errcode='P0001', message='SERVICE_DURATION_CONFIGURATION_INVALID';
  end if;
  if p_contracted_minutes % v_service.booking_block_minutes <> 0 then
    raise exception using errcode='P0001', message='INVALID_CONTRACTED_MINUTES';
  end if;

  v_blocks := p_contracted_minutes / v_service.booking_block_minutes;
  if v_blocks < coalesce(v_service.minimum_booking_blocks,1)
     or (v_service.maximum_booking_blocks is not null and v_blocks > v_service.maximum_booking_blocks) then
    raise exception using errcode='P0001', message='INVALID_CONTRACTED_MINUTES';
  end if;
  return v_blocks;
end;
$$;

create or replace function public.public_quote_booking_minutes(
  p_booking_page_slug text,
  p_service_id uuid,
  p_service_employee_id uuid,
  p_contracted_minutes integer,
  p_extra_selections jsonb default '[]'::jsonb,
  p_people_count integer default 1
)
returns jsonb
language plpgsql
stable
security definer
set search_path=public
as $$
declare v_blocks integer;
begin
  v_blocks := public.resolve_service_duration_blocks_from_minutes(p_service_id,p_contracted_minutes);
  perform public.assert_public_booking_duration(
    p_booking_page_slug,p_service_id,p_service_employee_id,v_blocks,p_extra_selections,p_people_count
  );
  return public.calculate_booking_quote_for_duration(
    p_service_id,p_service_employee_id,v_blocks,p_extra_selections,p_people_count,null,null
  ) - 'duration_blocks' || jsonb_build_object('contracted_minutes',p_contracted_minutes);
end;
$$;

create or replace function public.public_list_available_slots_minutes(
  p_booking_page_slug text,
  p_service_id uuid,
  p_service_employee_id uuid,
  p_contracted_minutes integer,
  p_extra_selections jsonb default '[]'::jsonb,
  p_people_count integer default 1,
  p_local_date date default current_date
)
returns table(
  slot_start_at timestamptz, slot_end_at timestamptz, core_start_at timestamptz, core_end_at timestamptz,
  pre_service_minutes integer, post_service_minutes integer, duration_minutes integer, commercial_value numeric
)
language plpgsql
stable
security definer
set search_path=public
as $$
declare v_blocks integer;
begin
  v_blocks := public.resolve_service_duration_blocks_from_minutes(p_service_id,p_contracted_minutes);
  perform public.assert_public_booking_duration(
    p_booking_page_slug,p_service_id,p_service_employee_id,v_blocks,p_extra_selections,p_people_count
  );
  return query select * from public.list_available_slots_for_duration(
    p_service_id,p_service_employee_id,v_blocks,p_extra_selections,p_people_count,p_local_date,null
  );
end;
$$;

create or replace function public.public_create_checkout_hold_tracked_minutes(
  p_booking_page_slug text,
  p_service_id uuid,
  p_service_employee_id uuid,
  p_contracted_minutes integer,
  p_extra_selections jsonb,
  p_people_count integer,
  p_requested_start_at timestamptz,
  p_attribution_json jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_blocks integer;
  v_result jsonb;
  v_hold_id uuid;
begin
  if p_attribution_json is not null and jsonb_typeof(p_attribution_json)<>'object' then
    raise exception using errcode='P0001',message='ATTRIBUTION_INVALID';
  end if;
  v_blocks := public.resolve_service_duration_blocks_from_minutes(p_service_id,p_contracted_minutes);
  v_result := public.public_create_checkout_hold_duration(
    p_booking_page_slug,p_service_id,p_service_employee_id,v_blocks,p_extra_selections,p_people_count,p_requested_start_at
  );
  v_hold_id := (v_result->>'checkout_hold_id')::uuid;
  update public.checkout_holds
  set attribution_json=public.sanitize_public_attribution(coalesce(p_attribution_json,'{}'::jsonb)), updated_at=now()
  where id=v_hold_id;
  return (v_result - 'duration_blocks') || jsonb_build_object('contracted_minutes',p_contracted_minutes);
end;
$$;

revoke all on function public.resolve_service_duration_blocks_from_minutes(uuid,integer) from public,anon,authenticated;
revoke all on function public.public_quote_booking_minutes(text,uuid,uuid,integer,jsonb,integer) from public;
revoke all on function public.public_list_available_slots_minutes(text,uuid,uuid,integer,jsonb,integer,date) from public;
revoke all on function public.public_create_checkout_hold_tracked_minutes(text,uuid,uuid,integer,jsonb,integer,timestamptz,jsonb) from public,anon,authenticated;
grant execute on function public.public_quote_booking_minutes(text,uuid,uuid,integer,jsonb,integer) to anon,authenticated;
grant execute on function public.public_list_available_slots_minutes(text,uuid,uuid,integer,jsonb,integer,date) to anon,authenticated;
grant execute on function public.public_create_checkout_hold_tracked_minutes(text,uuid,uuid,integer,jsonb,integer,timestamptz,jsonb) to service_role;
