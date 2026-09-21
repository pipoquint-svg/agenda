-- Independent prebooking and invoicing. No customer or historical booking is rewritten.
-- Public invoicing requires the existing hold-bound, email-verified customer session.
-- Standard promotion remains the sole authority for pricing, consent and allocation transfer.
begin;

create or replace function public.normalize_customer_prebook_terms_global()
returns trigger language plpgsql set search_path to 'public' as $$
declare v_minutes integer;
begin
  select prebook_hold_minutes into v_minutes from public.operation_settings where id=1;
  if coalesce(v_minutes,0)<=0 then raise exception 'PREBOOK_GLOBAL_HOLD_INVALID'; end if;
  new.prebook_hold_minutes:=v_minutes;
  if new.billing_mode='CHECKOUT' then new.requires_manual_confirmation:=false; end if;
  return new;
end;
$$;
comment on column public.customer_commercial_terms.requires_manual_confirmation is
  'INVOICE: require team approval before confirmation. CHECKOUT: payment-only, normalized false.';

create or replace function public.service_public_get_checkout_prebook_option(
  p_checkout_hold_token text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions'
as $function$
declare
  v_hold public.checkout_holds%rowtype;
  v_terms public.customer_commercial_terms%rowtype;
  v_global_minutes integer := 2880;
  v_active_count integer := 0;
  v_authorized boolean := false;
  v_eligible boolean := false;
  v_private boolean;
  v_invoice boolean := false;
begin
  select * into v_hold from public.checkout_holds
  where public_token_hash = encode(digest(p_checkout_hold_token,'sha256'),'hex') for update;
  if not found or v_hold.status <> 'ACTIVE' or v_hold.expires_at <= now() then
    raise exception using errcode='P0001',message='CHECKOUT_HOLD_NOT_ACTIVE';
  end if;
  if v_hold.primary_customer_id is null then
    raise exception using errcode='P0001',message='CHECKOUT_CUSTOMER_REQUIRED';
  end if;

  select prebook_hold_minutes into v_global_minutes from public.operation_settings where id=1;
  if coalesce(v_global_minutes,0) <= 0 then
    raise exception using errcode='P0001',message='PREBOOK_GLOBAL_HOLD_INVALID';
  end if;

  select * into v_terms from public.customer_commercial_terms
  where customer_id = v_hold.primary_customer_id and is_active = true;
  if found then
    select exists(select 1 from public.customer_prebook_authorized_services cas
      where cas.customer_id = v_hold.primary_customer_id and cas.service_id = v_hold.service_id) into v_authorized;
    v_invoice := v_terms.billing_mode='INVOICE';
    v_eligible := coalesce(v_terms.can_prebook,false) and v_authorized;
  end if;

  v_private := coalesce(v_hold.attribution_json->>'source','') = 'WAITLIST_PRIVATE_INVITE';
  v_eligible := v_eligible and not v_private;
  if v_eligible then
    select count(*)::integer into v_active_count from public.pre_reservations pr
    where pr.customer_id = v_hold.primary_customer_id and pr.status = 'ACTIVE' and pr.expires_at > now();
  end if;

  return jsonb_build_object(
    'billing_mode', case when v_invoice then 'INVOICE' else 'CHECKOUT' end,
    'invoice_due_days', case when v_invoice then v_terms.invoice_due_days else null end,
    'requires_manual_confirmation', v_invoice and coalesce(v_terms.requires_manual_confirmation,false),
    'verification_required', v_invoice,
    'eligible', v_eligible,
    'available', v_eligible and v_active_count < coalesce(v_terms.max_active_prebooks,0),
    'active_count', v_active_count,
    'max_active_prebooks', case when v_eligible then v_terms.max_active_prebooks else 0 end,
    'hold_minutes', v_global_minutes,
    'reason', case
      when v_private then 'PREBOOK_NOT_AVAILABLE'
      when v_terms.customer_id is null then 'PREBOOK_NOT_ENABLED'
      when not coalesce(v_terms.can_prebook,false) then 'PREBOOK_NOT_ENABLED'
      when not v_authorized then 'SERVICE_NOT_AUTHORIZED_FOR_PREBOOK'
      when v_active_count >= coalesce(v_terms.max_active_prebooks,0) then 'MAX_ACTIVE_PREBOOKS_REACHED'
      else null end
  );
end;
$function$;

create or replace function public.service_public_checkout_benefit_hint(p_checkout_hold_token text)
returns jsonb
language plpgsql
security definer
set search_path to 'public','extensions'
as $function$
declare
  v_hold public.checkout_holds%rowtype;
  v_has_balance boolean := false;
  v_has_package boolean := false;
begin
  select * into v_hold
  from public.checkout_holds
  where public_token_hash = encode(digest(p_checkout_hold_token,'sha256'),'hex')
    and status = 'ACTIVE'
    and expires_at > now();

  if not found then
    raise exception using errcode='P0001', message='CHECKOUT_HOLD_NOT_ACTIVE';
  end if;
  if v_hold.primary_customer_id is null then
    raise exception using errcode='P0001', message='CHECKOUT_CUSTOMER_REQUIRED';
  end if;

  v_has_balance := public.customer_balance_available(v_hold.primary_customer_id) > 0;

  select exists (
    select 1
    from public.hour_packages hp
    join public.hour_package_balances hb on hb.hour_package_id = hp.id
    where hp.customer_id = v_hold.primary_customer_id
      and hp.status = 'ACTIVE'
      and hb.available_seconds > 0
      and v_hold.requested_start_at >= hp.valid_from
      and v_hold.requested_start_at < hp.valid_until
      and exists (
        select 1 from public.hour_package_services hps
        where hps.hour_package_id = hp.id
          and hps.service_id = v_hold.service_id
      )
  ) into v_has_package;

  return jsonb_build_object('verification_required', v_has_balance or v_has_package or exists (
    select 1 from public.customer_commercial_terms t
    where t.customer_id=v_hold.primary_customer_id and t.is_active and t.billing_mode='INVOICE'
  ));
end;
$function$;


create or replace function public.service_admin_set_customer_commercial_terms(
  p_customer_id uuid,
  p_can_prebook boolean,
  p_prebook_hold_minutes integer,
  p_max_active_prebooks integer,
  p_requires_manual_confirmation boolean,
  p_billing_mode text,
  p_invoice_due_days integer,
  p_is_active boolean,
  p_authorized_service_ids uuid[],
  p_admin_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_before jsonb;
  v_current public.customer_commercial_terms%rowtype;
  v_after jsonb;
  v_mode text := upper(btrim(coalesce(p_billing_mode, '')));
begin
  if not exists (select 1 from public.customers where id = p_customer_id) then
    raise exception using errcode = 'P0001', message = 'CUSTOMER_NOT_FOUND';
  end if;

  if coalesce(p_prebook_hold_minutes, 0) <= 0 then
    raise exception using errcode = 'P0001', message = 'PREBOOK_HOLD_MINUTES_INVALID';
  end if;
  if coalesce(p_max_active_prebooks, 0) <= 0 then
    raise exception using errcode = 'P0001', message = 'MAX_ACTIVE_PREBOOKS_INVALID';
  end if;
  if v_mode not in ('CHECKOUT','INVOICE') then
    raise exception using errcode = 'P0001', message = 'BILLING_MODE_INVALID';
  end if;
  if v_mode = 'INVOICE' and (p_invoice_due_days is null or p_invoice_due_days < 0) then
    raise exception using errcode = 'P0001', message = 'INVOICE_DUE_DAYS_INVALID';
  end if;
  if v_mode = 'CHECKOUT' and p_invoice_due_days is not null then
    raise exception using errcode = 'P0001', message = 'INVOICE_DUE_DAYS_NOT_ALLOWED';
  end if;

  -- Serialize authorization updates with invoice submissions.
  select * into v_current from public.customer_commercial_terms where customer_id=p_customer_id for update;
  if (v_mode='INVOICE' or v_current.billing_mode='INVOICE') and (
    v_current.customer_id is null or v_current.billing_mode is distinct from v_mode
    or v_current.invoice_due_days is distinct from p_invoice_due_days
    or v_current.requires_manual_confirmation is distinct from coalesce(p_requires_manual_confirmation,true)
    or v_current.is_active is distinct from coalesce(p_is_active,true)
  ) and not public.service_admin_has_permission(p_admin_id,'FINANCE_MANAGE') then
    raise exception 'ADMIN_FINANCE_PERMISSION_REQUIRED';
  end if;

  select public.service_admin_get_customer_commercial_profile(p_customer_id) into v_before;

  insert into public.customer_commercial_terms(
    customer_id, can_prebook, prebook_hold_minutes, max_active_prebooks,
    requires_manual_confirmation, billing_mode, invoice_due_days, is_active, updated_at
  ) values (
    p_customer_id, coalesce(p_can_prebook, false), p_prebook_hold_minutes, p_max_active_prebooks,
    coalesce(p_requires_manual_confirmation, true), v_mode,
    case when v_mode = 'INVOICE' then p_invoice_due_days else null end,
    coalesce(p_is_active, true), now()
  )
  on conflict (customer_id) do update set
    can_prebook = excluded.can_prebook,
    prebook_hold_minutes = excluded.prebook_hold_minutes,
    max_active_prebooks = excluded.max_active_prebooks,
    requires_manual_confirmation = excluded.requires_manual_confirmation,
    billing_mode = excluded.billing_mode,
    invoice_due_days = excluded.invoice_due_days,
    is_active = excluded.is_active,
    updated_at = now();

  delete from public.customer_prebook_authorized_services where customer_id = p_customer_id;

  if coalesce(array_length(p_authorized_service_ids, 1), 0) > 0 then
    if exists (
      select 1 from unnest(p_authorized_service_ids) x(service_id)
      left join public.services s on s.id = x.service_id and s.is_active
      where s.id is null
    ) then
      raise exception using errcode = 'P0001', message = 'AUTHORIZED_SERVICE_INVALID';
    end if;

    insert into public.customer_prebook_authorized_services(customer_id, service_id)
    select p_customer_id, service_id
    from unnest(p_authorized_service_ids) x(service_id)
    on conflict do nothing;
  end if;

  select public.service_admin_get_customer_commercial_profile(p_customer_id) into v_after;

  insert into public.audit_logs(admin_user_id, entity_type, entity_id, action, before_json, after_json, origin)
  values (p_admin_id, 'CUSTOMER', p_customer_id, 'COMMERCIAL_TERMS_CHANGED', v_before, v_after, 'ADMIN');

  return v_after;
end;
$$;

-- Private projection: billing never becomes cash received or a PIX discount.
create function public.invoice_checkout_result(p_appointment_id uuid)
returns jsonb language sql stable set search_path to 'public' as $$
  select jsonb_build_object(
    'appointment_id',a.id,'public_code',a.public_code,'status',a.status,
    'financial_status',a.financial_status,'hold_expires_at',a.hold_expires_at,
    'billing_mode',a.billing_mode_snapshot,'invoice_due_at',a.invoice_due_at,
    'invoice_due_days',a.invoice_due_days_snapshot,
    'cash_due',greatest(a.commercial_value-public.appointment_contract_coverage_amount(a.id),0),
    'payment_required',false,'amount_due_now',0,
    'confirmation_pending',a.status='AWAITING_PAYMENT',
    'requires_manual_confirmation',coalesce(pr.requires_manual_confirmation_snapshot,false)
  ) from public.appointments a left join public.pre_reservations pr on pr.id=a.source_pre_reservation_id
    where a.id=p_appointment_id;
$$;
revoke all on function public.invoice_checkout_result(uuid) from public,anon,authenticated,service_role;

create function public.attach_checkout_pre_reservation(
  p_checkout_hold_id uuid,p_result jsonb,p_manual_review boolean default false
) returns jsonb language plpgsql set search_path to 'public','extensions' as $$
declare
  v_hold public.checkout_holds%rowtype;
  v_terms public.customer_commercial_terms%rowtype;
  v_result jsonb := p_result;
  v_appointment_id uuid; v_pre_reservation_id uuid; v_employee_id uuid;
  v_global_minutes integer; v_deadline timestamptz; v_raw_token text; v_token_hash text;
  v_extras_snapshot jsonb := '[]'::jsonb;
begin
  select * into strict v_hold from public.checkout_holds where id=p_checkout_hold_id;
  select * into v_terms from public.customer_commercial_terms
    where customer_id=v_hold.primary_customer_id and is_active for update;
  if not found then raise exception 'PREBOOK_NOT_AVAILABLE'; end if;
  if coalesce(v_hold.attribution_json->>'source','')='WAITLIST_PRIVATE_INVITE' then
    raise exception 'PREBOOK_NOT_AVAILABLE';
  end if;
  if not (p_manual_review and v_terms.billing_mode='INVOICE' and v_terms.requires_manual_confirmation) then
    if not v_terms.can_prebook or not exists (
      select 1 from public.customer_prebook_authorized_services s
      where s.customer_id=v_hold.primary_customer_id and s.service_id=v_hold.service_id
    ) then raise exception 'PREBOOK_NOT_AVAILABLE'; end if;
  end if;
  if (select count(*) from public.pre_reservations where customer_id=v_hold.primary_customer_id
      and status='ACTIVE' and expires_at>now())>=v_terms.max_active_prebooks then
    raise exception 'MAX_ACTIVE_PREBOOKS_REACHED';
  end if;
  v_appointment_id := nullif(v_result->>'appointment_id','')::uuid;
  v_raw_token := nullif(v_result->>'access_token','');
  if v_appointment_id is null or v_raw_token is null then
    raise exception using errcode='P0001',message='PREBOOK_PAYMENT_CONTEXT_MISSING';
  end if;

  select prebook_hold_minutes into v_global_minutes
  from public.operation_settings where id = 1;
  if coalesce(v_global_minutes,0) <= 0 then
    raise exception using errcode='P0001',message='PREBOOK_GLOBAL_HOLD_INVALID';
  end if;
  v_deadline := now() + make_interval(mins => v_global_minutes);

  select se.employee_id into v_employee_id
  from public.service_employees se
  where se.id = v_hold.service_employee_id;
  if v_employee_id is null then
    raise exception using errcode='P0001',message='PREBOOK_EMPLOYEE_NOT_FOUND';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'extra_id', ae.extra_id,
    'name', ae.name_snapshot,
    'quantity', ae.quantity,
    'unit_price', ae.unit_price_snapshot,
    'total_price', ae.total_price,
    'duration_delta_minutes', ae.total_duration_delta
  ) order by ae.created_at), '[]'::jsonb)
  into v_extras_snapshot
  from public.appointment_extras ae
  where ae.appointment_id = v_appointment_id;

  insert into public.pre_reservations(
    customer_id,service_id,employee_id,service_employee_id,public_code,
    start_at,end_at,core_start_at,core_end_at,pre_service_minutes,post_service_minutes,
    expires_at,status,people_count,extra_selections,extras_snapshot,duration_blocks,
    contracted_minutes,duration_minutes,schedule_profile_snapshot,quote_snapshot,resource_ids,
    billing_mode_snapshot,invoice_due_days_snapshot,requires_manual_confirmation_snapshot,
    converted_appointment_id,created_by_admin_id
  ) values (
    v_hold.primary_customer_id,v_hold.service_id,v_employee_id,v_hold.service_employee_id,v_result->>'public_code',
    v_hold.requested_start_at,v_hold.requested_end_at,v_hold.core_start_at,v_hold.core_end_at,
    v_hold.pre_service_minutes,v_hold.post_service_minutes,
    v_deadline,'ACTIVE',v_hold.people_count,v_hold.extra_selections,v_extras_snapshot,v_hold.duration_blocks,
    v_hold.contracted_minutes,v_hold.duration_minutes,v_hold.schedule_profile,v_hold.quote_snapshot,v_hold.resource_ids,
    v_terms.billing_mode,v_terms.invoice_due_days,
    case when v_terms.billing_mode='INVOICE' then v_terms.requires_manual_confirmation else false end,v_appointment_id,null
  ) returning id into v_pre_reservation_id;

  update public.appointments
  set hold_expires_at = v_deadline,
      source_pre_reservation_id = v_pre_reservation_id,
      updated_at = now()
  where id = v_appointment_id
    and status = 'AWAITING_PAYMENT';
  if not found then
    raise exception using errcode='P0001',message='PREBOOK_APPOINTMENT_NOT_AWAITING_PAYMENT';
  end if;

  v_token_hash := encode(digest(v_raw_token,'sha256'),'hex');
  insert into public.pre_reservation_access_tokens(pre_reservation_id,token_hash,scope,expires_at)
  values(v_pre_reservation_id,v_token_hash,'VIEW',v_deadline);

  insert into public.audit_logs(entity_type,entity_id,action,after_json,origin)
  values(
    'PRE_RESERVATION',v_pre_reservation_id,'PRE_RESERVATION_CREATED_FROM_CHECKOUT',
    jsonb_build_object(
      'appointment_id',v_appointment_id,
      'expires_at',v_deadline,
      'hold_minutes',v_global_minutes,
      'confirmation',case when v_terms.billing_mode='INVOICE' then 'INVOICE_ACCEPTANCE' else 'PAYMENT_ONLY' end
    ),'PUBLIC'
  );

  if v_terms.billing_mode='INVOICE' then
    update public.appointments set billing_mode_snapshot='INVOICE',invoice_due_basis='SERVICE_START',
      invoice_due_days_snapshot=v_terms.invoice_due_days,invoice_due_base_at=coalesce(core_start_at,start_at),
      financial_status=case when public.appointment_contract_coverage_amount(id)>0 then 'PARTIALLY_PAID'::public.financial_status
        else 'UNPAID_AUTHORIZED'::public.financial_status end,updated_at=now() where id=v_appointment_id;
    v_result := v_result || public.invoice_checkout_result(v_appointment_id);
  end if;
  return v_result || jsonb_build_object('requires_manual_confirmation',v_terms.billing_mode='INVOICE' and v_terms.requires_manual_confirmation) || jsonb_build_object(
    'pre_reservation',true,
    'pre_reservation_id',v_pre_reservation_id,
    'pre_reservation_expires_at',v_deadline,
    'hold_expires_at',v_deadline
  );
end;
$$;


revoke all on function public.attach_checkout_pre_reservation(uuid,jsonb,boolean) from public,anon,authenticated,service_role;

create or replace function public.promote_checkout_hold_prebook(
  p_checkout_hold_id uuid,p_customer_id uuid,p_coupon_code text default null,
  p_term_version_ids uuid[] default '{}'::uuid[],p_participants jsonb default '[]'::jsonb,
  p_answers jsonb default '[]'::jsonb,p_acceptance_ip inet default null,p_acceptance_user_agent text default null
) returns jsonb language plpgsql set search_path to 'public','extensions' as $$
declare v_result jsonb;
begin
  -- Canonical promoter preserves consent, fields, coupons, packages and atomic allocations.
  v_result:=public.promote_checkout_hold_standard(p_checkout_hold_id,p_customer_id,p_coupon_code,
    p_term_version_ids,p_participants,p_answers,p_acceptance_ip,p_acceptance_user_agent);
  if v_result->>'status'<>'AWAITING_PAYMENT' then
    return v_result || jsonb_build_object('pre_reservation',false);
  end if;
  return public.attach_checkout_pre_reservation(p_checkout_hold_id,v_result,false);
end;
$$;

alter function public.service_submit_public_checkout_choice_with_benefits(text,text,text,uuid[],jsonb,inet,text,text,text,boolean)
  rename to submit_checkout_benefits_before_invoice;
revoke all on function public.submit_checkout_benefits_before_invoice(text,text,text,uuid[],jsonb,inet,text,text,text,boolean)
  from public,anon,authenticated,service_role;

create function public.service_submit_public_checkout_choice_with_benefits(
  p_checkout_hold_token text,p_checkout_mode text,p_coupon_code text,p_term_version_ids uuid[],
  p_answers jsonb,p_acceptance_ip inet,p_user_agent text,p_request_id text,
  p_customer_session_token text,p_apply_customer_balance boolean
) returns jsonb language plpgsql security definer set search_path to 'public','extensions' as $$
declare
  v_hold public.checkout_holds%rowtype;
  v_terms public.customer_commercial_terms%rowtype;
  v_result jsonb; v_id uuid; v_invoice boolean := false;
begin
  select * into v_hold from public.checkout_holds
    where public_token_hash=encode(digest(p_checkout_hold_token,'sha256'),'hex') for update;
  if not found or v_hold.status<>'ACTIVE' or v_hold.expires_at<=now() then
    raise exception 'CHECKOUT_HOLD_NOT_ACTIVE';
  end if;
  if v_hold.primary_customer_id is null then raise exception 'CHECKOUT_CUSTOMER_REQUIRED'; end if;
  select * into v_terms from public.customer_commercial_terms
    where customer_id=v_hold.primary_customer_id and is_active for update;
  v_invoice := found and v_terms.billing_mode='INVOICE' and v_hold.commercial_value>0;
  if v_invoice then
    perform public.service_assert_checkout_customer_session(p_checkout_hold_token,p_customer_session_token);
  end if;
  v_result:=public.submit_checkout_benefits_before_invoice(
    p_checkout_hold_token,p_checkout_mode,p_coupon_code,p_term_version_ids,p_answers,p_acceptance_ip,
    p_user_agent,p_request_id,p_customer_session_token,p_apply_customer_balance);
  -- Already fully covered by free service/package/balance: leave canonical paid semantics intact.
  if not v_invoice or v_result->>'status'='CONFIRMED' then return v_result; end if;
  v_id:=(v_result->>'appointment_id')::uuid;
  if coalesce((v_result->>'pre_reservation')::boolean,false) then return v_result; end if;
  if v_terms.requires_manual_confirmation then
    return public.attach_checkout_pre_reservation(v_hold.id,v_result,true);
  end if;
  update public.appointments set billing_mode_snapshot='INVOICE',invoice_due_basis='SERVICE_START',
    invoice_due_days_snapshot=v_terms.invoice_due_days,invoice_due_base_at=coalesce(core_start_at,start_at),
    financial_status=case when public.appointment_contract_coverage_amount(id)>0 then 'PARTIALLY_PAID'::public.financial_status
      else 'UNPAID_AUTHORIZED'::public.financial_status end,updated_at=now()
    where id=v_id;
  -- Confirmation clears hold_expires_at and confirms the SAME allocations, atomically.
  perform public.confirm_appointment_internal(v_id,'CUSTOMER_VERIFIED_INVOICE');
  insert into public.audit_logs(entity_type,entity_id,action,after_json,origin)
    values('APPOINTMENT',v_id,'CUSTOMER_VERIFIED_INVOICE',jsonb_build_object(
      'customer_id',v_hold.primary_customer_id,'invoice_due_days',v_terms.invoice_due_days,
      'checkout_hold_id',v_hold.id,'identity','VERIFIED_EMAIL_SESSION'),'PUBLIC');
  return v_result || public.invoice_checkout_result(v_id);
end;
$$;
revoke all on function public.service_submit_public_checkout_choice_with_benefits(text,text,text,uuid[],jsonb,inet,text,text,text,boolean) from public,anon,authenticated;
grant execute on function public.service_submit_public_checkout_choice_with_benefits(text,text,text,uuid[],jsonb,inet,text,text,text,boolean) to service_role;

-- One confirmation implementation for invoice prebooks linked to an existing appointment.
create function public.confirm_linked_invoice_prebook(p_pre_reservation_id uuid,p_admin_id uuid,p_customer_confirmation boolean)
returns jsonb language plpgsql set search_path to 'public','extensions' as $$
declare v_pr public.pre_reservations%rowtype; v_id uuid; v_appt public.appointments%rowtype;
begin
  select converted_appointment_id into v_id from public.pre_reservations where id=p_pre_reservation_id;
  select * into v_appt from public.appointments where id=v_id for update;
  select * into v_pr from public.pre_reservations where id=p_pre_reservation_id for update;
  if v_appt.id is null or v_pr.id is null or v_pr.billing_mode_snapshot<>'INVOICE'
    or v_appt.source_pre_reservation_id is distinct from v_pr.id then raise exception 'PRE_RESERVATION_NOT_FOUND'; end if;
  if v_appt.status='CONFIRMED' and v_pr.status='CONFIRMED' then
    return public.invoice_checkout_result(v_id) || jsonb_build_object('pre_reservation_id',v_pr.id);
  end if;
  if v_pr.status<>'ACTIVE' or v_pr.expires_at<=now() or v_appt.status<>'AWAITING_PAYMENT' then
    raise exception 'PRE_RESERVATION_NOT_ACTIVE';
  end if;
  if p_customer_confirmation and v_pr.requires_manual_confirmation_snapshot then
    raise exception 'INVOICE_MANUAL_CONFIRMATION_REQUIRED';
  end if;
  perform 1 from public.customer_commercial_terms where customer_id=v_pr.customer_id
    and is_active and billing_mode='INVOICE' for share;
  if not found then raise exception 'CUSTOMER_NOT_AUTHORIZED_FOR_INVOICE'; end if;
  -- Use agreed snapshot, not a later edit of the customer's number of days.
  update public.appointments set invoice_authorized_by_admin_id=p_admin_id,updated_at=now() where id=v_id;
  perform public.confirm_appointment_internal(v_id,'INVOICE_PREBOOK_CONFIRMED');
  if p_admin_id is not null then
    update public.pre_reservations set confirmed_by_admin_id=p_admin_id where id=v_pr.id;
  end if;
  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,after_json,origin)
    values(p_admin_id,'APPOINTMENT',v_id,'INVOICE_PREBOOK_CONFIRMED',jsonb_build_object(
      'pre_reservation_id',v_pr.id,'customer_confirmation',p_customer_confirmation),
      case when p_customer_confirmation then 'PUBLIC' else 'ADMIN' end);
  return public.invoice_checkout_result(v_id) || jsonb_build_object('pre_reservation_id',v_pr.id);
end;
$$;
revoke all on function public.confirm_linked_invoice_prebook(uuid,uuid,boolean) from public,anon,authenticated,service_role;

alter function public.service_admin_confirm_pre_reservation(uuid,uuid) rename to confirm_standalone_pre_reservation;
revoke all on function public.confirm_standalone_pre_reservation(uuid,uuid) from public,anon,authenticated,service_role;
create function public.service_admin_confirm_pre_reservation(p_pre_reservation_id uuid,p_admin_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public','extensions' as $$
begin
  if not public.service_admin_has_permission(p_admin_id,'AGENDA_MANAGE') then raise exception 'ADMIN_PERMISSION_DENIED'; end if;
  if exists(select 1 from public.pre_reservations where id=p_pre_reservation_id
    and converted_appointment_id is not null and billing_mode_snapshot='INVOICE') then
    if not public.service_admin_has_permission(p_admin_id,'FINANCE_MANAGE') then raise exception 'ADMIN_FINANCE_PERMISSION_REQUIRED'; end if;
    return public.confirm_linked_invoice_prebook(p_pre_reservation_id,p_admin_id,false);
  end if;
  return public.confirm_standalone_pre_reservation(p_pre_reservation_id,p_admin_id);
end;
$$;
revoke all on function public.service_admin_confirm_pre_reservation(uuid,uuid) from public,anon,authenticated;
grant execute on function public.service_admin_confirm_pre_reservation(uuid,uuid) to service_role;

create function public.service_confirm_invoice_prebook_by_token(p_access_token text)
returns jsonb language plpgsql security definer set search_path to 'public','extensions' as $$
declare v_id uuid; v_pr_id uuid;
begin
  v_id:=public.resolve_appointment_access_token(p_access_token,'MANAGE');
  select source_pre_reservation_id into v_pr_id from public.appointments where id=v_id;
  return public.confirm_linked_invoice_prebook(v_pr_id,null,true);
end;
$$;
revoke all on function public.service_confirm_invoice_prebook_by_token(text) from public,anon,authenticated;
grant execute on function public.service_confirm_invoice_prebook_by_token(text) to service_role;

-- Block upfront public charges for INVOICE, without touching administrative receipts.
do $$
declare v_sig text; v_def text; v_anchor text := '  v_idempotency_key:=';
begin
  foreach v_sig in array array[
    'public.service_create_payment_intent_by_token(text,text,text,text)',
    'public.service_create_infinitepay_payment_intent_by_token(text,text,text)'
  ] loop
    v_def:=pg_get_functiondef(v_sig::regprocedure);
    if position(v_anchor in v_def)=0 then raise exception 'INVOICE_PAYMENT_GUARD_ANCHOR_MISSING: %',v_sig; end if;
    v_def:=replace(v_def,v_anchor,
      $guard$  if v_appointment.billing_mode_snapshot='INVOICE' then raise exception 'INVOICE_CHECKOUT_PAYMENT_NOT_REQUIRED'; end if;$guard$ || E'\n' || v_anchor);
    execute v_def;
  end loop;
  v_def:=pg_get_functiondef('public.service_claim_infinitepay_checkout_by_token(text,text,text)'::regprocedure);
  v_anchor:='  -- One unresolved hosted checkout';
  if position(v_anchor in v_def)=0 then raise exception 'INVOICE_CLAIM_GUARD_ANCHOR_MISSING'; end if;
  execute replace(v_def,v_anchor,$guard$  if v_appointment.billing_mode_snapshot='INVOICE' then raise exception 'INVOICE_CHECKOUT_PAYMENT_NOT_REQUIRED'; end if;
$guard$ || v_anchor);
end;
$$;

alter function public.service_get_public_payment_context(text) rename to payment_context_before_invoice;
revoke all on function public.payment_context_before_invoice(text) from public,anon,authenticated,service_role;
create function public.service_get_public_payment_context(p_access_token text)
returns jsonb language plpgsql security definer set search_path to 'public','extensions' as $$
declare v_id uuid; v_appt public.appointments%rowtype; v_context jsonb;
begin
  v_id:=public.resolve_appointment_access_token(p_access_token,'VIEW');
  select * into strict v_appt from public.appointments where id=v_id;
  if v_appt.billing_mode_snapshot is distinct from 'INVOICE' then return public.payment_context_before_invoice(p_access_token); end if;
  return public.invoice_checkout_result(v_id) || jsonb_build_object(
    'appointment_status',v_appt.status,'service_name',v_appt.service_name_snapshot,
    'commercial_value',v_appt.commercial_value,'contract_balance',greatest(v_appt.commercial_value-public.appointment_contract_coverage_amount(v_id),0),
    'minimum_due_contract_amount',0,'minimum_available',false,'full_available',false,
    'policy_allows_minimum',false,'policy_allows_full',false,'pix_discount_percent',0);
end;
$$;
revoke all on function public.service_get_public_payment_context(text) from public,anon,authenticated;
grant execute on function public.service_get_public_payment_context(text) to service_role;

-- Invoice prebook links show confirmation instead of payment; never expose customer identity.
alter function public.public_get_pre_reservation_context(text) rename to prebook_context_before_invoice;
revoke all on function public.prebook_context_before_invoice(text) from public,anon,authenticated,service_role;
create function public.public_get_pre_reservation_context(p_access_token text)
returns jsonb language plpgsql security definer set search_path to 'public','extensions' as $$
declare v_pr public.pre_reservations%rowtype; v_appt public.appointments%rowtype; v_id uuid;
begin
  select pr.* into v_pr from public.pre_reservations pr
    join public.appointment_access_tokens t on t.appointment_id=pr.converted_appointment_id
    where t.token_hash=encode(digest(btrim(p_access_token),'sha256'),'hex')
      and pr.billing_mode_snapshot='INVOICE';
  if not found then return public.prebook_context_before_invoice(p_access_token); end if;
  v_id:=public.resolve_appointment_access_token(p_access_token,'VIEW');
  select * into strict v_appt from public.appointments where id=v_id;
  return jsonb_build_object('public_code',v_pr.public_code,'service_name',v_appt.service_name_snapshot,
    'status',case when v_pr.status='ACTIVE' and v_pr.expires_at<=now() then 'EXPIRED' else v_pr.status end,
    'start_at',v_pr.start_at,'end_at',v_pr.end_at,'core_start_at',v_pr.core_start_at,'core_end_at',v_pr.core_end_at,
    'expires_at',v_pr.expires_at,'billing_mode','INVOICE','invoice_due_at',v_appt.invoice_due_at,
    'invoice_due_days',v_pr.invoice_due_days_snapshot,'requires_manual_confirmation',v_pr.requires_manual_confirmation_snapshot,
    'authoritative_resource_hold',exists(select 1 from public.resource_allocations
      where appointment_id=v_id and status in ('HELD','CONFIRMED')));
end;
$$;
revoke all on function public.public_get_pre_reservation_context(text) from public,anon,authenticated;
grant execute on function public.public_get_pre_reservation_context(text) to service_role;

commit;
