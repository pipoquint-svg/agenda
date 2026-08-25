-- V1 pre-production data preparation only. No runtime behavior may branch on service_type in this phase.
--
-- Taxonomy principle:
-- service_type carries only what changes scheduling logic: block composition,
-- resource requirement, edge positioning, and Google representation.
-- Duration, price, payment mode, checkout requirement, and Kommo mapping are
-- service attributes, not service_type attributes.
--
-- Declared exclusions:
-- EVENTO is commercially out of scope for now and may be inserted later.
-- PARTO is not a service_type: it is on-call availability and does not consume a slot.
-- PACOTE_HORAS is a prepaid commercial modality of LOCACAO, not a type.
-- VISITA is LOCACAO with fixed duration, zero price, and no checkout, not a type.

create table if not exists public.service_type (
  id uuid primary key default gen_random_uuid(),
  key text not null unique,
  created_at timestamptz not null default now(),
  constraint service_type_key_nonempty check (btrim(key) <> '')
);

comment on table public.service_type is
  'Scheduling-semantic service types. V1 pre-production structure only; no behavior branches on this table.';

insert into public.service_type (key)
values ('ENSAIO'), ('LOCACAO')
on conflict (key) do nothing;

alter table public.services
  add column if not exists service_type_id uuid null references public.service_type(id);

create index if not exists services_service_type_id_idx
  on public.services(service_type_id);

-- N:N catalog offer. operation_scope is the existing canonical business-unit key.
-- Exclusivity is data, never code: future offers are changed by row insert/delete.
create table if not exists public.operation_service_types (
  operation_scope text not null,
  service_type_id uuid not null references public.service_type(id) on delete restrict,
  created_at timestamptz not null default now(),
  primary key (operation_scope, service_type_id),
  constraint operation_service_types_scope_check
    check (operation_scope in ('SABRINA', 'BLACKSHEEP'))
);

insert into public.operation_service_types (operation_scope, service_type_id)
select 'SABRINA', id from public.service_type where key = 'ENSAIO'
on conflict do nothing;

insert into public.operation_service_types (operation_scope, service_type_id)
select 'BLACKSHEEP', id from public.service_type where key = 'LOCACAO'
on conflict do nothing;

alter table public.appointments
  add column if not exists service_type_snapshot_id uuid null references public.service_type(id);

create index if not exists appointments_service_type_snapshot_id_idx
  on public.appointments(service_type_snapshot_id);

create or replace function public.capture_appointment_service_type_snapshot()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.status = 'CONFIRMED' and new.service_type_snapshot_id is null then
    select s.service_type_id
      into new.service_type_snapshot_id
    from public.services s
    where s.id = new.service_id;
  end if;
  return new;
end;
$$;

drop trigger if exists appointments_capture_service_type_snapshot on public.appointments;
create trigger appointments_capture_service_type_snapshot
before insert or update of status on public.appointments
for each row
execute function public.capture_appointment_service_type_snapshot();

revoke all on table public.service_type from anon, authenticated;
revoke all on table public.operation_service_types from anon, authenticated;
