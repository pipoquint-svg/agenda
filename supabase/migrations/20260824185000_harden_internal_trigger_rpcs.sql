begin;

-- Internal trigger functions execute only through their table triggers.
-- They are not part of the public Data API surface and must not be callable
-- directly by anon/authenticated roles through /rest/v1/rpc/*.
revoke execute on function public.customer_access_appointment_before_insert() from public, anon, authenticated;
revoke execute on function public.customer_access_no_show_after_update() from public, anon, authenticated;
revoke execute on function public.customers_capture_identity_keys_trigger() from public, anon, authenticated;
revoke execute on function public.enqueue_no_show_balance_cancellation() from public, anon, authenticated;

-- Pin search_path for the helper flagged by the database advisor.
alter function public.kommo_guard_adjust_due(timestamp with time zone)
  set search_path = public;

commit;
