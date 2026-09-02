-- External studio blocks protect rental availability, so derive their post-buffer
-- only from active BLOCKS services (the rental duration model), not from FIXED
-- photography services that may intentionally carry longer turnaround buffers.

create or replace function public.apply_external_physical_post_buffer()
returns trigger
language plpgsql
set search_path to 'public'
as $function$
declare
  v_buffer_after_minutes integer := 0;
  v_resource_type public.resource_type;
begin
  if new.allocation_type <> 'EXTERNAL_BLOCK' then
    return new;
  end if;

  -- Do not stack the buffer on metadata/status-only updates. Google
  -- reconciliation writes the raw event range when the event is inserted or
  -- changes, and update-of-occupied_range then normalizes it exactly once.
  if tg_op = 'UPDATE'
     and new.occupied_range is not distinct from old.occupied_range then
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

  new.occupied_range := tstzrange(
    lower(new.occupied_range),
    upper(new.occupied_range) + make_interval(mins => v_buffer_after_minutes),
    '[)'
  );

  return new;
end;
$function$;

comment on function public.apply_external_physical_post_buffer() is
  'Extends changed/new EXTERNAL_BLOCK ranges after the raw event only on PHYSICAL resources, using the active BLOCKS/rental service buffer_after_minutes. FIXED photography-service buffers do not affect external rental separation.';
