-- A provider-accepted payment that does not match the internal intent must never
-- confirm a reservation, but it also must not be discarded as a normal rejection.
-- Keep the internal charge PENDING, link the observed provider payment only when
-- that identifier is not already owned elsewhere, and open an incident for review.

alter table public.payment_incidents
  drop constraint if exists payment_incidents_incident_type_check;

alter table public.payment_incidents
  add constraint payment_incidents_incident_type_check
  check (incident_type in ('PAYMENT_AFTER_EXPIRATION','PROVIDER_INTENT_MISMATCH'));

create or replace function public.service_quarantine_provider_payment_mismatch(
  p_transaction_id uuid,
  p_provider_payment_id text,
  p_reason text,
  p_payload_json jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_tx public.payment_transactions%rowtype;
  v_incident_id uuid;
  v_observed_provider_id text;
  v_linked_provider_id text;
  v_provider_id_owned_elsewhere boolean := false;
begin
  if p_reason not in (
    'MERCADO_PAGO_PAYMENT_ID_MISSING',
    'MERCADO_PAGO_PAYMENT_ID_MISMATCH',
    'MERCADO_PAGO_EXTERNAL_REFERENCE_MISMATCH',
    'MERCADO_PAGO_PAYMENT_AMOUNT_MISMATCH',
    'MERCADO_PAGO_PAYMENT_METHOD_MISMATCH',
    'MERCADO_PAGO_PAYMENT_AMOUNT_INVALID'
  ) then
    raise exception using errcode='P0001', message='PROVIDER_INTENT_MISMATCH_REASON_INVALID';
  end if;

  v_observed_provider_id := nullif(btrim(coalesce(p_provider_payment_id,'')),'');

  select * into v_tx
  from public.payment_transactions
  where id = p_transaction_id
  for update;

  if not found then
    raise exception using errcode='P0001', message='PAYMENT_TRANSACTION_NOT_FOUND';
  end if;
  if v_tx.provider <> 'MERCADO_PAGO' or v_tx.transaction_type <> 'CHARGE' then
    raise exception using errcode='P0001', message='PAYMENT_TRANSACTION_NOT_MERCADO_PAGO_CHARGE';
  end if;

  if v_observed_provider_id is not null then
    select exists(
      select 1
      from public.payment_transactions pt
      where pt.provider='MERCADO_PAGO'
        and pt.transaction_type='CHARGE'
        and pt.provider_payment_id=v_observed_provider_id
        and pt.id<>v_tx.id
    ) into v_provider_id_owned_elsewhere;
  end if;

  v_linked_provider_id := v_tx.provider_payment_id;
  if v_linked_provider_id is null and v_observed_provider_id is not null and not v_provider_id_owned_elsewhere then
    v_linked_provider_id := v_observed_provider_id;
  end if;

  update public.payment_transactions
  set provider_payment_id = v_linked_provider_id,
      provider_payload_json = coalesce(p_payload_json, '{}'::jsonb),
      updated_at = now()
  where id = v_tx.id;

  insert into public.payment_incidents(
    appointment_id,
    payment_transaction_id,
    incident_type,
    status,
    details_json
  ) values (
    v_tx.appointment_id,
    v_tx.id,
    'PROVIDER_INTENT_MISMATCH',
    'OPEN',
    jsonb_build_object(
      'provider','MERCADO_PAGO',
      'observed_provider_payment_id',v_observed_provider_id,
      'linked_provider_payment_id',v_linked_provider_id,
      'provider_payment_id_owned_elsewhere',v_provider_id_owned_elsewhere,
      'reason',p_reason,
      'provider_snapshot',coalesce(p_payload_json,'{}'::jsonb)
    )
  )
  on conflict(payment_transaction_id,incident_type)
  do update set
    status='OPEN',
    details_json=excluded.details_json,
    detected_at=now(),
    resolved_at=null,
    resolved_by_admin_id=null,
    resolution_notes=null
  returning id into v_incident_id;

  insert into public.audit_logs(
    entity_type,entity_id,action,before_json,after_json,origin
  ) values (
    'PAYMENT_TRANSACTION',
    v_tx.id,
    'MERCADO_PAGO_PAYMENT_QUARANTINED',
    jsonb_build_object(
      'status',v_tx.status,
      'provider_payment_id',v_tx.provider_payment_id
    ),
    jsonb_build_object(
      'status',v_tx.status,
      'provider_payment_id',v_linked_provider_id,
      'observed_provider_payment_id',v_observed_provider_id,
      'provider_payment_id_owned_elsewhere',v_provider_id_owned_elsewhere,
      'incident_id',v_incident_id,
      'reason',p_reason
    ),
    'SYSTEM'
  );

  return jsonb_build_object(
    'transaction_id',v_tx.id,
    'appointment_id',v_tx.appointment_id,
    'transaction_status',v_tx.status,
    'provider_payment_id',v_linked_provider_id,
    'observed_provider_payment_id',v_observed_provider_id,
    'provider_payment_id_owned_elsewhere',v_provider_id_owned_elsewhere,
    'incident_id',v_incident_id,
    'incident_status','OPEN',
    'reason',p_reason
  );
end;
$$;

revoke all on function public.service_quarantine_provider_payment_mismatch(uuid,text,text,jsonb)
  from public, anon, authenticated;
grant execute on function public.service_quarantine_provider_payment_mismatch(uuid,text,text,jsonb)
  to service_role;
