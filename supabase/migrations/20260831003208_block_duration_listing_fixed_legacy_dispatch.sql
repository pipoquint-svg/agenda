create or replace function public.calculate_booking_quotes_for_duration_listing_batch(
  p_service_id uuid,
  p_service_employee_id uuid,
  p_duration_blocks integer,
  p_extra_selections jsonb default '[]'::jsonb,
  p_people_count integer default 1,
  p_requested_start_ats timestamptz[] default '{}'::timestamptz[],
  p_coupon_code text default null
)
returns table(requested_start_at timestamptz, quote jsonb)
language plpgsql
stable
set search_path = public, extensions
as $function$
declare
  v_duration_mode text;
  v_start timestamptz;
begin
  select s.duration_mode
    into v_duration_mode
  from public.services s
  where s.id = p_service_id
    and s.is_active;

  if not found then
    raise exception using errcode='P0001', message='SERVICE_NOT_AVAILABLE';
  end if;

  if v_duration_mode = 'BLOCKS' then
    return query
    select b.requested_start_at, b.quote
    from public.calculate_booking_quotes_for_duration_batch(
      p_service_id,
      p_service_employee_id,
      p_duration_blocks,
      p_extra_selections,
      p_people_count,
      p_requested_start_ats,
      p_coupon_code
    ) b;
    return;
  end if;

  -- FIXED must retain the legacy quote semantics. This is a dispatcher only:
  -- it delegates every candidate to the existing canonical FIXED wrapper and
  -- does not reimplement any pricing formula.
  foreach v_start in array coalesce(p_requested_start_ats, '{}'::timestamptz[])
  loop
    requested_start_at := v_start;
    quote := public.calculate_booking_quote_for_duration(
      p_service_id,
      p_service_employee_id,
      p_duration_blocks,
      p_extra_selections,
      p_people_count,
      v_start,
      p_coupon_code
    );
    return next;
  end loop;
end;
$function$;

do $patch_listing$
declare
  v_oid oid;
  v_definition text;
  v_patched text;
begin
  select p.oid
    into v_oid
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname = 'list_available_slots_for_duration_without_google_sync_gate'
    and pg_get_function_identity_arguments(p.oid) =
      'p_service_id uuid, p_service_employee_id uuid, p_duration_blocks integer, p_extra_selections jsonb, p_people_count integer, p_local_date date, p_coupon_code text';

  if v_oid is null then
    raise exception 'duration slot function not found';
  end if;

  v_definition := pg_get_functiondef(v_oid);

  if position('public.calculate_booking_quotes_for_duration_listing_batch(' in v_definition) = 0 then
    v_patched := replace(
      v_definition,
      'public.calculate_booking_quotes_for_duration_batch(',
      'public.calculate_booking_quotes_for_duration_listing_batch('
    );

    if v_patched = v_definition then
      raise exception 'duration slot batch pricing call not found';
    end if;

    execute v_patched;
  end if;
end;
$patch_listing$;

comment on function public.calculate_booking_quotes_for_duration_listing_batch(uuid,uuid,integer,jsonb,integer,timestamptz[],text)
is 'Pricing dispatcher for duration slot listings: BLOCKS uses the canonical batch core; FIXED delegates to the existing legacy canonical quote wrapper without reimplementing pricing.';