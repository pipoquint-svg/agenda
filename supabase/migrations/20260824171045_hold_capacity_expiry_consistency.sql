-- Keep public availability and authoritative hold creation consistent.
-- Availability intentionally stops hiding expired AWAITING_PAYMENT allocations before
-- periodic cleanup. Hold creation must therefore expire those allocations before the
-- exclusion constraint attempts to protect the newly selected slot.

create or replace function public.public_create_checkout_hold(
  p_booking_page_slug text,
  p_service_id uuid,
  p_service_employee_id uuid,
  p_extra_selections jsonb,
  p_people_count integer,
  p_requested_start_at timestamptz
) returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_page_id uuid;
  v_result jsonb;
  v_hold_id uuid;
begin
  perform public.expire_due_appointment_holds();

  perform public.assert_public_booking_selection(
    p_booking_page_slug,
    p_service_id,
    p_service_employee_id,
    p_extra_selections,
    p_people_count
  );

  select id into v_page_id
  from public.booking_pages
  where slug=lower(btrim(p_booking_page_slug))
    and is_active;

  v_result := public.create_checkout_hold(
    p_service_id,
    p_service_employee_id,
    p_extra_selections,
    p_people_count,
    p_requested_start_at
  );

  v_hold_id := (v_result->>'checkout_hold_id')::uuid;

  update public.checkout_holds
  set booking_page_id=v_page_id,
      updated_at=now()
  where id=v_hold_id;

  return v_result || jsonb_build_object('booking_page_slug',lower(btrim(p_booking_page_slug)));
end;
$$;

create or replace function public.public_create_checkout_hold_duration(
  p_booking_page_slug text,
  p_service_id uuid,
  p_service_employee_id uuid,
  p_duration_blocks integer,
  p_extra_selections jsonb,
  p_people_count integer,
  p_requested_start_at timestamptz
) returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_page_id uuid;
  v_result jsonb;
  v_hold_id uuid;
begin
  perform public.expire_due_appointment_holds();

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
  where slug=lower(btrim(p_booking_page_slug))
    and is_active;

  if v_page_id is null then
    raise exception using errcode='P0001',message='BOOKING_PAGE_NOT_AVAILABLE';
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
  set booking_page_id=v_page_id,
      updated_at=now()
  where id=v_hold_id;

  if not found then
    raise exception using errcode='P0001',message='CHECKOUT_HOLD_NOT_FOUND';
  end if;

  return v_result || jsonb_build_object(
    'booking_page_slug',lower(btrim(p_booking_page_slug))
  );
end;
$$;
