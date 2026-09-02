create table if not exists public.checkout_customer_verifications (
  checkout_hold_id uuid primary key references public.checkout_holds(id) on delete cascade,
  customer_id uuid not null references public.customers(id) on delete cascade,
  code_hash text not null,
  status text not null default 'PENDING' check (status in ('PENDING','VERIFIED','REVOKED')),
  expires_at timestamptz not null,
  verify_attempts smallint not null default 0 check (verify_attempts between 0 and 10),
  verified_at timestamptz,
  session_token_hash text,
  session_expires_at timestamptz,
  last_sent_at timestamptz not null default now(),
  request_window_started_at timestamptz not null default now(),
  request_count smallint not null default 1 check (request_count between 1 and 20),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.checkout_customer_verifications enable row level security;
revoke all on table public.checkout_customer_verifications from public, anon, authenticated;
grant select, insert, update, delete on table public.checkout_customer_verifications to service_role;

create index if not exists idx_checkout_customer_verifications_session_hash
  on public.checkout_customer_verifications(session_token_hash)
  where session_token_hash is not null;

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

  return jsonb_build_object('verification_required', v_has_balance or v_has_package);
end;
$function$;

create or replace function public.service_request_checkout_customer_verification(p_checkout_hold_token text)
returns jsonb
language plpgsql
security definer
set search_path to 'public','extensions'
as $function$
declare
  v_hold public.checkout_holds%rowtype;
  v_customer public.customers%rowtype;
  v_existing public.checkout_customer_verifications%rowtype;
  v_hint jsonb;
  v_code text;
  v_code_hash text;
  v_window_started timestamptz;
  v_request_count smallint;
begin
  select * into v_hold
  from public.checkout_holds
  where public_token_hash = encode(digest(p_checkout_hold_token,'sha256'),'hex')
    and status = 'ACTIVE'
    and expires_at > now()
  for update;

  if not found then
    raise exception using errcode='P0001', message='CHECKOUT_HOLD_NOT_ACTIVE';
  end if;
  if v_hold.primary_customer_id is null then
    raise exception using errcode='P0001', message='CHECKOUT_CUSTOMER_REQUIRED';
  end if;

  v_hint := public.service_public_checkout_benefit_hint(p_checkout_hold_token);
  if not coalesce((v_hint->>'verification_required')::boolean,false) then
    return jsonb_build_object('verification_required',false,'should_send',false);
  end if;

  select * into v_customer from public.customers where id=v_hold.primary_customer_id;
  if not found or nullif(btrim(v_customer.email),'') is null then
    raise exception using errcode='P0001', message='CUSTOMER_VERIFICATION_EMAIL_REQUIRED';
  end if;

  select * into v_existing
  from public.checkout_customer_verifications
  where checkout_hold_id=v_hold.id
  for update;

  if found then
    if v_existing.last_sent_at > now() - interval '60 seconds' then
      raise exception using errcode='P0001', message='CUSTOMER_VERIFICATION_COOLDOWN';
    end if;
    if v_existing.request_window_started_at > now() - interval '30 minutes' then
      if v_existing.request_count >= 5 then
        raise exception using errcode='P0001', message='CUSTOMER_VERIFICATION_RATE_LIMITED';
      end if;
      v_window_started := v_existing.request_window_started_at;
      v_request_count := v_existing.request_count + 1;
    else
      v_window_started := now();
      v_request_count := 1;
    end if;
  else
    v_window_started := now();
    v_request_count := 1;
  end if;

  v_code := lpad((((('x' || encode(gen_random_bytes(4),'hex'))::bit(32)::bigint) % 1000000)::int)::text,6,'0');
  v_code_hash := encode(digest(v_code || ':' || v_hold.id::text || ':' || v_hold.primary_customer_id::text,'sha256'),'hex');

  insert into public.checkout_customer_verifications(
    checkout_hold_id,customer_id,code_hash,status,expires_at,verify_attempts,verified_at,
    session_token_hash,session_expires_at,last_sent_at,request_window_started_at,request_count,updated_at
  ) values (
    v_hold.id,v_hold.primary_customer_id,v_code_hash,'PENDING',least(now()+interval '10 minutes',v_hold.expires_at),0,null,
    null,null,now(),v_window_started,v_request_count,now()
  )
  on conflict (checkout_hold_id) do update set
    customer_id=excluded.customer_id,
    code_hash=excluded.code_hash,
    status='PENDING',
    expires_at=excluded.expires_at,
    verify_attempts=0,
    verified_at=null,
    session_token_hash=null,
    session_expires_at=null,
    last_sent_at=excluded.last_sent_at,
    request_window_started_at=excluded.request_window_started_at,
    request_count=excluded.request_count,
    updated_at=now();

  return jsonb_build_object(
    'verification_required',true,
    'should_send',true,
    'email',lower(v_customer.email),
    'code',v_code,
    'expires_at',least(now()+interval '10 minutes',v_hold.expires_at)
  );
end;
$function$;

create or replace function public.service_verify_checkout_customer_code(
  p_checkout_hold_token text,
  p_code text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public','extensions'
as $function$
declare
  v_hold public.checkout_holds%rowtype;
  v_verification public.checkout_customer_verifications%rowtype;
  v_expected text;
  v_session text;
  v_session_hash text;
  v_session_expires timestamptz;
begin
  if p_code is null or p_code !~ '^[0-9]{6}$' then
    raise exception using errcode='P0001', message='CUSTOMER_VERIFICATION_CODE_INVALID';
  end if;

  select * into v_hold
  from public.checkout_holds
  where public_token_hash = encode(digest(p_checkout_hold_token,'sha256'),'hex')
    and status='ACTIVE'
    and expires_at>now()
  for update;
  if not found then raise exception using errcode='P0001',message='CHECKOUT_HOLD_NOT_ACTIVE'; end if;
  if v_hold.primary_customer_id is null then raise exception using errcode='P0001',message='CHECKOUT_CUSTOMER_REQUIRED'; end if;

  select * into v_verification
  from public.checkout_customer_verifications
  where checkout_hold_id=v_hold.id
    and customer_id=v_hold.primary_customer_id
  for update;
  if not found or v_verification.status <> 'PENDING' then
    raise exception using errcode='P0001',message='CUSTOMER_VERIFICATION_NOT_PENDING';
  end if;
  if v_verification.expires_at <= now() then
    update public.checkout_customer_verifications set status='REVOKED',updated_at=now() where checkout_hold_id=v_hold.id;
    raise exception using errcode='P0001',message='CUSTOMER_VERIFICATION_EXPIRED';
  end if;
  if v_verification.verify_attempts >= 5 then
    update public.checkout_customer_verifications set status='REVOKED',updated_at=now() where checkout_hold_id=v_hold.id;
    raise exception using errcode='P0001',message='CUSTOMER_VERIFICATION_ATTEMPTS_EXCEEDED';
  end if;

  v_expected := encode(digest(p_code || ':' || v_hold.id::text || ':' || v_hold.primary_customer_id::text,'sha256'),'hex');
  if v_expected <> v_verification.code_hash then
    update public.checkout_customer_verifications
      set verify_attempts=verify_attempts+1,
          status=case when verify_attempts+1>=5 then 'REVOKED' else status end,
          updated_at=now()
      where checkout_hold_id=v_hold.id;
    raise exception using errcode='P0001',message='CUSTOMER_VERIFICATION_CODE_INVALID';
  end if;

  v_session := encode(gen_random_bytes(32),'hex');
  v_session_hash := encode(digest(v_session,'sha256'),'hex');
  v_session_expires := least(now()+interval '30 minutes',v_hold.expires_at);

  update public.checkout_customer_verifications
  set status='VERIFIED',verified_at=now(),session_token_hash=v_session_hash,
      session_expires_at=v_session_expires,updated_at=now()
  where checkout_hold_id=v_hold.id;

  return jsonb_build_object('verified',true,'session_token',v_session,'expires_at',v_session_expires);
end;
$function$;

create or replace function public.service_assert_checkout_customer_session(
  p_checkout_hold_token text,
  p_customer_session_token text
)
returns uuid
language plpgsql
security definer
set search_path to 'public','extensions'
as $function$
declare
  v_hold public.checkout_holds%rowtype;
  v_verification public.checkout_customer_verifications%rowtype;
  v_hash text;
begin
  if p_customer_session_token is null or length(btrim(p_customer_session_token)) < 32 then
    raise exception using errcode='P0001',message='CUSTOMER_VERIFICATION_REQUIRED';
  end if;
  select * into v_hold
  from public.checkout_holds
  where public_token_hash=encode(digest(p_checkout_hold_token,'sha256'),'hex')
    and status='ACTIVE' and expires_at>now();
  if not found then raise exception using errcode='P0001',message='CHECKOUT_HOLD_NOT_ACTIVE'; end if;
  if v_hold.primary_customer_id is null then raise exception using errcode='P0001',message='CHECKOUT_CUSTOMER_REQUIRED'; end if;

  v_hash := encode(digest(btrim(p_customer_session_token),'sha256'),'hex');
  select * into v_verification
  from public.checkout_customer_verifications
  where checkout_hold_id=v_hold.id
    and customer_id=v_hold.primary_customer_id
    and status='VERIFIED'
    and session_token_hash=v_hash
    and session_expires_at>now();
  if not found then raise exception using errcode='P0001',message='CUSTOMER_VERIFICATION_REQUIRED'; end if;
  return v_hold.primary_customer_id;
end;
$function$;

create or replace function public.service_public_checkout_benefits(
  p_checkout_hold_token text,
  p_customer_session_token text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public','extensions'
as $function$
declare
  v_customer_id uuid;
  v_packages jsonb;
begin
  v_customer_id := public.service_assert_checkout_customer_session(p_checkout_hold_token,p_customer_session_token);
  v_packages := public.public_list_checkout_hour_packages(p_checkout_hold_token);
  return jsonb_build_object(
    'verified',true,
    'customer_balance_available',public.customer_balance_available(v_customer_id),
    'packages',coalesce(v_packages,'[]'::jsonb)
  );
end;
$function$;

create or replace function public.service_public_select_checkout_hour_package_secure(
  p_checkout_hold_token text,
  p_customer_session_token text,
  p_hour_package_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'public','extensions'
as $function$
begin
  perform public.service_assert_checkout_customer_session(p_checkout_hold_token,p_customer_session_token);
  return public.public_select_checkout_hour_package(p_checkout_hold_token,p_hour_package_id);
end;
$function$;

create or replace function public.service_public_clear_checkout_hour_package_secure(
  p_checkout_hold_token text,
  p_customer_session_token text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public','extensions'
as $function$
begin
  perform public.service_assert_checkout_customer_session(p_checkout_hold_token,p_customer_session_token);
  return public.public_clear_checkout_hour_package(p_checkout_hold_token);
end;
$function$;

create or replace function public.refresh_appointment_financial_status(p_appointment_id uuid)
returns public.financial_status
language plpgsql
set search_path to 'public'
as $function$
declare
  v_appointment public.appointments%rowtype;
  v_gross_contract numeric(12,2);
  v_gross_cash numeric(12,2);
  v_refunded_contract numeric(12,2);
  v_refunded_cash numeric(12,2);
  v_pending_count integer;
  v_net_contract numeric(12,2);
  v_net_cash numeric(12,2);
  v_contract_coverage numeric(12,2);
  v_new_status public.financial_status;
begin
  select * into v_appointment from public.appointments where id=p_appointment_id for update;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if;

  select
    coalesce(sum(contract_amount_settled) filter(where payment_purpose='CONTRACT' and transaction_type='CHARGE' and status in('APPROVED','PARTIALLY_REFUNDED','REFUNDED')),0)::numeric(12,2),
    coalesce(sum(cash_amount) filter(where payment_purpose='CONTRACT' and transaction_type='CHARGE' and status in('APPROVED','PARTIALLY_REFUNDED','REFUNDED')),0)::numeric(12,2),
    coalesce(sum(contract_amount_settled) filter(where payment_purpose='CONTRACT' and transaction_type='REFUND' and status in('APPROVED','REFUNDED')),0)::numeric(12,2),
    coalesce(sum(cash_amount) filter(where payment_purpose='CONTRACT' and transaction_type='REFUND' and status in('APPROVED','REFUNDED')),0)::numeric(12,2),
    count(*) filter(where payment_purpose='CONTRACT' and transaction_type='CHARGE' and status='PENDING')::integer
  into v_gross_contract,v_gross_cash,v_refunded_contract,v_refunded_cash,v_pending_count
  from public.payment_transactions where appointment_id=p_appointment_id;

  v_net_contract:=round(greatest(v_gross_contract-v_refunded_contract,0),2);
  v_net_cash:=round(greatest(v_gross_cash-v_refunded_cash,0),2);
  v_contract_coverage:=public.appointment_contract_coverage_amount(p_appointment_id);

  if v_refunded_cash>0 and v_gross_cash>0 and v_net_cash<=0.01 then v_new_status:='REFUNDED';
  elsif v_refunded_cash>0 then v_new_status:='PARTIALLY_REFUNDED';
  elsif v_contract_coverage>=coalesce(v_appointment.commercial_value,0) and coalesce(v_appointment.commercial_value,0)>0 then v_new_status:='PAID';
  elsif v_contract_coverage>0 then v_new_status:='PARTIALLY_PAID';
  elsif v_appointment.financial_status='UNPAID_AUTHORIZED' then v_new_status:='UNPAID_AUTHORIZED';
  elsif v_pending_count>0 then v_new_status:='PENDING';
  elsif v_appointment.status='EXPIRED' then v_new_status:='EXPIRED';
  else v_new_status:='NOT_STARTED'; end if;

  update public.appointments set financial_status=v_new_status,updated_at=now() where id=p_appointment_id;
  return v_new_status;
end;
$function$;

create or replace function public.service_submit_public_checkout_choice_with_benefits(
  p_checkout_hold_token text,
  p_checkout_mode text,
  p_coupon_code text,
  p_term_version_ids uuid[],
  p_answers jsonb,
  p_acceptance_ip inet,
  p_user_agent text,
  p_request_id text,
  p_customer_session_token text,
  p_apply_customer_balance boolean
)
returns jsonb
language plpgsql
security definer
set search_path to 'public','extensions'
as $function$
declare
  v_hold public.checkout_holds%rowtype;
  v_has_package boolean := false;
  v_result jsonb;
  v_appointment_id uuid;
  v_balance_available numeric(12,2);
  v_due numeric(12,2);
  v_apply jsonb := '{}'::jsonb;
  v_context jsonb;
  v_summary jsonb;
  v_status text;
  v_financial text;
begin
  select * into v_hold
  from public.checkout_holds
  where public_token_hash=encode(digest(p_checkout_hold_token,'sha256'),'hex')
  for update;
  if not found or v_hold.status<>'ACTIVE' or v_hold.expires_at<=now() then
    raise exception using errcode='P0001',message='CHECKOUT_HOLD_NOT_ACTIVE';
  end if;

  select exists(
    select 1 from public.checkout_hour_package_reservations phr
    where phr.checkout_hold_id=v_hold.id and phr.status='HELD'
  ) into v_has_package;

  if v_has_package or coalesce(p_apply_customer_balance,false) then
    if upper(coalesce(p_checkout_mode,'PAY_NOW')) <> 'PAY_NOW' then
      raise exception using errcode='P0001',message='CHECKOUT_BENEFITS_REQUIRE_PAY_NOW';
    end if;
    perform public.service_assert_checkout_customer_session(p_checkout_hold_token,p_customer_session_token);
  end if;

  v_result := public.service_submit_public_checkout_choice(
    p_checkout_hold_token,p_checkout_mode,p_coupon_code,coalesce(p_term_version_ids,'{}'::uuid[]),
    coalesce(p_answers,'[]'::jsonb),p_acceptance_ip,p_user_agent
  );

  if not coalesce(p_apply_customer_balance,false) or coalesce((v_result->>'pre_reservation')::boolean,false) then
    return v_result;
  end if;

  v_appointment_id := nullif(v_result->>'appointment_id','')::uuid;
  if v_appointment_id is null then return v_result; end if;

  v_due := round(greatest(
    coalesce((select commercial_value from public.appointments where id=v_appointment_id),0)
    - public.appointment_contract_coverage_amount(v_appointment_id),0
  ),2);
  v_balance_available := public.customer_balance_available(v_hold.primary_customer_id);

  if v_due > 0 then
    if v_balance_available <= 0 then
      raise exception using errcode='P0001',message='CUSTOMER_BALANCE_EMPTY';
    end if;
    v_apply := public.service_apply_customer_balance_to_appointment(
      v_appointment_id,null,'CLIENT_TOKEN',null,p_acceptance_ip,p_user_agent,p_request_id,null
    );
    perform public.refresh_appointment_financial_status(v_appointment_id);
  end if;

  v_context := public.service_get_public_payment_context(v_result->>'access_token');
  if coalesce((v_context->>'minimum_due_contract_amount')::numeric,0) <= 0
     and coalesce(v_context->>'appointment_status','')='AWAITING_PAYMENT' then
    perform public.confirm_appointment_internal(v_appointment_id,'CUSTOMER_BALANCE_CONFIRMED');
  end if;

  v_financial := public.refresh_appointment_financial_status(v_appointment_id)::text;
  v_summary := public.get_appointment_financial_summary(v_appointment_id);
  select status into v_status from public.appointments where id=v_appointment_id;

  return v_result || jsonb_build_object(
    'status',v_status,
    'financial_status',v_financial,
    'cash_due',coalesce((v_summary->>'contract_balance')::numeric,0),
    'customer_balance_applied',coalesce((v_apply->>'amount_applied')::numeric,0),
    'customer_balance_remaining',public.customer_balance_available(v_hold.primary_customer_id)
  );
end;
$function$;

revoke all on function public.service_public_checkout_benefit_hint(text) from public,anon,authenticated;
revoke all on function public.service_request_checkout_customer_verification(text) from public,anon,authenticated;
revoke all on function public.service_verify_checkout_customer_code(text,text) from public,anon,authenticated;
revoke all on function public.service_assert_checkout_customer_session(text,text) from public,anon,authenticated;
revoke all on function public.service_public_checkout_benefits(text,text) from public,anon,authenticated;
revoke all on function public.service_public_select_checkout_hour_package_secure(text,text,uuid) from public,anon,authenticated;
revoke all on function public.service_public_clear_checkout_hour_package_secure(text,text) from public,anon,authenticated;
revoke all on function public.service_submit_public_checkout_choice_with_benefits(text,text,text,uuid[],jsonb,inet,text,text,text,boolean) from public,anon,authenticated;

grant execute on function public.service_public_checkout_benefit_hint(text) to service_role;
grant execute on function public.service_request_checkout_customer_verification(text) to service_role;
grant execute on function public.service_verify_checkout_customer_code(text,text) to service_role;
grant execute on function public.service_assert_checkout_customer_session(text,text) to service_role;
grant execute on function public.service_public_checkout_benefits(text,text) to service_role;
grant execute on function public.service_public_select_checkout_hour_package_secure(text,text,uuid) to service_role;
grant execute on function public.service_public_clear_checkout_hour_package_secure(text,text) to service_role;
grant execute on function public.service_submit_public_checkout_choice_with_benefits(text,text,text,uuid[],jsonb,inet,text,text,text,boolean) to service_role;
