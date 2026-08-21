-- PREPEND extras change the customer arrival time, not the commercial time anchor.
-- Hold quote snapshots must always use core_start_at when available.

create or replace function public.populate_checkout_hold_quote_snapshot()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.quote_snapshot is null then
    new.quote_snapshot := public.calculate_booking_quote(
      new.service_id,
      new.service_employee_id,
      coalesce(new.extra_selections, '[]'::jsonb),
      new.people_count,
      coalesce(new.core_start_at, new.requested_start_at),
      null
    );
  end if;

  return new;
end;
$$;

comment on function public.populate_checkout_hold_quote_snapshot() is
  'Snapshots checkout pricing at core_start_at. PREPEND arrival time never changes DAY_TIME pricing by itself.';
