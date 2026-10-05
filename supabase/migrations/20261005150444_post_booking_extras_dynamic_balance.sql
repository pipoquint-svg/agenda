-- Additive ledger: the reservation's original commercial_value remains untouched.
-- Reverting the feature can stop writes and ignore this table; no historic row is rewritten.
create table public.appointment_post_booking_extras (
  id uuid primary key default gen_random_uuid(),
  appointment_id uuid not null references public.appointments(id) on delete restrict,
  kind text not null check (kind in ('EXTRA_TIME','ASSISTANCE','SOCIAL_COVERAGE','CATALOG_EXTRA')),
  extra_id uuid references public.extras(id) on delete set null,
  name_snapshot text not null,
  quantity integer not null check (quantity > 0),
  unit text not null check (unit in ('30_MIN_BLOCK','HOUR','ITEM')),
  unit_price_snapshot numeric(14,6) not null check (unit_price_snapshot >= 0),
  total numeric(12,2) not null check (total >= 0),
  original_price_snapshot numeric(12,2),
  original_blocks_snapshot integer,
  admin_id uuid not null references public.admin_users(id),
  origin text not null default 'ADMIN_UI',
  idempotency_key uuid not null,
  created_at timestamptz not null default now(),
  unique (appointment_id,idempotency_key),
  check ((kind='EXTRA_TIME') = (unit='30_MIN_BLOCK')),
  check (kind not in ('ASSISTANCE','SOCIAL_COVERAGE') or unit='HOUR'),
  check (kind<>'EXTRA_TIME' or (original_price_snapshot is not null and original_blocks_snapshot>0))
);
create index appointment_post_booking_extras_appointment_idx
  on public.appointment_post_booking_extras(appointment_id,created_at);
alter table public.appointment_post_booking_extras enable row level security;
revoke all on public.appointment_post_booking_extras from public,anon,authenticated;
grant select,insert on public.appointment_post_booking_extras to service_role;

-- Catalog classification is explicit and extensible. Existing BlackSheep
-- catalog records are tagged by their current names, without changing prices.
alter table public.extras add column if not exists post_booking_kind text;
alter table public.extras add constraint extras_post_booking_kind_check
  check (post_booking_kind is null or post_booking_kind in ('ASSISTANCE','SOCIAL_COVERAGE','CATALOG_EXTRA'));
update public.extras set post_booking_kind='ASSISTANCE'
where post_booking_kind is null and lower(name) like 'assistência de iluminação%';
update public.extras set post_booking_kind='SOCIAL_COVERAGE'
where post_booking_kind is null and lower(name) like 'cobertura de bastidores%';

alter table public.appointment_balance_collections
  drop constraint if exists appointment_balance_collections_source_check;
alter table public.appointment_balance_collections
  add constraint appointment_balance_collections_source_check
  check (source in ('AUTO_START','ADMIN_REISSUE','POST_BOOKING_EXTRA'));
alter table public.appointment_balance_collections
  add column if not exists provider_refresh_pending boolean not null default false;

create or replace function public.appointment_post_booking_total(p_appointment_id uuid)
returns numeric(12,2) language sql stable set search_path=public as $$
  select coalesce(sum(total),0)::numeric(12,2)
  from public.appointment_post_booking_extras where appointment_id=p_appointment_id
$$;
revoke all on function public.appointment_post_booking_total(uuid) from public,anon,authenticated;
grant execute on function public.appointment_post_booking_total(uuid) to service_role;

create or replace function public.appointment_returnable_excess(p_appointment_id uuid)
returns numeric(12,2) language plpgsql stable set search_path=public as $$
declare v_a public.appointments%rowtype; v_funds numeric(12,2);
begin
  select * into v_a from public.appointments where id=p_appointment_id;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if;
  v_funds:=public.appointment_customer_funds_amount(p_appointment_id);
  return round(greatest(v_funds-coalesce(v_a.commercial_value,0)-
    public.appointment_post_booking_total(p_appointment_id),0),2);
end;
$$;

-- The original rental quote takes precedence. An old, rescheduled booking
-- without a recoverable original quote fails closed for EXTRA_TIME.
create or replace function public.appointment_original_time_quote(p_appointment_id uuid)
returns jsonb language plpgsql stable set search_path=public as $$
declare v_a public.appointments%rowtype; v_q jsonb; v_minutes integer; v_price numeric(12,2);
begin
  select * into v_a from public.appointments where id=p_appointment_id;
  if not found then raise exception 'APPOINTMENT_NOT_FOUND'; end if;
  select ch.quote_snapshot into v_q from public.checkout_holds ch
  where ch.promoted_appointment_id=p_appointment_id and ch.quote_snapshot is not null
  order by ch.created_at limit 1;
  if v_q is null then
    select pr.quote_snapshot into v_q from public.pre_reservations pr
    where pr.converted_appointment_id=p_appointment_id and pr.quote_snapshot is not null
    order by pr.created_at limit 1;
  end if;
  if v_q is not null then
    v_minutes:=coalesce((v_q->>'contracted_minutes')::integer,(v_q->>'core_duration_minutes')::integer);
    v_price:=round(coalesce((v_q->>'base_price')::numeric,0)
      + coalesce((v_q->>'day_time_adjustment')::numeric,0)
      + coalesce((v_q->>'people_adjustment')::numeric,0),2);
  else
    if exists (select 1 from public.appointment_policy_actions apa
      where apa.appointment_id=p_appointment_id and apa.action_type='RESCHEDULE' and apa.status='APPLIED') then
      raise exception 'ORIGINAL_PRICE_SNAPSHOT_MISSING';
    end if;
    v_minutes:=coalesce(v_a.contracted_minutes,v_a.base_duration_snapshot,v_a.duration_minutes);
    v_price:=round(coalesce(v_a.base_price_snapshot,0)+coalesce(v_a.variable_price_adjustment,0),2);
  end if;
  if v_minutes is null or v_minutes<30 or v_minutes%30<>0 or v_price<=0 then
    raise exception 'ORIGINAL_PRICE_SNAPSHOT_MISSING';
  end if;
  return jsonb_build_object('price',v_price,'blocks',v_minutes/30,
    'unit_price',round(v_price/(v_minutes/30),6));
end;
$$;
revoke all on function public.appointment_original_time_quote(uuid) from public,anon,authenticated;
grant execute on function public.appointment_original_time_quote(uuid) to service_role;

create or replace function public.service_admin_post_booking_extra_options(p_appointment_id uuid,p_admin_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_a public.appointments%rowtype; v_quote jsonb; v_balance numeric(12,2); v_extras jsonb; v_history jsonb;
begin
  if not public.service_admin_has_permission(p_admin_id,'AGENDA_MANAGE')
     or not public.service_admin_has_permission(p_admin_id,'FINANCE_MANAGE') then
    raise exception 'ADMIN_PERMISSION_DENIED';
  end if;
  select * into v_a from public.appointments where id=p_appointment_id;
  if not found then raise exception 'APPOINTMENT_NOT_FOUND'; end if;
  if (select operation_scope from public.services where id=v_a.service_id)<>'BLACKSHEEP' then
    raise exception 'APPOINTMENT_EXTRA_SCOPE_DENIED';
  end if;
  begin v_quote:=public.appointment_original_time_quote(p_appointment_id);
  exception when others then v_quote:=null; end;
  v_balance:=coalesce((public.get_appointment_financial_summary(p_appointment_id)->>'contract_balance')::numeric,0);
  select coalesce(jsonb_agg(jsonb_build_object('id',e.id,'name',e.name,'kind',e.post_booking_kind,
    'price',e.price) order by se.sort_order,e.name),'[]'::jsonb) into v_extras
  from public.service_extras se join public.extras e on e.id=se.extra_id
  where se.service_id=v_a.service_id and e.is_active and e.post_booking_kind is not null;
  select coalesce(jsonb_agg(jsonb_build_object('id',x.id,'kind',x.kind,'name',x.name_snapshot,
    'quantity',x.quantity,'unit',x.unit,'unit_price',x.unit_price_snapshot,
    'total',x.total,'admin_id',x.admin_id,
    'admin_name',(select au.display_name from public.admin_users au where au.id=x.admin_id),
    'created_at',x.created_at)
    order by x.created_at),'[]'::jsonb) into v_history
  from public.appointment_post_booking_extras x where x.appointment_id=p_appointment_id;
  return jsonb_build_object('appointment_id',p_appointment_id,'balance',v_balance,
    'time_quote',v_quote,'catalog_extras',v_extras,'history',v_history);
end;
$$;

create or replace function public.service_admin_add_post_booking_extra(
  p_appointment_id uuid,p_kind text,p_extra_id uuid,p_quantity integer,p_admin_id uuid,p_request_id uuid
) returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_a public.appointments%rowtype; v_e public.extras%rowtype; v_q jsonb;
  v_unit numeric(14,6); v_total numeric(12,2); v_name text; v_unit_name text;
  v_before numeric(12,2); v_after numeric(12,2); v_row public.appointment_post_booking_extras%rowtype;
  v_collection public.appointment_balance_collections%rowtype; v_existing jsonb;
  v_sequence integer; v_notice text; v_has_provider boolean;
begin
  if not public.service_admin_has_permission(p_admin_id,'AGENDA_MANAGE')
     or not public.service_admin_has_permission(p_admin_id,'FINANCE_MANAGE') then
    raise exception 'ADMIN_PERMISSION_DENIED';
  end if;
  if p_request_id is null or p_quantity is null or p_quantity<1 then
    raise exception 'APPOINTMENT_EXTRA_REQUEST_INVALID';
  end if;
  select * into v_a from public.appointments where id=p_appointment_id for update;
  if not found then raise exception 'APPOINTMENT_NOT_FOUND'; end if;
  select jsonb_build_object('id',x.id,'kind',x.kind,'quantity',x.quantity,
    'unit_price',x.unit_price_snapshot,'total',x.total,'balance_after',
    (public.get_appointment_financial_summary(p_appointment_id)->>'contract_balance')::numeric)
    into v_existing from public.appointment_post_booking_extras x
    where x.appointment_id=p_appointment_id and x.idempotency_key=p_request_id;
  if v_existing is not null then
    select * into v_collection from public.appointment_balance_collections
      where appointment_id=p_appointment_id order by sequence desc limit 1;
    return v_existing||jsonb_build_object('idempotent_replay',true,
      'collection_id',v_collection.id,
      'notification',case when v_collection.provider_refresh_pending then 'PROVIDER_REFRESH_PENDING'
        else 'LINK_UPDATED' end);
  end if;
  if (select operation_scope from public.services where id=v_a.service_id)<>'BLACKSHEEP'
     or v_a.status not in ('CONFIRMED','COMPLETED','NO_SHOW') then
    raise exception 'APPOINTMENT_EXTRA_NOT_ALLOWED';
  end if;
  if coalesce(v_a.billing_mode_snapshot,'CHECKOUT')='INVOICE' then
    raise exception 'APPOINTMENT_EXTRA_INVOICE_POLICY_UNSUPPORTED';
  end if;
  if p_kind='EXTRA_TIME' then
    if p_extra_id is not null then raise exception 'APPOINTMENT_EXTRA_KIND_INVALID'; end if;
    v_q:=public.appointment_original_time_quote(p_appointment_id);
    v_unit:=(v_q->>'unit_price')::numeric; v_total:=round((v_q->>'price')::numeric*p_quantity/(v_q->>'blocks')::numeric,2);
    v_name:='Tempo extra'; v_unit_name:='30_MIN_BLOCK';
  else
    select e.* into v_e from public.extras e join public.service_extras se on se.extra_id=e.id
    where e.id=p_extra_id and se.service_id=v_a.service_id and e.is_active and e.post_booking_kind=p_kind
    for share of e;
    if not found then raise exception 'APPOINTMENT_EXTRA_NOT_AVAILABLE'; end if;
    v_unit:=v_e.price; v_total:=round(v_unit*p_quantity,2);
    v_name:=v_e.name;
    v_unit_name:=case when p_kind in ('ASSISTANCE','SOCIAL_COVERAGE') then 'HOUR' else 'ITEM' end;
  end if;
  if v_total<=0 then raise exception 'APPOINTMENT_EXTRA_PRICE_INVALID'; end if;
  v_before:=coalesce((public.get_appointment_financial_summary(p_appointment_id)->>'contract_balance')::numeric,0);
  insert into public.appointment_post_booking_extras(
    appointment_id,kind,extra_id,name_snapshot,quantity,unit,unit_price_snapshot,total,
    original_price_snapshot,original_blocks_snapshot,admin_id,idempotency_key
  ) values(p_appointment_id,p_kind,p_extra_id,v_name,p_quantity,v_unit_name,v_unit,v_total,
    case when p_kind='EXTRA_TIME' then (v_q->>'price')::numeric else null end,
    case when p_kind='EXTRA_TIME' then (v_q->>'blocks')::integer else null end,
    p_admin_id,p_request_id) returning * into v_row;
  v_after:=coalesce((public.get_appointment_financial_summary(p_appointment_id)->>'contract_balance')::numeric,0);
  perform public.refresh_appointment_financial_status(p_appointment_id);
  perform public.expire_due_balance_collections();
  select * into v_collection from public.appointment_balance_collections
  where appointment_id=p_appointment_id order by sequence desc limit 1 for update;
  if found and v_collection.status='PENDING' and v_collection.expires_at>public.balance_collection_clock() then
    select exists(select 1 from public.payment_transactions pt where pt.balance_collection_id=v_collection.id
      and pt.status='PENDING' and pt.provider='MERCADO_PAGO') into v_has_provider;
    update public.appointment_balance_collections set provider_refresh_pending=v_has_provider,
      updated_at=now() where id=v_collection.id;
    v_notice:=case when v_has_provider then 'PROVIDER_REFRESH_PENDING' else 'LINK_UPDATED' end;
  else
    select coalesce(max(sequence),0)+1 into v_sequence from public.appointment_balance_collections
    where appointment_id=p_appointment_id;
    insert into public.appointment_balance_collections(
      appointment_id,sequence,source,status,amount_snapshot,issued_at,expires_at
    ) values(p_appointment_id,v_sequence,'POST_BOOKING_EXTRA','PENDING',v_after,
      public.balance_collection_clock(),public.balance_collection_clock()+interval '48 hours')
      returning * into v_collection;
    insert into public.integration_jobs(job_type,entity_type,entity_id,entity_version,payload_json,idempotency_key)
    values('RENTAL_BALANCE_DUE_EMAIL','BALANCE_COLLECTION',v_collection.id,v_sequence,
      jsonb_build_object('appointment_id',p_appointment_id,'source','POST_BOOKING_EXTRA'),
      'rental-balance-email:'||v_collection.id::text) on conflict(idempotency_key) do nothing;
    v_notice:='EMAIL_QUEUED';
  end if;
  insert into public.audit_logs(entity_type,entity_id,action,after_json,origin,admin_user_id,request_id)
  values('APPOINTMENT',p_appointment_id,'POST_BOOKING_EXTRA_ADDED',
    jsonb_build_object('extra_id',v_row.id,'kind',p_kind,'quantity',p_quantity,
      'unit_price',v_unit,'total',v_total,'balance_before',v_before,'balance_after',v_after,
      'collection_id',v_collection.id,'notification',v_notice),
    'ADMIN_UI',p_admin_id,p_request_id);
  return jsonb_build_object('id',v_row.id,'kind',p_kind,'quantity',p_quantity,'unit_price',v_unit,
    'total',v_total,'balance_before',v_before,'balance_after',v_after,
    'collection_id',v_collection.id,'notification',v_notice,'idempotent_replay',false);
end;
$$;
revoke all on function public.service_admin_post_booking_extra_options(uuid,uuid) from public,anon,authenticated;
revoke all on function public.service_admin_add_post_booking_extra(uuid,text,uuid,integer,uuid,uuid) from public,anon,authenticated;
grant execute on function public.service_admin_post_booking_extra_options(uuid,uuid) to service_role;
grant execute on function public.service_admin_add_post_booking_extra(uuid,text,uuid,integer,uuid,uuid) to service_role;

-- Financial totals are original contract plus the separate post-booking ledger.
create or replace function public.get_appointment_financial_summary(p_appointment_id uuid)
returns jsonb
language plpgsql
stable
set search_path=public
as $$
declare
  v_appointment public.appointments%rowtype;
  v_contract_payment numeric(12,2);
  v_contract_coverage numeric(12,2);
  v_cash numeric(12,2);
  v_balance_applied numeric(12,2);
  v_penalties numeric(12,2);
  v_funds numeric(12,2);
  v_customer_contract_cover numeric(12,2);
  v_excess numeric(12,2);
  v_pending integer;
  v_post_total numeric(12,2);
begin
  select * into v_appointment from public.appointments where id=p_appointment_id;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if;

  v_contract_payment:=public.appointment_net_contract_settled_amount(p_appointment_id);
  v_contract_coverage:=public.appointment_contract_coverage_amount(p_appointment_id);
  v_cash:=public.appointment_net_cash_received_amount(p_appointment_id);

  select coalesce(sum(amount),0)::numeric(12,2)
    into v_balance_applied
  from public.customer_balance_movements
  where appointment_id=p_appointment_id and movement_type='APPLY_TO_APPOINTMENT';

  select coalesce(sum(acs.penalty_retained),0)::numeric(12,2)
    into v_penalties
  from public.appointment_change_settlements acs
  join public.appointment_policy_actions apa on apa.id=acs.policy_action_id
  where acs.appointment_id=p_appointment_id
    and ((acs.action_type='RESCHEDULE' and apa.status='APPLIED') or acs.action_type='CANCEL');

  v_post_total:=public.appointment_post_booking_total(p_appointment_id);
  v_funds:=public.appointment_customer_funds_amount(p_appointment_id);
  v_customer_contract_cover:=round(least(v_funds,coalesce(v_appointment.commercial_value,0)+v_post_total),2);
  v_excess:=round(greatest(v_funds-coalesce(v_appointment.commercial_value,0)-v_post_total,0),2);

  select count(*)::integer into v_pending
  from public.payment_transactions
  where appointment_id=p_appointment_id
    and payment_purpose='CONTRACT'
    and transaction_type='CHARGE'
    and status='PENDING';

  return jsonb_build_object(
    'appointment_id',p_appointment_id,
    'commercial_value',coalesce(v_appointment.commercial_value,0),
    'post_booking_extras_total',v_post_total,
    'amount_due_total',coalesce(v_appointment.commercial_value,0)+v_post_total,
    'contract_payment_settled',v_contract_payment,
    'contract_settled',v_contract_coverage,
    'contract_coverage',v_contract_coverage,
    'cash_received',v_cash,
    'cash_contract_net',v_cash,
    'customer_balance_applied',v_balance_applied,
    'penalties_retained',v_penalties,
    'customer_funds_under_reservation',v_funds,
    'customer_cash_cover_of_contract',v_customer_contract_cover,
    'customer_excess_held',v_excess,
    'contract_balance',round(greatest(coalesce(v_appointment.commercial_value,0)+v_post_total-v_contract_coverage,0),2),
    'pending_charge_count',v_pending,
    'financial_status',v_appointment.financial_status
  );
end;
$$;

-- Status tracks the combined payable amount while commercial_value stays original.
-- Appointment financial status represents the reservation's current contract coverage.
-- A refund/reversal transaction must not force PARTIALLY_REFUNDED when other
-- approved funds still cover the commercial value in full. Transaction history
-- continues to preserve the refund/reversal itself.

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
  v_amount_due numeric(12,2);
begin
  select * into v_appointment
  from public.appointments
  where id=p_appointment_id
  for update;

  if not found then
    raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND';
  end if;

  select
    coalesce(sum(contract_amount_settled) filter(
      where payment_purpose='CONTRACT'
        and transaction_type='CHARGE'
        and status in('APPROVED','PARTIALLY_REFUNDED','REFUNDED')
    ),0)::numeric(12,2),
    coalesce(sum(cash_amount) filter(
      where payment_purpose='CONTRACT'
        and transaction_type='CHARGE'
        and status in('APPROVED','PARTIALLY_REFUNDED','REFUNDED')
    ),0)::numeric(12,2),
    coalesce(sum(contract_amount_settled) filter(
      where payment_purpose='CONTRACT'
        and transaction_type='REFUND'
        and status in('APPROVED','REFUNDED')
    ),0)::numeric(12,2),
    coalesce(sum(cash_amount) filter(
      where payment_purpose='CONTRACT'
        and transaction_type='REFUND'
        and status in('APPROVED','REFUNDED')
    ),0)::numeric(12,2),
    count(*) filter(
      where payment_purpose='CONTRACT'
        and transaction_type='CHARGE'
        and status='PENDING'
    )::integer
  into v_gross_contract,v_gross_cash,v_refunded_contract,v_refunded_cash,v_pending_count
  from public.payment_transactions
  where appointment_id=p_appointment_id;

  v_net_contract:=round(greatest(v_gross_contract-v_refunded_contract,0),2);
  v_net_cash:=round(greatest(v_gross_cash-v_refunded_cash,0),2);
  v_contract_coverage:=public.appointment_contract_coverage_amount(p_appointment_id);
  v_amount_due:=coalesce(v_appointment.commercial_value,0)+public.appointment_post_booking_total(p_appointment_id);

  -- A true full refund still wins when no customer cash remains.
  if v_refunded_cash>0 and v_gross_cash>0 and v_net_cash<=0.01 then
    v_new_status:='REFUNDED';
  -- If the contract remains fully covered after a refund/reversal, the reservation
  -- itself is paid. The refund remains visible in payment transaction history.
  elsif v_contract_coverage>=v_amount_due
    and v_amount_due>0 then
    v_new_status:='PAID';
  elsif v_refunded_cash>0 then
    v_new_status:='PARTIALLY_REFUNDED';
  elsif v_contract_coverage>0 then
    v_new_status:='PARTIALLY_PAID';
  elsif v_appointment.financial_status='UNPAID_AUTHORIZED' then
    v_new_status:='UNPAID_AUTHORIZED';
  elsif v_pending_count>0 then
    v_new_status:='PENDING';
  elsif v_appointment.status='EXPIRED' then
    v_new_status:='EXPIRED';
  else
    v_new_status:='NOT_STARTED';
  end if;

  update public.appointments
  set financial_status=v_new_status,updated_at=now()
  where id=p_appointment_id;

  return v_new_status;
end;
$function$;

-- New payment intents always read the current balance; stale retries fail.
create or replace function public.service_create_payment_intent_by_token(
  p_access_token text,
  p_payment_kind text,
  p_method text,
  p_request_key text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions'
as $function$
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
  v_payment_mode text;
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
  if coalesce(v_appointment.payment_provider_snapshot,'MERCADO_PAGO') <> 'MERCADO_PAGO' then
    raise exception using errcode='P0001',message='PAYMENT_PROVIDER_MISMATCH';
  end if;
  if v_appointment.billing_mode_snapshot='INVOICE' then
    raise exception using errcode='P0001',message='INVOICE_CHECKOUT_PAYMENT_NOT_REQUIRED';
  end if;

  v_idempotency_key:='public:'||v_appointment_id::text||':'||p_request_key;
  v_payment_mode:=coalesce(
    v_appointment.payment_mode_snapshot,
    (select s.payment_mode from public.services s where s.id=v_appointment.service_id),
    'MINIMUM_OR_FULL'
  );

  if v_collection_id is not null then
    if v_payment_mode='MINIMUM_ONLY' then
      raise exception using errcode='P0001',message='BALANCE_COLLECTION_POLICY_DENIED:Esta reserva permite online apenas o sinal. Quite o saldo presencialmente e registre a baixa manual na Gestão.';
    end if;

    perform public.expire_due_balance_collections();
    select * into v_collection from public.appointment_balance_collections where id=v_collection_id for update;
    if not found or v_collection.status<>'PENDING' or v_collection.expires_at<=public.balance_collection_clock() then
      raise exception using errcode='P0001',message='BALANCE_COLLECTION_INVALID_OR_EXPIRED';
    end if;
    if v_collection.appointment_id<>v_appointment_id then raise exception using errcode='P0001',message='BALANCE_COLLECTION_APPOINTMENT_MISMATCH'; end if;
    if v_appointment.status not in ('CONFIRMED','COMPLETED','NO_SHOW') then raise exception using errcode='P0001',message='BALANCE_COLLECTION_APPOINTMENT_NOT_PAYABLE'; end if;
    if coalesce(v_appointment.billing_mode_snapshot,'CHECKOUT')='INVOICE' then raise exception using errcode='P0001',message='BALANCE_COLLECTION_INVOICE_DENIED'; end if;
    if p_payment_kind<>'FULL' then raise exception using errcode='P0001',message='BALANCE_COLLECTION_FULL_PAYMENT_REQUIRED'; end if;

    if v_collection.provider_refresh_pending then
      raise exception using errcode='P0001',message='BALANCE_PROVIDER_REFRESH_PENDING';
    end if;
    perform 1 from public.appointments where id=v_appointment_id for update;
    v_balance:=round(greatest(coalesce((public.get_appointment_financial_summary(v_appointment_id)->>'contract_balance')::numeric,0),0),2);
    select * into v_existing from public.payment_transactions where idempotency_key=v_idempotency_key;
    if found then
      if v_existing.appointment_id<>v_appointment_id or v_existing.method<>p_method
         or coalesce(v_existing.requested_payment_kind,case when v_existing.requested_percentage=100 then 'FULL' else null end)<>'FULL'
         or v_existing.balance_collection_id is distinct from v_collection_id then
        raise exception using errcode='P0001',message='IDEMPOTENCY_KEY_CONFLICT';
      end if;
      if abs(v_existing.contract_amount_settled-v_balance)>0.005 then
        raise exception using errcode='P0001',message='BALANCE_PAYMENT_AMOUNT_CHANGED';
      end if;
      return jsonb_build_object(
        'transaction_id',v_existing.id,'appointment_id',v_existing.appointment_id,'status',v_existing.status,
        'payment_kind','FULL_BALANCE','payment_percentage',v_existing.requested_percentage,'contract_amount_settled',v_existing.contract_amount_settled,
        'payment_discount_amount',v_existing.payment_discount_amount,'cash_amount',v_existing.cash_amount,'method',v_existing.method,
        'provider',v_existing.provider,'balance_collection_id',v_collection_id,'idempotent_replay',true
      );
    end if;

    if v_balance<=0.005 then raise exception using errcode='P0001',message='APPOINTMENT_ALREADY_PAID'; end if;
    v_discount_percent:=public.service_resolve_appointment_pix_discount(v_appointment_id);
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

    return jsonb_build_object(
      'transaction_id',v_transaction_id,'appointment_id',v_appointment_id,'status','PENDING',
      'payment_kind','FULL_BALANCE','payment_percentage',100,'payment_mode',v_payment_mode,
      'contract_balance_before',v_balance,'contract_amount_settled',v_balance,
      'payment_discount_amount',v_discount,'cash_amount',v_cash_amount,'method',p_method,'provider','MERCADO_PAGO',
      'balance_collection_id',v_collection_id,'idempotent_replay',false
    );
  end if;

  v_result:=public.create_payment_intent_v2(v_appointment_id,p_payment_kind,p_method,v_idempotency_key);
  return v_result||jsonb_build_object('balance_collection_id',null);
end;
$function$;

-- Completed/no-show rentals remain payable through a valid collection PAY token.
create or replace function public.payment_context_before_invoice(p_access_token text)
returns jsonb
language plpgsql
security definer
set search_path to 'public','extensions'
as $function$
declare
  v_appointment_id uuid;
  v_appointment public.appointments%rowtype;
  v_service public.services%rowtype;
  v_customer public.customers%rowtype;
  v_summary jsonb;
  v_rule_type text;
  v_rule_value numeric(12,2);
  v_minimum_target numeric(12,2);
  v_settled numeric(12,2);
  v_minimum_due numeric(12,2);
  v_description text;
  v_provider_description text;
  v_payment_mode text;
  v_card_max_installments integer;
  v_pix_discount_percent numeric(5,2);
  v_policy_allows_minimum boolean;
  v_policy_allows_full boolean;
  v_is_balance_collection boolean;
  v_provider_refresh_pending boolean;
begin
  v_appointment_id:=public.resolve_appointment_access_token(p_access_token,'PAY');
  select * into v_appointment from public.appointments where id=v_appointment_id;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if;
  select exists(select 1 from public.appointment_access_tokens t
    join public.appointment_balance_collections c on c.id=t.balance_collection_id
    where t.token_hash=encode(digest(p_access_token,'sha256'),'hex')
      and t.scope='PAY' and t.revoked_at is null and c.status='PENDING'
      and c.expires_at>public.balance_collection_clock()) into v_is_balance_collection;
  select coalesce(bool_or(c.provider_refresh_pending),false) into v_provider_refresh_pending
  from public.appointment_access_tokens t join public.appointment_balance_collections c on c.id=t.balance_collection_id
  where t.token_hash=encode(digest(p_access_token,'sha256'),'hex') and t.scope='PAY';
  if v_appointment.status not in ('AWAITING_PAYMENT','CONFIRMED')
    and not (v_is_balance_collection and v_appointment.status in ('COMPLETED','NO_SHOW')) then
    raise exception using errcode='P0001',message='APPOINTMENT_NOT_PAYABLE';
  end if;
  if v_appointment.status='AWAITING_PAYMENT' and (v_appointment.hold_expires_at is null or v_appointment.hold_expires_at<=now()) then
    raise exception using errcode='P0001',message='PAYMENT_HOLD_EXPIRED';
  end if;

  select * into v_service from public.services where id=v_appointment.service_id;
  select * into v_customer from public.customers where id=v_appointment.primary_customer_id;
  if v_customer.id is null then raise exception using errcode='P0001',message='CUSTOMER_NOT_FOUND'; end if;

  v_rule_type:=coalesce(v_appointment.checkout_minimum_payment_type_snapshot,v_service.checkout_minimum_payment_type,'PERCENT');
  v_rule_value:=coalesce(v_appointment.checkout_minimum_payment_value_snapshot,v_service.checkout_minimum_payment_value,v_appointment.confirmation_percentage_snapshot,v_service.confirmation_percentage);
  if v_rule_value is null then raise exception using errcode='P0001',message='APPOINTMENT_CONFIRMATION_SNAPSHOT_MISSING'; end if;

  v_payment_mode:=coalesce(v_appointment.payment_mode_snapshot,v_service.payment_mode,'MINIMUM_OR_FULL');
  v_card_max_installments:=coalesce(v_appointment.card_max_installments_snapshot,v_service.card_max_installments,6);
  v_pix_discount_percent:=public.service_resolve_appointment_pix_discount(v_appointment.id);
  v_policy_allows_minimum:=v_payment_mode in ('MINIMUM_ONLY','MINIMUM_OR_FULL');
  v_policy_allows_full:=v_payment_mode in ('FULL_ONLY','MINIMUM_OR_FULL');

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
    'post_booking_extras_total',public.appointment_post_booking_total(v_appointment.id),
    'post_booking_extras',coalesce((select jsonb_agg(jsonb_build_object(
      'name',x.name_snapshot,'quantity',x.quantity,'total',x.total) order by x.created_at,x.id)
      from public.appointment_post_booking_extras x where x.appointment_id=v_appointment.id),'[]'::jsonb),
    'provider_refresh_pending',v_provider_refresh_pending,
    'contract_settled',v_settled,'contract_balance',(v_summary->>'contract_balance')::numeric,
    'minimum_payment_type',v_rule_type,'minimum_payment_value',v_rule_value,
    'confirmation_percentage',v_appointment.confirmation_percentage_snapshot,
    'confirmation_target_amount',v_minimum_target,'minimum_due_contract_amount',v_minimum_due,
    'minimum_available',v_minimum_due>0 and not v_is_balance_collection,'full_available',(v_summary->>'contract_balance')::numeric>0,
    'payment_mode',v_payment_mode,'policy_allows_minimum',v_policy_allows_minimum and not v_is_balance_collection,'policy_allows_full',v_policy_allows_full,
    'pix_discount_percent',v_pix_discount_percent,'card_max_installments',v_card_max_installments,
    'payer',jsonb_build_object('name',v_customer.name,'email',v_customer.email,'tax_id',regexp_replace(coalesce(v_customer.cpf_cnpj,''),'\\D','','g'))
  );
end;
$function$;

-- Management lists show the combined payable total alongside the current balance.
create or replace view public.appointment_open_balances as
select
  a.id appointment_id,a.public_code,a.primary_customer_id customer_id,c.name customer_name,
  a.service_id,a.service_name_snapshot service_name,s.operation_scope,
  a.status appointment_status,a.financial_status,a.billing_mode_snapshot,a.start_at,a.core_end_at,(fin.summary->>'amount_due_total')::numeric(12,2) total_value,
  coalesce((fin.summary->>'contract_settled')::numeric,0)::numeric(12,2) paid_value,
  coalesce((fin.summary->>'contract_balance')::numeric,0)::numeric(12,2) balance_value,
  bc.id active_collection_id,bc.sequence collection_sequence,bc.expires_at collection_expires_at,bc.status collection_status,
  coalesce((select count(*) from public.appointment_balance_collections r where r.appointment_id=a.id and r.source='ADMIN_REISSUE'),0)::integer reissue_count,
  greatest(2-coalesce((select count(*) from public.appointment_balance_collections r where r.appointment_id=a.id and r.source='ADMIN_REISSUE'),0),0)::integer reissues_remaining
from public.appointments a
join public.services s on s.id=a.service_id
left join public.customers c on c.id=a.primary_customer_id
cross join lateral(select public.get_appointment_financial_summary(a.id) summary) fin
left join lateral(
  select x.id,x.sequence,x.expires_at,x.status
  from public.appointment_balance_collections x
  where x.appointment_id=a.id order by x.sequence desc limit 1
) bc on true
where a.status in ('CONFIRMED','COMPLETED','NO_SHOW')
  and coalesce(a.billing_mode_snapshot,'CHECKOUT')<>'INVOICE'
  and coalesce((fin.summary->>'contract_balance')::numeric,0)>0.005;
