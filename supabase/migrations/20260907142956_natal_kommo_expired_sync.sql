create or replace function public.enqueue_natal_2026_kommo_sync_trigger()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if not (new.service_id = any(array[
    '111e9ae4-f626-4a71-a209-e20166310ee5'::uuid,
    '5268a4a1-2cfb-4c23-a89a-3cf1853fb637'::uuid,
    'ca578a83-2188-4be7-93c8-532c77801b0c'::uuid,
    '0afb550a-3cd0-46f5-9482-b1e219bf9d2e'::uuid
  ])) then
    return new;
  end if;

  if tg_op = 'INSERT' then
    if new.status = 'AWAITING_PAYMENT' and new.financial_status = 'PENDING' then
      perform public.enqueue_kommo_appointment_sync(new.id,'CREATED');
    elsif new.status = 'CONFIRMED' and new.financial_status = 'PAID' then
      perform public.enqueue_kommo_appointment_sync(new.id,'STATUS_CHANGED');
    elsif new.status = 'EXPIRED' then
      perform public.enqueue_kommo_appointment_sync(new.id,'STATUS_CHANGED');
    end if;
  elsif tg_op = 'UPDATE' then
    if old.status is distinct from new.status or old.financial_status is distinct from new.financial_status then
      if new.status = 'CONFIRMED' and new.financial_status = 'PAID' then
        perform public.enqueue_kommo_appointment_sync(new.id,'STATUS_CHANGED');
      elsif new.status = 'EXPIRED' then
        perform public.enqueue_kommo_appointment_sync(new.id,'STATUS_CHANGED');
      end if;
    end if;
  end if;

  return new;
end;
$function$;
