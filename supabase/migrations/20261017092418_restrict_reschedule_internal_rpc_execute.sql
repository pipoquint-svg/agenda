-- Restrict the two internal rescheduling RPCs to the trusted backend.
-- Applied as a production migration; preserve this change in the Agenda repository.
revoke execute on function public.service_admin_create_reschedule_hold(uuid, timestamptz, timestamptz, text, uuid) from public, anon, authenticated;
revoke execute on function public.service_create_reschedule_difference_payment_intent(uuid, text, text) from public, anon, authenticated;

grant execute on function public.service_admin_create_reschedule_hold(uuid, timestamptz, timestamptz, text, uuid) to service_role;
grant execute on function public.service_create_reschedule_difference_payment_intent(uuid, text, text) to service_role;

do $$
declare
  target regprocedure;
begin
  foreach target in array array[
    'public.service_admin_create_reschedule_hold(uuid,timestamptz,timestamptz,text,uuid)'::regprocedure,
    'public.service_create_reschedule_difference_payment_intent(uuid,text,text)'::regprocedure
  ] loop
    if has_function_privilege('anon', target, 'EXECUTE')
       or has_function_privilege('authenticated', target, 'EXECUTE')
       or not has_function_privilege('service_role', target, 'EXECUTE') then
      raise exception 'Unexpected execute privileges for %', target;
    end if;
  end loop;
end $$;
