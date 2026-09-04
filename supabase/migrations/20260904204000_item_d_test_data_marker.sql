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

-- Exact audited pre-opening appointment set. A clean/local rebuild has zero of these IDs.
-- A partial match is always unsafe and aborts the migration.
do $$
declare
  v_found integer;
begin
  select count(*)::integer into v_found
  from public.appointments
  where id = any(array[
    'bb9d9d3e-6a51-4d43-86c5-9ab925da9dc4'::uuid,
    '92d350d7-ea63-40ea-aae0-e2431ae3e341'::uuid,
    '2da971ae-66f8-4bf8-8599-24a014c2bfa2'::uuid,
    'b52f0103-5815-4f5c-9900-ca09fff86a96'::uuid,
    '69f1ee55-b56f-4881-bc92-9cfe1c4e77fb'::uuid,
    '69b0e54e-2b6d-4506-a89a-1ed96ab03452'::uuid,
    '99d3e40b-4470-4eab-a541-6b90dbbbe31f'::uuid,
    '57186cdb-9c2b-45de-ac03-ee55fdbfff05'::uuid,
    'd052a506-39e8-4cad-905f-b14fb87dc866'::uuid,
    '7439ea01-28fb-4a73-8b2a-dca4880b5409'::uuid
  ]);

  if v_found not in (0,10) then
    raise exception using errcode='P0001', message='ITEM_D_TEST_APPOINTMENT_SET_MISMATCH';
  end if;

  if v_found = 10 then
    update public.appointments
       set is_test = true
     where id = any(array[
      'bb9d9d3e-6a51-4d43-86c5-9ab925da9dc4'::uuid,
      '92d350d7-ea63-40ea-aae0-e2431ae3e341'::uuid,
      '2da971ae-66f8-4bf8-8599-24a014c2bfa2'::uuid,
      'b52f0103-5815-4f5c-9900-ca09fff86a96'::uuid,
      '69f1ee55-b56f-4881-bc92-9cfe1c4e77fb'::uuid,
      '69b0e54e-2b6d-4506-a89a-1ed96ab03452'::uuid,
      '99d3e40b-4470-4eab-a541-6b90dbbbe31f'::uuid,
      '57186cdb-9c2b-45de-ac03-ee55fdbfff05'::uuid,
      'd052a506-39e8-4cad-905f-b14fb87dc866'::uuid,
      '7439ea01-28fb-4a73-8b2a-dca4880b5409'::uuid
    ]);
  end if;
end;
$$;
