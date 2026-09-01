create extension if not exists pg_net with schema extensions;

do $$
begin
  if not exists (
    select 1
    from vault.decrypted_secrets
    where name = 'google_appointment_fastlane_secret'
  ) then
    perform vault.create_secret(
      encode(gen_random_bytes(32), 'hex'),
      'google_appointment_fastlane_secret',
      'Internal database-to-edge authentication for immediate Google appointment sync'
    );
  end if;
end;
$$;

create or replace function public.service_verify_google_appointment_fastlane_secret(p_secret text)
returns boolean
language sql
stable
security definer
set search_path to 'public', 'vault', 'pg_temp'
as $function$
  select exists (
    select 1
    from vault.decrypted_secrets s
    where s.name = 'google_appointment_fastlane_secret'
      and s.decrypted_secret = p_secret
      and nullif(btrim(coalesce(p_secret, '')), '') is not null
  );
$function$;

revoke all on function public.service_verify_google_appointment_fastlane_secret(text) from public, anon, authenticated;
grant execute on function public.service_verify_google_appointment_fastlane_secret(text) to service_role;

create or replace function public.service_enqueue_google_appointment_fastlane(
  p_appointment_id uuid,
  p_entity_version integer
)
returns bigint
language plpgsql
security definer
set search_path to 'public', 'vault', 'net', 'pg_temp'
as $function$
declare
  v_secret text;
  v_request_id bigint;
begin
  if p_appointment_id is null then
    raise exception using errcode = '22023', message = 'APPOINTMENT_ID_REQUIRED';
  end if;
  if p_entity_version is null or p_entity_version < 1 then
    raise exception using errcode = '22023', message = 'ENTITY_VERSION_REQUIRED';
  end if;

  select s.decrypted_secret
    into v_secret
  from vault.decrypted_secrets s
  where s.name = 'google_appointment_fastlane_secret'
  limit 1;

  if nullif(v_secret, '') is null then
    raise exception using errcode = 'P0001', message = 'GOOGLE_APPOINTMENT_FASTLANE_SECRET_MISSING';
  end if;

  select net.http_post(
    url := 'https://sbexdggbwqvyhbkatucs.supabase.co/functions/v1/google-appointment-fastlane',
    headers := jsonb_build_object(
      'content-type', 'application/json',
      'x-fastlane-secret', v_secret
    ),
    body := jsonb_build_object(
      'appointment_id', p_appointment_id,
      'entity_version', p_entity_version
    ),
    timeout_milliseconds := 20000
  ) into v_request_id;

  return v_request_id;
end;
$function$;

revoke all on function public.service_enqueue_google_appointment_fastlane(uuid, integer) from public, anon, authenticated;
grant execute on function public.service_enqueue_google_appointment_fastlane(uuid, integer) to service_role;

create or replace function public.trigger_google_appointment_confirmation_fastlane()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
begin
  if new.status <> 'CONFIRMED' then
    return new;
  end if;

  if tg_op = 'UPDATE' and old.status is not distinct from new.status then
    return new;
  end if;

  perform public.service_enqueue_google_appointment_fastlane(new.id, new.version);
  return new;
exception
  when others then
    raise warning 'GOOGLE_APPOINTMENT_FASTLANE_ENQUEUE_FAILED';
    return new;
end;
$function$;

revoke all on function public.trigger_google_appointment_confirmation_fastlane() from public;

drop trigger if exists trg_google_appointment_confirmation_fastlane on public.appointments;
create trigger trg_google_appointment_confirmation_fastlane
after insert or update on public.appointments
for each row
execute function public.trigger_google_appointment_confirmation_fastlane();
