alter table public.resource_allocations
  add column external_payload_hash_at_ignore text;

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

  v_qualification := public.qualify_google_calendar_event(p_event_id);

  update public.google_calendar_events
  set qualification = v_qualification,
      last_seen_at = now(),
      updated_at = now()
  where id = p_event_id;

  if v_qualification <> 'BLOCKING' then
    update public.resource_allocations
    set status = 'RELEASED',
        updated_at = now()
    where google_calendar_event_id = p_event_id
      and allocation_type = 'EXTERNAL_BLOCK'
      and status in ('EXTERNAL_ACTIVE','IGNORED_BY_ADMIN');

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
    -- Resources no longer mapped are released.
    update public.resource_allocations ra
    set status = 'RELEASED',
        updated_at = now()
    where ra.google_calendar_event_id = p_event_id
      and ra.allocation_type = 'EXTERNAL_BLOCK'
      and ra.status in ('EXTERNAL_ACTIVE','IGNORED_BY_ADMIN')
      and not exists (
        select 1
        from public.google_calendar_resources gcr
        where gcr.google_calendar_id = v_event.google_calendar_id
          and gcr.resource_id = ra.resource_id
      );

    -- Existing rows are moved in place, avoiding duplicate remote identities.
    update public.resource_allocations ra
    set occupied_range = v_range,
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
    where ra.google_calendar_event_id = p_event_id
      and ra.allocation_type = 'EXTERNAL_BLOCK'
      and exists (
        select 1
        from public.google_calendar_resources gcr
        where gcr.google_calendar_id = v_event.google_calendar_id
          and gcr.resource_id = ra.resource_id
      );

    -- New resource mappings receive one stable allocation row.
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
      gc.google_calendar_id,
      v_event.google_event_id,
      v_event.recurring_event_id,
      v_event.original_start_at,
      p_event_id
    from public.google_calendar_resources gcr
    join public.google_calendars gc on gc.id = gcr.google_calendar_id
    where gcr.google_calendar_id = v_event.google_calendar_id
      and not exists (
        select 1
        from public.resource_allocations ra
        where ra.google_calendar_event_id = p_event_id
          and ra.resource_id = gcr.resource_id
          and ra.allocation_type = 'EXTERNAL_BLOCK'
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

create or replace function public.ignore_google_external_block(
  p_allocation_id uuid,
  p_admin_user_id uuid,
  p_reason text
)
returns jsonb
language plpgsql
volatile
set search_path = public
as $$
declare
  v_allocation public.resource_allocations%rowtype;
  v_payload_hash text;
begin
  if p_reason is null or btrim(p_reason) = '' then
    raise exception using errcode = 'P0001', message = 'IGNORE_REASON_REQUIRED';
  end if;

  select * into v_allocation
  from public.resource_allocations
  where id = p_allocation_id
  for update;

  if not found then
    raise exception using errcode = 'P0001', message = 'EXTERNAL_BLOCK_NOT_FOUND';
  end if;

  if v_allocation.allocation_type <> 'EXTERNAL_BLOCK'
     or v_allocation.status <> 'EXTERNAL_ACTIVE' then
    raise exception using errcode = 'P0001', message = 'EXTERNAL_BLOCK_NOT_IGNORABLE';
  end if;

  select payload_hash into v_payload_hash
  from public.google_calendar_events
  where id = v_allocation.google_calendar_event_id;

  update public.resource_allocations
  set status = 'IGNORED_BY_ADMIN',
      ignored_by_admin_id = p_admin_user_id,
      ignored_at = now(),
      ignore_reason = p_reason,
      external_payload_hash_at_ignore = v_payload_hash,
      updated_at = now()
  where id = p_allocation_id;

  insert into public.audit_logs (
    admin_user_id,
    entity_type,
    entity_id,
    action,
    before_json,
    after_json,
    origin
  ) values (
    p_admin_user_id,
    'RESOURCE_ALLOCATION',
    p_allocation_id,
    'GOOGLE_EXTERNAL_BLOCK_IGNORED',
    jsonb_build_object('status', v_allocation.status),
    jsonb_build_object('status', 'IGNORED_BY_ADMIN', 'reason', p_reason),
    'ADMIN'
  );

  return jsonb_build_object(
    'allocation_id', p_allocation_id,
    'status', 'IGNORED_BY_ADMIN'
  );
end;
$$;
