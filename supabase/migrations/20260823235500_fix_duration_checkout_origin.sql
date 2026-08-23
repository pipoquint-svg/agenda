-- Preserve the public booking-page origin on duration-based checkout holds.
-- The FIXED wrapper already does this; BLOCKS must follow the same contract so
-- public_get_checkout_context can enforce CHECKOUT_ORIGIN_MISSING fail-closed.

create or replace function public.public_create_checkout_hold_duration(
  p_booking_page_slug text,
  p_service_id uuid,
  p_service_employee_id uuid,
  p_duration_blocks integer,
  p_extra_selections jsonb,
  p_people_count integer,
  p_requested_start_at timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_page_id uuid;
  v_result jsonb;
  v_hold_id uuid;
begin
  perform public.assert_public_booking_duration(
    p_booking_page_slug,
    p_service_id,
    p_service_employee_id,
    p_duration_blocks,
    p_extra_selections,
    p_people_count
  );

  select id into v_page_id
  from public.booking_pages
  where slug = lower(btrim(p_booking_page_slug))
    and is_active;

  if v_page_id is null then
    raise exception using errcode = 'P0001', message = 'BOOKING_PAGE_NOT_AVAILABLE';
  end if;

  v_result := public.create_checkout_hold_for_duration(
    p_service_id,
    p_service_employee_id,
    p_duration_blocks,
    p_extra_selections,
    p_people_count,
    p_requested_start_at
  );

  v_hold_id := (v_result->>'checkout_hold_id')::uuid;

  update public.checkout_holds
  set booking_page_id = v_page_id,
      updated_at = now()
  where id = v_hold_id;

  if not found then
    raise exception using errcode = 'P0001', message = 'CHECKOUT_HOLD_NOT_FOUND';
  end if;

  return v_result || jsonb_build_object(
    'booking_page_slug', lower(btrim(p_booking_page_slug))
  );
end;
$$;

revoke all on function public.public_create_checkout_hold_duration(
  text, uuid, uuid, integer, jsonb, integer, timestamptz
) from public;
grant execute on function public.public_create_checkout_hold_duration(
  text, uuid, uuid, integer, jsonb, integer, timestamptz
) to anon, authenticated;
