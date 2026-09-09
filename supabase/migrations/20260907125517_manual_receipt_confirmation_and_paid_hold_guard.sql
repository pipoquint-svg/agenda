create or replace function public.service_admin_record_manual_receipt(
  p_appointment_id uuid,
  p_method text,
  p_amount numeric,
  p_paid_at timestamptz,
  p_notes text,
  p_admin_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_appointment public.appointments%rowtype;
  v_method text:=upper(btrim(coalesce(p_method,'')));
  v_amount numeric(12,2):=round(coalesce(p_amount,0),2);
  v_paid_at timestamptz:=coalesce(p_paid_at,now());
  v_notes text:=nullif(btrim(coalesce(p_notes,'')),'');
  v_net_paid numeric(12,2);
  v_remaining numeric(12,2);
  v_tx public.payment_transactions%rowtype;
  v_financial_status public.financial_status;
  v_suggestion jsonb;
  v_suggested_amount numeric(12,2);
  v_amount_overridden boolean;
  v_post_summary jsonb;
  v_contract_coverage numeric(12,2);
  v_payment_mode text;
  v_confirmation_target numeric(12,2);
  v_confirmed boolean:=false;
begin
  if not public.service_admin_has_permission(p_admin_id,'FINANCE_MANAGE') then raise exception 'ADMIN_PERMISSION_DENIED'; end if;
  if v_method not in ('CASH','PIX') then raise exception 'MANUAL_RECEIPT_METHOD_INVALID'; end if;
  if v_amount<=0 then raise exception 'MANUAL_RECEIPT_AMOUNT_INVALID'; end if;
  if v_paid_at>now()+interval '5 minutes' then raise exception 'MANUAL_RECEIPT_PAID_AT_FUTURE'; end if;
  if v_notes is not null and length(v_notes)>500 then raise exception 'MANUAL_RECEIPT_NOTES_TOO_LONG'; end if;

  select * into v_appointment from public.appointments where id=p_appointment_id for update;
  if not found then raise exception 'APPOINTMENT_NOT_FOUND'; end if;
  if v_appointment.primary_customer_id is null then raise exception 'MANUAL_RECEIPT_CUSTOMER_REQUIRED'; end if;
  if v_appointment.status::text in ('CANCELLED','EXPIRED') then raise exception 'MANUAL_RECEIPT_APPOINTMENT_CLOSED'; end if;
  if coalesce(v_appointment.commercial_value,0)<=0 then raise exception 'MANUAL_RECEIPT_CONTRACT_VALUE_REQUIRED'; end if;

  v_net_paid:=public.appointment_net_contract_settled_amount(p_appointment_id);
  v_remaining:=round(greatest(coalesce(v_appointment.commercial_value,0)-coalesce(v_net_paid,0),0),2);
  if v_amount>v_remaining+0.009 then raise exception 'MANUAL_RECEIPT_EXCEEDS_BALANCE'; end if;

  v_suggestion:=public.service_manual_contract_payment_suggestion(p_appointment_id);
  v_suggested_amount:=round(coalesce((v_suggestion->>'suggested_contract_amount')::numeric,0),2);
  v_amount_overridden:=abs(v_amount-v_suggested_amount)>0.009;

  insert into public.payment_transactions(
    appointment_id,transaction_type,method,provider,status,contract_amount_settled,payment_discount_amount,cash_amount,
    paid_at,created_by_admin_id,notes,payment_purpose
  ) values(
    p_appointment_id,'CHARGE',v_method,'MANUAL','APPROVED',v_amount,0,v_amount,v_paid_at,p_admin_id,v_notes,'CONTRACT'
  ) returning * into v_tx;

  v_financial_status:=public.refresh_appointment_financial_status(p_appointment_id);
  v_post_summary:=public.get_appointment_financial_summary(p_appointment_id);
  v_contract_coverage:=round(greatest(coalesce((v_post_summary->>'contract_coverage')::numeric,0),0),2);
  v_payment_mode:=coalesce(v_suggestion->>'payment_mode','MINIMUM_OR_FULL');
  v_confirmation_target:=case
    when v_payment_mode='FULL_ONLY' then round(coalesce(v_appointment.commercial_value,0),2)
    else round(greatest(coalesce((v_suggestion->>'confirmation_target_amount')::numeric,0),0),2)
  end;

  if v_appointment.status='AWAITING_PAYMENT'
     and v_appointment.hold_expires_at is not null
     and v_appointment.hold_expires_at>now()
     and v_contract_coverage+0.009>=v_confirmation_target then
    perform public.confirm_appointment_internal(p_appointment_id,'MANUAL_PAYMENT_CONFIRMED');
    v_financial_status:=public.refresh_appointment_financial_status(p_appointment_id);
    v_confirmed:=true;
  end if;

  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
  values(
    p_admin_id,'PAYMENT_TRANSACTION',v_tx.id,'MANUAL_RECEIPT_RECORDED',null,
    jsonb_build_object(
      'appointment_id',p_appointment_id,'customer_id',v_appointment.primary_customer_id,'method',v_method,'amount',v_amount,
      'paid_at',v_paid_at,'financial_status',v_financial_status,'suggested_contract_amount',v_suggested_amount,
      'amount_overridden',v_amount_overridden,'suggestion_reason',v_suggestion->>'suggestion_reason',
      'confirmation_target_amount',v_confirmation_target,'contract_coverage_after',v_contract_coverage,
      'appointment_confirmed',v_confirmed
    ),'ADMIN_UI'
  );

  return jsonb_build_object(
    'transaction',to_jsonb(v_tx),'appointment_id',p_appointment_id,'customer_id',v_appointment.primary_customer_id,
    'financial_status',v_financial_status,'appointment_status',(select status from public.appointments where id=p_appointment_id),
    'appointment_confirmed',v_confirmed,
    'net_paid',public.appointment_net_contract_settled_amount(p_appointment_id),
    'remaining_due',round(greatest(coalesce(v_appointment.commercial_value,0)-public.appointment_net_contract_settled_amount(p_appointment_id),0),2),
    'suggested_contract_amount',v_suggested_amount,'amount_overridden',v_amount_overridden
  );
end;
$function$;

create or replace function public.expire_due_appointment_holds()
returns integer
language plpgsql
set search_path to 'public'
as $function$
declare
  v_appointment record;
  v_count integer:=0;
  v_now timestamptz:=coalesce(nullif(current_setting('agenda.test_now',true),'')::timestamptz,now());
begin
  for v_appointment in
    select a.id
    from public.appointments a
    where a.status='AWAITING_PAYMENT'
      and a.hold_expires_at is not null
      and a.hold_expires_at<=v_now
      and a.financial_status<>'PAID'
    for update skip locked
  loop
    perform public.release_appointment_coupon_usage(v_appointment.id);
    update public.appointments
      set status='EXPIRED',
          financial_status=case when financial_status in ('NOT_STARTED','PENDING','REJECTED') then 'EXPIRED' else financial_status end,
          updated_at=v_now
      where id=v_appointment.id;
    update public.resource_allocations
      set status='EXPIRED',updated_at=v_now
      where appointment_id=v_appointment.id and status in ('HELD','AWAITING_PAYMENT');
    update public.checkout_hour_package_reservations phr
      set status='RELEASED',released_at=v_now,release_reason='APPOINTMENT_PAYMENT_HOLD_EXPIRED',updated_at=v_now
      from public.checkout_holds ch
      where ch.promoted_appointment_id=v_appointment.id
        and phr.checkout_hold_id=ch.id
        and phr.status='HELD';
    insert into public.audit_logs(entity_type,entity_id,action,after_json,origin)
      values('APPOINTMENT',v_appointment.id,'PAYMENT_HOLD_EXPIRED',jsonb_build_object('status','EXPIRED'),'SYSTEM');
    v_count:=v_count+1;
  end loop;
  return v_count;
end;
$function$;