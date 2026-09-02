-- Canonicalize Google external PHYSICAL allocations from the raw Google event
-- interval on every occupied_range reconciliation. This makes the post-buffer
-- idempotent and also backfills unchanged legacy allocations when Google state
-- is reconciled again.

create or replace function public.apply_external_physical_post_buffer()
returns trigger
language plpgsql
set search_path to 'public'
as $function$
declare
  v_buffer_after_minutes integer := 0;
  v_resource_type public.resource_type;
  v_google_is_all_day boolean := false;
  v_google_raw_range tstzrange;
begin
  if new.allocation_type <> 'EXTERNAL_BLOCK' then
    return new;
  end if;

  select r.resource_type
  into v_resource_type
  from public.resources r
  where r.id = new.resource_id;

  if v_resource_type is distinct from 'PHYSICAL'::public.resource_type then
    return new;
  end if;

  select coalesce(max(s.buffer_after_minutes), 0)
  into v_buffer_after_minutes
  from public.service_resources sr
  join public.services s
    on s.id = sr.service_id
   and s.is_active
   and s.duration_mode = 'BLOCKS'
  where sr.resource_id = new.resource_id
    and sr.is_required;

  if v_buffer_after_minutes <= 0 then
    return new;
  end if;

  -- Google-backed allocations can always be rebuilt from the canonical raw
  -- remote interval. This is what prevents repeated syncs from stacking the
  -- 30-minute rental buffer and allows unchanged legacy rows to be backfilled.
  if new.google_calendar_event_id is not null then
    select gce.is_all_day, public.google_event_desired_range(gce.id)
    into v_google_is_all_day, v_google_raw_range
    from public.google_calendar_events gce
    where gce.id = new.google_calendar_event_id;

    if not found or v_google_is_all_day then
      return new;
    end if;

    new.occupied_range := tstzrange(
      lower(v_google_raw_range),
      upper(v_google_raw_range) + make_interval(mins => v_buffer_after_minutes),
      '[)'
    );

    return new;
  end if;

  -- Non-Google external integrations do not have a canonical event row. Keep
  -- the previous single-application behavior for them.
  if tg_op = 'UPDATE'
     and new.occupied_range is not distinct from old.occupied_range then
    return new;
  end if;

  new.occupied_range := tstzrange(
    lower(new.occupied_range),
    upper(new.occupied_range) + make_interval(mins => v_buffer_after_minutes),
    '[)'
  );

  return new;
end;
$function$;

comment on function public.apply_external_physical_post_buffer() is
  'Canonicalizes timed Google EXTERNAL_BLOCK ranges on PHYSICAL resources to raw Google interval + active BLOCKS/rental post-buffer. Repeated reconciliation is idempotent; all-day and PERSON allocations are unchanged.';
