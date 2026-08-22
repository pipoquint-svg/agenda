-- Issue #72: authoritative pre-reservations + explicit invoice due basis.
-- No production customer is enabled or seeded here.

-- PRE_RESERVATION participates in the same exclusion constraint used by checkout holds,
-- appointments and external/manual blocks.
alter domain public.allocation_type drop constraint if exists allocation_type_check;
alter domain public.allocation_type add constraint allocation_type_check
  check (value in ('APPOINTMENT','CHECKOUT_HOLD','PRE_RESERVATION','MANUAL_BLOCK','EXTERNAL_BLOCK'));

alter table public.pre_reservations
  add column service_employee_id uuid references public.service_employees(id) on delete restrict,
  add column public_code text,
  add column people_count integer not null default 1 check (people_count >= 1),
  add column extra_selections jsonb not null default '[]'::jsonb,
  add column extras_snapshot jsonb not null default '[]'::jsonb,
  add column duration_blocks integer check (duration_blocks is null or duration_blocks >= 1),
  add column contracted_minutes integer check (contracted_minutes is null or contracted_minutes > 0),
  add column duration_minutes integer check (duration_minutes is null or duration_minutes > 0),
  add column core_start_at timestamptz,
  add column core_end_at timestamptz,
  add column pre_service_minutes integer not null default 0 check (pre_service_minutes >= 0),
  add column post_service_minutes integer not null default 0 check (post_service_minutes >= 0),
  add column schedule_profile_snapshot jsonb not null default '{}'::jsonb,
  add column quote_snapshot jsonb,
  add column resource_ids uuid[] not null default '{}'::uuid[],
  add column billing_mode_snapshot text check (billing_mode_snapshot is null or billing_mode_snapshot in ('CHECKOUT','INVOICE')),
  add column invoice_due_days_snapshot integer check (invoice_due_days_snapshot is null or invoice_due_days_snapshot >= 0),
  add column requires_manual_confirmation_snapshot boolean,
  add column released_at timestamptz,
  add column released_by_admin_id uuid,
  add column release_reason text;

create unique index pre_reservations_public_code_uq
  on public.pre_reservations(public_code)
  where public_code is not null;

alter table public.pre_reservations
  add constraint pre_reservations_core_range_check
    check (core_start_at is null or core_end_at is null or core_end_at > core_start_at),
  add constraint pre_reservations_schedule_envelope_check
    check (
      core_start_at is null
      or core_end_at is null
      or (start_at <= core_start_at and end_at >= core_end_at)
    );

alter table public.appointments
  add column invoice_due_basis text check (invoice_due_basis is null or invoice_due_basis = 'SERVICE_START'),
  add column invoice_due_days_snapshot integer check (invoice_due_days_snapshot is null or invoice_due_days_snapshot >= 0);

create table public.pre_reservation_access_tokens (
  id uuid primary key default gen_random_uuid(),
  pre_reservation_id uuid not null references public.pre_reservations(id) on delete cascade,
  token_hash text not null unique,
  scope text not null default 'VIEW' check (scope = 'VIEW'),
  expires_at timestamptz not null,
  revoked_at timestamptz,
  created_at timestamptz not null default now(),
  last_used_at timestamptz
);

create index pre_reservation_access_tokens_pre_reservation_idx
  on public.pre_reservation_access_tokens(pre_reservation_id)
  where revoked_at is null;

alter table public.resource_allocations
  add column pre_reservation_id uuid references public.pre_reservations(id) on delete restrict;

alter table public.resource_allocations
  drop constraint resource_allocations_owner_check;

alter table public.resource_allocations
  add constraint resource_allocations_owner_check check (
    (allocation_type = 'APPOINTMENT'
      and appointment_id is not null and checkout_hold_id is null and pre_reservation_id is null)
    or
    (allocation_type = 'CHECKOUT_HOLD'
      and checkout_hold_id is not null and appointment_id is null and pre_reservation_id is null)
    or
    (allocation_type = 'PRE_RESERVATION'
      and pre_reservation_id is not null and appointment_id is null and checkout_hold_id is null)
    or
    (allocation_type in ('MANUAL_BLOCK','EXTERNAL_BLOCK')
      and appointment_id is null and checkout_hold_id is null and pre_reservation_id is null)
  );

create index resource_allocations_pre_reservation_idx
  on public.resource_allocations(pre_reservation_id)
  where pre_reservation_id is not null;

-- Service-role callers must use the audited RPC surface instead of direct mutation.
revoke insert, update, delete, truncate on table public.pre_reservations
  from public, anon, authenticated, service_role;
revoke insert, update, delete, truncate on table public.pre_reservation_access_tokens
  from public, anon, authenticated, service_role;

create or replace function public.service_expire_pre_reservations()
returns integer
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_pr public.pre_reservations%rowtype;
  v_after jsonb;
  v_count integer := 0;
  v_released_at timestamptz;
begin
  for v_pr in
    select pr.*
    from public.pre_reservations pr
    where pr.status = 'ACTIVE'
      and pr.expires_at <= now()
    for update skip locked
  loop
    v_released_at := now();

    update public.resource_allocations
    set status = 'EXPIRED', updated_at = v_released_at
    where pre_reservation_id = v_pr.id
      and status = 'HELD';

    update public.pre_reservation_access_tokens
    set revoked_at = coalesce(revoked_at, v_released_at)
    where pre_reservation_id = v_pr.id
      and revoked_at is null;

    update public.pre_reservations
    set status = 'EXPIRED',
        released_at = v_released_at,
        released_by_admin_id = null,
        release_reason = 'EXPIRED',
        updated_at = v_released_at
    where id = v_pr.id
    returning to_jsonb(pre_reservations.*) into v_after;

    insert into public.audit_logs(
      admin_user_id, entity_type, entity_id, action, before_json, after_json, origin
    ) values (
      null, 'PRE_RESERVATION', v_pr.id, 'PRE_RESERVATION_EXPIRED',
      to_jsonb(v_pr), v_after, 'SYSTEM'
    );

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

create or replace function public.service_admin_create_pre_reservation(
  p_customer_id uuid,
  p_service_id uuid,
  p_service_employee_id uuid,
  p_requested_start_at timestamptz,
  p_admin_id uuid,
  p_duration_blocks integer default null,
  p_extra_selections jsonb default '[]'::jsonb,
  p_people_count integer default 1,
  p_notes text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_terms public.customer_commercial_terms%rowtype;
  v_service public.services%rowtype;
  v_customer public.customers%rowtype;
  v_employee_id uuid;
  v_timezone text;
  v_local_date date;
  v_slot record;
  v_quote jsonb;
  v_canonical_extras jsonb;
  v_extras_snapshot jsonb;
  v_resource_ids uuid[] := '{}'::uuid[];
  v_pre_reservation_id uuid := gen_random_uuid();
  v_public_code text;
  v_raw_token text;
  v_token_hash text;
  v_expires_at timestamptz;
  v_active_count integer;
  v_contracted_minutes integer;
begin
  if not public.service_admin_has_permission(p_admin_id, 'AGENDA_MANAGE') then
    raise exception using errcode = 'P0001', message = 'ADMIN_PERMISSION_DENIED';
  end if;

  perform public.service_expire_pre_reservations();

  select * into v_terms
  from public.customer_commercial_terms
  where customer_id = p_customer_id
    and is_active = true
  for update;

  if not found or not v_terms.can_prebook then
    raise exception using errcode = 'P0001', message = 'CUSTOMER_NOT_AUTHORIZED_FOR_PREBOOK';
  end if;

  if not exists (
    select 1
    from public.customer_prebook_authorized_services cas
    where cas.customer_id = p_customer_id
      and cas.service_id = p_service_id
  ) then
    raise exception using errcode = 'P0001', message = 'SERVICE_NOT_AUTHORIZED_FOR_PREBOOK';
  end if;

  select count(*)::integer into v_active_count
  from public.pre_reservations pr
  where pr.customer_id = p_customer_id
    and pr.status = 'ACTIVE'
    and pr.expires_at > now();

  if v_active_count >= v_terms.max_active_prebooks then
    raise exception using errcode = 'P0001', message = 'MAX_ACTIVE_PREBOOKS_REACHED';
  end if;

  select * into v_customer from public.customers where id = p_customer_id;
  if not found then
    raise exception using errcode = 'P0001', message = 'CUSTOMER_NOT_FOUND';
  end if;

  select s.* into v_service
  from public.services s
  where s.id = p_service_id and s.is_active;
  if not found then
    raise exception using errcode = 'P0001', message = 'SERVICE_NOT_AVAILABLE';
  end if;

  select se.employee_id into v_employee_id
  from public.service_employees se
  join public.employees e on e.id = se.employee_id and e.is_active
  where se.id = p_service_employee_id
    and se.service_id = p_service_id
    and se.is_active;
  if not found then
    raise exception using errcode = 'P0001', message = 'EMPLOYEE_NOT_AVAILABLE_FOR_SERVICE';
  end if;

  if jsonb_typeof(coalesce(p_extra_selections, '[]'::jsonb)) <> 'array' then
    raise exception using errcode = 'P0001', message = 'INVALID_EXTRA';
  end if;

  select coalesce(jsonb_agg(
    jsonb_build_object('extra_id', x.extra_id, 'quantity', x.quantity)
    order by x.extra_id
  ), '[]'::jsonb)
  into v_canonical_extras
  from jsonb_to_recordset(coalesce(p_extra_selections, '[]'::jsonb)) x(extra_id uuid, quantity integer);

  v_contracted_minutes := public.resolve_service_contracted_minutes(p_service_id, p_duration_blocks);
  select timezone into v_timezone from public.operation_settings where id = 1;
  v_local_date := (p_requested_start_at at time zone v_timezone)::date;

  select s.* into v_slot
  from (
    select * from public.list_available_slots_for_duration(
      p_service_id, p_service_employee_id, p_duration_blocks,
      v_canonical_extras, p_people_count, v_local_date, null
    )
    union all
    select * from public.list_available_slots_for_duration(
      p_service_id, p_service_employee_id, p_duration_blocks,
      v_canonical_extras, p_people_count, v_local_date + 1, null
    )
  ) s
  where s.slot_start_at = p_requested_start_at
  order by s.core_start_at
  limit 1;

  if not found then
    raise exception using errcode = 'P0001', message = 'SLOT_NO_LONGER_AVAILABLE';
  end if;

  v_quote := public.calculate_booking_quote_for_duration(
    p_service_id, p_service_employee_id, p_duration_blocks,
    v_canonical_extras, p_people_count, v_slot.core_start_at, null
  );

  select coalesce(array_agg(r.resource_id order by r.resource_id), '{}'::uuid[])
  into v_resource_ids
  from public.calculate_booking_resource_ranges_for_duration(
    p_service_id, v_canonical_extras, v_slot.core_start_at, p_duration_blocks
  ) r;

  if coalesce(array_length(v_resource_ids, 1), 0) = 0 then
    raise exception using errcode = 'P0001', message = 'SERVICE_HAS_NO_REQUIRED_RESOURCES';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'extra_id', e.id,
    'name', e.name,
    'unit_price', e.price,
    'duration_delta_minutes', e.duration_delta_minutes,
    'quantity', x.quantity,
    'total_price', round(e.price * x.quantity, 2),
    'total_duration_delta', e.duration_delta_minutes * x.quantity
  ) order by e.id), '[]'::jsonb)
  into v_extras_snapshot
  from jsonb_to_recordset(v_canonical_extras) x(extra_id uuid, quantity integer)
  join public.extras e on e.id = x.extra_id;

  loop
    v_public_code := upper(substr(encode(gen_random_bytes(8), 'hex'), 1, 12));
    exit when not exists (
      select 1 from public.pre_reservations pr where pr.public_code = v_public_code
    );
  end loop;

  v_raw_token := encode(gen_random_bytes(32), 'hex');
  v_token_hash := encode(digest(v_raw_token, 'sha256'), 'hex');
  v_expires_at := now() + make_interval(mins => v_terms.prebook_hold_minutes);

  insert into public.pre_reservations(
    id, customer_id, service_id, employee_id, service_employee_id, public_code,
    start_at, end_at, core_start_at, core_end_at,
    pre_service_minutes, post_service_minutes, schedule_profile_snapshot,
    expires_at, status, people_count, extra_selections, extras_snapshot,
    duration_blocks, contracted_minutes, duration_minutes, quote_snapshot, resource_ids,
    billing_mode_snapshot, invoice_due_days_snapshot, requires_manual_confirmation_snapshot,
    created_by_admin_id, notes
  ) values (
    v_pre_reservation_id, p_customer_id, p_service_id, v_employee_id, p_service_employee_id, v_public_code,
    v_slot.slot_start_at, v_slot.slot_end_at, v_slot.core_start_at, v_slot.core_end_at,
    v_slot.pre_service_minutes, v_slot.post_service_minutes, v_quote->'schedule_profile',
    v_expires_at, 'ACTIVE', p_people_count, v_canonical_extras, v_extras_snapshot,
    p_duration_blocks, v_contracted_minutes, v_slot.duration_minutes, v_quote, v_resource_ids,
    v_terms.billing_mode, v_terms.invoice_due_days, v_terms.requires_manual_confirmation,
    p_admin_id, nullif(btrim(coalesce(p_notes, '')), '')
  );

  insert into public.pre_reservation_access_tokens(
    pre_reservation_id, token_hash, scope, expires_at
  ) values (
    v_pre_reservation_id, v_token_hash, 'VIEW', v_expires_at
  );

  begin
    insert into public.resource_allocations(
      resource_id, pre_reservation_id, allocation_type, status, occupied_range,
      reason, created_by_admin_id
    )
    select r.resource_id, v_pre_reservation_id, 'PRE_RESERVATION', 'HELD', r.occupied_range,
           'PRE_RESERVATION', p_admin_id
    from public.calculate_booking_resource_ranges_for_duration(
      p_service_id, v_canonical_extras, v_slot.core_start_at, p_duration_blocks
    ) r;
  exception when exclusion_violation then
    raise exception using errcode = 'P0001', message = 'SLOT_NO_LONGER_AVAILABLE';
  end;

  insert into public.audit_logs(
    admin_user_id, entity_type, entity_id, action, after_json, origin
  ) values (
    p_admin_id, 'PRE_RESERVATION', v_pre_reservation_id, 'PRE_RESERVATION_CREATED',
    jsonb_build_object(
      'customer_id', p_customer_id,
      'service_id', p_service_id,
      'service_employee_id', p_service_employee_id,
      'public_code', v_public_code,
      'status', 'ACTIVE',
      'start_at', v_slot.slot_start_at,
      'end_at', v_slot.slot_end_at,
      'core_start_at', v_slot.core_start_at,
      'core_end_at', v_slot.core_end_at,
      'expires_at', v_expires_at,
      'resource_ids', to_jsonb(v_resource_ids),
      'billing_mode', v_terms.billing_mode,
      'invoice_due_days', v_terms.invoice_due_days,
      'requires_manual_confirmation', v_terms.requires_manual_confirmation
    ),
    'ADMIN'
  );

  return jsonb_build_object(
    'pre_reservation_id', v_pre_reservation_id,
    'public_code', v_public_code,
    'status', 'ACTIVE',
    'expires_at', v_expires_at,
    'start_at', v_slot.slot_start_at,
    'end_at', v_slot.slot_end_at,
    'core_start_at', v_slot.core_start_at,
    'core_end_at', v_slot.core_end_at,
    'billing_mode', v_terms.billing_mode,
    'invoice_due_days', v_terms.invoice_due_days,
    'commercial_value', (v_quote->>'commercial_value')::numeric(12,2),
    'access_token', v_raw_token,
    'authoritative_resource_hold', true
  );
end;
$$;

create or replace function public.service_admin_cancel_pre_reservation(
  p_pre_reservation_id uuid,
  p_admin_id uuid,
  p_reason text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_pr public.pre_reservations%rowtype;
  v_after jsonb;
  v_released_at timestamptz;
begin
  if not public.service_admin_has_permission(p_admin_id, 'AGENDA_MANAGE') then
    raise exception using errcode = 'P0001', message = 'ADMIN_PERMISSION_DENIED';
  end if;

  perform public.service_expire_pre_reservations();

  select * into v_pr
  from public.pre_reservations
  where id = p_pre_reservation_id
  for update;

  if not found then
    raise exception using errcode = 'P0001', message = 'PRE_RESERVATION_NOT_FOUND';
  end if;

  if v_pr.status = 'CANCELLED' then
    return jsonb_build_object(
      'pre_reservation_id', v_pr.id,
      'status', v_pr.status,
      'released_at', v_pr.released_at
    );
  end if;

  if v_pr.status <> 'ACTIVE' then
    raise exception using errcode = 'P0001', message = 'PRE_RESERVATION_NOT_ACTIVE';
  end if;

  v_released_at := now();

  update public.resource_allocations
  set status = 'CANCELLED', updated_at = v_released_at
  where pre_reservation_id = v_pr.id
    and status = 'HELD';

  update public.pre_reservation_access_tokens
  set revoked_at = coalesce(revoked_at, v_released_at)
  where pre_reservation_id = v_pr.id
    and revoked_at is null;

  update public.pre_reservations
  set status = 'CANCELLED',
      cancelled_by_admin_id = p_admin_id,
      cancelled_at = v_released_at,
      released_at = v_released_at,
      released_by_admin_id = p_admin_id,
      release_reason = nullif(btrim(coalesce(p_reason, '')), ''),
      updated_at = v_released_at
  where id = v_pr.id
  returning to_jsonb(pre_reservations.*) into v_after;

  insert into public.audit_logs(
    admin_user_id, entity_type, entity_id, action, before_json, after_json, origin
  ) values (
    p_admin_id, 'PRE_RESERVATION', v_pr.id, 'PRE_RESERVATION_CANCELLED',
    to_jsonb(v_pr), v_after, 'ADMIN'
  );

  return jsonb_build_object(
    'pre_reservation_id', v_pr.id,
    'status', 'CANCELLED',
    'released_at', v_released_at
  );
end;
$$;

create or replace function public.service_admin_confirm_pre_reservation(
  p_pre_reservation_id uuid,
  p_admin_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_pr public.pre_reservations%rowtype;
  v_service public.services%rowtype;
  v_customer public.customers%rowtype;
  v_quote jsonb;
  v_appointment_id uuid := gen_random_uuid();
  v_public_code text;
  v_raw_access_token text;
  v_access_token_hash text;
  v_access_scope text;
  v_final_status public.appointment_status;
  v_financial_status public.financial_status;
  v_allocation_status public.allocation_status;
  v_payment_hold_minutes integer;
  v_hold_expires_at timestamptz;
  v_invoice_due_at timestamptz;
  v_invoice_due_basis text;
  v_expected_allocations integer;
  v_actual_allocations integer;
  v_after jsonb;
begin
  if not public.service_admin_has_permission(p_admin_id, 'AGENDA_MANAGE') then
    raise exception using errcode = 'P0001', message = 'ADMIN_PERMISSION_DENIED';
  end if;

  perform public.service_expire_pre_reservations();

  select * into v_pr
  from public.pre_reservations
  where id = p_pre_reservation_id
  for update;

  if not found then
    raise exception using errcode = 'P0001', message = 'PRE_RESERVATION_NOT_FOUND';
  end if;

  if v_pr.status = 'CONFIRMED' and v_pr.converted_appointment_id is not null then
    return jsonb_build_object(
      'pre_reservation_id', v_pr.id,
      'status', 'CONFIRMED',
      'appointment_id', v_pr.converted_appointment_id,
      'appointment_access_token', null
    );
  end if;

  if v_pr.status <> 'ACTIVE' or v_pr.expires_at <= now() then
    raise exception using errcode = 'P0001', message = 'PRE_RESERVATION_NOT_ACTIVE';
  end if;

  if v_pr.billing_mode_snapshot is null then
    raise exception using errcode = 'P0001', message = 'PRE_RESERVATION_BILLING_SNAPSHOT_MISSING';
  end if;

  if v_pr.billing_mode_snapshot = 'INVOICE'
     and not public.service_admin_has_permission(p_admin_id, 'FINANCE_MANAGE') then
    raise exception using errcode = 'P0001', message = 'ADMIN_PERMISSION_DENIED';
  end if;

  select * into v_service from public.services where id = v_pr.service_id;
  if not found then
    raise exception using errcode = 'P0001', message = 'SERVICE_NOT_FOUND';
  end if;

  select * into v_customer from public.customers where id = v_pr.customer_id;
  if not found then
    raise exception using errcode = 'P0001', message = 'CUSTOMER_NOT_FOUND';
  end if;

  v_expected_allocations := coalesce(array_length(v_pr.resource_ids, 1), 0);
  select count(*)::integer into v_actual_allocations
  from public.resource_allocations ra
  where ra.pre_reservation_id = v_pr.id
    and ra.allocation_type = 'PRE_RESERVATION'
    and ra.status = 'HELD';

  if v_expected_allocations = 0 or v_actual_allocations <> v_expected_allocations then
    raise exception using errcode = 'P0001', message = 'PRE_RESERVATION_ALLOCATION_MISSING';
  end if;

  v_quote := v_pr.quote_snapshot;
  if v_quote is null then
    raise exception using errcode = 'P0001', message = 'PRE_RESERVATION_QUOTE_SNAPSHOT_MISSING';
  end if;

  if v_pr.billing_mode_snapshot = 'INVOICE' then
    if v_pr.invoice_due_days_snapshot is null then
      raise exception using errcode = 'P0001', message = 'INVOICE_DUE_DAYS_REQUIRED';
    end if;
    v_final_status := 'CONFIRMED';
    v_financial_status := 'UNPAID_AUTHORIZED';
    v_allocation_status := 'CONFIRMED';
    v_hold_expires_at := null;
    v_invoice_due_basis := 'SERVICE_START';
    v_invoice_due_at := coalesce(v_pr.core_start_at, v_pr.start_at)
      + make_interval(days => v_pr.invoice_due_days_snapshot);
    v_access_scope := 'VIEW';
  else
    v_final_status := 'AWAITING_PAYMENT';
    v_financial_status := 'PENDING';
    v_allocation_status := 'AWAITING_PAYMENT';
    select coalesce(v_service.payment_hold_minutes, os.payment_hold_minutes)
      into v_payment_hold_minutes
    from public.operation_settings os
    where os.id = 1;
    v_hold_expires_at := now() + make_interval(mins => v_payment_hold_minutes);
    v_invoice_due_basis := null;
    v_invoice_due_at := null;
    v_access_scope := 'PAY';
  end if;

  loop
    v_public_code := upper(substr(encode(gen_random_bytes(8), 'hex'), 1, 12));
    exit when not exists (
      select 1 from public.appointments a where a.public_code = v_public_code
    );
  end loop;

  insert into public.appointments(
    id, public_code, service_id, service_employee_id, primary_customer_id,
    status, financial_status, start_at, end_at, duration_minutes, people_count,
    hold_expires_at, version, origin,
    service_name_snapshot, service_description_snapshot,
    base_duration_snapshot, buffer_before_snapshot, buffer_after_snapshot,
    base_price_snapshot, variable_price_adjustment, extras_total, coupon_discount,
    commercial_value, confirmed_at,
    billing_mode_snapshot, invoice_due_at, invoice_authorized_by_admin_id,
    source_pre_reservation_id, invoice_due_basis, invoice_due_days_snapshot,
    core_start_at, core_end_at, pre_service_minutes, post_service_minutes,
    schedule_profile_snapshot, duration_blocks, contracted_minutes
  ) values (
    v_appointment_id, v_public_code, v_pr.service_id, v_pr.service_employee_id, v_pr.customer_id,
    v_final_status, v_financial_status, v_pr.start_at, v_pr.end_at,
    coalesce(v_pr.duration_minutes, greatest(1, round(extract(epoch from (v_pr.end_at - v_pr.start_at))/60)::integer)),
    v_pr.people_count,
    v_hold_expires_at, 1, 'ADMIN',
    v_service.name, v_service.full_description,
    v_service.base_duration_minutes, v_service.buffer_before_minutes, v_service.buffer_after_minutes,
    coalesce((v_quote->>'base_price')::numeric, v_service.base_price),
    coalesce((v_quote->>'day_time_adjustment')::numeric, 0) + coalesce((v_quote->>'people_adjustment')::numeric, 0),
    coalesce((v_quote->>'extras_total')::numeric, 0),
    coalesce((v_quote->>'coupon_discount')::numeric, 0),
    coalesce((v_quote->>'commercial_value')::numeric, 0),
    case when v_final_status = 'CONFIRMED' then now() else null end,
    v_pr.billing_mode_snapshot, v_invoice_due_at,
    case when v_pr.billing_mode_snapshot = 'INVOICE' then p_admin_id else null end,
    v_pr.id, v_invoice_due_basis,
    case when v_pr.billing_mode_snapshot = 'INVOICE' then v_pr.invoice_due_days_snapshot else null end,
    v_pr.core_start_at, v_pr.core_end_at, v_pr.pre_service_minutes, v_pr.post_service_minutes,
    v_pr.schedule_profile_snapshot, v_pr.duration_blocks, v_pr.contracted_minutes
  );

  insert into public.appointment_participants(
    appointment_id, customer_id, role, name_snapshot, email_snapshot, phone_snapshot, cpf_cnpj_snapshot
  ) values (
    v_appointment_id, v_customer.id, 'BOOKER', v_customer.name,
    v_customer.email, v_customer.phone, v_customer.cpf_cnpj
  );

  insert into public.appointment_extras(
    appointment_id, extra_id, name_snapshot, unit_price_snapshot,
    duration_delta_snapshot, quantity, total_price, total_duration_delta
  )
  select
    v_appointment_id, x.extra_id, x.name, x.unit_price,
    x.duration_delta_minutes, x.quantity, x.total_price, x.total_duration_delta
  from jsonb_to_recordset(coalesce(v_pr.extras_snapshot, '[]'::jsonb)) x(
    extra_id uuid,
    name text,
    unit_price numeric,
    duration_delta_minutes integer,
    quantity integer,
    total_price numeric,
    total_duration_delta integer
  );

  -- Atomic ownership transfer: the exact same allocation rows remain in place.
  -- There is no release/recreate window in which another booking can enter.
  update public.resource_allocations
  set appointment_id = v_appointment_id,
      pre_reservation_id = null,
      allocation_type = 'APPOINTMENT',
      status = v_allocation_status,
      updated_at = now()
  where pre_reservation_id = v_pr.id
    and allocation_type = 'PRE_RESERVATION'
    and status = 'HELD';

  update public.pre_reservation_access_tokens
  set revoked_at = coalesce(revoked_at, now())
  where pre_reservation_id = v_pr.id
    and revoked_at is null;

  update public.pre_reservations
  set status = 'CONFIRMED',
      converted_appointment_id = v_appointment_id,
      confirmed_by_admin_id = p_admin_id,
      confirmed_at = now(),
      updated_at = now()
  where id = v_pr.id
  returning to_jsonb(pre_reservations.*) into v_after;

  v_raw_access_token := encode(gen_random_bytes(32), 'hex');
  v_access_token_hash := encode(digest(v_raw_access_token, 'sha256'), 'hex');

  insert into public.appointment_access_tokens(
    appointment_id, token_hash, scope, expires_at
  ) values (
    v_appointment_id, v_access_token_hash, v_access_scope,
    case when v_access_scope = 'PAY' then v_hold_expires_at else null end
  );

  insert into public.audit_logs(
    admin_user_id, entity_type, entity_id, action, before_json, after_json, origin
  ) values (
    p_admin_id, 'PRE_RESERVATION', v_pr.id, 'PRE_RESERVATION_CONFIRMED',
    to_jsonb(v_pr), v_after || jsonb_build_object(
      'appointment_id', v_appointment_id,
      'billing_mode', v_pr.billing_mode_snapshot,
      'invoice_due_basis', v_invoice_due_basis,
      'invoice_due_days', v_pr.invoice_due_days_snapshot,
      'invoice_due_at', v_invoice_due_at
    ),
    'ADMIN'
  );

  return jsonb_build_object(
    'pre_reservation_id', v_pr.id,
    'status', 'CONFIRMED',
    'appointment_id', v_appointment_id,
    'appointment_status', v_final_status,
    'financial_status', v_financial_status,
    'billing_mode', v_pr.billing_mode_snapshot,
    'invoice_due_basis', v_invoice_due_basis,
    'invoice_due_days', case when v_pr.billing_mode_snapshot = 'INVOICE' then v_pr.invoice_due_days_snapshot else null end,
    'invoice_due_at', v_invoice_due_at,
    'hold_expires_at', v_hold_expires_at,
    'appointment_access_token', v_raw_access_token,
    'allocation_transferred_atomically', true
  );
end;
$$;

create or replace function public.public_get_pre_reservation_context(p_access_token text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions
as $$
declare
  v_hash text;
  v_token public.pre_reservation_access_tokens%rowtype;
  v_pr public.pre_reservations%rowtype;
  v_service public.services%rowtype;
begin
  perform public.service_expire_pre_reservations();

  if p_access_token is null or length(btrim(p_access_token)) < 32 then
    raise exception using errcode = 'P0001', message = 'PRE_RESERVATION_TOKEN_INVALID';
  end if;

  v_hash := encode(digest(btrim(p_access_token), 'sha256'), 'hex');

  select * into v_token
  from public.pre_reservation_access_tokens
  where token_hash = v_hash
  for update;

  if not found or v_token.revoked_at is not null then
    raise exception using errcode = 'P0001', message = 'PRE_RESERVATION_TOKEN_INVALID';
  end if;

  if v_token.expires_at <= now() then
    raise exception using errcode = 'P0001', message = 'PRE_RESERVATION_TOKEN_EXPIRED';
  end if;

  select * into v_pr
  from public.pre_reservations
  where id = v_token.pre_reservation_id;

  if not found or v_pr.status <> 'ACTIVE' then
    raise exception using errcode = 'P0001', message = 'PRE_RESERVATION_TOKEN_INVALID';
  end if;

  select * into v_service from public.services where id = v_pr.service_id;

  update public.pre_reservation_access_tokens
  set last_used_at = now()
  where id = v_token.id;

  return jsonb_build_object(
    'public_code', v_pr.public_code,
    'status', v_pr.status,
    'service_name', v_service.name,
    'start_at', v_pr.start_at,
    'end_at', v_pr.end_at,
    'core_start_at', v_pr.core_start_at,
    'core_end_at', v_pr.core_end_at,
    'expires_at', v_pr.expires_at,
    'authoritative_resource_hold', exists(
      select 1 from public.resource_allocations ra
      where ra.pre_reservation_id = v_pr.id
        and ra.allocation_type = 'PRE_RESERVATION'
        and ra.status = 'HELD'
    )
  );
end;
$$;

-- Existing standalone invoice authorization is kept, but its due basis is now explicit
-- and DB authorization is enforced, not only Edge authorization.
create or replace function public.service_admin_authorize_invoiced_appointment(
  p_appointment_id uuid,
  p_admin_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_appt public.appointments%rowtype;
  v_terms public.customer_commercial_terms%rowtype;
  v_due_base timestamptz;
  v_due_at timestamptz;
  v_before jsonb;
  v_after jsonb;
begin
  if not public.service_admin_has_permission(p_admin_id, 'FINANCE_MANAGE') then
    raise exception using errcode = 'P0001', message = 'ADMIN_PERMISSION_DENIED';
  end if;

  select * into v_appt
  from public.appointments
  where id = p_appointment_id
  for update;

  if not found then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_NOT_FOUND';
  end if;

  select * into v_terms
  from public.customer_commercial_terms
  where customer_id = v_appt.primary_customer_id
    and is_active = true;

  if not found or v_terms.billing_mode <> 'INVOICE' then
    raise exception using errcode = 'P0001', message = 'CUSTOMER_NOT_AUTHORIZED_FOR_INVOICE';
  end if;

  v_before := to_jsonb(v_appt);
  v_due_base := coalesce(v_appt.core_start_at, v_appt.start_at);
  v_due_at := v_due_base + make_interval(days => v_terms.invoice_due_days);

  update public.appointments
  set billing_mode_snapshot = 'INVOICE',
      invoice_due_basis = 'SERVICE_START',
      invoice_due_days_snapshot = v_terms.invoice_due_days,
      invoice_due_at = v_due_at,
      invoice_authorized_by_admin_id = p_admin_id,
      financial_status = 'UNPAID_AUTHORIZED',
      updated_at = now()
  where id = p_appointment_id
  returning to_jsonb(appointments.*) into v_after;

  insert into public.audit_logs(
    admin_user_id, entity_type, entity_id, action, before_json, after_json, origin
  ) values (
    p_admin_id, 'APPOINTMENT', p_appointment_id, 'AUTHORIZE_INVOICE',
    v_before, v_after, 'ADMIN'
  );

  return jsonb_build_object(
    'appointment_id', p_appointment_id,
    'billing_mode', 'INVOICE',
    'financial_status', 'UNPAID_AUTHORIZED',
    'invoice_due_basis', 'SERVICE_START',
    'invoice_due_days', v_terms.invoice_due_days,
    'invoice_due_at', v_due_at
  );
end;
$$;

-- Read model now makes the authoritative-hold state explicit; UI can only call a
-- pre-reservation protected when this flag is true.
create or replace function public.service_admin_get_customer_commercial_profile(p_customer_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'customer', jsonb_build_object(
      'id', c.id,
      'customer_type', c.customer_type,
      'name', c.name,
      'legal_name', c.legal_name,
      'cpf_cnpj', c.cpf_cnpj,
      'email', c.email,
      'phone', c.phone,
      'notes', c.notes
    ),
    'terms', case when t.customer_id is null then null else jsonb_build_object(
      'can_prebook', t.can_prebook,
      'prebook_hold_minutes', t.prebook_hold_minutes,
      'max_active_prebooks', t.max_active_prebooks,
      'requires_manual_confirmation', t.requires_manual_confirmation,
      'billing_mode', t.billing_mode,
      'invoice_due_days', t.invoice_due_days,
      'invoice_due_basis', case when t.billing_mode = 'INVOICE' then 'SERVICE_START' else null end,
      'is_active', t.is_active
    ) end,
    'authorized_services', coalesce((
      select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'slug', s.slug) order by s.sort_order, s.name)
      from public.customer_prebook_authorized_services cas
      join public.services s on s.id = cas.service_id
      where cas.customer_id = c.id
    ), '[]'::jsonb),
    'active_pre_reservations', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', pr.id,
        'public_code', pr.public_code,
        'service_id', pr.service_id,
        'service_name', s.name,
        'service_employee_id', pr.service_employee_id,
        'start_at', pr.start_at,
        'end_at', pr.end_at,
        'core_start_at', pr.core_start_at,
        'core_end_at', pr.core_end_at,
        'expires_at', pr.expires_at,
        'status', pr.status,
        'billing_mode', pr.billing_mode_snapshot,
        'invoice_due_days', pr.invoice_due_days_snapshot,
        'commercial_value', case when pr.quote_snapshot is null then null else (pr.quote_snapshot->>'commercial_value')::numeric end,
        'authoritative_resource_hold', exists(
          select 1 from public.resource_allocations ra
          where ra.pre_reservation_id = pr.id
            and ra.allocation_type = 'PRE_RESERVATION'
            and ra.status = 'HELD'
        ),
        'converted_appointment_id', pr.converted_appointment_id
      ) order by pr.start_at)
      from public.pre_reservations pr
      join public.services s on s.id = pr.service_id
      where pr.customer_id = c.id
        and pr.status = 'ACTIVE'
        and pr.expires_at > now()
    ), '[]'::jsonb)
  )
  from public.customers c
  left join public.customer_commercial_terms t on t.customer_id = c.id
  where c.id = p_customer_id;
$$;

revoke all on function public.service_expire_pre_reservations() from public, anon, authenticated;
revoke all on function public.service_admin_create_pre_reservation(uuid,uuid,uuid,timestamptz,uuid,integer,jsonb,integer,text)
  from public, anon, authenticated;
revoke all on function public.service_admin_cancel_pre_reservation(uuid,uuid,text)
  from public, anon, authenticated;
revoke all on function public.service_admin_confirm_pre_reservation(uuid,uuid)
  from public, anon, authenticated;
revoke all on function public.public_get_pre_reservation_context(text) from public;
revoke all on function public.service_admin_authorize_invoiced_appointment(uuid,uuid)
  from public, anon, authenticated;

grant execute on function public.service_expire_pre_reservations() to service_role;
grant execute on function public.service_admin_create_pre_reservation(uuid,uuid,uuid,timestamptz,uuid,integer,jsonb,integer,text)
  to service_role;
grant execute on function public.service_admin_cancel_pre_reservation(uuid,uuid,text)
  to service_role;
grant execute on function public.service_admin_confirm_pre_reservation(uuid,uuid)
  to service_role;
grant execute on function public.public_get_pre_reservation_context(text) to anon, authenticated, service_role;
grant execute on function public.service_admin_authorize_invoiced_appointment(uuid,uuid)
  to service_role;
