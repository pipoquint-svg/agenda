-- Gate 1: additive payment-provider abstraction.
-- This migration does not activate InfinitePay for any booking page and does not
-- change the existing Mercado Pago payment RPCs. Existing/public behavior remains MP.

alter table public.booking_pages
  add column if not exists payment_provider text not null default 'MERCADO_PAGO';

alter table public.booking_pages
  drop constraint if exists booking_pages_payment_provider_check;

alter table public.booking_pages
  add constraint booking_pages_payment_provider_check
  check (payment_provider = any (array['MERCADO_PAGO'::text, 'INFINITEPAY'::text]));

comment on column public.booking_pages.payment_provider is
  'Online payment provider selected for new checkout holds created from this booking page.';

alter table public.checkout_holds
  add column if not exists payment_provider_snapshot text;

-- Existing holds are frozen to the provider currently configured on their page.
-- At the time of this Gate 1 migration every page remains MERCADO_PAGO.
update public.checkout_holds h
set payment_provider_snapshot = coalesce(
  (select bp.payment_provider from public.booking_pages bp where bp.id = h.booking_page_id),
  'MERCADO_PAGO'
)
where h.payment_provider_snapshot is null;

alter table public.checkout_holds
  alter column payment_provider_snapshot set default 'MERCADO_PAGO',
  alter column payment_provider_snapshot set not null;

alter table public.checkout_holds
  drop constraint if exists checkout_holds_payment_provider_snapshot_check;

alter table public.checkout_holds
  add constraint checkout_holds_payment_provider_snapshot_check
  check (payment_provider_snapshot = any (array['MERCADO_PAGO'::text, 'INFINITEPAY'::text]));

comment on column public.checkout_holds.payment_provider_snapshot is
  'Immutable provider snapshot captured when a booking page is first attached to the hold.';

alter table public.appointments
  add column if not exists payment_provider_snapshot text not null default 'MERCADO_PAGO';

alter table public.appointments
  drop constraint if exists appointments_payment_provider_snapshot_check;

alter table public.appointments
  add constraint appointments_payment_provider_snapshot_check
  check (payment_provider_snapshot = any (array['MERCADO_PAGO'::text, 'INFINITEPAY'::text]));

comment on column public.appointments.payment_provider_snapshot is
  'Online provider frozen from the promoted checkout hold. Manual/admin appointments default to MERCADO_PAGO until explicitly generalized.';

create or replace function public.service_snapshot_checkout_payment_provider()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_provider text;
begin
  -- public_create_checkout_hold creates the hold first and attaches booking_page_id
  -- in a second statement. Snapshot on insert when possible, or on the first
  -- NULL -> non-NULL booking_page assignment. Never follow later page config changes.
  if tg_op = 'INSERT' then
    if new.booking_page_id is not null then
      select bp.payment_provider
      into v_provider
      from public.booking_pages bp
      where bp.id = new.booking_page_id;

      new.payment_provider_snapshot := coalesce(v_provider, 'MERCADO_PAGO');
    else
      new.payment_provider_snapshot := 'MERCADO_PAGO';
    end if;
  elsif old.booking_page_id is null and new.booking_page_id is not null then
    select bp.payment_provider
    into v_provider
    from public.booking_pages bp
    where bp.id = new.booking_page_id;

    new.payment_provider_snapshot := coalesce(v_provider, 'MERCADO_PAGO');
  end if;

  return new;
end;
$$;

revoke all on function public.service_snapshot_checkout_payment_provider() from public;

create or replace function public.service_copy_hold_payment_provider_to_appointment()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.promoted_appointment_id is not null
     and (tg_op = 'INSERT' or old.promoted_appointment_id is distinct from new.promoted_appointment_id) then
    update public.appointments
    set payment_provider_snapshot = new.payment_provider_snapshot,
        updated_at = now()
    where id = new.promoted_appointment_id;
  end if;

  return new;
end;
$$;

revoke all on function public.service_copy_hold_payment_provider_to_appointment() from public;

drop trigger if exists checkout_holds_snapshot_payment_provider_trg on public.checkout_holds;
create trigger checkout_holds_snapshot_payment_provider_trg
before insert or update of booking_page_id on public.checkout_holds
for each row
execute function public.service_snapshot_checkout_payment_provider();

drop trigger if exists checkout_holds_copy_payment_provider_to_appointment_trg on public.checkout_holds;
create trigger checkout_holds_copy_payment_provider_to_appointment_trg
after insert or update of promoted_appointment_id on public.checkout_holds
for each row
execute function public.service_copy_hold_payment_provider_to_appointment();

-- Backfill appointments already promoted before this migration.
update public.appointments a
set payment_provider_snapshot = h.payment_provider_snapshot
from public.checkout_holds h
where h.promoted_appointment_id = a.id
  and a.payment_provider_snapshot is distinct from h.payment_provider_snapshot;

-- Keep existing providers and add InfinitePay without changing any legacy row.
alter table public.payment_transactions
  drop constraint if exists payment_transactions_provider_check;

alter table public.payment_transactions
  add constraint payment_transactions_provider_check
  check (provider = any (array['MERCADO_PAGO'::text, 'INFINITEPAY'::text, 'MANUAL'::text]));

alter table public.payment_provider_events
  drop constraint if exists payment_provider_events_provider_check;

alter table public.payment_provider_events
  add constraint payment_provider_events_provider_check
  check (provider = any (array['MERCADO_PAGO'::text, 'INFINITEPAY'::text]));

create or replace function public.service_resolve_appointment_payment_provider(p_appointment_id uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select a.payment_provider_snapshot from public.appointments a where a.id = p_appointment_id),
    'MERCADO_PAGO'
  );
$$;

revoke all on function public.service_resolve_appointment_payment_provider(uuid) from public;
grant execute on function public.service_resolve_appointment_payment_provider(uuid) to service_role;
