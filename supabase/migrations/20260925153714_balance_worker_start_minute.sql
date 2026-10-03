-- Dedicated minute cadence for BlackSheep balance collection delivery.
-- The existing full integration fallback remains every 5 minutes.
-- This dedicated trigger invokes only the balance worker every minute so the
-- outstanding balance email is created/sent at the reservation start minute.

create or replace function public.service_invoke_balance_worker_minute_cron()
returns bigint
language plpgsql
security definer
set search_path to 'public', 'vault', 'net', 'pg_temp'
as $function$
declare
  v_secret text;
  v_request_id bigint;
begin
  select decrypted_secret into v_secret
  from vault.decrypted_secrets
  where name = 'integration_worker_db_cron_secret'
  limit 1;

  if nullif(v_secret, '') is null then
    raise exception using errcode = 'P0001', message = 'INTEGRATION_WORKER_DB_CRON_SECRET_MISSING';
  end if;

  select net.http_post(
    url := 'https://sbexdggbwqvyhbkatucs.supabase.co/functions/v1/integration-worker-trigger',
    headers := jsonb_build_object(
      'content-type', 'application/json',
      'x-db-cron-secret', v_secret
    ),
    body := jsonb_build_object('target','BALANCE'),
    timeout_milliseconds := 30000
  ) into v_request_id;

  return v_request_id;
end;
$function$;

revoke all on function public.service_invoke_balance_worker_minute_cron() from public, anon, authenticated;
grant execute on function public.service_invoke_balance_worker_minute_cron() to service_role;

do $$
declare
  v_jobid bigint;
  v_is_production boolean;
begin
  select exists (
    select 1
    from vault.decrypted_secrets
    where name = 'agenda_production_marker'
      and decrypted_secret = 'sbexdggbwqvyhbkatucs'
  ) into v_is_production;

  if not v_is_production then
    return;
  end if;

  select jobid into v_jobid
  from cron.job
  where jobname = 'balance-worker-start-minute'
  limit 1;

  if v_jobid is not null then
    perform cron.unschedule(v_jobid);
  end if;

  perform cron.schedule(
    'balance-worker-start-minute',
    '* * * * *',
    'select public.service_invoke_balance_worker_minute_cron();'
  );
end;
$$;
