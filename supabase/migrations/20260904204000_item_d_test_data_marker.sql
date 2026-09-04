-- Item D — explicit production test-data marker.
-- No provider state, amount, business rule, customer identity or Google row is changed.

alter table public.appointments
  add column if not exists is_test boolean not null default false;

alter table public.payment_transactions
  add column if not exists is_test boolean not null default false;

alter table public.customer_balance_movements
  add column if not exists is_test boolean not null default false;

comment on column public.appointments.is_test is
  'Explicit operational test marker. Test rows remain traceable but are excluded from fiscal/admin finance reporting.';
comment on column public.payment_transactions.is_test is
  'Inherited from appointment. Provider money remains fully traceable when classified as test.';
comment on column public.customer_balance_movements.is_test is
  'Inherited from appointment on insert. Ledger rows remain immutable and are never rewritten only to classify a test.';

create or replace function public.service_inherit_test_marker_from_appointment()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_is_test boolean;
begin
  if new.appointment_id is null then
    new.is_test := false;
    return new;
  end if;

  select a.is_test into v_is_test
  from public.appointments a
  where a.id = new.appointment_id;

  if found then
    new.is_test := coalesce(v_is_test,false);
  end if;
  return new;
end;
$$;

revoke all on function public.service_inherit_test_marker_from_appointment() from public, anon, authenticated, service_role;

drop trigger if exists trg_payment_transactions_inherit_test_marker on public.payment_transactions;
create trigger trg_payment_transactions_inherit_test_marker
before insert or update of appointment_id, is_test on public.payment_transactions
for each row execute function public.service_inherit_test_marker_from_appointment();

-- customer_balance_movements is an immutable financial ledger. Its marker is fixed
-- at INSERT time from the parent appointment and is never propagated by UPDATE.
drop trigger if exists trg_customer_balance_movements_inherit_test_marker on public.customer_balance_movements;
create trigger trg_customer_balance_movements_inherit_test_marker
before insert on public.customer_balance_movements
for each row execute function public.service_inherit_test_marker_from_appointment();

create or replace function public.service_propagate_appointment_test_marker()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if old.is_test is distinct from new.is_test then
    update public.payment_transactions
       set is_test = new.is_test
     where appointment_id = new.id
       and is_test is distinct from new.is_test;
  end if;
  return null;
end;
$$;

revoke all on function public.service_propagate_appointment_test_marker() from public, anon, authenticated, service_role;

drop trigger if exists trg_appointments_propagate_test_marker on public.appointments;
create trigger trg_appointments_propagate_test_marker
after update of is_test on public.appointments
for each row execute function public.service_propagate_appointment_test_marker();

-- Exact audited pre-opening appointment set re-read from production immediately
-- before this migration was finalized. A clean/local rebuild has zero of these IDs.
-- A partial match is always unsafe and aborts the migration.
do $$
declare
  v_found integer;
begin
  select count(*)::integer into v_found
  from public.appointments
  where id = any(array[
    '2459b897-4b81-4186-bc4a-284f275a76df'::uuid,
    'da207b65-88b8-41ce-999b-f3263b1d31ed'::uuid,
    '0fcbed97-3f4f-4ea4-a803-74efce86d24b'::uuid,
    'ae412689-cce7-43ea-9461-560764d3cc91'::uuid,
    '44fc4f56-d49b-40be-934a-6f3edc928853'::uuid,
    '46cd279b-922f-4392-9d34-8adbee5906b2'::uuid,
    '4e2a9e52-1399-4139-8463-b593f219f8b2'::uuid,
    '1b531f34-630f-4619-8824-a891866d7236'::uuid,
    '6fc4914f-36b2-4b22-a592-1cf8c0bb7c91'::uuid,
    'bd8647e0-d586-459f-aadf-39f78dc71749'::uuid
  ]);

  if v_found not in (0,10) then
    raise exception using errcode='P0001', message='ITEM_D_TEST_APPOINTMENT_SET_MISMATCH';
  end if;

  if v_found = 10 then
    update public.appointments
       set is_test = true
     where id = any(array[
      '2459b897-4b81-4186-bc4a-284f275a76df'::uuid,
      'da207b65-88b8-41ce-999b-f3263b1d31ed'::uuid,
      '0fcbed97-3f4f-4ea4-a803-74efce86d24b'::uuid,
      'ae412689-cce7-43ea-9461-560764d3cc91'::uuid,
      '44fc4f56-d49b-40be-934a-6f3edc928853'::uuid,
      '46cd279b-922f-4392-9d34-8adbee5906b2'::uuid,
      '4e2a9e52-1399-4139-8463-b593f219f8b2'::uuid,
      '1b531f34-630f-4619-8824-a891866d7236'::uuid,
      '6fc4914f-36b2-4b22-a592-1cf8c0bb7c91'::uuid,
      'bd8647e0-d586-459f-aadf-39f78dc71749'::uuid
    ]);
  end if;
end;
$$;
