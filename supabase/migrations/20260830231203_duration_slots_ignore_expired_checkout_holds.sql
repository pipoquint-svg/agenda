-- BLOCKS/duration availability must not keep a physical resource busy after
-- a checkout hold expires, even if its resource_allocation cleanup is delayed.
-- Active checkout holds still block normally. Other HELD allocations keep their
-- previous semantics. The existing AWAITING_PAYMENT expiry rule is preserved.

do $migration$
declare
  v_oid oid;
  v_def text;
  v_old text := $old$          and ra.occupied_range && v_resource.occupied_range
          and not (
            ra.status = 'AWAITING_PAYMENT'$old$;
  v_new text := $new$          and ra.occupied_range && v_resource.occupied_range
          and (
            ra.status <> 'HELD'
            or ra.allocation_type <> 'CHECKOUT_HOLD'
            or exists (
              select 1
              from public.checkout_holds ch
              where ch.id = ra.checkout_hold_id
                and ch.status = 'ACTIVE'
                and ch.expires_at > v_now
            )
          )
          and not (
            ra.status = 'AWAITING_PAYMENT'$new$;
begin
  select p.oid
    into v_oid
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname = 'list_available_slots_for_duration_without_google_sync_gate'
    and pg_get_function_identity_arguments(p.oid) = 'p_service_id uuid, p_service_employee_id uuid, p_duration_blocks integer, p_extra_selections jsonb, p_people_count integer, p_local_date date, p_coupon_code text';

  if v_oid is null then
    raise exception 'duration slot core function not found';
  end if;

  v_def := pg_get_functiondef(v_oid);

  if position(v_old in v_def) = 0 then
    raise exception 'expected duration allocation conflict predicate not found';
  end if;

  execute replace(v_def, v_old, v_new);
end;
$migration$;
