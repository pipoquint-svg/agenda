alter table public.payment_transactions
  add column idempotency_key text,
  add column requested_percentage numeric(5,2) check (requested_percentage is null or requested_percentage > 0 and requested_percentage <= 100),
  add column provider_payload_json jsonb not null default '{}'::jsonb;

create unique index payment_transactions_idempotency_uq
  on public.payment_transactions (idempotency_key)
  where idempotency_key is not null;

create table public.payment_provider_events (
  id uuid primary key default gen_random_uuid(),
  provider text not null check (provider in ('MERCADO_PAGO')),
  event_key text not null,
  transaction_id uuid not null references public.payment_transactions(id) on delete restrict,
  provider_payment_id text,
  normalized_status text not null check (normalized_status in ('PENDING','APPROVED','REJECTED','EXPIRED')),
  payload_json jsonb not null default '{}'::jsonb,
  received_at timestamptz not null default now(),
  unique (provider, event_key)
);

create index payment_provider_events_transaction_idx
  on public.payment_provider_events (transaction_id, received_at);

create table public.payment_incidents (
  id uuid primary key default gen_random_uuid(),
  appointment_id uuid not null references public.appointments(id) on delete restrict,
  payment_transaction_id uuid not null references public.payment_transactions(id) on delete restrict,
  incident_type text not null check (incident_type in ('PAYMENT_AFTER_EXPIRATION')),
  status text not null default 'OPEN' check (status in ('OPEN','RESOLVED','IGNORED_WITH_REASON')),
  details_json jsonb not null default '{}'::jsonb,
  detected_at timestamptz not null default now(),
  resolved_at timestamptz,
  resolved_by_admin_id uuid,
  resolution_notes text,
  unique (payment_transaction_id, incident_type)
);

create index payment_incidents_open_idx
  on public.payment_incidents (detected_at)
  where status = 'OPEN';

create or replace function public.get_appointment_financial_summary(p_appointment_id uuid)
returns jsonb
language plpgsql
stable
set search_path = public
as $$
declare
  v_appointment public.appointments%rowtype;
  v_contract_settled numeric(12,2);
  v_cash_received numeric(12,2);
  v_pending_count integer;
begin
  select * into v_appointment
  from public.appointments
  where id = p_appointment_id;

  if not found then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_NOT_FOUND';
  end if;

  select
    coalesce(sum(contract_amount_settled) filter (
      where transaction_type = 'CHARGE' and status = 'APPROVED'
    ), 0)::numeric(12,2),
    coalesce(sum(cash_amount) filter (
      where transaction_type = 'CHARGE' and status = 'APPROVED'
    ), 0)::numeric(12,2),
    count(*) filter (
      where transaction_type = 'CHARGE' and status = 'PENDING'
    )::integer
  into v_contract_settled, v_cash_received, v_pending_count
  from public.payment_transactions
  where appointment_id = p_appointment_id;

  return jsonb_build_object(
    'appointment_id', v_appointment.id,
    'commercial_value', coalesce(v_appointment.commercial_value, 0),
    'contract_settled', v_contract_settled,
    'cash_received', v_cash_received,
    'contract_balance', round(greatest(coalesce(v_appointment.commercial_value, 0) - v_contract_settled, 0), 2),
    'pending_charge_count', v_pending_count,
    'financial_status', v_appointment.financial_status
  );
end;
$$;

create or replace function public.refresh_appointment_financial_status(p_appointment_id uuid)
returns public.financial_status
language plpgsql
volatile
set search_path = public
as $$
declare
  v_appointment public.appointments%rowtype;
  v_contract_settled numeric(12,2);
  v_pending_count integer;
  v_new_status public.financial_status;
begin
  select * into v_appointment
  from public.appointments
  where id = p_appointment_id
  for update;

  if not found then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_NOT_FOUND';
  end if;

  select
    coalesce(sum(contract_amount_settled) filter (
      where transaction_type = 'CHARGE' and status = 'APPROVED'
    ), 0)::numeric(12,2),
    count(*) filter (
      where transaction_type = 'CHARGE' and status = 'PENDING'
    )::integer
  into v_contract_settled, v_pending_count
  from public.payment_transactions
  where appointment_id = p_appointment_id;

  if v_contract_settled >= coalesce(v_appointment.commercial_value, 0)
     and coalesce(v_appointment.commercial_value, 0) > 0 then
    v_new_status := 'PAID';
  elsif v_contract_settled > 0 then
    v_new_status := 'PARTIALLY_PAID';
  elsif v_appointment.financial_status = 'UNPAID_AUTHORIZED' then
    v_new_status := 'UNPAID_AUTHORIZED';
  elsif v_pending_count > 0 then
    v_new_status := 'PENDING';
  elsif v_appointment.status = 'EXPIRED' then
    v_new_status := 'EXPIRED';
  else
    v_new_status := 'NOT_STARTED';
  end if;

  update public.appointments
  set financial_status = v_new_status,
      updated_at = now()
  where id = p_appointment_id;

  return v_new_status;
end;
$$;

create or replace function public.enqueue_appointment_confirmation_jobs(
  p_appointment_id uuid,
  p_reason text default 'PAYMENT_CONFIRMED'
)
returns void
language plpgsql
volatile
set search_path = public
as $$
declare
  v_version integer;
begin
  select version into v_version
  from public.appointments
  where id = p_appointment_id;

  if v_version is null then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_NOT_FOUND';
  end if;

  insert into public.integration_jobs (
    job_type,
    entity_type,
    entity_id,
    entity_version,
    payload_json,
    idempotency_key
  ) values
    (
      'GOOGLE_APPOINTMENT_SYNC',
      'APPOINTMENT',
      p_appointment_id,
      v_version,
      jsonb_build_object('reason', p_reason),
      'google-appointment-sync:' || p_appointment_id::text || ':' || v_version::text
    ),
    (
      'APPOINTMENT_CONFIRMED_MESSAGE',
      'APPOINTMENT',
      p_appointment_id,
      v_version,
      jsonb_build_object('reason', p_reason),
      'appointment-confirmed-message:' || p_appointment_id::text || ':' || v_version::text
    )
  on conflict (idempotency_key) do nothing;
end;
$$;

create or replace function public.confirm_appointment_internal(
  p_appointment_id uuid,
  p_reason text
)
returns jsonb
language plpgsql
volatile
set search_path = public
as $$
declare
  v_appointment public.appointments%rowtype;
  v_checkout_hold_id uuid;
  v_package_held boolean := false;
  v_new_version integer;
begin
  select * into v_appointment
  from public.appointments
  where id = p_appointment_id
  for update;

  if not found then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_NOT_FOUND';
  end if;

  if v_appointment.status = 'CONFIRMED' then
    return jsonb_build_object(
      'appointment_id', v_appointment.id,
      'status', v_appointment.status,
      'version', v_appointment.version,
      'already_confirmed', true
    );
  end if;

  if v_appointment.status <> 'AWAITING_PAYMENT' then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_NOT_CONFIRMABLE';
  end if;

  if v_appointment.hold_expires_at is null or v_appointment.hold_expires_at <= now() then
    raise exception using errcode = 'P0001', message = 'PAYMENT_HOLD_EXPIRED';
  end if;

  select ch.id into v_checkout_hold_id
  from public.checkout_holds ch
  where ch.promoted_appointment_id = p_appointment_id;

  if v_checkout_hold_id is not null then
    select exists (
      select 1
      from public.checkout_hour_package_reservations phr
      where phr.checkout_hold_id = v_checkout_hold_id
        and phr.status = 'HELD'
    ) into v_package_held;
  end if;

  update public.appointments
  set status = 'CONFIRMED',
      confirmed_at = coalesce(confirmed_at, now()),
      hold_expires_at = null,
      version = version + 1,
      updated_at = now()
  where id = p_appointment_id
  returning version into v_new_version;

  update public.resource_allocations
  set status = 'CONFIRMED',
      updated_at = now()
  where appointment_id = p_appointment_id
    and allocation_type = 'APPOINTMENT'
    and status in ('HELD','AWAITING_PAYMENT');

  if v_package_held then
    perform public.consume_hour_package_checkout(v_checkout_hold_id, p_appointment_id);
  end if;

  perform public.enqueue_appointment_confirmation_jobs(p_appointment_id, p_reason);

  insert into public.audit_logs (
    entity_type,
    entity_id,
    action,
    before_json,
    after_json,
    origin
  ) values (
    'APPOINTMENT',
    p_appointment_id,
    'APPOINTMENT_CONFIRMED',
    jsonb_build_object('status', v_appointment.status, 'version', v_appointment.version),
    jsonb_build_object('status', 'CONFIRMED', 'version', v_new_version, 'reason', p_reason),
    'SYSTEM'
  );

  return jsonb_build_object(
    'appointment_id', p_appointment_id,
    'status', 'CONFIRMED',
    'version', v_new_version,
    'package_consumed', v_package_held
  );
end;
$$;

create or replace function public.create_payment_intent(
  p_appointment_id uuid,
  p_payment_percentage numeric,
  p_method text,
  p_idempotency_key text
)
returns jsonb
language plpgsql
volatile
set search_path = public
as $$
declare
  v_appointment public.appointments%rowtype;
  v_existing public.payment_transactions%rowtype;
  v_summary jsonb;
  v_balance numeric(12,2);
  v_contract_amount numeric(12,2);
  v_discount_percent numeric(5,2);
  v_discount numeric(12,2);
  v_cash_amount numeric(12,2);
  v_transaction_id uuid;
begin
  if p_method not in ('PIX','CARD') then
    raise exception using errcode = 'P0001', message = 'PUBLIC_PAYMENT_METHOD_NOT_ALLOWED';
  end if;

  if p_payment_percentage not in (50, 100) then
    raise exception using errcode = 'P0001', message = 'INVALID_PAYMENT_PERCENTAGE';
  end if;

  if p_idempotency_key is null or btrim(p_idempotency_key) = '' then
    raise exception using errcode = 'P0001', message = 'IDEMPOTENCY_KEY_REQUIRED';
  end if;

  select * into v_existing
  from public.payment_transactions
  where idempotency_key = p_idempotency_key;

  if found then
    if v_existing.appointment_id <> p_appointment_id then
      raise exception using errcode = 'P0001', message = 'IDEMPOTENCY_KEY_CONFLICT';
    end if;

    return jsonb_build_object(
      'transaction_id', v_existing.id,
      'appointment_id', v_existing.appointment_id,
      'status', v_existing.status,
      'contract_amount_settled', v_existing.contract_amount_settled,
      'payment_discount_amount', v_existing.payment_discount_amount,
      'cash_amount', v_existing.cash_amount,
      'method', v_existing.method,
      'idempotent_replay', true
    );
  end if;

  perform public.expire_due_appointment_holds();

  select * into v_appointment
  from public.appointments
  where id = p_appointment_id
  for update;

  if not found then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_NOT_FOUND';
  end if;

  if v_appointment.status not in ('AWAITING_PAYMENT','CONFIRMED') then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_NOT_PAYABLE';
  end if;

  if v_appointment.status = 'AWAITING_PAYMENT'
     and (v_appointment.hold_expires_at is null or v_appointment.hold_expires_at <= now()) then
    raise exception using errcode = 'P0001', message = 'PAYMENT_HOLD_EXPIRED';
  end if;

  v_summary := public.get_appointment_financial_summary(p_appointment_id);
  v_balance := (v_summary->>'contract_balance')::numeric;

  if v_balance <= 0 then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_ALREADY_PAID';
  end if;

  v_contract_amount := case
    when p_payment_percentage = 100 then v_balance
    else round(v_balance * p_payment_percentage / 100, 2)
  end;

  select pix_discount_percent into v_discount_percent
  from public.operation_settings
  where id = 1;

  v_discount := case
    when p_method = 'PIX' then round(v_contract_amount * v_discount_percent / 100, 2)
    else 0
  end;

  v_cash_amount := round(v_contract_amount - v_discount, 2);

  insert into public.payment_transactions (
    appointment_id,
    transaction_type,
    method,
    provider,
    status,
    contract_amount_settled,
    payment_discount_amount,
    cash_amount,
    idempotency_key,
    requested_percentage
  ) values (
    p_appointment_id,
    'CHARGE',
    p_method,
    'MERCADO_PAGO',
    'PENDING',
    v_contract_amount,
    v_discount,
    v_cash_amount,
    p_idempotency_key,
    p_payment_percentage
  ) returning id into v_transaction_id;

  if v_appointment.financial_status not in ('PARTIALLY_PAID','PAID','UNPAID_AUTHORIZED') then
    update public.appointments
    set financial_status = 'PENDING',
        updated_at = now()
    where id = p_appointment_id;
  end if;

  return jsonb_build_object(
    'transaction_id', v_transaction_id,
    'appointment_id', p_appointment_id,
    'status', 'PENDING',
    'payment_percentage', p_payment_percentage,
    'contract_amount_settled', v_contract_amount,
    'payment_discount_amount', v_discount,
    'cash_amount', v_cash_amount,
    'method', p_method,
    'provider', 'MERCADO_PAGO',
    'idempotent_replay', false
  );
end;
$$;

create or replace function public.apply_provider_payment_status(
  p_transaction_id uuid,
  p_provider_payment_id text,
  p_normalized_status text,
  p_event_key text,
  p_payload_json jsonb default '{}'::jsonb,
  p_paid_at timestamptz default now()
)
returns jsonb
language plpgsql
volatile
set search_path = public
as $$
declare
  v_tx public.payment_transactions%rowtype;
  v_appointment public.appointments%rowtype;
  v_financial_status public.financial_status;
  v_event_exists boolean;
  v_late boolean := false;
begin
  if p_normalized_status not in ('PENDING','APPROVED','REJECTED','EXPIRED') then
    raise exception using errcode = 'P0001', message = 'INVALID_PROVIDER_PAYMENT_STATUS';
  end if;

  if p_event_key is null or btrim(p_event_key) = '' then
    raise exception using errcode = 'P0001', message = 'PROVIDER_EVENT_KEY_REQUIRED';
  end if;

  select exists (
    select 1
    from public.payment_provider_events
    where provider = 'MERCADO_PAGO'
      and event_key = p_event_key
  ) into v_event_exists;

  if v_event_exists then
    select * into v_tx
    from public.payment_transactions
    where id = p_transaction_id;

    if not found then
      raise exception using errcode = 'P0001', message = 'PAYMENT_TRANSACTION_NOT_FOUND';
    end if;

    return jsonb_build_object(
      'transaction_id', v_tx.id,
      'appointment_id', v_tx.appointment_id,
      'transaction_status', v_tx.status,
      'financial_status', (select financial_status from public.appointments where id = v_tx.appointment_id),
      'idempotent_replay', true
    );
  end if;

  perform public.expire_due_appointment_holds();

  select * into v_tx
  from public.payment_transactions
  where id = p_transaction_id
  for update;

  if not found then
    raise exception using errcode = 'P0001', message = 'PAYMENT_TRANSACTION_NOT_FOUND';
  end if;

  if v_tx.provider <> 'MERCADO_PAGO' then
    raise exception using errcode = 'P0001', message = 'PAYMENT_PROVIDER_MISMATCH';
  end if;

  if v_tx.provider_payment_id is not null
     and p_provider_payment_id is not null
     and v_tx.provider_payment_id <> p_provider_payment_id then
    raise exception using errcode = 'P0001', message = 'PROVIDER_PAYMENT_ID_MISMATCH';
  end if;

  select * into v_appointment
  from public.appointments
  where id = v_tx.appointment_id
  for update;

  if not found then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_NOT_FOUND';
  end if;

  insert into public.payment_provider_events (
    provider,
    event_key,
    transaction_id,
    provider_payment_id,
    normalized_status,
    payload_json
  ) values (
    'MERCADO_PAGO',
    p_event_key,
    v_tx.id,
    p_provider_payment_id,
    p_normalized_status,
    coalesce(p_payload_json, '{}'::jsonb)
  );

  if v_tx.status = 'APPROVED' then
    return jsonb_build_object(
      'transaction_id', v_tx.id,
      'appointment_id', v_tx.appointment_id,
      'transaction_status', v_tx.status,
      'financial_status', v_appointment.financial_status,
      'appointment_status', v_appointment.status,
      'idempotent_replay', true
    );
  end if;

  update public.payment_transactions
  set provider_payment_id = coalesce(provider_payment_id, p_provider_payment_id),
      status = p_normalized_status,
      provider_payload_json = coalesce(p_payload_json, '{}'::jsonb),
      paid_at = case when p_normalized_status = 'APPROVED' then coalesce(p_paid_at, now()) else paid_at end,
      updated_at = now()
  where id = v_tx.id;

  if p_normalized_status = 'APPROVED' then
    v_financial_status := public.refresh_appointment_financial_status(v_appointment.id);

    select * into v_appointment
    from public.appointments
    where id = v_appointment.id
    for update;

    if v_appointment.status = 'EXPIRED'
       or (v_appointment.status = 'AWAITING_PAYMENT'
           and (v_appointment.hold_expires_at is null or v_appointment.hold_expires_at <= now())) then
      v_late := true;

      insert into public.payment_incidents (
        appointment_id,
        payment_transaction_id,
        incident_type,
        details_json
      ) values (
        v_appointment.id,
        v_tx.id,
        'PAYMENT_AFTER_EXPIRATION',
        jsonb_build_object(
          'provider_payment_id', p_provider_payment_id,
          'cash_amount', v_tx.cash_amount,
          'contract_amount_settled', v_tx.contract_amount_settled,
          'appointment_status', v_appointment.status
        )
      ) on conflict (payment_transaction_id, incident_type) do nothing;

      insert into public.audit_logs (
        entity_type,
        entity_id,
        action,
        after_json,
        origin
      ) values (
        'APPOINTMENT',
        v_appointment.id,
        'PAYMENT_AFTER_EXPIRATION',
        jsonb_build_object('payment_transaction_id', v_tx.id),
        'MERCADO_PAGO'
      );
    elsif v_appointment.status = 'AWAITING_PAYMENT' then
      perform public.confirm_appointment_internal(v_appointment.id, 'PAYMENT_CONFIRMED');
      v_financial_status := public.refresh_appointment_financial_status(v_appointment.id);
    end if;
  elsif p_normalized_status = 'REJECTED' then
    if not exists (
      select 1 from public.payment_transactions pt
      where pt.appointment_id = v_appointment.id
        and pt.transaction_type = 'CHARGE'
        and pt.status = 'APPROVED'
    ) then
      update public.appointments
      set financial_status = 'REJECTED',
          updated_at = now()
      where id = v_appointment.id
        and status = 'AWAITING_PAYMENT';
    end if;
  elsif p_normalized_status = 'EXPIRED' then
    perform public.refresh_appointment_financial_status(v_appointment.id);
  end if;

  select * into v_appointment
  from public.appointments
  where id = v_tx.appointment_id;

  return jsonb_build_object(
    'transaction_id', v_tx.id,
    'appointment_id', v_tx.appointment_id,
    'transaction_status', p_normalized_status,
    'financial_status', v_appointment.financial_status,
    'appointment_status', v_appointment.status,
    'payment_after_expiration', v_late,
    'idempotent_replay', false
  );
end;
$$;

create or replace function public.register_manual_payment(
  p_appointment_id uuid,
  p_method text,
  p_contract_amount_settled numeric,
  p_notes text,
  p_created_by_admin_id uuid,
  p_confirm_if_pending boolean default false
)
returns jsonb
language plpgsql
volatile
set search_path = public
as $$
declare
  v_appointment public.appointments%rowtype;
  v_summary jsonb;
  v_balance numeric(12,2);
  v_discount_percent numeric(5,2);
  v_discount numeric(12,2) := 0;
  v_cash numeric(12,2);
  v_transaction_id uuid;
  v_financial_status public.financial_status;
begin
  if p_method not in ('PIX','CARD','CASH','TRANSFER','CREDIT','COURTESY','OTHER') then
    raise exception using errcode = 'P0001', message = 'INVALID_MANUAL_PAYMENT_METHOD';
  end if;

  if p_contract_amount_settled <= 0 then
    raise exception using errcode = 'P0001', message = 'INVALID_MANUAL_PAYMENT_AMOUNT';
  end if;

  select * into v_appointment
  from public.appointments
  where id = p_appointment_id
  for update;

  if not found then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_NOT_FOUND';
  end if;

  if v_appointment.status in ('CANCELLED','EXPIRED') then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_NOT_PAYABLE';
  end if;

  v_summary := public.get_appointment_financial_summary(p_appointment_id);
  v_balance := (v_summary->>'contract_balance')::numeric;

  if p_contract_amount_settled > v_balance then
    raise exception using errcode = 'P0001', message = 'PAYMENT_EXCEEDS_BALANCE';
  end if;

  select pix_discount_percent into v_discount_percent
  from public.operation_settings
  where id = 1;

  if p_method = 'PIX' then
    v_discount := round(p_contract_amount_settled * v_discount_percent / 100, 2);
    v_cash := round(p_contract_amount_settled - v_discount, 2);
  elsif p_method = 'COURTESY' then
    v_cash := 0;
  else
    v_cash := round(p_contract_amount_settled, 2);
  end if;

  insert into public.payment_transactions (
    appointment_id,
    transaction_type,
    method,
    provider,
    status,
    contract_amount_settled,
    payment_discount_amount,
    cash_amount,
    paid_at,
    created_by_admin_id,
    notes
  ) values (
    p_appointment_id,
    'CHARGE',
    p_method,
    'MANUAL',
    'APPROVED',
    round(p_contract_amount_settled, 2),
    v_discount,
    v_cash,
    now(),
    p_created_by_admin_id,
    p_notes
  ) returning id into v_transaction_id;

  v_financial_status := public.refresh_appointment_financial_status(p_appointment_id);

  if p_confirm_if_pending and v_appointment.status = 'AWAITING_PAYMENT' then
    perform public.confirm_appointment_internal(p_appointment_id, 'MANUAL_PAYMENT_CONFIRMED');
    v_financial_status := public.refresh_appointment_financial_status(p_appointment_id);
  end if;

  insert into public.audit_logs (
    admin_user_id,
    entity_type,
    entity_id,
    action,
    after_json,
    origin
  ) values (
    p_created_by_admin_id,
    'APPOINTMENT',
    p_appointment_id,
    'MANUAL_PAYMENT_REGISTERED',
    jsonb_build_object(
      'transaction_id', v_transaction_id,
      'method', p_method,
      'contract_amount_settled', p_contract_amount_settled,
      'cash_amount', v_cash,
      'confirmed', p_confirm_if_pending
    ),
    'ADMIN'
  );

  return jsonb_build_object(
    'transaction_id', v_transaction_id,
    'appointment_id', p_appointment_id,
    'contract_amount_settled', round(p_contract_amount_settled, 2),
    'payment_discount_amount', v_discount,
    'cash_amount', v_cash,
    'financial_status', v_financial_status,
    'appointment_status', (select status from public.appointments where id = p_appointment_id)
  );
end;
$$;

create or replace function public.confirm_without_payment(
  p_appointment_id uuid,
  p_reason text,
  p_admin_user_id uuid
)
returns jsonb
language plpgsql
volatile
set search_path = public
as $$
declare
  v_appointment public.appointments%rowtype;
begin
  if p_reason is null or btrim(p_reason) = '' then
    raise exception using errcode = 'P0001', message = 'CONFIRM_WITHOUT_PAYMENT_REASON_REQUIRED';
  end if;

  perform public.expire_due_appointment_holds();

  select * into v_appointment
  from public.appointments
  where id = p_appointment_id
  for update;

  if not found then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_NOT_FOUND';
  end if;

  if v_appointment.status <> 'AWAITING_PAYMENT' then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_NOT_CONFIRMABLE';
  end if;

  if v_appointment.hold_expires_at is null or v_appointment.hold_expires_at <= now() then
    raise exception using errcode = 'P0001', message = 'PAYMENT_HOLD_EXPIRED';
  end if;

  perform public.confirm_appointment_internal(p_appointment_id, 'UNPAID_AUTHORIZED');

  update public.appointments
  set financial_status = 'UNPAID_AUTHORIZED',
      updated_at = now()
  where id = p_appointment_id;

  insert into public.audit_logs (
    admin_user_id,
    entity_type,
    entity_id,
    action,
    before_json,
    after_json,
    origin
  ) values (
    p_admin_user_id,
    'APPOINTMENT',
    p_appointment_id,
    'CONFIRMED_WITHOUT_PAYMENT',
    jsonb_build_object('status', v_appointment.status, 'financial_status', v_appointment.financial_status),
    jsonb_build_object('status', 'CONFIRMED', 'financial_status', 'UNPAID_AUTHORIZED', 'reason', p_reason),
    'ADMIN'
  );

  return jsonb_build_object(
    'appointment_id', p_appointment_id,
    'status', 'CONFIRMED',
    'financial_status', 'UNPAID_AUTHORIZED'
  );
end;
$$;

comment on function public.create_payment_intent(uuid,numeric,text,text) is
  'Creates an idempotent Mercado Pago payment intent; PIX discount applies only to the contract portion settled by this transaction.';

comment on function public.apply_provider_payment_status(uuid,text,text,text,jsonb,timestamptz) is
  'Applies a normalized provider event idempotently; late approval opens PAYMENT_AFTER_EXPIRATION and never reoccupies a released slot.';
