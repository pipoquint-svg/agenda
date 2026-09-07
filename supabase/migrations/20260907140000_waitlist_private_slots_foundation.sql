-- Private waitlist invitation slots: hidden from public availability, token-gated checkout.

create table if not exists public.waitlist_private_slots (
  id uuid primary key default gen_random_uuid(),
  booking_page_id uuid not null references public.booking_pages(id) on delete restrict,
  start_at timestamptz not null,
  expires_at timestamptz not null,
  status text not null default 'OPEN'
    check (status in ('OPEN','CLAIMED','FILLED','CLOSED','EXPIRED')),
  claimed_checkout_hold_id uuid null references public.checkout_holds(id) on delete set null,
  claimed_appointment_id uuid null references public.appointments(id) on delete set null,
  created_by_admin_id uuid not null references public.admin_users(id) on delete restrict,
  filled_at timestamptz null,
  closed_at timestamptz null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (expires_at > created_at),
  check (start_at > created_at)
);

create table if not exists public.waitlist_private_slot_services (
  slot_id uuid not null references public.waitlist_private_slots(id) on delete cascade,
  service_id uuid not null references public.services(id) on delete restrict,
  service_employee_id uuid not null references public.service_employees(id) on delete restrict,
  primary key (slot_id, service_id)
);

create table if not exists public.waitlist_private_slot_resources (
  slot_id uuid not null references public.waitlist_private_slots(id) on delete cascade,
  resource_id uuid not null references public.resources(id) on delete restrict,
  allocation_id uuid not null unique references public.resource_allocations(id) on delete restrict,
  occupied_range_snapshot tstzrange not null,
  primary key (slot_id, resource_id),
  check (not isempty(occupied_range_snapshot)),
  check (lower_inc(occupied_range_snapshot) and not upper_inc(occupied_range_snapshot))
);

create table if not exists public.waitlist_private_invites (
  id uuid primary key default gen_random_uuid(),
  slot_id uuid not null references public.waitlist_private_slots(id) on delete cascade,
  waitlist_entry_id uuid not null references public.service_waitlist_entries(id) on delete restrict,
  token_hash text not null unique,
  expires_at timestamptz not null,
  opened_at timestamptz null,
  revoked_at timestamptz null,
  checkout_hold_id uuid null references public.checkout_holds(id) on delete set null,
  appointment_id uuid null references public.appointments(id) on delete set null,
  created_by_admin_id uuid not null references public.admin_users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (slot_id, waitlist_entry_id)
);

create index if not exists waitlist_private_slots_status_start_idx
  on public.waitlist_private_slots(status, start_at);
create index if not exists waitlist_private_invites_slot_idx
  on public.waitlist_private_invites(slot_id);
create index if not exists waitlist_private_invites_waitlist_idx
  on public.waitlist_private_invites(waitlist_entry_id);
create index if not exists waitlist_private_invites_checkout_idx
  on public.waitlist_private_invites(checkout_hold_id) where checkout_hold_id is not null;
create index if not exists waitlist_private_invites_appointment_idx
  on public.waitlist_private_invites(appointment_id) where appointment_id is not null;

alter table public.waitlist_private_slots enable row level security;
alter table public.waitlist_private_slot_services enable row level security;
alter table public.waitlist_private_slot_resources enable row level security;
alter table public.waitlist_private_invites enable row level security;

revoke all on public.waitlist_private_slots from anon, authenticated;
revoke all on public.waitlist_private_slot_services from anon, authenticated;
revoke all on public.waitlist_private_slot_resources from anon, authenticated;
revoke all on public.waitlist_private_invites from anon, authenticated;

create or replace function public.service_expire_waitlist_private_slots()
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_slot record;
  v_count integer := 0;
begin
  for v_slot in
    select s.id
    from public.waitlist_private_slots s
    where s.status = 'OPEN'
      and (s.expires_at <= now() or s.start_at <= now())
    for update skip locked
  loop
    update public.waitlist_private_slots
    set status = 'EXPIRED',
        updated_at = now()
    where id = v_slot.id;

    update public.resource_allocations ra
    set status = 'RELEASED',
        updated_at = now()
    from public.waitlist_private_slot_resources sr
    where sr.slot_id = v_slot.id
      and sr.allocation_id = ra.id
      and ra.allocation_type = 'MANUAL_BLOCK'
      and ra.status = 'BLOCKED';

    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$function$;

create or replace function public.try_restore_waitlist_private_slot(p_slot_id uuid, p_reason text default 'CLAIM_RELEASED')
returns boolean
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_slot public.waitlist_private_slots%rowtype;
  v_resource record;
  v_new_allocation_id uuid;
begin
  select * into v_slot
  from public.waitlist_private_slots
  where id = p_slot_id
  for update;

  if not found or v_slot.status <> 'CLAIMED' then
    return false;
  end if;

  if exists (
    select 1
    from public.waitlist_private_slot_resources sr
    join public.resource_allocations ra on ra.id = sr.allocation_id
    where sr.slot_id = v_slot.id
      and ra.status in ('HELD','AWAITING_PAYMENT','CONFIRMED','BLOCKED','EXTERNAL_ACTIVE')
  ) then
    return false;
  end if;

  if v_slot.expires_at <= now() or v_slot.start_at <= now() then
    update public.waitlist_private_slots
    set status = 'EXPIRED',
        claimed_checkout_hold_id = null,
        claimed_appointment_id = null,
        updated_at = now()
    where id = v_slot.id;
    return false;
  end if;

  for v_resource in
    select sr.resource_id, sr.occupied_range_snapshot
    from public.waitlist_private_slot_resources sr
    where sr.slot_id = v_slot.id
    order by sr.resource_id
  loop
    insert into public.resource_allocations (
      resource_id, allocation_type, status, occupied_range, reason, created_by_admin_id
    ) values (
      v_resource.resource_id, 'MANUAL_BLOCK', 'BLOCKED',
      v_resource.occupied_range_snapshot,
      'WAITLIST_PRIVATE_SLOT:' || v_slot.id::text,
      v_slot.created_by_admin_id
    )
    returning id into v_new_allocation_id;

    update public.waitlist_private_slot_resources
    set allocation_id = v_new_allocation_id
    where slot_id = v_slot.id
      and resource_id = v_resource.resource_id;
  end loop;

  update public.waitlist_private_invites
  set checkout_hold_id = null,
      appointment_id = null,
      updated_at = now()
  where slot_id = v_slot.id
    and (
      checkout_hold_id = v_slot.claimed_checkout_hold_id
      or appointment_id = v_slot.claimed_appointment_id
    );

  update public.waitlist_private_slots
  set status = 'OPEN',
      claimed_checkout_hold_id = null,
      claimed_appointment_id = null,
      updated_at = now()
  where id = v_slot.id;

  insert into public.audit_logs(entity_type, entity_id, action, after_json, origin)
  values (
    'WAITLIST_PRIVATE_SLOT',
    v_slot.id,
    'WAITLIST_PRIVATE_SLOT_REOPENED',
    jsonb_build_object('reason', coalesce(nullif(btrim(p_reason),''),'CLAIM_RELEASED')),
    'SYSTEM'
  );

  return true;
exception
  when exclusion_violation then
    update public.waitlist_private_slots
    set status = 'CLOSED',
        closed_at = coalesce(closed_at, now()),
        updated_at = now()
    where id = p_slot_id;
    insert into public.audit_logs(entity_type, entity_id, action, after_json, origin)
    values (
      'WAITLIST_PRIVATE_SLOT', p_slot_id, 'WAITLIST_PRIVATE_SLOT_RESTORE_CONFLICT',
      jsonb_build_object('reason', coalesce(nullif(btrim(p_reason),''),'CLAIM_RELEASED')), 'SYSTEM'
    );
    return false;
end;
$function$;

create or replace function public.trg_restore_waitlist_private_slot_allocation()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_slot_id uuid;
begin
  if new.status not in ('EXPIRED','RELEASED') or old.status = new.status then
    return new;
  end if;

  select sr.slot_id into v_slot_id
  from public.waitlist_private_slot_resources sr
  where sr.allocation_id = new.id;

  if v_slot_id is not null then
    perform public.try_restore_waitlist_private_slot(v_slot_id, 'RESOURCE_' || new.status);
  end if;
  return new;
end;
$function$;

drop trigger if exists waitlist_private_slot_allocation_restore_trg on public.resource_allocations;
create trigger waitlist_private_slot_allocation_restore_trg
after update of status on public.resource_allocations
for each row
execute function public.trg_restore_waitlist_private_slot_allocation();

create or replace function public.trg_sync_waitlist_private_checkout_promotion()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_invite public.waitlist_private_invites%rowtype;
  v_status text;
begin
  if new.promoted_appointment_id is null
     or new.promoted_appointment_id is not distinct from old.promoted_appointment_id then
    return new;
  end if;

  select * into v_invite
  from public.waitlist_private_invites
  where checkout_hold_id = new.id
  limit 1;

  if not found then
    return new;
  end if;

  update public.waitlist_private_invites
  set appointment_id = new.promoted_appointment_id,
      updated_at = now()
  where id = v_invite.id;

  update public.waitlist_private_slots
  set claimed_appointment_id = new.promoted_appointment_id,
      updated_at = now()
  where id = v_invite.slot_id
    and status = 'CLAIMED';

  select a.status::text into v_status
  from public.appointments a
  where a.id = new.promoted_appointment_id;

  if v_status = 'CONFIRMED' then
    update public.waitlist_private_slots
    set status = 'FILLED',
        filled_at = coalesce(filled_at, now()),
        updated_at = now()
    where id = v_invite.slot_id
      and status = 'CLAIMED';
  end if;

  return new;
end;
$function$;

drop trigger if exists waitlist_private_checkout_promotion_trg on public.checkout_holds;
create trigger waitlist_private_checkout_promotion_trg
after update of promoted_appointment_id on public.checkout_holds
for each row
execute function public.trg_sync_waitlist_private_checkout_promotion();

create or replace function public.trg_sync_waitlist_private_appointment_status()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if new.status::text = 'CONFIRMED'
     and (tg_op = 'INSERT' or old.status is distinct from new.status) then
    update public.waitlist_private_slots
    set status = 'FILLED',
        filled_at = coalesce(filled_at, now()),
        updated_at = now()
    where claimed_appointment_id = new.id
      and status = 'CLAIMED';
  end if;
  return new;
end;
$function$;

drop trigger if exists waitlist_private_appointment_status_trg on public.appointments;
create trigger waitlist_private_appointment_status_trg
after insert or update of status on public.appointments
for each row
execute function public.trg_sync_waitlist_private_appointment_status();
