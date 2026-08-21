-- PostgreSQL grants EXECUTE on new functions to PUBLIC by default.
-- Public web roles must reach scheduling only through the page-scoped wrappers.

revoke all on function public.calculate_booking_quote(uuid,uuid,jsonb,integer,timestamptz,text)
  from public, anon, authenticated;
revoke all on function public.list_available_slots(uuid,uuid,jsonb,integer,date,text)
  from public, anon, authenticated;
revoke all on function public.create_checkout_hold(uuid,uuid,jsonb,integer,timestamptz)
  from public, anon, authenticated;

-- Service role and database owner continue to use the core functions internally.
grant execute on function public.calculate_booking_quote(uuid,uuid,jsonb,integer,timestamptz,text)
  to service_role;
grant execute on function public.list_available_slots(uuid,uuid,jsonb,integer,date,text)
  to service_role;
grant execute on function public.create_checkout_hold(uuid,uuid,jsonb,integer,timestamptz)
  to service_role;
