do $fix_reschedule_hold_slot_end_field$
declare
  v_oid oid;
  v_definition text;
  v_patched text;
begin
  select p.oid
    into v_oid
  from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public'
    and p.proname='create_checkout_hold_for_reschedule'
    and pg_get_function_identity_arguments(p.oid)='p_appointment_id uuid, p_requested_start_at timestamp with time zone';

  if v_oid is null then
    raise exception 'create_checkout_hold_for_reschedule not found';
  end if;

  v_definition:=pg_get_functiondef(v_oid);
  if position('v_slot.requested_end_at' in v_definition)=0 then
    return;
  end if;

  v_patched:=replace(v_definition,'v_slot.requested_end_at','v_slot.slot_end_at');
  execute v_patched;
end;
$fix_reschedule_hold_slot_end_field$;
