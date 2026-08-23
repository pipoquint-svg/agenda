-- Kommo card projection for BlackSheep reservations.
-- Agenda remains authoritative. Kommo mirrors operational/card data only.
-- Shared Kommo lead card semantics:
--   Data            <- appointment.start_at (America/Sao_Paulo in Edge adapter)
--   Venda           <- appointment.commercial_value (Kommo built-in lead price)
--   Saldo           <- get_appointment_financial_summary().contract_balance
--   Extras locação  <- appointment_extras snapshots

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
  v_financial jsonb;
  v_extras jsonb;
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

  v_financial := public.get_appointment_financial_summary(v_appointment.id);

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', ae.id,
        'extra_id', ae.extra_id,
        'name', ae.name_snapshot,
        'quantity', ae.quantity,
        'unit_price', ae.unit_price_snapshot,
        'total_price', ae.total_price
      ) order by ae.created_at, ae.id
    ),
    '[]'::jsonb
  ) into v_extras
  from public.appointment_extras ae
  where ae.appointment_id = v_appointment.id;

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
    'financial', v_financial,
    'extras', v_extras,
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

-- Appointment version is intentionally not the sole idempotency dimension. Financial
-- coverage and extras can change while the appointment version remains unchanged.
-- Fingerprinting the canonical projection lets those same-version changes enqueue safely.
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
  v_projection jsonb;
  v_fingerprint text;
begin
  if v_event not in ('CREATED','UPDATED','RESCHEDULED','STATUS_CHANGED','FINANCIAL_CHANGED','EXTRAS_CHANGED') then
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

  v_projection := public.get_kommo_appointment_desired_state(v_appointment.id);
  if coalesce((v_projection->>'eligible')::boolean, false) is not true then
    return null;
  end if;

  v_fingerprint := md5(v_projection::text || ':' || v_event);

  insert into public.integration_jobs (
    job_type, entity_type, entity_id, entity_version,
    payload_json, status, run_after, idempotency_key
  ) values (
    'KOMMO_APPOINTMENT_SYNC',
    'APPOINTMENT',
    v_appointment.id,
    v_appointment.version,
    jsonb_build_object('event_kind', v_event, 'projection_fingerprint', v_fingerprint),
    'PENDING',
    now(),
    'kommo-appointment:' || v_appointment.id::text || ':v' || v_appointment.version::text || ':' || lower(v_event) || ':' || v_fingerprint
  )
  on conflict (idempotency_key) do update
    set updated_at = public.integration_jobs.updated_at
  returning id into v_job_id;

  return v_job_id;
end;
$$;

revoke all on function public.enqueue_kommo_appointment_sync(uuid,text) from public, anon, authenticated;
grant execute on function public.enqueue_kommo_appointment_sync(uuid,text) to service_role;

-- Payment rows can change Saldo without changing appointment.version. Mirror every
-- authoritative contract-payment mutation through the same outbox function.
create or replace function public.trg_enqueue_kommo_payment_sync()
returns trigger
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_appointment_id uuid;
begin
  v_appointment_id := case when tg_op = 'DELETE' then old.appointment_id else new.appointment_id end;
  if v_appointment_id is not null then
    perform public.enqueue_kommo_appointment_sync(v_appointment_id, 'FINANCIAL_CHANGED');
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

revoke all on function public.trg_enqueue_kommo_payment_sync() from public, anon, authenticated, service_role;

drop trigger if exists payment_transactions_enqueue_kommo_sync on public.payment_transactions;
create trigger payment_transactions_enqueue_kommo_sync
after insert or delete or update of status, contract_amount_settled, payment_discount_amount, cash_amount, transaction_type, payment_purpose, parent_transaction_id
on public.payment_transactions
for each row execute function public.trg_enqueue_kommo_payment_sync();

-- Extras are appointment-owned snapshots. Any add/edit/remove must update the existing
-- lead card rather than create a new lead.
create or replace function public.trg_enqueue_kommo_extra_sync()
returns trigger
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_appointment_id uuid;
begin
  v_appointment_id := case when tg_op = 'DELETE' then old.appointment_id else new.appointment_id end;
  if v_appointment_id is not null then
    perform public.enqueue_kommo_appointment_sync(v_appointment_id, 'EXTRAS_CHANGED');
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

revoke all on function public.trg_enqueue_kommo_extra_sync() from public, anon, authenticated, service_role;

drop trigger if exists appointment_extras_enqueue_kommo_sync on public.appointment_extras;
create trigger appointment_extras_enqueue_kommo_sync
after insert or delete or update of extra_id, name_snapshot, unit_price_snapshot, quantity, total_price
on public.appointment_extras
for each row execute function public.trg_enqueue_kommo_extra_sync();

comment on function public.get_kommo_appointment_desired_state(uuid) is
  'Canonical Agenda-to-Kommo projection including reservation date, authoritative finance balance and contracted extras. Agenda remains authoritative.';
comment on function public.enqueue_kommo_appointment_sync(uuid,text) is
  'Idempotent Kommo outbox enqueue keyed by canonical projection fingerprint so same-version finance/extra changes are mirrored safely.';
comment on function public.trg_enqueue_kommo_payment_sync() is
  'Internal trigger only: refresh Kommo Saldo after payment/refund mutations.';
comment on function public.trg_enqueue_kommo_extra_sync() is
  'Internal trigger only: refresh Kommo Extras locação after appointment-extra mutations.';
