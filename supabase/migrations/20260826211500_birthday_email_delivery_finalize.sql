-- Issue #217 / V1.5 #257 — atomic post-provider finalization for birthday email delivery.
-- The provider call remains outside Postgres. Replays use the persisted provider idempotency key;
-- this RPC atomically records SENT evidence and its audit trail after a successful provider response.

create or replace function public.finalize_birthday_email_delivery(
  p_delivery_log_id uuid,
  p_cycle_id uuid,
  p_provider_message_id text,
  p_recipient_masked text
)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_log public.notification_delivery_logs%rowtype;
  v_cycle_id uuid;
begin
  if p_delivery_log_id is null or p_cycle_id is null then
    raise exception using errcode = 'P0001', message = 'BIRTHDAY_DELIVERY_FINALIZE_ID_REQUIRED';
  end if;

  select * into v_log
  from public.notification_delivery_logs
  where id = p_delivery_log_id
    and event_key = 'BIRTHDAY'
    and channel = 'EMAIL'
    and audience = 'CUSTOMER'
  for update;

  if not found then
    raise exception using errcode = 'P0001', message = 'BIRTHDAY_DELIVERY_LOG_NOT_FOUND';
  end if;

  if v_log.status = 'SENT' then
    return true;
  end if;

  if v_log.status <> 'PENDING' then
    raise exception using errcode = 'P0001', message = 'BIRTHDAY_DELIVERY_LOG_NOT_PENDING';
  end if;

  begin
    v_cycle_id := nullif(v_log.payload_snapshot->>'birthday_cycle_id', '')::uuid;
  exception when invalid_text_representation then
    raise exception using errcode = 'P0001', message = 'BIRTHDAY_DELIVERY_CYCLE_INVALID';
  end;

  if v_cycle_id is distinct from p_cycle_id then
    raise exception using errcode = 'P0001', message = 'BIRTHDAY_DELIVERY_CYCLE_MISMATCH';
  end if;

  if not exists (
    select 1 from public.birthday_automation_cycles c
    where c.id = p_cycle_id and c.customer_id = v_log.customer_id
  ) then
    raise exception using errcode = 'P0001', message = 'BIRTHDAY_DELIVERY_CYCLE_NOT_FOUND';
  end if;

  update public.notification_delivery_logs
  set status = 'SENT',
      attempt_count = attempt_count + 1,
      last_error_code = null,
      provider_message_id = nullif(btrim(p_provider_message_id), ''),
      updated_at = now()
  where id = p_delivery_log_id;

  update public.birthday_automation_cycles
  set message_status = 'SENT', updated_at = now()
  where id = p_cycle_id;

  insert into public.audit_logs(entity_type, entity_id, action, before_json, after_json, origin)
  values (
    'BIRTHDAY_AUTOMATION',
    p_cycle_id,
    'BIRTHDAY_MESSAGE_SENT',
    null,
    jsonb_build_object(
      'delivery_log_id', p_delivery_log_id,
      'operation_scope', v_log.payload_snapshot->>'operation_scope',
      'recipient_masked', nullif(btrim(p_recipient_masked), '')
    ),
    'SYSTEM'
  );

  return true;
end;
$$;

revoke all on function public.finalize_birthday_email_delivery(uuid,uuid,text,text) from public, anon, authenticated;
grant execute on function public.finalize_birthday_email_delivery(uuid,uuid,text,text) to service_role;

comment on function public.finalize_birthday_email_delivery(uuid,uuid,text,text) is
  'Atomically finalizes a successful BIRTHDAY email delivery and audit evidence. Provider idempotency remains external and keyed by notification_delivery_logs.idempotency_key.';
