-- `calculate_reservation_change` is an authoritative internal calculator consumed
-- by administrative/service-role surfaces. Direct table grants stay closed; the
-- function crosses that boundary as its owner and remains executable only by
-- service_role.

alter function public.calculate_reservation_change(uuid,text,timestamptz,text,numeric)
  security definer;

alter function public.calculate_reservation_change(uuid,text,timestamptz,text,numeric)
  set search_path = public, pg_temp;

revoke all on function public.calculate_reservation_change(uuid,text,timestamptz,text,numeric) from public;
revoke all on function public.calculate_reservation_change(uuid,text,timestamptz,text,numeric) from anon;
revoke all on function public.calculate_reservation_change(uuid,text,timestamptz,text,numeric) from authenticated;
grant execute on function public.calculate_reservation_change(uuid,text,timestamptz,text,numeric) to service_role;

comment on function public.calculate_reservation_change(uuid,text,timestamptz,text,numeric) is
  'Service-role-only authoritative reservation change calculator. SECURITY DEFINER crosses hardened appointment-table privileges without reopening direct table access.';
