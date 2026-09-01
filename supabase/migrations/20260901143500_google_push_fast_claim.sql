create or replace function public.claim_google_calendar_sync_job(
  p_google_calendar_id uuid,
  p_worker_id text
)
returns public.integration_jobs
language plpgsql
security definer
set search_path = public
as $$
declare
  v_job public.integration_jobs%rowtype;
begin
  if p_google_calendar_id is null then
    raise exception using errcode = 'P0001', message = 'GOOGLE_CALENDAR_ID_REQUIRED';
  end if;

  if p_worker_id is null or btrim(p_worker_id) = '' then
    raise exception using errcode = 'P0001', message = 'INTEGRATION_WORKER_ID_REQUIRED';
  end if;

  -- Serialize the immediate webhook lane per calendar. This avoids two Google push
  -- notifications starting overlapping incremental syncs for the same calendar.
  perform pg_advisory_xact_lock(
    hashtextextended('GOOGLE_CALENDAR_SYNC|' || p_google_calendar_id::text, 0)
  );

  if exists (
    select 1
    from public.integration_jobs ij
    where ij.job_type = 'GOOGLE_CALENDAR_SYNC'
      and ij.entity_id = p_google_calendar_id
      and ij.status = 'PROCESSING'
  ) then
    return null;
  end if;

  select ij.*
  into v_job
  from public.integration_jobs ij
  where ij.job_type = 'GOOGLE_CALENDAR_SYNC'
    and ij.entity_id = p_google_calendar_id
    and ij.status = 'PENDING'
    and ij.run_after <= now()
    and ij.attempt_count < ij.max_attempts
  order by ij.created_at desc
  for update skip locked
  limit 1;

  if not found then
    return null;
  end if;

  update public.integration_jobs ij
  set status = 'PROCESSING',
      attempt_count = ij.attempt_count + 1,
      locked_at = now(),
      locked_by = p_worker_id,
      updated_at = now()
  where ij.id = v_job.id
  returning ij.* into v_job;

  return v_job;
end;
$$;

revoke all on function public.claim_google_calendar_sync_job(uuid, text) from public;
grant execute on function public.claim_google_calendar_sync_job(uuid, text) to service_role;
