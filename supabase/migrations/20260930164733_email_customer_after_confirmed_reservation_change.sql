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
      job_type,
      entity_type,
      entity_id,
      entity_version,
      payload_json,
      idempotency_key
    )
    values(
      'APPOINTMENT_CONFIRMED_MESSAGE',
      'APPOINTMENT',
      new.id,
      new.version,
      jsonb_build_object('reason','APPOINTMENT_UPDATED'),
      'appointment-confirmed-message:'||new.id::text||':'||new.version::text
    )
    on conflict(idempotency_key) do nothing;
  end if;
  return new;
end;
$$;

drop trigger if exists appointments_enqueue_confirmation_email_on_change on public.appointments;

create trigger appointments_enqueue_confirmation_email_on_change
after update of version,status on public.appointments
for each row
execute function public.enqueue_confirmation_email_on_confirmed_appointment_change();
