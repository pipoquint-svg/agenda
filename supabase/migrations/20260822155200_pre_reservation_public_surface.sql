-- Keep the opaque-token resolver behind the rate-limited Edge surface.
revoke all on function public.public_get_pre_reservation_context(text)
  from public, anon, authenticated;
grant execute on function public.public_get_pre_reservation_context(text)
  to service_role;
