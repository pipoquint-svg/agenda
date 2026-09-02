-- Keep Google/external blocks asymmetric with service booking buffers.
-- Internal bookings already occupy their required physical resources through
-- core_end + service.buffer_after_minutes. External blocks, however, arrive
-- without a service identity and historically occupied only their raw event
-- interval, which allowed a booking to start exactly when the external event
-- ended.
--
-- For PHYSICAL resources only, extend a changed/new EXTERNAL_BLOCK by the
-- largest active buffer_after_minutes of services that require that resource.
-- We intentionally do not extend the lower bound: a booking that ends before
-- the external event already contributes its own post-service buffer, so adding
-- a pre-buffer to the external event would double the separation.

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

  -- Avoid adding the same buffer again on status/metadata-only updates. Google
  -- reconciliation writes the raw event range back when the remote event is
  -- inserted or changes, so those updates still pass through this branch once.
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

drop trigger if exists resource_allocations_external_physical_post_buffer
  on public.resource_allocations;

create trigger resource_allocations_external_physical_post_buffer
before insert or update of occupied_range
on public.resource_allocations
for each row
execute function public.apply_external_physical_post_buffer();

comment on function public.apply_external_physical_post_buffer() is
  'Extends changed/new EXTERNAL_BLOCK ranges only after the raw event on PHYSICAL resources, using the maximum active required-service buffer_after_minutes. The lower bound is intentionally unchanged to avoid double buffering before external events.';
