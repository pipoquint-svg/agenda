create or replace function public.claim_integration_jobs_for_entity(
  p_worker_id text,
  p_entity_type text,
  p_entity_id uuid,
  p_job_types text[],
  p_limit integer default 10
)
returns setof public.integration_jobs
language sql
security definer
set search_path = 'public'
as $function$
  with selected as (
    select ij.id
    from public.integration_jobs ij
    where ij.status = 'PENDING'
      and ij.run_after <= now()
      and ij.attempt_count < ij.max_attempts
      and ij.entity_type = p_entity_type
      and ij.entity_id = p_entity_id
      and ij.job_type = any(p_job_types)
    order by
      case ij.job_type
        when 'APPOINTMENT_CONFIRMED_MESSAGE' then 0
        when 'GOOGLE_APPOINTMENT_SYNC' then 1
        when 'KOMMO_APPOINTMENT_SYNC' then 2
        else 9
      end,
      ij.run_after,
      ij.created_at
    for update skip locked
    limit greatest(1, least(coalesce(p_limit, 10), 20))
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

revoke all on function public.claim_integration_jobs_for_entity(text, text, uuid, text[], integer) from public;
revoke all on function public.claim_integration_jobs_for_entity(text, text, uuid, text[], integer) from anon;
revoke all on function public.claim_integration_jobs_for_entity(text, text, uuid, text[], integer) from authenticated;
grant execute on function public.claim_integration_jobs_for_entity(text, text, uuid, text[], integer) to service_role;

comment on function public.claim_integration_jobs_for_entity(text, text, uuid, text[], integer) is
  'Claims due integration outbox jobs for one entity so request-time fastlane dispatch can process the exact reservation while the periodic worker remains a durable fallback.';
