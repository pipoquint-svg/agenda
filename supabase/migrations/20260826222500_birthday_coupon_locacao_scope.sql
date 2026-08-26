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

create or replace function public.assert_birthday_coupon_has_locacao_service()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if new.source = 'BIRTHDAY' and not exists (
    select 1
    from public.coupon_services cs
    join public.services s on s.id = cs.service_id
    join public.service_type st on st.id = s.service_type_id
    where cs.coupon_id = new.id
      and st.key = 'LOCACAO'
  ) then
    raise exception using errcode='P0001', message='BIRTHDAY_COUPON_REQUIRES_LOCACAO_SERVICE';
  end if;
  return new;
end;
$$;

revoke all on function public.guard_birthday_coupon_service_scope() from public, anon, authenticated;
revoke all on function public.assert_birthday_coupon_has_locacao_service() from public, anon, authenticated;
grant execute on function public.guard_birthday_coupon_service_scope() to service_role;
grant execute on function public.assert_birthday_coupon_has_locacao_service() to service_role;

drop trigger if exists coupon_services_birthday_scope_guard on public.coupon_services;
create trigger coupon_services_birthday_scope_guard
before insert or update of coupon_id, service_id on public.coupon_services
for each row execute function public.guard_birthday_coupon_service_scope();

drop trigger if exists birthday_coupon_requires_locacao_service on public.coupons;
create constraint trigger birthday_coupon_requires_locacao_service
after insert or update of source on public.coupons
deferrable initially deferred
for each row execute function public.assert_birthday_coupon_has_locacao_service();

comment on function public.guard_birthday_coupon_service_scope() is
  'Database guard for #217: BIRTHDAY coupons can be linked only to services classified as service_type LOCACAO.';
comment on function public.assert_birthday_coupon_has_locacao_service() is
  'Deferred invariant for #217: every BIRTHDAY coupon must finish its transaction with at least one LOCACAO service.';
