create or replace function public.coalesce_natal_kommo_pending_jobs()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if new.job_type <> 'KOMMO_APPOINTMENT_SYNC'
     or new.entity_type <> 'APPOINTMENT'
     or new.status <> 'PENDING' then
    return new;
  end if;

  if not exists (
    select 1
    from public.appointments a
    where a.id = new.entity_id
      and a.service_id = any(array[
        '111e9ae4-f626-4a71-a209-e20166310ee5'::uuid,
        '5268a4a1-2cfb-4c23-a89a-3cf1853fb637'::uuid,
        'ca578a83-2188-4be7-93c8-532c77801b0c'::uuid,
        '0afb550a-3cd0-46f5-9482-b1e219bf9d2e'::uuid
      ])
  ) then
    return new;
  end if;

  update public.integration_jobs ij
  set status = 'DISCARDED_STALE',
      last_error = 'COALESCED_BY_NEWER_NATAL_KOMMO_JOB:' || new.id::text,
      locked_at = null,
      locked_by = null,
      processed_at = now(),
      updated_at = now()
  where ij.job_type = 'KOMMO_APPOINTMENT_SYNC'
    and ij.entity_type = 'APPOINTMENT'
    and ij.entity_id = new.entity_id
    and ij.status = 'PENDING'
    and ij.id <> new.id;

  return new;
end;
$function$;

drop trigger if exists trg_coalesce_natal_kommo_pending_jobs on public.integration_jobs;
create trigger trg_coalesce_natal_kommo_pending_jobs
after insert on public.integration_jobs
for each row
when (new.job_type = 'KOMMO_APPOINTMENT_SYNC' and new.entity_type = 'APPOINTMENT' and new.status = 'PENDING')
execute function public.coalesce_natal_kommo_pending_jobs();

with ranked as (
  select
    ij.id,
    row_number() over (
      partition by ij.entity_id
      order by ij.entity_version desc nulls last, ij.created_at desc, ij.id desc
    ) as rn,
    first_value(ij.id) over (
      partition by ij.entity_id
      order by ij.entity_version desc nulls last, ij.created_at desc, ij.id desc
    ) as keeper_id
  from public.integration_jobs ij
  join public.appointments a on a.id = ij.entity_id
  where ij.job_type = 'KOMMO_APPOINTMENT_SYNC'
    and ij.entity_type = 'APPOINTMENT'
    and ij.status = 'PENDING'
    and a.service_id = any(array[
      '111e9ae4-f626-4a71-a209-e20166310ee5'::uuid,
      '5268a4a1-2cfb-4c23-a89a-3cf1853fb637'::uuid,
      'ca578a83-2188-4be7-93c8-532c77801b0c'::uuid,
      '0afb550a-3cd0-46f5-9482-b1e219bf9d2e'::uuid
    ])
)
update public.integration_jobs ij
set status = 'DISCARDED_STALE',
    last_error = 'COALESCED_NATAL_BACKLOG_KEEPER:' || ranked.keeper_id::text,
    locked_at = null,
    locked_by = null,
    processed_at = now(),
    updated_at = now()
from ranked
where ij.id = ranked.id
  and ranked.rn > 1;

create or replace function public.claim_integration_jobs(
  p_worker_id text,
  p_job_types text[],
  p_limit integer default 10
)
returns setof public.integration_jobs
language sql
security definer
set search_path to 'public'
as $function$
  with params as (
    select
      greatest(1, least(coalesce(p_limit, 10), 50))::integer as base_limit,
      coalesce('KOMMO_APPOINTMENT_SYNC' = any(p_job_types), false) as has_kommo
  ),
  kommo_selected as (
    select ij.id
    from public.integration_jobs ij, params p
    where p.has_kommo
      and ij.status = 'PENDING'
      and ij.run_after <= now()
      and ij.attempt_count < ij.max_attempts
      and ij.job_type = 'KOMMO_APPOINTMENT_SYNC'
    order by ij.run_after, ij.created_at
    for update skip locked
    limit (select least(base_limit, 10) from params)
  ),
  other_selected as (
    select ij.id
    from public.integration_jobs ij, params p
    where ij.status = 'PENDING'
      and ij.run_after <= now()
      and ij.attempt_count < ij.max_attempts
      and ij.job_type = any(p_job_types)
      and ij.job_type <> 'KOMMO_APPOINTMENT_SYNC'
    order by ij.run_after, ij.created_at
    for update skip locked
    limit (
      select case
        when has_kommo then least(greatest(1, (base_limit + 1) / 2), 5)
        else base_limit
      end
      from params
    )
  ),
  selected as (
    select id from kommo_selected
    union all
    select id from other_selected
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
$function$;