-- Per-service checkout minimum payment rule.
-- Existing services keep their effective confirmation percentage as PERCENT.
-- New appointments snapshot type + value so later service changes are not retroactive.

alter table public.services
  add column if not exists checkout_minimum_payment_type text,
  add column if not exists checkout_minimum_payment_value numeric(12,2);

alter table public.appointments
  add column if not exists checkout_minimum_payment_type_snapshot text,
  add column if not exists checkout_minimum_payment_value_snapshot numeric(12,2);

alter table public.payment_transactions
  add column if not exists requested_payment_kind text;

update public.services s
set checkout_minimum_payment_type = coalesce(s.checkout_minimum_payment_type, 'PERCENT'),
    checkout_minimum_payment_value = coalesce(
      s.checkout_minimum_payment_value,
      s.confirmation_percentage,
      (select os.default_confirmation_percentage from public.operation_settings os where os.id=1),
      50
    )
where s.checkout_minimum_payment_type is null
   or s.checkout_minimum_payment_value is null;

update public.appointments a
set checkout_minimum_payment_type_snapshot = coalesce(a.checkout_minimum_payment_type_snapshot, 'PERCENT'),
    checkout_minimum_payment_value_snapshot = coalesce(
      a.checkout_minimum_payment_value_snapshot,
      a.confirmation_percentage_snapshot,
      (select s.checkout_minimum_payment_value from public.services s where s.id=a.service_id),
      50
    )
where a.checkout_minimum_payment_type_snapshot is null
   or a.checkout_minimum_payment_value_snapshot is null;

alter table public.services
  alter column checkout_minimum_payment_type set default 'PERCENT',
  alter column checkout_minimum_payment_value set default 50,
  alter column checkout_minimum_payment_type set not null,
  alter column checkout_minimum_payment_value set not null;

alter table public.services drop constraint if exists services_checkout_minimum_payment_rule_check;
alter table public.services add constraint services_checkout_minimum_payment_rule_check check (
  checkout_minimum_payment_type in ('PERCENT','FIXED')
  and checkout_minimum_payment_value >= 0
  and (checkout_minimum_payment_type <> 'PERCENT' or checkout_minimum_payment_value <= 100)
);

alter table public.appointments drop constraint if exists appointments_checkout_minimum_payment_rule_check;
alter table public.appointments add constraint appointments_checkout_minimum_payment_rule_check check (
  checkout_minimum_payment_type_snapshot is null
  or (
    checkout_minimum_payment_type_snapshot in ('PERCENT','FIXED')
    and checkout_minimum_payment_value_snapshot is not null
    and checkout_minimum_payment_value_snapshot >= 0
    and (checkout_minimum_payment_type_snapshot <> 'PERCENT' or checkout_minimum_payment_value_snapshot <= 100)
  )
);

alter table public.payment_transactions drop constraint if exists payment_transactions_requested_payment_kind_check;
alter table public.payment_transactions add constraint payment_transactions_requested_payment_kind_check check (
  requested_payment_kind is null or requested_payment_kind in ('MINIMUM','FULL','RESCHEDULE_DIFFERENCE')
);

create or replace function public.service_checkout_minimum_target(
  p_contract_value numeric,
  p_rule_type text,
  p_rule_value numeric
)
returns numeric
language plpgsql
immutable
set search_path = public, pg_temp
as $$
declare
  v_contract numeric(12,2) := round(greatest(coalesce(p_contract_value,0),0),2);
  v_value numeric(12,2) := round(greatest(coalesce(p_rule_value,0),0),2);
begin
  if p_rule_type not in ('PERCENT','FIXED') then
    raise exception using errcode='P0001',message='CHECKOUT_MINIMUM_PAYMENT_TYPE_INVALID';
  end if;
  if p_rule_type='PERCENT' and v_value>100 then
    raise exception using errcode='P0001',message='CHECKOUT_MINIMUM_PAYMENT_VALUE_INVALID';
  end if;
  if p_rule_type='PERCENT' then
    return round(v_contract*v_value/100,2);
  end if;
  return round(least(v_contract,v_value),2);
end;
$$;

revoke all on function public.service_checkout_minimum_target(numeric,text,numeric) from public, anon, authenticated;
grant execute on function public.service_checkout_minimum_target(numeric,text,numeric) to service_role;

create or replace function public.capture_appointment_commercial_configuration()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_type text;
  v_value numeric(12,2);
  v_legacy_percent numeric(5,2);
  v_target numeric(12,2);
begin
  if new.checkout_minimum_payment_type_snapshot is null
     or new.checkout_minimum_payment_value_snapshot is null then
    select
      coalesce(s.checkout_minimum_payment_type,'PERCENT'),
      coalesce(s.checkout_minimum_payment_value,s.confirmation_percentage,os.default_confirmation_percentage,50)
    into v_type,v_value
    from public.services s
    cross join public.operation_settings os
    where s.id=new.service_id and os.id=1;

    if v_type is null or v_value is null then
      raise exception using errcode='P0001',message='APPOINTMENT_CONFIRMATION_CONFIGURATION_MISSING';
    end if;
    new.checkout_minimum_payment_type_snapshot:=v_type;
    new.checkout_minimum_payment_value_snapshot:=v_value;
  end if;

  if new.confirmation_percentage_snapshot is null then
    if new.checkout_minimum_payment_type_snapshot='PERCENT' then
      v_legacy_percent:=new.checkout_minimum_payment_value_snapshot;
    elsif coalesce(new.commercial_value,0)>0 then
      v_target:=public.service_checkout_minimum_target(
        new.commercial_value,
        new.checkout_minimum_payment_type_snapshot,
        new.checkout_minimum_payment_value_snapshot
      );
      v_legacy_percent:=round(v_target*100/new.commercial_value,2);
    else
      v_legacy_percent:=100;
    end if;
    new.confirmation_percentage_snapshot:=least(greatest(v_legacy_percent,0),100);
  end if;
  return new;
end;
$$;

create or replace function public.prevent_appointment_confirmation_snapshot_change()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if old.confirmation_percentage_snapshot is not null
     and new.confirmation_percentage_snapshot is distinct from old.confirmation_percentage_snapshot then
    raise exception using errcode='42501',message='APPOINTMENT_CONFIRMATION_SNAPSHOT_IMMUTABLE';
  end if;
  if old.checkout_minimum_payment_type_snapshot is not null
     and new.checkout_minimum_payment_type_snapshot is distinct from old.checkout_minimum_payment_type_snapshot then
    raise exception using errcode='42501',message='APPOINTMENT_CHECKOUT_MINIMUM_SNAPSHOT_IMMUTABLE';
  end if;
  if old.checkout_minimum_payment_value_snapshot is not null
     and new.checkout_minimum_payment_value_snapshot is distinct from old.checkout_minimum_payment_value_snapshot then
    raise exception using errcode='42501',message='APPOINTMENT_CHECKOUT_MINIMUM_SNAPSHOT_IMMUTABLE';
  end if;
  return new;
end;
$$;

drop trigger if exists appointments_protect_confirmation_snapshot on public.appointments;
create trigger appointments_protect_confirmation_snapshot
before update of confirmation_percentage_snapshot, checkout_minimum_payment_type_snapshot, checkout_minimum_payment_value_snapshot
on public.appointments
for each row execute function public.prevent_appointment_confirmation_snapshot_change();

create or replace function public.customer_access_appointment_before_insert()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  a record;
  s public.services%rowtype;
  cfg public.customer_access_policy_settings%rowtype;
begin
  if new.origin<>'PUBLIC' or new.primary_customer_id is null then return new; end if;
  select * into a from public.customer_effective_access where customer_id=new.primary_customer_id;
  if coalesce(a.online_blocked,false) or coalesce(a.no_online_booking,false) then
    raise exception using errcode='P0001',message='ONLINE_BOOKING_NOT_AVAILABLE';
  end if;
  if coalesce(a.require_full_payment,false) then
    new.confirmation_percentage_snapshot:=100;
    new.checkout_minimum_payment_type_snapshot:='PERCENT';
    new.checkout_minimum_payment_value_snapshot:=100;
  end if;
  select * into s from public.services where id=new.service_id;
  if s.booking_product_type='FREE_VISIT' then
    if coalesce(a.no_free_visits,false) then raise exception using errcode='P0001',message='FREE_VISIT_NOT_AVAILABLE'; end if;
    select * into cfg from public.customer_access_policy_settings where id=1;
    new.free_visit_confirmation_deadline:=new.start_at-make_interval(hours=>cfg.free_visit_confirmation_hours_before);
  end if;
  return new;
end;
$$;

create or replace function public.service_admin_update_checkout_payment_audited(
  p_service_id uuid,
  p_payment_type text,
  p_payment_value numeric,
  p_admin_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_type text:=upper(btrim(coalesce(p_payment_type,'')));
  v_value numeric(12,2):=round(coalesce(p_payment_value,-1),2);
  v_before jsonb;
  v_after jsonb;
begin
  if not public.service_admin_has_permission(p_admin_id,'SERVICES_MANAGE')
     or not public.service_admin_has_permission(p_admin_id,'FINANCE_MANAGE') then
    raise exception using errcode='P0001',message='ADMIN_PERMISSION_DENIED';
  end if;
  if v_type not in ('PERCENT','FIXED') or v_value<0 or (v_type='PERCENT' and v_value>100) then
    raise exception using errcode='P0001',message='CHECKOUT_MINIMUM_PAYMENT_RULE_INVALID';
  end if;
  v_before:=public.service_admin_service_snapshot(p_service_id);
  if v_before is null then raise exception using errcode='P0001',message='SERVICE_NOT_FOUND'; end if;

  update public.services
  set checkout_minimum_payment_type=v_type,
      checkout_minimum_payment_value=v_value,
      confirmation_percentage=case when v_type='PERCENT' then v_value else null end,
      updated_at=now()
  where id=p_service_id;

  v_after:=public.service_admin_service_snapshot(p_service_id);
  if v_before is distinct from v_after then
    insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
    values(p_admin_id,'SERVICE',p_service_id,'SERVICE_CHECKOUT_MINIMUM_PAYMENT_UPDATED',v_before,v_after,'ADMIN');
  end if;
  return jsonb_build_object(
    'service_id',p_service_id,
    'checkout_minimum_payment_type',v_type,
    'checkout_minimum_payment_value',v_value
  );
end;
$$;

revoke all on function public.service_admin_update_checkout_payment_audited(uuid,text,numeric,uuid) from public, anon, authenticated;
grant execute on function public.service_admin_update_checkout_payment_audited(uuid,text,numeric,uuid) to service_role;

create or replace function public.service_admin_list_service_settings_v2()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(
    jsonb_agg(
      item || jsonb_build_object(
        'checkout_minimum_payment_type',s.checkout_minimum_payment_type,
        'checkout_minimum_payment_value',s.checkout_minimum_payment_value
      )
      order by ord
    ),
    '[]'::jsonb
  )
  from jsonb_array_elements(public.service_admin_list_service_settings()) with ordinality as base(item,ord)
  join public.services s on s.id=(item->>'id')::uuid;
$$;

revoke all on function public.service_admin_list_service_settings_v2() from public, anon, authenticated;
grant execute on function public.service_admin_list_service_settings_v2() to service_role;

create or replace function public.create_payment_intent_v2(
  p_appointment_id uuid,
  p_payment_kind text,
  p_method text,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_appointment public.appointments%rowtype;
  v_existing public.payment_transactions%rowtype;
  v_summary jsonb;
  v_balance numeric(12,2);
  v_settled_before numeric(12,2);
  v_rule_type text;
  v_rule_value numeric(12,2);
  v_minimum_target numeric(12,2);
  v_contract_amount numeric(12,2);
  v_discount_percent numeric(5,2);
  v_discount numeric(12,2);
  v_cash_amount numeric(12,2);
  v_amounts jsonb;
  v_transaction_id uuid;
  v_existing_kind text;
  v_requested_percentage numeric(5,2);
begin
  if p_payment_kind not in ('MINIMUM','FULL') then raise exception using errcode='P0001',message='INVALID_PAYMENT_KIND'; end if;
  if p_method not in ('PIX','CARD') then raise exception using errcode='P0001',message='PUBLIC_PAYMENT_METHOD_NOT_ALLOWED'; end if;
  if p_idempotency_key is null or btrim(p_idempotency_key)='' then raise exception using errcode='P0001',message='IDEMPOTENCY_KEY_REQUIRED'; end if;

  select * into v_existing from public.payment_transactions where idempotency_key=p_idempotency_key;
  if found then
    v_existing_kind:=coalesce(v_existing.requested_payment_kind,case when v_existing.requested_percentage=100 then 'FULL' else 'MINIMUM' end);
    if v_existing.appointment_id<>p_appointment_id or v_existing.method<>p_method or v_existing_kind<>p_payment_kind then
      raise exception using errcode='P0001',message='IDEMPOTENCY_KEY_CONFLICT';
    end if;
    return jsonb_build_object(
      'transaction_id',v_existing.id,'appointment_id',v_existing.appointment_id,'status',v_existing.status,
      'payment_kind',case when p_payment_kind='FULL' then 'FULL_BALANCE' else 'CONFIRMATION_MINIMUM' end,
      'payment_percentage',v_existing.requested_percentage,'contract_amount_settled',v_existing.contract_amount_settled,
      'payment_discount_amount',v_existing.payment_discount_amount,'cash_amount',v_existing.cash_amount,'method',v_existing.method,
      'idempotent_replay',true
    );
  end if;

  perform public.expire_due_appointment_holds();
  select * into v_appointment from public.appointments where id=p_appointment_id for update;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if;
  if v_appointment.status not in ('AWAITING_PAYMENT','CONFIRMED') then raise exception using errcode='P0001',message='APPOINTMENT_NOT_PAYABLE'; end if;
  if v_appointment.status='AWAITING_PAYMENT' and (v_appointment.hold_expires_at is null or v_appointment.hold_expires_at<=now()) then
    raise exception using errcode='P0001',message='PAYMENT_HOLD_EXPIRED';
  end if;

  v_rule_type:=coalesce(v_appointment.checkout_minimum_payment_type_snapshot,'PERCENT');
  v_rule_value:=coalesce(v_appointment.checkout_minimum_payment_value_snapshot,v_appointment.confirmation_percentage_snapshot);
  if v_rule_value is null then raise exception using errcode='P0001',message='APPOINTMENT_CONFIRMATION_SNAPSHOT_MISSING'; end if;

  select os.pix_discount_percent into v_discount_percent from public.operation_settings os where os.id=1;
  v_summary:=public.get_appointment_financial_summary(p_appointment_id);
  v_balance:=(v_summary->>'contract_balance')::numeric;
  v_settled_before:=(v_summary->>'contract_settled')::numeric;
  if v_balance<=0 then raise exception using errcode='P0001',message='APPOINTMENT_ALREADY_PAID'; end if;

  v_minimum_target:=public.service_checkout_minimum_target(v_appointment.commercial_value,v_rule_type,v_rule_value);
  if p_payment_kind='FULL' then
    v_contract_amount:=v_balance;
    v_requested_percentage:=100;
  else
    v_contract_amount:=round(greatest(v_minimum_target-v_settled_before,0),2);
    if v_contract_amount<=0 then raise exception using errcode='P0001',message='CONFIRMATION_PAYMENT_ALREADY_SATISFIED'; end if;
    v_contract_amount:=least(v_contract_amount,v_balance);
    v_requested_percentage:=case when v_rule_type='PERCENT' then v_rule_value else null end;
  end if;

  v_amounts:=public.service_calculate_payment_cash_amount(v_contract_amount,p_method,v_discount_percent);
  v_discount:=(v_amounts->>'payment_discount_amount')::numeric;
  v_cash_amount:=(v_amounts->>'cash_amount')::numeric;

  insert into public.payment_transactions(
    appointment_id,transaction_type,method,provider,status,contract_amount_settled,payment_discount_amount,cash_amount,
    idempotency_key,requested_percentage,requested_payment_kind
  ) values(
    p_appointment_id,'CHARGE',p_method,'MERCADO_PAGO','PENDING',v_contract_amount,v_discount,v_cash_amount,
    p_idempotency_key,v_requested_percentage,p_payment_kind
  ) returning id into v_transaction_id;

  if v_appointment.financial_status not in ('PARTIALLY_PAID','PAID','UNPAID_AUTHORIZED') then
    update public.appointments set financial_status='PENDING',updated_at=now() where id=p_appointment_id;
  end if;

  return jsonb_build_object(
    'transaction_id',v_transaction_id,'appointment_id',p_appointment_id,'status','PENDING',
    'payment_kind',case when p_payment_kind='FULL' then 'FULL_BALANCE' else 'CONFIRMATION_MINIMUM' end,
    'payment_percentage',v_requested_percentage,
    'minimum_payment_type',v_rule_type,'minimum_payment_value',v_rule_value,'confirmation_target_amount',v_minimum_target,
    'contract_settled_before',v_settled_before,'contract_balance_before',v_balance,
    'contract_amount_settled',v_contract_amount,'payment_discount_amount',v_discount,'cash_amount',v_cash_amount,
    'method',p_method,'provider','MERCADO_PAGO','idempotent_replay',false
  );
end;
$$;

revoke all on function public.create_payment_intent_v2(uuid,text,text,text) from public, anon, authenticated;
grant execute on function public.create_payment_intent_v2(uuid,text,text,text) to service_role;

create or replace function public.service_create_payment_intent_by_token(
  p_access_token text,
  p_payment_kind text,
  p_method text,
  p_request_key text
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_appointment_id uuid;
  v_appointment public.appointments%rowtype;
  v_idempotency_key text;
  v_result jsonb;
  v_transaction_id uuid;
  v_hash text;
  v_collection_id uuid;
  v_collection public.appointment_balance_collections%rowtype;
  v_existing public.payment_transactions%rowtype;
  v_balance numeric(12,2);
  v_discount_percent numeric(5,2);
  v_amounts jsonb;
  v_discount numeric(12,2);
  v_cash_amount numeric(12,2);
begin
  if p_payment_kind not in ('MINIMUM','FULL') then raise exception using errcode='P0001',message='INVALID_PAYMENT_KIND'; end if;
  if p_method not in ('PIX','CARD') then raise exception using errcode='P0001',message='PUBLIC_PAYMENT_METHOD_NOT_ALLOWED'; end if;
  if p_request_key is null or p_request_key !~ '^[A-Za-z0-9_-]{12,100}$' then raise exception using errcode='P0001',message='PAYMENT_REQUEST_KEY_INVALID'; end if;

  v_hash:=encode(digest(p_access_token,'sha256'),'hex');
  select appointment_id,balance_collection_id into v_appointment_id,v_collection_id
  from public.appointment_access_tokens
  where token_hash=v_hash and revoked_at is null and consumed_at is null and (expires_at is null or expires_at>now())
  order by created_at desc limit 1;
  if v_appointment_id is null then
    v_appointment_id:=public.resolve_appointment_access_token(p_access_token,'PAY');
  else
    perform public.resolve_appointment_access_token(p_access_token,'PAY');
  end if;
  select * into v_appointment from public.appointments where id=v_appointment_id;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if;
  v_idempotency_key:='public:'||v_appointment_id::text||':'||p_request_key;

  if v_collection_id is not null then
    perform public.expire_due_balance_collections();
    select * into v_collection from public.appointment_balance_collections where id=v_collection_id for update;
    if not found or v_collection.status<>'PENDING' or v_collection.expires_at<=public.balance_collection_clock() then
      raise exception using errcode='P0001',message='BALANCE_COLLECTION_INVALID_OR_EXPIRED';
    end if;
    if v_collection.appointment_id<>v_appointment_id then raise exception using errcode='P0001',message='BALANCE_COLLECTION_APPOINTMENT_MISMATCH'; end if;
    if v_appointment.status not in ('CONFIRMED','COMPLETED','NO_SHOW') then raise exception using errcode='P0001',message='BALANCE_COLLECTION_APPOINTMENT_NOT_PAYABLE'; end if;
    if coalesce(v_appointment.billing_mode_snapshot,'CHECKOUT')='INVOICE' then raise exception using errcode='P0001',message='BALANCE_COLLECTION_INVOICE_DENIED'; end if;
    if p_payment_kind<>'FULL' then raise exception using errcode='P0001',message='BALANCE_COLLECTION_FULL_PAYMENT_REQUIRED'; end if;

    select * into v_existing from public.payment_transactions where idempotency_key=v_idempotency_key;
    if found then
      if v_existing.appointment_id<>v_appointment_id or v_existing.method<>p_method
         or coalesce(v_existing.requested_payment_kind,case when v_existing.requested_percentage=100 then 'FULL' else null end)<>'FULL'
         or v_existing.balance_collection_id is distinct from v_collection_id then
        raise exception using errcode='P0001',message='IDEMPOTENCY_KEY_CONFLICT';
      end if;
      return jsonb_build_object('transaction_id',v_existing.id,'appointment_id',v_existing.appointment_id,'status',v_existing.status,
        'payment_kind','FULL_BALANCE','payment_percentage',v_existing.requested_percentage,'contract_amount_settled',v_existing.contract_amount_settled,
        'payment_discount_amount',v_existing.payment_discount_amount,'cash_amount',v_existing.cash_amount,'method',v_existing.method,
        'provider',v_existing.provider,'balance_collection_id',v_collection_id,'idempotent_replay',true);
    end if;

    perform 1 from public.appointments where id=v_appointment_id for update;
    v_balance:=round(greatest(coalesce((public.get_appointment_financial_summary(v_appointment_id)->>'contract_balance')::numeric,0),0),2);
    if v_balance<=0.005 then raise exception using errcode='P0001',message='APPOINTMENT_ALREADY_PAID'; end if;
    select coalesce(os.pix_discount_percent,0) into v_discount_percent from public.operation_settings os where os.id=1;
    if v_discount_percent is null then raise exception using errcode='P0001',message='PAYMENT_SETTINGS_LOAD_FAILED'; end if;
    v_amounts:=public.service_calculate_payment_cash_amount(v_balance,p_method,v_discount_percent);
    v_discount:=(v_amounts->>'payment_discount_amount')::numeric;
    v_cash_amount:=(v_amounts->>'cash_amount')::numeric;
    insert into public.payment_transactions(
      appointment_id,transaction_type,method,provider,status,contract_amount_settled,payment_discount_amount,cash_amount,
      idempotency_key,requested_percentage,requested_payment_kind,payment_purpose,balance_collection_id
    ) values(
      v_appointment_id,'CHARGE',p_method,'MERCADO_PAGO','PENDING',v_balance,v_discount,v_cash_amount,
      v_idempotency_key,100,'FULL','CONTRACT',v_collection_id
    ) returning id into v_transaction_id;
    return jsonb_build_object('transaction_id',v_transaction_id,'appointment_id',v_appointment_id,'status','PENDING',
      'payment_kind','FULL_BALANCE','payment_percentage',100,'contract_balance_before',v_balance,'contract_amount_settled',v_balance,
      'payment_discount_amount',v_discount,'cash_amount',v_cash_amount,'method',p_method,'provider','MERCADO_PAGO',
      'balance_collection_id',v_collection_id,'idempotent_replay',false);
  end if;

  v_result:=public.create_payment_intent_v2(v_appointment_id,p_payment_kind,p_method,v_idempotency_key);
  return v_result||jsonb_build_object('balance_collection_id',null);
end;
$$;

create or replace function public.service_get_public_payment_context(p_access_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_appointment_id uuid;
  v_appointment public.appointments%rowtype;
  v_customer public.customers%rowtype;
  v_summary jsonb;
  v_rule_type text;
  v_rule_value numeric(12,2);
  v_minimum_target numeric(12,2);
  v_settled numeric(12,2);
  v_minimum_due numeric(12,2);
  v_description text;
  v_provider_description text;
begin
  v_appointment_id:=public.resolve_appointment_access_token(p_access_token,'PAY');
  select * into v_appointment from public.appointments where id=v_appointment_id;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if;
  if v_appointment.status not in ('AWAITING_PAYMENT','CONFIRMED') then raise exception using errcode='P0001',message='APPOINTMENT_NOT_PAYABLE'; end if;
  if v_appointment.status='AWAITING_PAYMENT' and (v_appointment.hold_expires_at is null or v_appointment.hold_expires_at<=now()) then
    raise exception using errcode='P0001',message='PAYMENT_HOLD_EXPIRED';
  end if;
  select * into v_customer from public.customers where id=v_appointment.primary_customer_id;
  if v_customer.id is null then raise exception using errcode='P0001',message='CUSTOMER_NOT_FOUND'; end if;

  v_rule_type:=coalesce(v_appointment.checkout_minimum_payment_type_snapshot,'PERCENT');
  v_rule_value:=coalesce(v_appointment.checkout_minimum_payment_value_snapshot,v_appointment.confirmation_percentage_snapshot);
  if v_rule_value is null then raise exception using errcode='P0001',message='APPOINTMENT_CONFIRMATION_SNAPSHOT_MISSING'; end if;

  v_summary:=public.get_appointment_financial_summary(v_appointment.id);
  v_settled:=(v_summary->>'contract_settled')::numeric;
  v_minimum_target:=public.service_checkout_minimum_target(v_appointment.commercial_value,v_rule_type,v_rule_value);
  v_minimum_due:=round(greatest(v_minimum_target-v_settled,0),2);
  v_description:=public.appointment_commercial_description(v_appointment.id);
  v_provider_description:=public.appointment_provider_commercial_description(v_appointment.id);

  return jsonb_build_object(
    'appointment_id',v_appointment.id,'public_code',v_appointment.public_code,'appointment_status',v_appointment.status,
    'financial_status',v_appointment.financial_status,'service_name',v_appointment.service_name_snapshot,
    'commercial_description',v_description,'provider_commercial_description',v_provider_description,
    'contracted_minutes',coalesce(v_appointment.contracted_minutes,v_appointment.base_duration_snapshot,v_appointment.duration_minutes),
    'hold_expires_at',v_appointment.hold_expires_at,'commercial_value',coalesce(v_appointment.commercial_value,0),
    'contract_settled',v_settled,'contract_balance',(v_summary->>'contract_balance')::numeric,
    'minimum_payment_type',v_rule_type,'minimum_payment_value',v_rule_value,
    'confirmation_percentage',v_appointment.confirmation_percentage_snapshot,
    'confirmation_target_amount',v_minimum_target,'minimum_due_contract_amount',v_minimum_due,
    'minimum_available',v_minimum_due>0,'full_available',(v_summary->>'contract_balance')::numeric>0,
    'payer',jsonb_build_object('name',v_customer.name,'email',v_customer.email,'tax_id',regexp_replace(coalesce(v_customer.cpf_cnpj,''),'\D','','g'))
  );
end;
$$;

create or replace function public.service_get_public_payment_method_preview(p_access_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_context jsonb;
  v_minimum_contract numeric(12,2);
  v_full_contract numeric(12,2);
  v_discount_percent numeric(5,2);
  v_minimum_pix jsonb;
  v_full_pix jsonb;
begin
  v_context:=public.service_get_public_payment_context(p_access_token);
  v_minimum_contract:=round(coalesce((v_context->>'minimum_due_contract_amount')::numeric,0),2);
  v_full_contract:=round(coalesce((v_context->>'contract_balance')::numeric,0),2);
  select round(coalesce(os.pix_discount_percent,0),2) into v_discount_percent from public.operation_settings os where os.id=1;
  if v_discount_percent is null then raise exception using errcode='P0001',message='PAYMENT_SETTINGS_LOAD_FAILED'; end if;
  v_minimum_pix:=public.service_calculate_payment_cash_amount(v_minimum_contract,'PIX',v_discount_percent);
  v_full_pix:=public.service_calculate_payment_cash_amount(v_full_contract,'PIX',v_discount_percent);
  return jsonb_build_object(
    'pix_discount_percent',v_discount_percent,
    'minimum_payment_type',v_context->>'minimum_payment_type',
    'minimum_payment_value',(v_context->>'minimum_payment_value')::numeric,
    'confirmation_percentage',(v_context->>'confirmation_percentage')::numeric,
    'minimum_available',coalesce((v_context->>'minimum_available')::boolean,false),
    'full_available',coalesce((v_context->>'full_available')::boolean,false),
    'minimum_due_contract_amount',v_minimum_contract,
    'minimum_due_card_cash_amount',v_minimum_contract,
    'minimum_due_pix_cash_amount',(v_minimum_pix->>'cash_amount')::numeric,
    'full_due_contract_amount',v_full_contract,
    'full_due_card_cash_amount',v_full_contract,
    'full_due_pix_cash_amount',(v_full_pix->>'cash_amount')::numeric
  );
end;
$$;