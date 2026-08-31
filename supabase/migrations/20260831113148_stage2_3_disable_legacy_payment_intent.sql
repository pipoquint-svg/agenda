create or replace function public.create_payment_intent(
  p_appointment_id uuid,
  p_payment_percentage numeric,
  p_method text,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  raise exception using
    errcode='P0001',
    message='Rotina legada create_payment_intent desativada. Use create_payment_intent_v2.';
end;
$function$;