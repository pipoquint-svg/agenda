-- Issue #217 — BlackSheep birthday coupons are commercially valid only for rentals.
-- Keep this as a database invariant so future active non-rental services cannot become
-- eligible by accident. The birthday campaign remains disabled by configuration.

create or replace function public.guard_birthday_coupon_service_scope()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_source text;
  v_service_type text;
begin
  select c.source, st.key
    into v_source, v_service_type
  from public.coupons c
  join public.services s on s.id = new.service_id
  left join public.service_type st on st.id = s.service_type_id
  where c.id = new.coupon_id;

  if v_source is distinct from 'BIRTHDAY' then
    return new;
  end if;

  -- BIRTHDAY coupons must never gain ENSAIO or an unclassified service.
  if v_service_type is distinct from 'LOCACAO' then
    return null;
  end if;

  return new;
end;
$$;

revoke all on function public.guard_birthday_coupon_service_scope() from public, anon, authenticated;
grant execute on function public.guard_birthday_coupon_service_scope() to service_role;

drop trigger if exists coupon_services_birthday_scope_guard on public.coupon_services;
create trigger coupon_services_birthday_scope_guard
before insert or update of coupon_id, service_id on public.coupon_services
for each row execute function public.guard_birthday_coupon_service_scope();

comment on function public.guard_birthday_coupon_service_scope() is
  'Database guard for #217: BIRTHDAY coupons can be linked only to services classified as service_type LOCACAO.';
