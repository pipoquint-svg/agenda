-- Align the database-side InfinitePay hosted-checkout URL validation with the
-- provider hosts observed and accepted by the Edge adapter. Keep this as an exact
-- two-host allowlist; no wildcard/subdomain matching is permitted.

create or replace function public.service_record_infinitepay_checkout_link_result(
  p_transaction_id uuid,
  p_outcome text,
  p_checkout_url text default null,
  p_payload_json jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  v_tx public.payment_transactions%rowtype;
  v_url text;
begin
  if p_outcome not in ('READY','REJECTED') then
    raise exception using errcode='P0001',message='INFINITEPAY_LINK_OUTCOME_INVALID';
  end if;

  select * into v_tx
  from public.payment_transactions
  where id=p_transaction_id
  for update;
  if not found or v_tx.provider<>'INFINITEPAY' or v_tx.transaction_type<>'CHARGE' then
    raise exception using errcode='P0001',message='INFINITEPAY_PAYMENT_TRANSACTION_NOT_FOUND';
  end if;
  if v_tx.status<>'PENDING' then
    raise exception using errcode='P0001',message='INFINITEPAY_PAYMENT_TRANSACTION_NOT_PENDING';
  end if;
  if coalesce(v_tx.provider_payload_json->>'link_state','')<>'CREATE_STARTED' then
    raise exception using errcode='P0001',message='INFINITEPAY_LINK_NOT_CLAIMED';
  end if;

  if p_outcome='READY' then
    v_url:=nullif(btrim(coalesce(p_checkout_url,'')),'');
    if v_url is null or (
      v_url !~ '^https://checkout[.]infinitepay[.]com[.]br(?:/|$)'
      and v_url !~ '^https://checkout[.]infinitepay[.]io(?:/|$)'
    ) then
      raise exception using errcode='P0001',message='INFINITEPAY_CHECKOUT_URL_INVALID';
    end if;

    update public.payment_transactions
    set provider_payload_json=coalesce(provider_payload_json,'{}'::jsonb) || jsonb_build_object(
          'link_state','READY',
          'checkout_url',v_url,
          'link_ready_at',now(),
          'link_response',coalesce(p_payload_json,'{}'::jsonb)
        ),
        updated_at=now()
    where id=v_tx.id;

    return jsonb_build_object(
      'transaction_id',v_tx.id,
      'status','PENDING',
      'link_state','READY',
      'checkout_url',v_url
    );
  end if;

  update public.payment_transactions
  set status='REJECTED',
      provider_payload_json=coalesce(provider_payload_json,'{}'::jsonb) || jsonb_build_object(
        'link_state','REJECTED',
        'link_rejected_at',now(),
        'link_response',coalesce(p_payload_json,'{}'::jsonb)
      ),
      updated_at=now()
  where id=v_tx.id;

  if not exists(
    select 1 from public.payment_transactions pt
    where pt.appointment_id=v_tx.appointment_id
      and pt.transaction_type='CHARGE'
      and pt.status='APPROVED'
  ) then
    update public.appointments
    set financial_status='REJECTED',updated_at=now()
    where id=v_tx.appointment_id and status='AWAITING_PAYMENT';
  else
    perform public.refresh_appointment_financial_status(v_tx.appointment_id);
  end if;

  insert into public.audit_logs(entity_type,entity_id,action,after_json,origin)
  values(
    'APPOINTMENT',v_tx.appointment_id,'PAYMENT_INTENT_PROVIDER_REJECTED',
    jsonb_build_object('payment_transaction_id',v_tx.id,'provider','INFINITEPAY'),
    'INFINITEPAY'
  );

  return jsonb_build_object(
    'transaction_id',v_tx.id,
    'status','REJECTED',
    'link_state','REJECTED',
    'checkout_url',null
  );
end;
$$;

alter function public.service_record_infinitepay_checkout_link_result(uuid,text,text,jsonb) owner to postgres;
revoke all on function public.service_record_infinitepay_checkout_link_result(uuid,text,text,jsonb)
  from public, anon, authenticated;
grant execute on function public.service_record_infinitepay_checkout_link_result(uuid,text,text,jsonb)
  to service_role;
