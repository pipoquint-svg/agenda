-- A reservation confirmed manually with payment later ("pagamento posterior autorizado")
-- became CONFIRMED without queuing the confirmation jobs, so the customer got no WhatsApp
-- or e-mail confirmation and the reservation did not reach Google Calendar (reservation
-- 9A62C8B1C8D1, 2026-10-22). It now queues the same jobs as a confirmation by payment.
-- Body otherwise identical to production.

create or replace function public.service_admin_confirm_appointment_unpaid(p_appointment_id uuid, p_reason text, p_admin_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_appointment public.appointments%rowtype;
  v_reason text:=nullif(btrim(coalesce(p_reason,'')),'');
  v_allocation_count integer;
  v_financial_status public.financial_status;
begin
  if not public.service_admin_has_permission(p_admin_id,'AGENDA_MANAGE') then
    raise exception 'ADMIN_PERMISSION_DENIED';
  end if;
  if v_reason is null then raise exception 'CONFIRM_WITHOUT_PAYMENT_REASON_REQUIRED'; end if;
  if length(v_reason)>500 then raise exception 'CONFIRM_WITHOUT_PAYMENT_REASON_TOO_LONG'; end if;

  select * into v_appointment
  from public.appointments
  where id=p_appointment_id
  for update;

  if not found then raise exception 'APPOINTMENT_NOT_FOUND'; end if;

  if v_appointment.status='CONFIRMED' then
    return jsonb_build_object(
      'appointment_id',v_appointment.id,
      'status',v_appointment.status,
      'financial_status',v_appointment.financial_status,
      'already_confirmed',true
    );
  end if;

  if v_appointment.status not in ('EXPIRED','AWAITING_PAYMENT') then
    raise exception 'APPOINTMENT_NOT_CONFIRMABLE';
  end if;

  if v_appointment.status='EXPIRED' and (
    coalesce(v_appointment.coupon_discount,0)>0
    or exists (select 1 from public.appointment_discounts ad where ad.appointment_id=v_appointment.id)
  ) then
    raise exception 'EXPIRED_COUPON_REACTIVATION_REQUIRES_DECISION';
  end if;

  if exists (
    select 1 from public.appointment_package_usage apu
    where apu.appointment_id=v_appointment.id
  ) or exists (
    select 1
    from public.checkout_holds ch
    join public.checkout_hour_package_reservations phr on phr.checkout_hold_id=ch.id
    where ch.promoted_appointment_id=v_appointment.id
  ) then
    raise exception 'EXPIRED_PACKAGE_REACTIVATION_REQUIRES_DECISION';
  end if;

  if exists (
    select 1
    from public.resource_allocations mine
    join public.resource_allocations other
      on other.resource_id=mine.resource_id
     and other.id<>mine.id
     and other.occupied_range && mine.occupied_range
     and other.status in ('HELD','AWAITING_PAYMENT','CONFIRMED','BLOCKED','EXTERNAL_ACTIVE')
    where mine.appointment_id=v_appointment.id
      and mine.allocation_type='APPOINTMENT'
  ) then
    raise exception 'APPOINTMENT_SLOT_NO_LONGER_AVAILABLE';
  end if;

  update public.resource_allocations
  set status='CONFIRMED',updated_at=now()
  where appointment_id=v_appointment.id
    and allocation_type='APPOINTMENT'
    and status in ('EXPIRED','AWAITING_PAYMENT','HELD');
  get diagnostics v_allocation_count=row_count;

  if v_allocation_count=0 then
    if not exists (
      select 1 from public.resource_allocations
      where appointment_id=v_appointment.id
        and allocation_type='APPOINTMENT'
        and status='CONFIRMED'
    ) then
      raise exception 'APPOINTMENT_RESOURCE_ALLOCATION_MISSING';
    end if;
  end if;

  update public.appointments
  set status='CONFIRMED',
      financial_status=case
        when financial_status in ('PAID','PARTIALLY_PAID','PARTIALLY_REFUNDED','REFUNDED','UNPAID_AUTHORIZED') then financial_status
        else 'UNPAID_AUTHORIZED'
      end,
      confirmed_at=coalesce(confirmed_at,now()),
      hold_expires_at=null,
      version=version+1,
      updated_at=now()
  where id=v_appointment.id;

  v_financial_status:=public.refresh_appointment_financial_status(v_appointment.id);

  -- Same messages and calendar sync as a confirmation by payment: the customer gets the
  -- WhatsApp and e-mail confirmation and the reservation reaches Google Calendar.
  perform public.enqueue_appointment_confirmation_jobs(v_appointment.id, 'ADMIN_CONFIRMED_WITHOUT_PAYMENT');

  insert into public.audit_logs(
    admin_user_id,entity_type,entity_id,action,before_json,after_json,origin
  ) values (
    p_admin_id,'APPOINTMENT',v_appointment.id,'APPOINTMENT_CONFIRMED_WITHOUT_PAYMENT_ADMIN',
    jsonb_build_object('status',v_appointment.status,'financial_status',v_appointment.financial_status,'version',v_appointment.version),
    jsonb_build_object('status','CONFIRMED','financial_status',v_financial_status,'reason',v_reason),
    'ADMIN_UI'
  );

  return jsonb_build_object(
    'appointment_id',v_appointment.id,
    'status','CONFIRMED',
    'financial_status',v_financial_status,
    'already_confirmed',false
  );
exception
  when exclusion_violation then
    raise exception 'APPOINTMENT_SLOT_NO_LONGER_AVAILABLE';
end;
$function$;

revoke all on function public.service_admin_confirm_appointment_unpaid(uuid,text,uuid) from public, anon, authenticated;
grant execute on function public.service_admin_confirm_appointment_unpaid(uuid,text,uuid) to service_role;
