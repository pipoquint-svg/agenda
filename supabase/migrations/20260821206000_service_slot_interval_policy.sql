-- Public slot cadence policy.
-- BlackSheep uses the system default of 30 minutes.
-- Sabrina services may override the cadence per service.

alter table public.operation_settings
  add column if not exists default_slot_interval_minutes integer not null default 30
  check (default_slot_interval_minutes > 0 and default_slot_interval_minutes <= 1440);

alter table public.services
  add column public_slot_interval_minutes integer
  check (public_slot_interval_minutes is null or (public_slot_interval_minutes > 0 and public_slot_interval_minutes <= 1440));

update public.operation_settings
set default_slot_interval_minutes = 30,
    updated_at = now()
where id = 1;

create or replace function public.get_service_public_slot_interval(p_service_id uuid)
returns integer
language sql
stable
set search_path = public
as $$
select coalesce(
  (select s.public_slot_interval_minutes from public.services s where s.id = p_service_id),
  (select os.default_slot_interval_minutes from public.operation_settings os where os.id = 1),
  30
);
$$;

comment on column public.operation_settings.default_slot_interval_minutes is
  'Default cadence between offered start times. BlackSheep standard is 30 minutes.';

comment on column public.services.public_slot_interval_minutes is
  'Optional per-service override for offered start-time cadence. Used by Sabrina services when their grid differs from the 30-minute system default.';

comment on function public.get_service_public_slot_interval(uuid) is
  'Resolves public slot cadence: service override first, otherwise the 30-minute operation default.';

-- availability_rules still defines opening windows. Its historical interval column is
-- kept for compatibility, but public cadence is normalized to the service policy.
create or replace function public.enforce_service_slot_interval_on_availability_rule()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_service_id uuid;
begin
  select se.service_id into v_service_id
  from public.service_employees se
  where se.id = new.service_employee_id;

  if v_service_id is null then
    raise exception using errcode = 'P0001', message = 'SERVICE_EMPLOYEE_NOT_FOUND';
  end if;

  new.slot_interval_minutes := public.get_service_public_slot_interval(v_service_id);
  return new;
end;
$$;

drop trigger if exists availability_rules_service_slot_interval_trg on public.availability_rules;
create trigger availability_rules_service_slot_interval_trg
before insert or update of service_employee_id, slot_interval_minutes
on public.availability_rules
for each row execute function public.enforce_service_slot_interval_on_availability_rule();

create or replace function public.sync_service_slot_interval_to_availability_rules()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if old.public_slot_interval_minutes is distinct from new.public_slot_interval_minutes then
    update public.availability_rules ar
    set slot_interval_minutes = public.get_service_public_slot_interval(new.id),
        updated_at = now()
    from public.service_employees se
    where se.id = ar.service_employee_id
      and se.service_id = new.id;
  end if;
  return new;
end;
$$;

drop trigger if exists services_sync_slot_interval_trg on public.services;
create trigger services_sync_slot_interval_trg
after update of public_slot_interval_minutes on public.services
for each row execute function public.sync_service_slot_interval_to_availability_rules();

-- Normalize existing rules. This makes the current BlackSheep behavior 30 minutes
-- and lets Sabrina move away from 30 only by configuring the service itself.
update public.availability_rules ar
set slot_interval_minutes = public.get_service_public_slot_interval(se.service_id),
    updated_at = now()
from public.service_employees se
where se.id = ar.service_employee_id
  and ar.slot_interval_minutes is distinct from public.get_service_public_slot_interval(se.service_id);

-- Backend-only helper for the future admin service editor.
create or replace function public.set_service_public_slot_interval(
  p_service_id uuid,
  p_interval_minutes integer
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_service public.services%rowtype;
begin
  if p_interval_minutes is null or p_interval_minutes <= 0 or p_interval_minutes > 1440 then
    raise exception using errcode = 'P0001', message = 'INVALID_SLOT_INTERVAL';
  end if;

  update public.services
  set public_slot_interval_minutes = p_interval_minutes,
      updated_at = now()
  where id = p_service_id
  returning * into v_service;

  if not found then
    raise exception using errcode = 'P0001', message = 'SERVICE_NOT_FOUND';
  end if;

  insert into public.audit_logs(entity_type, entity_id, action, after_json, origin)
  values (
    'SERVICE', p_service_id, 'PUBLIC_SLOT_INTERVAL_CHANGED',
    jsonb_build_object('public_slot_interval_minutes', p_interval_minutes),
    'ADMIN'
  );

  return jsonb_build_object(
    'service_id', p_service_id,
    'public_slot_interval_minutes', p_interval_minutes
  );
end;
$$;

revoke all on function public.get_service_public_slot_interval(uuid) from public, anon, authenticated;
grant execute on function public.get_service_public_slot_interval(uuid) to service_role;
revoke all on function public.set_service_public_slot_interval(uuid,integer) from public, anon, authenticated;
grant execute on function public.set_service_public_slot_interval(uuid,integer) to service_role;
