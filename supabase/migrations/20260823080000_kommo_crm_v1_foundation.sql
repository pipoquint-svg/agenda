-- V1 communication architecture:
-- Agenda is the booking authority; Kommo is the external CRM/communication mirror.
-- Only services explicitly classified as BLACKSHEEP are eligible for Kommo sync.
-- Sabrina services do not sync to Kommo and do not receive Agenda confirmation e-mail.
-- Provider credentials are intentionally NOT stored in the database.

create table public.kommo_integration_settings (
  id smallint primary key default 1 check (id = 1),
  enabled boolean not null default false,
  operation_scope text not null default 'BLACKSHEEP' check (operation_scope = 'BLACKSHEEP'),
  account_subdomain text,
  pipeline_id bigint,
  stage_awaiting_payment_id bigint,
  stage_confirmed_id bigint,
  stage_rescheduled_id bigint,
  stage_cancelled_id bigint,
  stage_completed_id bigint,
  stage_no_show_id bigint,
  stage_expired_id bigint,
  booking_mailbox text not null default 'agenda@blacksheepestudiocriativo.com.br',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (account_subdomain is null or account_subdomain ~ '^[a-z0-9][a-z0-9-]{1,62}$'),
  check (pipeline_id is null or pipeline_id > 0),
  check (stage_awaiting_payment_id is null or stage_awaiting_payment_id > 0),
  check (stage_confirmed_id is null or stage_confirmed_id > 0),
  check (stage_rescheduled_id is null or stage_rescheduled_id > 0),
  check (stage_cancelled_id is null or stage_cancelled_id > 0),
  check (stage_completed_id is null or stage_completed_id > 0),
  check (stage_no_show_id is null or stage_no_show_id > 0),
  check (stage_expired_id is null or stage_expired_id > 0)
);

insert into public.kommo_integration_settings (id)
values (1)
on conflict (id) do nothing;

create table public.kommo_customer_links (
  customer_id uuid primary key references public.customers(id) on delete cascade,
  kommo_contact_id bigint not null unique check (kommo_contact_id > 0),
  last_synced_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.kommo_appointment_links (
  appointment_id uuid primary key references public.appointments(id) on delete cascade,
  kommo_lead_id bigint not null unique check (kommo_lead_id > 0),
  kommo_contact_id bigint check (kommo_contact_id is null or kommo_contact_id > 0),
  last_synced_version integer check (last_synced_version is null or last_synced_version >= 1),
  last_synced_status text,
  last_synced_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index kommo_appointment_links_contact_idx
  on public.kommo_appointment_links (kommo_contact_id)
  where kommo_contact_id is not null;

alter table public.kommo_integration_settings enable row level security;
alter table public.kommo_customer_links enable row level security;
alter table public.kommo_appointment_links enable row level security;

revoke all on table public.kommo_integration_settings from public, anon, authenticated;
revoke all on table public.kommo_customer_links from public, anon, authenticated;
revoke all on table public.kommo_appointment_links from public, anon, authenticated;
grant select, insert, update, delete on table public.kommo_integration_settings to service_role;
grant select, insert, update, delete on table public.kommo_customer_links to service_role;
grant select, insert, update, delete on table public.kommo_appointment_links to service_role;

create or replace function public.get_kommo_appointment_desired_state(p_appointment_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_appointment public.appointments%rowtype;
  v_service public.services%rowtype;
  v_customer public.customers%rowtype;
  v_settings public.kommo_integration_settings%rowtype;
  v_stage_key text;
begin
  select * into v_appointment
  from public.appointments
  where id = p_appointment_id;

  if not found then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_NOT_FOUND';
  end if;

  select * into v_service
  from public.services
  where id = v_appointment.service_id;

  select * into v_settings
  from public.kommo_integration_settings
  where id = 1;

  if not found or not v_settings.enabled or v_service.operation_scope is distinct from 'BLACKSHEEP' then
    return jsonb_build_object(
      'appointment_id', v_appointment.id,
      'version', v_appointment.version,
      'eligible', false,
      'reason', case
        when v_service.operation_scope is distinct from 'BLACKSHEEP' then 'OPERATION_SCOPE_NOT_BLACKSHEEP'
        else 'KOMMO_DISABLED'
      end
    );
  end if;

  if v_appointment.primary_customer_id is not null then
    select * into v_customer
    from public.customers
    where id = v_appointment.primary_customer_id;
  end if;

  v_stage_key := case v_appointment.status
    when 'AWAITING_PAYMENT' then 'AWAITING_PAYMENT'
    when 'CONFIRMED' then 'CONFIRMED'
    when 'COMPLETED' then 'COMPLETED'
    when 'CANCELLED' then 'CANCELLED'
    when 'NO_SHOW' then 'NO_SHOW'
    when 'EXPIRED' then 'EXPIRED'
    else 'CREATED'
  end;

  return jsonb_build_object(
    'appointment_id', v_appointment.id,
    'public_code', v_appointment.public_code,
    'version', v_appointment.version,
    'eligible', true,
    'operation_scope', v_service.operation_scope,
    'appointment_status', v_appointment.status,
    'financial_status', v_appointment.financial_status,
    'stage_key', v_stage_key,
    'service', jsonb_build_object(
      'id', v_service.id,
      'name', coalesce(nullif(v_appointment.service_name_snapshot, ''), v_service.name)
    ),
    'schedule', jsonb_build_object(
      'start_at', v_appointment.start_at,
      'end_at', v_appointment.end_at
    ),
    'commercial_value', v_appointment.commercial_value,
    'customer', case when v_customer.id is null then null else jsonb_build_object(
      'id', v_customer.id,
      'name', v_customer.name,
      'email', v_customer.email,
      'phone', v_customer.phone
    ) end
  );
end;
$$;

revoke all on function public.get_kommo_appointment_desired_state(uuid) from public, anon, authenticated;
grant execute on function public.get_kommo_appointment_desired_state(uuid) to service_role;

create or replace function public.enqueue_kommo_appointment_sync(
  p_appointment_id uuid,
  p_event_kind text default 'UPDATED'
)
returns uuid
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_appointment public.appointments%rowtype;
  v_scope text;
  v_enabled boolean;
  v_job_id uuid;
  v_event text := upper(btrim(coalesce(p_event_kind, 'UPDATED')));
begin
  if v_event not in ('CREATED','UPDATED','RESCHEDULED','STATUS_CHANGED','FINANCIAL_CHANGED') then
    raise exception using errcode = 'P0001', message = 'KOMMO_EVENT_KIND_INVALID';
  end if;

  select * into v_appointment
  from public.appointments
  where id = p_appointment_id;

  if not found then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_NOT_FOUND';
  end if;

  select operation_scope into v_scope
  from public.services
  where id = v_appointment.service_id;

  select enabled into v_enabled
  from public.kommo_integration_settings
  where id = 1;

  if not coalesce(v_enabled, false) or v_scope is distinct from 'BLACKSHEEP' then
    return null;
  end if;

  insert into public.integration_jobs (
    job_type, entity_type, entity_id, entity_version,
    payload_json, status, run_after, idempotency_key
  ) values (
    'KOMMO_APPOINTMENT_SYNC',
    'APPOINTMENT',
    v_appointment.id,
    v_appointment.version,
    jsonb_build_object('event_kind', v_event),
    'PENDING',
    now(),
    'kommo-appointment:' || v_appointment.id::text || ':v' || v_appointment.version::text
  )
  on conflict (idempotency_key) do update
    set updated_at = public.integration_jobs.updated_at
  returning id into v_job_id;

  return v_job_id;
end;
$$;

revoke all on function public.enqueue_kommo_appointment_sync(uuid,text) from public, anon, authenticated;
grant execute on function public.enqueue_kommo_appointment_sync(uuid,text) to service_role;

create or replace function public.trg_enqueue_kommo_appointment_sync()
returns trigger
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_scope text;
  v_enabled boolean;
  v_event text;
begin
  select enabled into v_enabled from public.kommo_integration_settings where id = 1;
  if not coalesce(v_enabled, false) then
    return new;
  end if;

  select operation_scope into v_scope from public.services where id = new.service_id;
  if v_scope is distinct from 'BLACKSHEEP' then
    return new;
  end if;

  if tg_op = 'INSERT' then
    v_event := 'CREATED';
  elsif old.start_at is distinct from new.start_at or old.end_at is distinct from new.end_at then
    v_event := 'RESCHEDULED';
  elsif old.status is distinct from new.status then
    v_event := 'STATUS_CHANGED';
  elsif old.financial_status is distinct from new.financial_status then
    v_event := 'FINANCIAL_CHANGED';
  else
    v_event := 'UPDATED';
  end if;

  perform public.enqueue_kommo_appointment_sync(new.id, v_event);
  return new;
end;
$$;

revoke all on function public.trg_enqueue_kommo_appointment_sync() from public, anon, authenticated;

drop trigger if exists appointments_enqueue_kommo_sync on public.appointments;
create trigger appointments_enqueue_kommo_sync
after insert or update of status, financial_status, start_at, end_at, primary_customer_id, service_id, service_employee_id, commercial_value, version
on public.appointments
for each row execute function public.trg_enqueue_kommo_appointment_sync();

-- Direct WhatsApp recovery is retired from active V1 scope. Preserve historical
-- columns/tables for audit compatibility, but disable all public creation/resume paths
-- and stop enqueueing provider jobs.
update public.message_templates
set is_active = false,
    updated_at = now()
where template_key = 'checkout_hold_expired_recovery';

update public.checkout_holds
set recovery_enabled = false,
    recovery_phone = null,
    updated_at = now()
where recovery_enabled or recovery_phone is not null;

revoke all on function public.set_checkout_hold_recovery_contact(text,text,boolean) from public, anon, authenticated;
revoke all on function public.get_checkout_hold_resume_context(text) from public, anon, authenticated;
grant execute on function public.set_checkout_hold_recovery_contact(text,text,boolean) to service_role;
grant execute on function public.get_checkout_hold_resume_context(text) to service_role;

create or replace function public.expire_due_checkout_holds()
returns void
language plpgsql
volatile
set search_path = public
as $$
declare
  v_hold public.checkout_holds%rowtype;
begin
  for v_hold in
    select ch.*
    from public.checkout_holds ch
    where ch.status = 'ACTIVE'
      and ch.expires_at <= now()
    for update skip locked
  loop
    update public.checkout_holds
    set status = 'EXPIRED', updated_at = now()
    where id = v_hold.id;

    update public.resource_allocations
    set status = 'EXPIRED', updated_at = now()
    where checkout_hold_id = v_hold.id
      and status = 'HELD';

    update public.checkout_hour_package_reservations
    set status = 'RELEASED',
        released_at = now(),
        release_reason = 'CHECKOUT_HOLD_EXPIRED',
        updated_at = now()
    where checkout_hold_id = v_hold.id
      and status = 'HELD';
  end loop;
end;
$$;

comment on table public.kommo_integration_settings is
  'BlackSheep-only external CRM configuration. Long-lived Kommo token is an Edge secret, never a database value. Integration is disabled until provider sandbox/account spike passes.';
comment on function public.get_kommo_appointment_desired_state(uuid) is
  'Canonical Agenda-to-Kommo projection. Agenda remains authoritative; Sabrina scope is never eligible.';
comment on function public.enqueue_kommo_appointment_sync(uuid,text) is
  'Idempotent outbox enqueue for one BlackSheep reservation. One Agenda appointment maps to one Kommo lead.';
