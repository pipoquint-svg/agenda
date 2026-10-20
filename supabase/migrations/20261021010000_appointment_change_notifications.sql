-- Customer messages for a confirmed reservation that changes:
--   * new date or time  -> APPOINTMENT_RESCHEDULED, with the previous times;
--   * cancelled         -> APPOINTMENT_CANCELLED;
--   * any other change  -> the updated confirmation, as before.
-- The worker hands event_key and the previous times to email-send.

create or replace function public.enqueue_confirmation_email_on_confirmed_appointment_change()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if old.status = 'CONFIRMED'
     and new.status = 'CONFIRMED'
     and coalesce(new.version,0) > coalesce(old.version,0)
  then
    insert into public.integration_jobs(
      job_type, entity_type, entity_id, entity_version, payload_json, idempotency_key
    )
    values(
      'APPOINTMENT_CONFIRMED_MESSAGE',
      'APPOINTMENT',
      new.id,
      new.version,
      case
        when new.start_at is distinct from old.start_at or new.end_at is distinct from old.end_at then
          jsonb_build_object(
            'reason','APPOINTMENT_RESCHEDULED',
            'event_key','APPOINTMENT_RESCHEDULED',
            'previous_start_at', old.start_at,
            'previous_end_at', old.end_at
          )
        else jsonb_build_object('reason','APPOINTMENT_UPDATED')
      end,
      'appointment-confirmed-message:'||new.id::text||':'||new.version::text
    )
    on conflict(idempotency_key) do nothing;
  elsif old.status = 'CONFIRMED' and new.status = 'CANCELLED' then
    insert into public.integration_jobs(
      job_type, entity_type, entity_id, entity_version, payload_json, idempotency_key
    )
    values(
      'APPOINTMENT_CONFIRMED_MESSAGE',
      'APPOINTMENT',
      new.id,
      new.version,
      jsonb_build_object('reason','APPOINTMENT_CANCELLED','event_key','APPOINTMENT_CANCELLED'),
      'appointment-cancelled-message:'||new.id::text||':'||coalesce(new.version,0)::text
    )
    on conflict(idempotency_key) do nothing;
  end if;
  return new;
end;
$$;

revoke all on function public.enqueue_confirmation_email_on_confirmed_appointment_change()
  from public, anon, authenticated;
grant execute on function public.enqueue_confirmation_email_on_confirmed_appointment_change()
  to service_role;
