-- A valid Google push watch is the normal steady-state signal after an initial sync.
-- Requiring last_success_at to be younger than 10 minutes even while the watch is
-- active makes public availability fail closed whenever there are no calendar
-- changes for 10 minutes. Keep the fail-closed behavior for disconnected,
-- never-synced, unhealthy, or unwatched stale calendars.

create or replace function public.google_resource_sync_is_ready(
  p_resource_id uuid,
  p_max_age_seconds integer default 600
)
returns boolean
language sql
stable
set search_path to 'public'
as $function$
  select not exists (
    select 1
    from public.google_calendar_resources gcr
    join public.google_calendars gc
      on gc.id = gcr.google_calendar_id
    join public.google_connections gconn
      on gconn.id = gc.google_connection_id
    left join public.google_sync_state gss
      on gss.google_calendar_id = gc.id
    where gcr.resource_id = p_resource_id
      and gc.is_active
      and (
        gconn.status <> 'ACTIVE'
        or gss.google_calendar_id is null
        or gss.health_status <> 'HEALTHY'
        or gss.last_success_at is null
        or (
          not public.google_sync_is_fresh(gc.id, p_max_age_seconds)
          and not exists (
            select 1
            from public.google_watch_channels gwc
            where gwc.google_calendar_id = gc.id
              and gwc.status = 'ACTIVE'
              and gwc.expiration_at > now()
          )
        )
      )
  );
$function$;

comment on function public.google_resource_sync_is_ready(uuid, integer) is
  'Fail-closed Google readiness gate. A mapped calendar is ready after a healthy initial sync when either its sync is recent or it has an active, unexpired Google push watch.';
