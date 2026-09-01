-- Make Google external block reconciliation idempotent across shared-calendar mirrors.
-- A shared Google calendar can be discovered through multiple connected accounts. The
-- stable identity of an external block is the remote calendar/event/instance/resource,
-- not the internal google_calendar_events row used to observe it.

create or replace function public.apply_google_calendar_event_state(p_event_id uuid)
returns jsonb
language plpgsql
volatile
set search_path = public
as $$
declare
  v_event public.google_calendar_events%rowtype;
  v_qualification public.google_event_qualification;
  v_range tstzrange;
  v_resource record;
  v_active_range tstzrange;
  v_external_calendar_id text;
  v_conflict_count integer := 0;
  v_allocation_count integer := 0;
begin
  select * into v_event
  from public.google_calendar_events
  where id = p_event_id
  for update;

  if not found then
    raise exception using errcode = 'P0001', message = 'GOOGLE_EVENT_NOT_FOUND';
  end if;

  select gc.google_calendar_id
  into v_external_calendar_id
  from public.google_calendars gc
  where gc.id = v_event.google_calendar_id;

  if v_external_calendar_id is null then
    raise exception using errcode = 'P0001', message = 'GOOGLE_CALENDAR_NOT_FOUND';
  end if;

  -- Serialize reconciliation by the stable remote identity so webhook and periodic
  -- reconciliation cannot create competing allocations for the same Google event.
  perform pg_advisory_xact_lock(hashtextextended(concat_ws('|',
    'GOOGLE',
    v_external_calendar_id,
    v_event.google_event_id,
    coalesce(v_event.original_start_at::text, '-infinity')
  ), 0));

  v_qualification := public.qualify_google_calendar_event(p_event_id);

  update public.google_calendar_events
  set qualification = v_qualification,
      last_seen_at = now(),
      updated_at = now()
  where id = p_event_id;

  if v_qualification <> 'BLOCKING' then
    update public.resource_allocations
    set status = 'RELEASED',
        google_calendar_event_id = p_event_id,
        updated_at = now()
    where allocation_type = 'EXTERNAL_BLOCK'
      and status in ('EXTERNAL_ACTIVE','IGNORED_BY_ADMIN')
      and external_source = 'GOOGLE'
      and external_calendar_id = v_external_calendar_id
      and external_event_id = v_event.google_event_id
      and coalesce(external_event_instance_start, '-infinity'::timestamptz)
          = coalesce(v_event.original_start_at, '-infinity'::timestamptz);

    update public.schedule_divergences
    set status = 'RESOLVED',
        resolved_at = now(),
        resolution_notes = coalesce(resolution_notes, '') || case when resolution_notes is null or resolution_notes = '' then '' else E'\n' end || 'Remote event no longer qualifies as blocking.',
        updated_at = now()
    where google_calendar_event_id = p_event_id
      and status = 'OPEN';

    return jsonb_build_object(
      'event_id', p_event_id,
      'qualification', v_qualification,
      'allocations', 0,
      'divergences', 0
    );
  end if;

  v_range := public.google_event_desired_range(p_event_id);

  begin
    -- Any existing row for the same stable remote identity is authoritative, even
    -- if it was originally materialized from another connected account's mirror.
    -- Resources no longer mapped by the canonical calendar are released.
    update public.resource_allocations ra
    set status = 'RELEASED',
        google_calendar_event_id = p_event_id,
        updated_at = now()
    where ra.allocation_type = 'EXTERNAL_BLOCK'
      and ra.external_source = 'GOOGLE'
      and ra.external_calendar_id = v_external_calendar_id
      and ra.external_event_id = v_event.google_event_id
      and coalesce(ra.external_event_instance_start, '-infinity'::timestamptz)
          = coalesce(v_event.original_start_at, '-infinity'::timestamptz)
      and not exists (
        select 1
        from public.google_calendar_resources gcr
        where gcr.google_calendar_id = v_event.google_calendar_id
          and gcr.resource_id = ra.resource_id
      );

    -- Adopt/update stable remote rows in place. This is the key shared-calendar
    -- idempotency rule: the internal mirror may change, the remote identity does not.
    update public.resource_allocations ra
    set google_calendar_event_id = p_event_id,
        occupied_range = v_range,
        status = case
          when ra.status = 'IGNORED_BY_ADMIN'
           and ra.external_payload_hash_at_ignore = v_event.payload_hash
          then 'IGNORED_BY_ADMIN'::public.allocation_status
          else 'EXTERNAL_ACTIVE'::public.allocation_status
        end,
        ignored_by_admin_id = case
          when ra.status = 'IGNORED_BY_ADMIN'
           and ra.external_payload_hash_at_ignore = v_event.payload_hash
          then ra.ignored_by_admin_id else null end,
        ignored_at = case
          when ra.status = 'IGNORED_BY_ADMIN'
           and ra.external_payload_hash_at_ignore = v_event.payload_hash
          then ra.ignored_at else null end,
        ignore_reason = case
          when ra.status = 'IGNORED_BY_ADMIN'
           and ra.external_payload_hash_at_ignore = v_event.payload_hash
          then ra.ignore_reason else null end,
        external_payload_hash_at_ignore = case
          when ra.status = 'IGNORED_BY_ADMIN'
           and ra.external_payload_hash_at_ignore = v_event.payload_hash
          then ra.external_payload_hash_at_ignore else null end,
        external_event_recurring_id = v_event.recurring_event_id,
        external_event_instance_start = v_event.original_start_at,
        updated_at = now()
    where ra.allocation_type = 'EXTERNAL_BLOCK'
      and ra.external_source = 'GOOGLE'
      and ra.external_calendar_id = v_external_calendar_id
      and ra.external_event_id = v_event.google_event_id
      and coalesce(ra.external_event_instance_start, '-infinity'::timestamptz)
          = coalesce(v_event.original_start_at, '-infinity'::timestamptz)
      and exists (
        select 1
        from public.google_calendar_resources gcr
        where gcr.google_calendar_id = v_event.google_calendar_id
          and gcr.resource_id = ra.resource_id
      );

    -- Only genuinely new remote identities receive a new allocation row.
    insert into public.resource_allocations (
      resource_id,
      allocation_type,
      status,
      occupied_range,
      external_source,
      external_calendar_id,
      external_event_id,
      external_event_recurring_id,
      external_event_instance_start,
      google_calendar_event_id
    )
    select
      gcr.resource_id,
      'EXTERNAL_BLOCK',
      'EXTERNAL_ACTIVE',
      v_range,
      'GOOGLE',
      v_external_calendar_id,
      v_event.google_event_id,
      v_event.recurring_event_id,
      v_event.original_start_at,
      p_event_id
    from public.google_calendar_resources gcr
    where gcr.google_calendar_id = v_event.google_calendar_id
      and not exists (
        select 1
        from public.resource_allocations ra
        where ra.allocation_type = 'EXTERNAL_BLOCK'
          and ra.external_source = 'GOOGLE'
          and ra.external_calendar_id = v_external_calendar_id
          and ra.external_event_id = v_event.google_event_id
          and ra.resource_id = gcr.resource_id
          and coalesce(ra.external_event_instance_start, '-infinity'::timestamptz)
              = coalesce(v_event.original_start_at, '-infinity'::timestamptz)
      );

    select count(*)::integer
    into v_allocation_count
    from public.resource_allocations ra
    where ra.google_calendar_event_id = p_event_id
      and ra.status = 'EXTERNAL_ACTIVE';

    update public.schedule_divergences
    set status = 'RESOLVED',
        resolved_at = now(),
        resolution_notes = coalesce(resolution_notes, '') || case when resolution_notes is null or resolution_notes = '' then '' else E'\n' end || 'Desired external allocation applied successfully.',
        updated_at = now()
    where google_calendar_event_id = p_event_id
      and status = 'OPEN';

  exception
    when exclusion_violation then
      v_allocation_count := 0;

      for v_resource in
        select
          gcr.resource_id,
          ra.appointment_id,
          ra.occupied_range
        from public.google_calendar_resources gcr
        left join lateral (
          select ra.appointment_id, ra.occupied_range
          from public.resource_allocations ra
          where ra.resource_id = gcr.resource_id
            and ra.status in ('HELD','AWAITING_PAYMENT','CONFIRMED','BLOCKED','EXTERNAL_ACTIVE')
            and ra.google_calendar_event_id is distinct from p_event_id
            and ra.occupied_range && v_range
          order by lower(ra.occupied_range)
          limit 1
        ) ra on true
        where gcr.google_calendar_id = v_event.google_calendar_id
          and ra.occupied_range is not null
      loop
        select ra.occupied_range into v_active_range
        from public.resource_allocations ra
        where ra.google_calendar_event_id = p_event_id
          and ra.resource_id = v_resource.resource_id
          and ra.status in ('EXTERNAL_ACTIVE','IGNORED_BY_ADMIN')
        order by ra.created_at desc
        limit 1;

        insert into public.schedule_divergences (
          resource_id,
          appointment_id,
          google_calendar_event_id,
          desired_range,
          active_range,
          reason
        ) values (
          v_resource.resource_id,
          v_resource.appointment_id,
          p_event_id,
          v_range,
          v_active_range,
          'GOOGLE_EVENT_CONFLICT'
        )
        on conflict (google_calendar_event_id, resource_id) where status = 'OPEN'
        do update set
          appointment_id = excluded.appointment_id,
          desired_range = excluded.desired_range,
          active_range = excluded.active_range,
          detected_at = now(),
          updated_at = now();

        v_conflict_count := v_conflict_count + 1;
      end loop;
  end;

  return jsonb_build_object(
    'event_id', p_event_id,
    'qualification', v_qualification,
    'desired_range', v_range,
    'allocations', v_allocation_count,
    'divergences', v_conflict_count
  );
end;
$$;

comment on function public.apply_google_calendar_event_state(uuid) is
'Reconciles one Google event using stable remote identity so shared-calendar mirrors and concurrent sync triggers remain idempotent.';
