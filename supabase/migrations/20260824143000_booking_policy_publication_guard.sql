-- Phase 3 / finding 4: a service cannot be publicly bookable without an
-- authoritative change/cancellation policy. Existing invalid links are disabled;
-- no historical appointment policy is fabricated by this migration.

create or replace function public.assert_booking_page_service_has_change_policy()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_page_active boolean;
begin
  if not new.is_active then
    return new;
  end if;

  select bp.is_active into v_page_active
  from public.booking_pages bp
  where bp.id = new.booking_page_id;

  if coalesce(v_page_active, false)
     and not exists (
       select 1
       from public.service_change_policies cp
       where cp.service_id = new.service_id
     ) then
    raise exception using
      errcode = 'P0001',
      message = 'SERVICE_CHANGE_POLICY_REQUIRED_FOR_PUBLIC_BOOKING';
  end if;

  return new;
end;
$$;

create or replace function public.assert_booking_page_activation_has_policies()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.is_active and (tg_op = 'INSERT' or old.is_active is distinct from true) then
    if exists (
      select 1
      from public.booking_page_services bps
      left join public.service_change_policies cp on cp.service_id = bps.service_id
      where bps.booking_page_id = new.id
        and bps.is_active
        and cp.service_id is null
    ) then
      raise exception using
        errcode = 'P0001',
        message = 'BOOKING_PAGE_HAS_SERVICE_WITHOUT_CHANGE_POLICY';
    end if;
  end if;

  return new;
end;
$$;

create or replace function public.prevent_public_service_policy_delete()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if exists (
    select 1
    from public.booking_page_services bps
    join public.booking_pages bp on bp.id = bps.booking_page_id
    where bps.service_id = old.service_id
      and bps.is_active
      and bp.is_active
  ) then
    raise exception using
      errcode = 'P0001',
      message = 'PUBLIC_SERVICE_CHANGE_POLICY_CANNOT_BE_REMOVED';
  end if;

  return old;
end;
$$;

-- Repair current staging/seed state conservatively: invalid public links are
-- disabled rather than inventing commercial policy values.
update public.booking_page_services bps
set is_active = false
where bps.is_active
  and exists (
    select 1
    from public.booking_pages bp
    where bp.id = bps.booking_page_id
      and bp.is_active
  )
  and not exists (
    select 1
    from public.service_change_policies cp
    where cp.service_id = bps.service_id
  );

drop trigger if exists booking_page_services_require_change_policy on public.booking_page_services;
create trigger booking_page_services_require_change_policy
before insert or update of booking_page_id, service_id, is_active
on public.booking_page_services
for each row execute function public.assert_booking_page_service_has_change_policy();

drop trigger if exists booking_pages_require_service_policies on public.booking_pages;
create trigger booking_pages_require_service_policies
before insert or update of is_active
on public.booking_pages
for each row execute function public.assert_booking_page_activation_has_policies();

drop trigger if exists service_change_policies_protect_public_service on public.service_change_policies;
create trigger service_change_policies_protect_public_service
before delete on public.service_change_policies
for each row execute function public.prevent_public_service_policy_delete();

revoke all on function public.assert_booking_page_service_has_change_policy() from public, anon, authenticated;
revoke all on function public.assert_booking_page_activation_has_policies() from public, anon, authenticated;
revoke all on function public.prevent_public_service_policy_delete() from public, anon, authenticated;

comment on function public.assert_booking_page_service_has_change_policy() is
  'Fail-closed publication guard: active services on active booking pages require service_change_policies.';
comment on function public.prevent_public_service_policy_delete() is
  'Prevents removal of the authoritative change policy while a service remains publicly bookable.';
