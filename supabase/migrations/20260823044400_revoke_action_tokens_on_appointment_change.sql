-- Action links are valid only for the appointment state/start time they were issued for.
-- Any status or start_at change revokes unconsumed action-specific tokens. Generic
-- VIEW/MANAGE/PAY tokens retain their existing behavior.

create or replace function public.revoke_action_tokens_after_appointment_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if old.status is distinct from new.status or old.start_at is distinct from new.start_at then
    perform public.service_revoke_appointment_action_tokens(
      new.id,
      case
        when old.status is distinct from new.status and old.start_at is distinct from new.start_at then 'APPOINTMENT_STATUS_AND_START_CHANGED'
        when old.status is distinct from new.status then 'APPOINTMENT_STATUS_CHANGED'
        else 'APPOINTMENT_START_CHANGED'
      end,
      null
    );
  end if;
  return new;
end;
$$;

revoke execute on function public.revoke_action_tokens_after_appointment_change()
  from public, anon, authenticated;

drop trigger if exists appointments_revoke_action_tokens on public.appointments;
create trigger appointments_revoke_action_tokens
after update of status, start_at on public.appointments
for each row
when (old.status is distinct from new.status or old.start_at is distinct from new.start_at)
execute function public.revoke_action_tokens_after_appointment_change();
