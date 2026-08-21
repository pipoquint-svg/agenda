create or replace function public.enforce_time_package_usage_validity()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_valid_from timestamptz;
  v_expires_at timestamptz;
  v_usage_at timestamptz;
begin
  select p.valid_from, p.expires_at
  into v_valid_from, v_expires_at
  from public.customer_time_packages p
  where p.id = new.package_id;

  if new.checkout_hold_id is not null then
    select h.requested_start_at
    into v_usage_at
    from public.checkout_holds h
    where h.id = new.checkout_hold_id;
  elsif new.appointment_id is not null then
    select a.start_at
    into v_usage_at
    from public.appointments a
    where a.id = new.appointment_id;
  end if;

  if v_usage_at is null
     or v_usage_at < v_valid_from
     or v_usage_at >= v_expires_at then
    raise exception 'TIME_PACKAGE_OUTSIDE_VALIDITY' using errcode = 'P0001';
  end if;

  return new;
end;
$$;

create trigger time_package_usages_validity_trg
before insert or update of package_id, checkout_hold_id, appointment_id
on public.time_package_usages
for each row
execute function public.enforce_time_package_usage_validity();
