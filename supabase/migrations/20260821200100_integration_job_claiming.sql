alter table public.integration_jobs
  add column if not exists max_attempts integer not null default 5 check (max_attempts >= 1),
  add column if not exists locked_at timestamptz,
  add column if not exists locked_by text;

create index if not exists integration_jobs_processing_lock_idx
  on public.integration_jobs (locked_at)
  where status = 'PROCESSING';

create or replace function public.release_stale_integration_jobs(p_stale_after_seconds integer default 300)
returns integer
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_count integer;
begin
  update public.integration_jobs
  set status = case when attempt_count >= max_attempts then 'FAILED' else 'PENDING' end,
      run_after = case when attempt_count >= max_attempts then run_after else now() end,
      last_error = concat_ws(' | ', nullif(last_error, ''), 'STALE_PROCESSING_RECOVERED'),
      locked_at = null,
      locked_by = null,
      updated_at = now()
  where status = 'PROCESSING'
    and locked_at < now() - make_interval(secs => p_stale_after_seconds);

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

create or replace function public.claim_integration_jobs(
  p_worker_id text,
  p_job_types text[],
  p_limit integer default 10
)
returns setof public.integration_jobs
language sql
volatile
security definer
set search_path = public
as $$
  with selected as (
    select ij.id
    from public.integration_jobs ij
    where ij.status = 'PENDING'
      and ij.run_after <= now()
      and ij.attempt_count < ij.max_attempts
      and ij.job_type = any(p_job_types)
    order by ij.run_after, ij.created_at
    for update skip locked
    limit greatest(1, least(p_limit, 50))
  )
  update public.integration_jobs ij
  set status = 'PROCESSING',
      attempt_count = ij.attempt_count + 1,
      locked_at = now(),
      locked_by = p_worker_id,
      updated_at = now()
  from selected s
  where ij.id = s.id
  returning ij.*;
$$;

create or replace function public.finish_integration_job(
  p_job_id uuid,
  p_worker_id text,
  p_succeeded boolean,
  p_error text default null,
  p_retry_after_seconds integer default null
)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_job public.integration_jobs%rowtype;
begin
  select * into v_job
  from public.integration_jobs
  where id = p_job_id
  for update;

  if not found then
    raise exception using errcode = 'P0001', message = 'INTEGRATION_JOB_NOT_FOUND';
  end if;

  if v_job.status <> 'PROCESSING' or v_job.locked_by is distinct from p_worker_id then
    raise exception using errcode = 'P0001', message = 'INTEGRATION_JOB_LOCK_MISMATCH';
  end if;

  if p_succeeded then
    update public.integration_jobs
    set status = 'SUCCEEDED',
        last_error = null,
        locked_at = null,
        locked_by = null,
        processed_at = now(),
        updated_at = now()
    where id = p_job_id;
  elsif v_job.attempt_count >= v_job.max_attempts or p_retry_after_seconds is null then
    update public.integration_jobs
    set status = 'FAILED',
        last_error = left(coalesce(p_error, 'INTEGRATION_JOB_FAILED'), 4000),
        locked_at = null,
        locked_by = null,
        processed_at = now(),
        updated_at = now()
    where id = p_job_id;
  else
    update public.integration_jobs
    set status = 'PENDING',
        last_error = left(coalesce(p_error, 'INTEGRATION_JOB_RETRY'), 4000),
        run_after = now() + make_interval(secs => greatest(1, p_retry_after_seconds)),
        locked_at = null,
        locked_by = null,
        updated_at = now()
    where id = p_job_id;
  end if;
end;
$$;

revoke all on function public.release_stale_integration_jobs(integer) from public, anon, authenticated;
revoke all on function public.claim_integration_jobs(text,text[],integer) from public, anon, authenticated;
revoke all on function public.finish_integration_job(uuid,text,boolean,text,integer) from public, anon, authenticated;

grant execute on function public.release_stale_integration_jobs(integer) to service_role;
grant execute on function public.claim_integration_jobs(text,text[],integer) to service_role;
grant execute on function public.finish_integration_job(uuid,text,boolean,text,integer) to service_role;
