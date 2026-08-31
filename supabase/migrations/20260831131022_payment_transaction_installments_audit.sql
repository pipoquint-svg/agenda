alter table public.payment_transactions
  add column if not exists installments smallint;

alter table public.payment_transactions
  drop constraint if exists payment_transactions_installments_ck;

alter table public.payment_transactions
  add constraint payment_transactions_installments_ck
  check (installments is null or installments between 1 and 12);

comment on column public.payment_transactions.installments is
  'Informational installment count confirmed by the payment provider. Audit/reconciliation only; must not participate in contract settlement, revenue, month close, NFS-e, or financial reports.';

create or replace function public.apply_provider_payment_status(
  p_transaction_id uuid,
  p_provider_payment_id text,
  p_normalized_status text,
  p_event_key text,
  p_payload_json jsonb default '{}'::jsonb,
  p_paid_at timestamp with time zone default now()
)
returns jsonb
language plpgsql
set search_path to 'public'
as $function$
declare
  v_tx public.payment_transactions%rowtype;
  v_appointment public.appointments%rowtype;
  v_financial_status public.financial_status;
  v_event_exists boolean;
  v_late boolean := false;
  v_provider_installments smallint := null;
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

  if v_tx.method = 'CARD'
     and coalesce(p_payload_json->>'payment_type_id','') = 'credit_card'
     and nullif(p_payload_json->>'installments','') is not null then
    begin
      v_provider_installments := (p_payload_json->>'installments')::smallint;
    exception when invalid_text_representation or numeric_value_out_of_range then
      raise exception using errcode='P0001',message='PROVIDER_INSTALLMENTS_INVALID';
    end;
    if v_provider_installments < 1 or v_provider_installments > 12 then
      raise exception using errcode='P0001',message='PROVIDER_INSTALLMENTS_INVALID';
    end if;
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
    if v_tx.installments is null and v_provider_installments is not null then
      update public.payment_transactions
      set installments = v_provider_installments,
          updated_at = now()
      where id = v_tx.id;
    end if;

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
      installments = coalesce(installments, v_provider_installments),
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
$function$;