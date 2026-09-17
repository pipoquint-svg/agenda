-- Free public visits are confirmed when the customer completes the booking.
-- They must not depend on a second administrative confirmation deadline.
-- Also fixes legacy expiry cleanup so confirmed resource allocations are released.

create or replace function public.customer_access_appointment_before_insert()
returns trigger
language plpgsql
set search_path to 'public', 'pg_temp'
as $function$
declare
  a record;
  s public.services%rowtype;
begin
  if new.origin <> 'PUBLIC' or new.primary_customer_id is null then
    return new;
  end if;

  select * into a
  from public.customer_effective_access
  where customer_id = new.primary_customer_id;

  if coalesce(a.online_blocked, false) or coalesce(a.no_online_booking, false) then
    raise exception using errcode = 'P0001', message = 'ONLINE_BOOKING_NOT_AVAILABLE';
  end if;

  if coalesce(a.require_full_payment, false) then
    new.confirmation_percentage_snapshot := 100;
    new.checkout_minimum_payment_type_snapshot := 'PERCENT';
    new.checkout_minimum_payment_value_snapshot := 100;
  end if;

  select * into s
  from public.services
  where id = new.service_id;

  if s.booking_product_type = 'FREE_VISIT' then
    if coalesce(a.no_free_visits, false) then
      raise exception using errcode = 'P0001', message = 'FREE_VISIT_NOT_AVAILABLE';
    end if;

    new.free_visit_confirmed_at := coalesce(new.free_visit_confirmed_at, now());
    new.free_visit_confirmation_deadline := null;
  end if;

  return new;
end;
$function$;

create or replace function public.expire_unconfirmed_free_visits()
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  r record;
  n integer := 0;
begin
  for r in
    select a.id
    from public.appointments a
    join public.services s on s.id = a.service_id
    where s.booking_product_type = 'FREE_VISIT'
      and a.status = 'CONFIRMED'
      and a.free_visit_confirmed_at is null
      and a.free_visit_confirmation_deadline is not null
      and a.free_visit_confirmation_deadline <= now()
    for update of a
  loop
    update public.appointments
    set status = 'CANCELLED',
        cancelled_at = now(),
        cancel_reason = 'FREE_VISIT_CONFIRMATION_MISSING',
        updated_at = now(),
        version = version + 1
    where id = r.id;

    update public.resource_allocations
    set status = 'CANCELLED',
        updated_at = now()
    where appointment_id = r.id
      and status = 'CONFIRMED';

    n := n + 1;
  end loop;

  return n;
end;
$function$;
