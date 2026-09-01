create or replace function public.retry_open_google_schedule_divergences_for_resource(
  p_resource_id uuid,
  p_exclude_google_event_id uuid default null,
  p_limit integer default 20
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event_id uuid;
  v_result jsonb;
  v_attempted integer := 0;
  v_resolved integer := 0;
  v_still_open integer := 0;
  v_failed integer := 0;
  v_limit integer := greatest(1, least(coalesce(p_limit, 20), 100));
begin
  if p_resource_id is null then
    raise exception using errcode = 'P0001', message = 'RESOURCE_ID_REQUIRED';
  end if;

  -- Only one recovery lane per resource may run inside a transaction. A concurrent
  -- Google push or appointment mutation can safely leave the recovery to the other lane.
  if not pg_try_advisory_xact_lock(
    hashtextextended('GOOGLE_DIVERGENCE_RETRY|' || p_resource_id::text, 0)
  ) then
    return jsonb_build_object(
      'resource_id', p_resource_id,
      'attempted', 0,
      'resolved', 0,
      'still_open', 0,
      'failed', 0,
      'skipped_locked', true
    );
  end if;

  for v_event_id in
    select sd.google_calendar_event_id
    from public.schedule_divergences sd
    join public.google_calendar_events gce
      on gce.id = sd.google_calendar_event_id
    where sd.resource_id = p_resource_id
      and sd.status = 'OPEN'
      and sd.reason = 'GOOGLE_EVENT_CONFLICT'
      and sd.google_calendar_event_id is not null
      and (p_exclude_google_event_id is null or sd.google_calendar_event_id <> p_exclude_google_event_id)
    group by sd.google_calendar_event_id
    order by min(sd.detected_at), sd.google_calendar_event_id
    limit v_limit
  loop
    v_attempted := v_attempted + 1;
    begin
      v_result := public.apply_google_calendar_event_state(v_event_id);
      if coalesce((v_result->>'divergences')::integer, 0) = 0 then
        v_resolved := v_resolved + 1;
      else
        v_still_open := v_still_open + 1;
      end if;
    exception
      when others then
        -- Recovery is best-effort. Never make the capacity-releasing mutation fail
        -- because another stale/conflicting Google event could not be reapplied.
        v_failed := v_failed + 1;
    end;
  end loop;

  return jsonb_build_object(
    'resource_id', p_resource_id,
    'attempted', v_attempted,
    'resolved', v_resolved,
    'still_open', v_still_open,
    'failed', v_failed,
    'skipped_locked', false
  );
end;
$$;

revoke all on function public.retry_open_google_schedule_divergences_for_resource(uuid, uuid, integer) from public;
grant execute on function public.retry_open_google_schedule_divergences_for_resource(uuid, uuid, integer) to service_role;

create or replace function public.retry_google_divergences_after_capacity_release()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_active_statuses text[] := array['HELD', 'AWAITING_PAYMENT', 'CONFIRMED', 'BLOCKED', 'EXTERNAL_ACTIVE'];
  v_exclude_event_id uuid;
begin
  -- apply_google_calendar_event_state can itself change an allocation while this
  -- recovery lane is running. Ignore nested trigger invocations to avoid recursion.
  if pg_trigger_depth() > 1 then
    if tg_op = 'DELETE' then return old; end if;
    return new;
  end if;

  if tg_op = 'DELETE' then
    if old.status::text = any(v_active_statuses) then
      begin
        perform public.retry_open_google_schedule_divergences_for_resource(
          old.resource_id,
          old.google_calendar_event_id,
          20
        );
      exception when others then
        null;
      end;
    end if;
    return old;
  end if;

  if old.status::text = any(v_active_statuses)
     and (
       new.resource_id is distinct from old.resource_id
       or new.occupied_range is distinct from old.occupied_range
       or not (new.status::text = any(v_active_statuses))
     ) then
    -- Exclude the event whose own allocation is currently being updated. Its outer
    -- apply call will finish its own divergence bookkeeping after this trigger returns.
    v_exclude_event_id := coalesce(new.google_calendar_event_id, old.google_calendar_event_id);
    begin
      perform public.retry_open_google_schedule_divergences_for_resource(
        old.resource_id,
        v_exclude_event_id,
        20
      );
    exception when others then
      null;
    end;
  end if;

  return new;
end;
$$;

revoke all on function public.retry_google_divergences_after_capacity_release() from public;

drop trigger if exists resource_allocations_retry_google_divergences_after_release
  on public.resource_allocations;

create trigger resource_allocations_retry_google_divergences_after_release
after update of status, occupied_range, resource_id or delete
on public.resource_allocations
for each row
execute function public.retry_google_divergences_after_capacity_release();
