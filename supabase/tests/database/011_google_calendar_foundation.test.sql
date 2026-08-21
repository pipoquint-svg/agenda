begin;

create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;

select plan(17);

insert into public.resources (id, name, resource_type)
values ('92000000-0000-0000-0000-000000000001', 'GOOGLE TEST STUDIO', 'PHYSICAL');

insert into public.google_connections (
  id, account_email, scopes, status
) values (
  '92000000-0000-0000-0000-000000000010',
  'calendar-test@example.com',
  array['calendar.events','calendar.calendarlist.readonly'],
  'ACTIVE'
);

insert into public.google_calendars (
  id, google_connection_id, google_calendar_id, name, timezone
) values (
  '92000000-0000-0000-0000-000000000020',
  '92000000-0000-0000-0000-000000000010',
  'studio@example.com',
  'Studio Google Test',
  'America/Sao_Paulo'
);

insert into public.google_calendar_resources (google_calendar_id, resource_id)
values (
  '92000000-0000-0000-0000-000000000020',
  '92000000-0000-0000-0000-000000000001'
);

select is(
  public.google_sync_is_fresh('92000000-0000-0000-0000-000000000020', 120),
  false,
  'calendar without successful sync is not fresh'
);

select public.mark_google_sync_success(
  '92000000-0000-0000-0000-000000000020',
  'sync-token-1',
  true
);

select is(
  public.google_sync_is_fresh('92000000-0000-0000-0000-000000000020', 120),
  true,
  'successful sync marks calendar healthy and fresh'
);

select public.mark_google_sync_failure(
  '92000000-0000-0000-0000-000000000020',
  '410 fullSyncRequired',
  true
);

select ok(
  exists (
    select 1
    from public.google_sync_state
    where google_calendar_id = '92000000-0000-0000-0000-000000000020'
      and health_status = 'STALE'
      and sync_token is null
  ),
  '410-style failure marks state stale and clears invalid sync token'
);

select is(
  (public.upsert_google_calendar_event(
    p_google_calendar_id => '92000000-0000-0000-0000-000000000020',
    p_google_event_id => 'transparent-1',
    p_status => 'confirmed',
    p_start_at => '2035-01-15 09:00:00-03'::timestamptz,
    p_end_at => '2035-01-15 10:00:00-03'::timestamptz,
    p_transparency => 'transparent',
    p_normalized_payload => '{"v":1}'::jsonb
  )->>'qualification'),
  'IGNORED_TRANSPARENT',
  'transparent event is ignored by default'
);

select is(
  (public.upsert_google_calendar_event(
    p_google_calendar_id => '92000000-0000-0000-0000-000000000020',
    p_google_event_id => 'declined-1',
    p_status => 'confirmed',
    p_start_at => '2035-01-15 10:00:00-03'::timestamptz,
    p_end_at => '2035-01-15 11:00:00-03'::timestamptz,
    p_self_response_status => 'declined',
    p_normalized_payload => '{"v":1}'::jsonb
  )->>'qualification'),
  'IGNORED_DECLINED',
  'declined invitation is ignored by default'
);

select is(
  (public.upsert_google_calendar_event(
    p_google_calendar_id => '92000000-0000-0000-0000-000000000020',
    p_google_event_id => 'all-day-1',
    p_status => 'confirmed',
    p_is_all_day => true,
    p_start_date => '2035-01-16'::date,
    p_end_date => '2035-01-17'::date,
    p_normalized_payload => '{"v":1}'::jsonb
  )->>'qualification'),
  'IGNORED_ALL_DAY',
  'all-day event is ignored when calendar block_all_day_events is false'
);

select is(
  (public.upsert_google_calendar_event(
    p_google_calendar_id => '92000000-0000-0000-0000-000000000020',
    p_google_event_id => 'managed-1',
    p_status => 'confirmed',
    p_start_at => '2035-01-15 11:00:00-03'::timestamptz,
    p_end_at => '2035-01-15 12:00:00-03'::timestamptz,
    p_managed_by_agenda => true,
    p_bs_source => 'blacksheep_agenda',
    p_normalized_payload => '{"v":1}'::jsonb
  )->>'qualification'),
  'MANAGED',
  'Agenda-managed Google mirror never becomes an external block'
);

create temporary table blocking_event as
select public.upsert_google_calendar_event(
  p_google_calendar_id => '92000000-0000-0000-0000-000000000020',
  p_google_event_id => 'blocking-1',
  p_status => 'confirmed',
  p_start_at => '2035-01-15 09:00:00-03'::timestamptz,
  p_end_at => '2035-01-15 10:00:00-03'::timestamptz,
  p_normalized_payload => '{"v":1}'::jsonb
) as payload;

select is(
  (select payload->>'qualification' from blocking_event),
  'BLOCKING',
  'opaque timed event qualifies as blocking'
);

select is(
  (select count(*)::integer
   from public.resource_allocations ra
   where ra.google_calendar_event_id = ((select payload->>'google_calendar_event_id' from blocking_event))::uuid
     and ra.status = 'EXTERNAL_ACTIVE'),
  1,
  'blocking event creates exactly one external allocation for mapped resource'
);

select public.upsert_google_calendar_event(
  p_google_calendar_id => '92000000-0000-0000-0000-000000000020',
  p_google_event_id => 'blocking-1',
  p_status => 'confirmed',
  p_start_at => '2035-01-15 09:00:00-03'::timestamptz,
  p_end_at => '2035-01-15 10:00:00-03'::timestamptz,
  p_normalized_payload => '{"v":1}'::jsonb
);

select is(
  (select count(*)::integer
   from public.resource_allocations ra
   where ra.google_calendar_event_id = ((select payload->>'google_calendar_event_id' from blocking_event))::uuid),
  1,
  'replaying identical remote event is allocation-idempotent'
);

create temporary table ignored_block as
select public.ignore_google_external_block(
  (select ra.id
   from public.resource_allocations ra
   where ra.google_calendar_event_id = ((select payload->>'google_calendar_event_id' from blocking_event))::uuid),
  '92000000-0000-0000-0000-000000000099',
  'Known exception for test'
) as payload;

select is(
  (select payload->>'status' from ignored_block),
  'IGNORED_BY_ADMIN',
  'admin can dismiss a specific active external block with reason'
);

select public.upsert_google_calendar_event(
  p_google_calendar_id => '92000000-0000-0000-0000-000000000020',
  p_google_event_id => 'blocking-1',
  p_status => 'confirmed',
  p_start_at => '2035-01-15 09:00:00-03'::timestamptz,
  p_end_at => '2035-01-15 10:00:00-03'::timestamptz,
  p_normalized_payload => '{"v":1}'::jsonb
);

select ok(
  exists (
    select 1
    from public.resource_allocations ra
    where ra.google_calendar_event_id = ((select payload->>'google_calendar_event_id' from blocking_event))::uuid
      and ra.status = 'IGNORED_BY_ADMIN'
  ),
  'unchanged remote payload preserves administrative ignore'
);

select public.upsert_google_calendar_event(
  p_google_calendar_id => '92000000-0000-0000-0000-000000000020',
  p_google_event_id => 'blocking-1',
  p_status => 'confirmed',
  p_start_at => '2035-01-15 10:00:00-03'::timestamptz,
  p_end_at => '2035-01-15 11:00:00-03'::timestamptz,
  p_normalized_payload => '{"v":2}'::jsonb
);

select ok(
  exists (
    select 1
    from public.resource_allocations ra
    where ra.google_calendar_event_id = ((select payload->>'google_calendar_event_id' from blocking_event))::uuid
      and ra.status = 'EXTERNAL_ACTIVE'
      and ra.occupied_range = tstzrange(
        '2035-01-15 10:00:00-03'::timestamptz,
        '2035-01-15 11:00:00-03'::timestamptz,
        '[)'
      )
  ),
  'changed remote payload invalidates prior ignore and reevaluates the block'
);

select public.upsert_google_calendar_event(
  p_google_calendar_id => '92000000-0000-0000-0000-000000000020',
  p_google_event_id => 'blocking-1',
  p_status => 'cancelled',
  p_normalized_payload => '{"v":3,"cancelled":true}'::jsonb
);

select ok(
  exists (
    select 1
    from public.resource_allocations ra
    where ra.google_calendar_event_id = ((select payload->>'google_calendar_event_id' from blocking_event))::uuid
      and ra.status = 'RELEASED'
  ),
  'Google cancellation releases active external allocation'
);

select is(
  (public.upsert_google_calendar_event(
    p_google_calendar_id => '92000000-0000-0000-0000-000000000020',
    p_google_event_id => 'cancelled-recurring-instance',
    p_status => 'cancelled',
    p_is_all_day => true,
    p_recurring_event_id => 'recurring-parent',
    p_original_start_date => '2035-01-20'::date,
    p_normalized_payload => '{"status":"cancelled"}'::jsonb
  )->>'qualification'),
  'CANCELLED',
  'sparse cancelled recurring instance is accepted without start/end payload'
);

create temporary table conflict_event as
select public.upsert_google_calendar_event(
  p_google_calendar_id => '92000000-0000-0000-0000-000000000020',
  p_google_event_id => 'move-conflict-1',
  p_status => 'confirmed',
  p_start_at => '2035-01-15 12:00:00-03'::timestamptz,
  p_end_at => '2035-01-15 13:00:00-03'::timestamptz,
  p_normalized_payload => '{"v":1}'::jsonb
) as payload;

insert into public.resource_allocations (
  resource_id, allocation_type, status, occupied_range, reason
) values (
  '92000000-0000-0000-0000-000000000001',
  'MANUAL_BLOCK',
  'BLOCKED',
  tstzrange(
    '2035-01-15 14:00:00-03'::timestamptz,
    '2035-01-15 15:00:00-03'::timestamptz,
    '[)'
  ),
  'Internal conflict target'
);

select public.upsert_google_calendar_event(
  p_google_calendar_id => '92000000-0000-0000-0000-000000000020',
  p_google_event_id => 'move-conflict-1',
  p_status => 'confirmed',
  p_start_at => '2035-01-15 14:00:00-03'::timestamptz,
  p_end_at => '2035-01-15 15:00:00-03'::timestamptz,
  p_normalized_payload => '{"v":2}'::jsonb
);

select ok(
  exists (
    select 1
    from public.resource_allocations ra
    where ra.google_calendar_event_id = ((select payload->>'google_calendar_event_id' from conflict_event))::uuid
      and ra.status = 'EXTERNAL_ACTIVE'
      and ra.occupied_range = tstzrange(
        '2035-01-15 12:00:00-03'::timestamptz,
        '2035-01-15 13:00:00-03'::timestamptz,
        '[)'
      )
  ),
  'conflicting Google move preserves previous safe blocking allocation'
);

select ok(
  exists (
    select 1
    from public.schedule_divergences sd
    where sd.google_calendar_event_id = ((select payload->>'google_calendar_event_id' from conflict_event))::uuid
      and sd.status = 'OPEN'
      and sd.desired_range = tstzrange(
        '2035-01-15 14:00:00-03'::timestamptz,
        '2035-01-15 15:00:00-03'::timestamptz,
        '[)'
      )
      and sd.active_range = tstzrange(
        '2035-01-15 12:00:00-03'::timestamptz,
        '2035-01-15 13:00:00-03'::timestamptz,
        '[)'
      )
  ),
  'conflicting Google move opens divergence with desired and active ranges'
);

select * from finish();
rollback;