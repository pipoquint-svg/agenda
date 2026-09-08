-- A private slot may only offer services that actually belong to the slot's
-- booking page. This closes the gap where a mixed service array could select a
-- page through one service while another selected service was not published on it.

create or replace function public.trg_validate_waitlist_private_slot_service()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if not exists (
    select 1
    from public.waitlist_private_slots slot
    join public.booking_page_services bps
      on bps.booking_page_id = slot.booking_page_id
     and bps.service_id = new.service_id
     and bps.is_active
    join public.services svc
      on svc.id = new.service_id
     and svc.is_active
    where slot.id = new.slot_id
  ) then
    raise exception using errcode='P0001', message='WAITLIST_PRIVATE_SERVICE_NOT_ON_PAGE';
  end if;
  return new;
end;
$function$;

drop trigger if exists waitlist_private_slot_service_page_guard_trg
  on public.waitlist_private_slot_services;
create trigger waitlist_private_slot_service_page_guard_trg
before insert or update of slot_id, service_id
on public.waitlist_private_slot_services
for each row
execute function public.trg_validate_waitlist_private_slot_service();

revoke all on function public.trg_validate_waitlist_private_slot_service()
  from public, anon, authenticated;
