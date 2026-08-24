begin;

-- Internal trigger functions execute only through their table triggers.
-- They are not part of the public Data API surface and must not be callable
-- directly by anon/authenticated roles through /rest/v1/rpc/*.
revoke execute on function public.customer_access_appointment_before_insert() from public, anon, authenticated;
revoke execute on function public.customer_access_no_show_after_update() from public, anon, authenticated;
revoke execute on function public.customers_capture_identity_keys_trigger() from public, anon, authenticated;
revoke execute on function public.enqueue_no_show_balance_cancellation() from public, anon, authenticated;

-- The advisor can report this helper on hosted environments even when a clean
-- migration replay does not contain the legacy function. Harden every existing
-- overload when present, but keep a fresh local rebuild deterministic.
do $$
declare
  v_signature text;
begin
  for v_signature in
    select p.oid::regprocedure::text
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'kommo_guard_adjust_due'
      and p.prokind = 'f'
  loop
    execute format('alter function %s set search_path = public', v_signature);
  end loop;
end;
$$;

commit;
