-- Safe public summary for tokenized appointment actions.
-- The summary deliberately excludes customer/contact/payment details and is only
-- callable by the server-side service role after the action token was resolved.

create or replace function public.service_appointment_action_public_summary(
  p_token_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_token public.appointment_access_tokens%rowtype;
  v_appointment public.appointments%rowtype;
  v_service public.services%rowtype;
  v_resource_name text;
  v_status_label text;
begin
  select * into v_token
  from public.appointment_access_tokens
  where id = p_token_id;

  if not found
     or v_token.scope not in ('CANCEL','RESCHEDULE')
     or v_token.revoked_at is not null
     or v_token.consumed_at is not null
     or v_token.expires_at is null
     or v_token.expires_at <= now() then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_TOKEN_INVALID';
  end if;

  select * into v_appointment
  from public.appointments
  where id = v_token.appointment_id
    and deleted_at is null;

  if not found
     or v_appointment.start_at <= now()
     or v_token.expires_at <> v_appointment.start_at then
    raise exception using errcode = 'P0001', message = 'APPOINTMENT_TOKEN_INVALID';
  end if;

  select * into v_service
  from public.services
  where id = v_appointment.service_id;

  if not found then
    raise exception using errcode = 'P0001', message = 'SERVICE_NOT_FOUND';
  end if;

  v_resource_name := case
    when v_service.operation_scope = 'BLACKSHEEP' then 'BlackSheep Estúdio Criativo'
    else null
  end;

  v_status_label := case v_appointment.status::text
    when 'CONFIRMED' then 'Confirmada'
    when 'AWAITING_PAYMENT' then 'Aguardando pagamento'
    when 'CANCELLED' then 'Cancelada'
    when 'COMPLETED' then 'Concluída'
    when 'NO_SHOW' then 'Não compareceu'
    else 'Em andamento'
  end;

  return jsonb_strip_nulls(jsonb_build_object(
    'public_code', v_appointment.public_code,
    'service_name', coalesce(v_appointment.service_name_snapshot, v_service.name),
    'resource_name', v_resource_name,
    'operation_scope', v_service.operation_scope,
    'start_at', v_appointment.start_at,
    'end_at', v_appointment.end_at,
    'status_label', v_status_label
  ));
end;
$$;

revoke all on function public.service_appointment_action_public_summary(uuid)
from public, anon, authenticated;
grant execute on function public.service_appointment_action_public_summary(uuid) to service_role;

comment on function public.service_appointment_action_public_summary(uuid) is
  'Returns the minimal non-PII appointment summary needed by the tokenized cancel/reschedule UI. Requires a currently valid CANCEL or RESCHEDULE token id and exposes no customer/contact/payment data.';
