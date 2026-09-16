create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron with schema pg_catalog;

grant usage on schema cron to postgres;
grant all privileges on all tables in schema cron to postgres;

create table if not exists public.mercado_pago_webhook_receipts (
  id uuid primary key default gen_random_uuid(),
  received_at timestamptz not null default now(),
  completed_at timestamptz,
  data_id text,
  event_type text,
  action text,
  live_mode boolean,
  request_id_prefix text,
  signature_present boolean not null default false,
  outcome text not null default 'RECEIVED',
  http_status integer,
  detail text
);

create index if not exists mercado_pago_webhook_receipts_received_at_idx
  on public.mercado_pago_webhook_receipts (received_at desc);
create index if not exists mercado_pago_webhook_receipts_data_id_idx
  on public.mercado_pago_webhook_receipts (data_id, received_at desc);

alter table public.mercado_pago_webhook_receipts enable row level security;
revoke all on public.mercado_pago_webhook_receipts from public, anon, authenticated;
grant select, insert, update on public.mercado_pago_webhook_receipts to service_role;

do $$
begin
  if not exists (
    select 1 from vault.decrypted_secrets where name = 'mercado_pago_reconcile_cron_secret'
  ) then
    perform vault.create_secret(
      encode(gen_random_bytes(32), 'hex'),
      'mercado_pago_reconcile_cron_secret',
      'Internal database cron authentication for Mercado Pago reconciliation'
    );
  end if;

  if not exists (
    select 1 from vault.decrypted_secrets where name = 'integration_worker_db_cron_secret'
  ) then
    perform vault.create_secret(
      encode(gen_random_bytes(32), 'hex'),
      'integration_worker_db_cron_secret',
      'Internal database cron authentication for integration worker trigger'
    );
  end if;
end;
$$;

create or replace function public.service_verify_mercado_pago_reconcile_cron_secret(p_secret text)
returns boolean
language sql
stable
security definer
set search_path to 'public', 'vault', 'pg_temp'
as $function$
  select exists (
    select 1
    from vault.decrypted_secrets s
    where s.name = 'mercado_pago_reconcile_cron_secret'
      and s.decrypted_secret = p_secret
      and nullif(btrim(coalesce(p_secret, '')), '') is not null
  );
$function$;

revoke all on function public.service_verify_mercado_pago_reconcile_cron_secret(text) from public, anon, authenticated;
grant execute on function public.service_verify_mercado_pago_reconcile_cron_secret(text) to service_role;

create or replace function public.service_verify_integration_worker_db_cron_secret(p_secret text)
returns boolean
language sql
stable
security definer
set search_path to 'public', 'vault', 'pg_temp'
as $function$
  select exists (
    select 1
    from vault.decrypted_secrets s
    where s.name = 'integration_worker_db_cron_secret'
      and s.decrypted_secret = p_secret
      and nullif(btrim(coalesce(p_secret, '')), '') is not null
  );
$function$;

revoke all on function public.service_verify_integration_worker_db_cron_secret(text) from public, anon, authenticated;
grant execute on function public.service_verify_integration_worker_db_cron_secret(text) to service_role;

create or replace function public.service_invoke_mercado_pago_reconcile_cron()
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
  where name = 'mercado_pago_reconcile_cron_secret'
  limit 1;

  if nullif(v_secret, '') is null then
    raise exception using errcode = 'P0001', message = 'MERCADO_PAGO_RECONCILE_CRON_SECRET_MISSING';
  end if;

  select net.http_post(
    url := 'https://sbexdggbwqvyhbkatucs.supabase.co/functions/v1/mercado-pago-reconcile',
    headers := jsonb_build_object(
      'content-type', 'application/json',
      'x-reconcile-secret', v_secret
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 90000
  ) into v_request_id;

  return v_request_id;
end;
$function$;

revoke all on function public.service_invoke_mercado_pago_reconcile_cron() from public, anon, authenticated;
grant execute on function public.service_invoke_mercado_pago_reconcile_cron() to service_role;

create or replace function public.service_invoke_integration_worker_db_cron()
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
    body := '{}'::jsonb,
    timeout_milliseconds := 120000
  ) into v_request_id;

  return v_request_id;
end;
$function$;

revoke all on function public.service_invoke_integration_worker_db_cron() from public, anon, authenticated;
grant execute on function public.service_invoke_integration_worker_db_cron() to service_role;

do $$
declare
  v_jobid bigint;
begin
  select jobid into v_jobid from cron.job where jobname = 'mercado-pago-reconcile-db-fallback' limit 1;
  if v_jobid is not null then perform cron.unschedule(v_jobid); end if;

  select jobid into v_jobid from cron.job where jobname = 'integration-worker-db-fallback' limit 1;
  if v_jobid is not null then perform cron.unschedule(v_jobid); end if;
end;
$$;

select cron.schedule(
  'mercado-pago-reconcile-db-fallback',
  '*/2 * * * *',
  $$select public.service_invoke_mercado_pago_reconcile_cron();$$
);

select cron.schedule(
  'integration-worker-db-fallback',
  '*/5 * * * *',
  $$select public.service_invoke_integration_worker_db_cron();$$
);
