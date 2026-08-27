
-- BEGIN RC MIGRATION 20260824162000_contracted_minutes_transport.sql
-- Commercial duration boundary: blocks are selection/pricing internals only.
-- Legacy duration_blocks transport is accepted temporarily by booking-hold until 2026-09-07.

create table if not exists public.booking_contract_legacy_usage (
  id bigint generated always as identity primary key,
  occurred_at timestamptz not null default now(),
  surface text not null,
  booking_page_slug text,
  service_id uuid,
  duration_blocks integer,
  user_agent text,
  constraint booking_contract_legacy_usage_surface_check check (surface in ('BOOKING_HOLD'))
);

revoke all on table public.booking_contract_legacy_usage from public, anon, authenticated;
grant insert, select on table public.booking_contract_legacy_usage to service_role;
grant usage, select on sequence public.booking_contract_legacy_usage_id_seq to service_role;

create or replace function public.resolve_service_duration_blocks_from_minutes(
  p_service_id uuid,
  p_contracted_minutes integer
)
returns integer
language plpgsql
stable
set search_path = public
as $$
declare
  v_service public.services%rowtype;
  v_blocks integer;
begin
  if p_contracted_minutes is null or p_contracted_minutes <= 0 then
    raise exception using errcode='P0001', message='INVALID_CONTRACTED_MINUTES';
  end if;

  select * into v_service from public.services where id=p_service_id and is_active;
  if not found then raise exception using errcode='P0001', message='SERVICE_NOT_AVAILABLE'; end if;

  if v_service.duration_mode='FIXED' then
    if p_contracted_minutes <> v_service.base_duration_minutes then
      raise exception using errcode='P0001', message='INVALID_CONTRACTED_MINUTES';
    end if;
    return null;
  end if;

  if v_service.booking_block_minutes is null or v_service.booking_block_minutes <= 0 then
    raise exception using errcode='P0001', message='SERVICE_DURATION_CONFIGURATION_INVALID';
  end if;
  if p_contracted_minutes % v_service.booking_block_minutes <> 0 then
    raise exception using errcode='P0001', message='INVALID_CONTRACTED_MINUTES';
  end if;

  v_blocks := p_contracted_minutes / v_service.booking_block_minutes;
  if v_blocks < coalesce(v_service.minimum_booking_blocks,1)
     or (v_service.maximum_booking_blocks is not null and v_blocks > v_service.maximum_booking_blocks) then
    raise exception using errcode='P0001', message='INVALID_CONTRACTED_MINUTES';
  end if;
  return v_blocks;
end;
$$;

create or replace function public.public_quote_booking_minutes(
  p_booking_page_slug text,
  p_service_id uuid,
  p_service_employee_id uuid,
  p_contracted_minutes integer,
  p_extra_selections jsonb default '[]'::jsonb,
  p_people_count integer default 1
)
returns jsonb
language plpgsql
stable
security definer
set search_path=public
as $$
declare v_blocks integer;
begin
  v_blocks := public.resolve_service_duration_blocks_from_minutes(p_service_id,p_contracted_minutes);
  perform public.assert_public_booking_duration(
    p_booking_page_slug,p_service_id,p_service_employee_id,v_blocks,p_extra_selections,p_people_count
  );
  return (public.calculate_booking_quote_for_duration(
    p_service_id,p_service_employee_id,v_blocks,p_extra_selections,p_people_count,null,null
  ) - 'duration_blocks') || jsonb_build_object('contracted_minutes',p_contracted_minutes);
end;
$$;

create or replace function public.public_list_available_slots_minutes(
  p_booking_page_slug text,
  p_service_id uuid,
  p_service_employee_id uuid,
  p_contracted_minutes integer,
  p_extra_selections jsonb default '[]'::jsonb,
  p_people_count integer default 1,
  p_local_date date default current_date
)
returns table(
  slot_start_at timestamptz, slot_end_at timestamptz, core_start_at timestamptz, core_end_at timestamptz,
  pre_service_minutes integer, post_service_minutes integer, duration_minutes integer, commercial_value numeric
)
language plpgsql
stable
security definer
set search_path=public
as $$
declare v_blocks integer;
begin
  v_blocks := public.resolve_service_duration_blocks_from_minutes(p_service_id,p_contracted_minutes);
  perform public.assert_public_booking_duration(
    p_booking_page_slug,p_service_id,p_service_employee_id,v_blocks,p_extra_selections,p_people_count
  );
  return query select * from public.list_available_slots_for_duration(
    p_service_id,p_service_employee_id,v_blocks,p_extra_selections,p_people_count,p_local_date,null
  );
end;
$$;

create or replace function public.public_create_checkout_hold_tracked_minutes(
  p_booking_page_slug text,
  p_service_id uuid,
  p_service_employee_id uuid,
  p_contracted_minutes integer,
  p_extra_selections jsonb,
  p_people_count integer,
  p_requested_start_at timestamptz,
  p_attribution_json jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_blocks integer;
  v_result jsonb;
  v_hold_id uuid;
begin
  if p_attribution_json is not null and jsonb_typeof(p_attribution_json)<>'object' then
    raise exception using errcode='P0001',message='ATTRIBUTION_INVALID';
  end if;
  v_blocks := public.resolve_service_duration_blocks_from_minutes(p_service_id,p_contracted_minutes);
  v_result := public.public_create_checkout_hold_duration(
    p_booking_page_slug,p_service_id,p_service_employee_id,v_blocks,p_extra_selections,p_people_count,p_requested_start_at
  );
  v_hold_id := (v_result->>'checkout_hold_id')::uuid;
  update public.checkout_holds
  set attribution_json=public.sanitize_public_attribution(coalesce(p_attribution_json,'{}'::jsonb)), updated_at=now()
  where id=v_hold_id;
  return (v_result - 'duration_blocks') || jsonb_build_object('contracted_minutes',p_contracted_minutes);
end;
$$;

revoke all on function public.resolve_service_duration_blocks_from_minutes(uuid,integer) from public,anon,authenticated;
revoke all on function public.public_quote_booking_minutes(text,uuid,uuid,integer,jsonb,integer) from public;
revoke all on function public.public_list_available_slots_minutes(text,uuid,uuid,integer,jsonb,integer,date) from public;
revoke all on function public.public_create_checkout_hold_tracked_minutes(text,uuid,uuid,integer,jsonb,integer,timestamptz,jsonb) from public,anon,authenticated;
grant execute on function public.public_quote_booking_minutes(text,uuid,uuid,integer,jsonb,integer) to anon,authenticated;
grant execute on function public.public_list_available_slots_minutes(text,uuid,uuid,integer,jsonb,integer,date) to anon,authenticated;
grant execute on function public.public_create_checkout_hold_tracked_minutes(text,uuid,uuid,integer,jsonb,integer,timestamptz,jsonb) to service_role;
-- END RC MIGRATION 20260824162000_contracted_minutes_transport.sql

-- BEGIN RC MIGRATION 20260824163000_commercial_description.sql
-- One commercial description for checkout, payment provider, receipts and future transactional messages.

create or replace function public.format_contracted_duration(p_minutes integer)
returns text
language plpgsql
immutable
set search_path=public
as $$
declare v_hours integer; v_rest integer;
begin
  if p_minutes is null or p_minutes <= 0 then
    raise exception using errcode='P0001',message='INVALID_CONTRACTED_MINUTES';
  end if;
  v_hours := p_minutes / 60;
  v_rest := p_minutes % 60;
  if v_hours = 0 then return v_rest::text || ' min'; end if;
  if v_rest = 0 then return v_hours::text || 'h'; end if;
  return v_hours::text || 'h' || lpad(v_rest::text,2,'0');
end;
$$;

create or replace function public.build_commercial_description(
  p_service_name text,
  p_duration_mode text,
  p_contracted_minutes integer
)
returns text
language plpgsql
immutable
set search_path=public
as $$
declare v_product text;
begin
  if p_service_name is null or btrim(p_service_name)='' then
    raise exception using errcode='P0001',message='COMMERCIAL_PRODUCT_NAME_MISSING';
  end if;
  if p_duration_mode='BLOCKS' then
    v_product := 'Locação de estúdio fotográfico';
  else
    v_product := btrim(p_service_name);
  end if;
  return v_product || ', ' || public.format_contracted_duration(p_contracted_minutes);
end;
$$;

create or replace function public.build_provider_commercial_description(
  p_service_name text,
  p_duration_mode text,
  p_contracted_minutes integer
)
returns text
language plpgsql
immutable
set search_path=public
as $$
declare v_full text; v_fallback text;
begin
  v_full := public.build_commercial_description(p_service_name,p_duration_mode,p_contracted_minutes);
  if char_length(v_full) <= 150 then return v_full; end if;
  v_fallback := 'Atendimento fotográfico, ' || public.format_contracted_duration(p_contracted_minutes);
  if char_length(v_fallback) > 150 then
    raise exception using errcode='P0001',message='PROVIDER_COMMERCIAL_DESCRIPTION_TOO_LONG';
  end if;
  return v_fallback;
end;
$$;

create or replace function public.appointment_commercial_description(p_appointment_id uuid)
returns text
language plpgsql
stable
security definer
set search_path=public
as $$
declare v_appointment public.appointments%rowtype; v_mode text;
begin
  select * into v_appointment from public.appointments where id=p_appointment_id and deleted_at is null;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if;
  select duration_mode into v_mode from public.services where id=v_appointment.service_id;
  return public.build_commercial_description(
    v_appointment.service_name_snapshot,
    coalesce(v_mode,'FIXED'),
    coalesce(v_appointment.contracted_minutes,v_appointment.base_duration_snapshot,v_appointment.duration_minutes)
  );
end;
$$;

create or replace function public.appointment_provider_commercial_description(p_appointment_id uuid)
returns text
language plpgsql
stable
security definer
set search_path=public
as $$
declare v_appointment public.appointments%rowtype; v_mode text;
begin
  select * into v_appointment from public.appointments where id=p_appointment_id and deleted_at is null;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if;
  select duration_mode into v_mode from public.services where id=v_appointment.service_id;
  return public.build_provider_commercial_description(
    v_appointment.service_name_snapshot,
    coalesce(v_mode,'FIXED'),
    coalesce(v_appointment.contracted_minutes,v_appointment.base_duration_snapshot,v_appointment.duration_minutes)
  );
end;
$$;

create or replace function public.service_get_public_payment_context(p_access_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_appointment_id uuid;
  v_appointment public.appointments%rowtype;
  v_customer public.customers%rowtype;
  v_summary jsonb;
  v_confirmation_percentage numeric(5,2);
  v_confirmation_target numeric(12,2);
  v_settled numeric(12,2);
  v_minimum_due numeric(12,2);
  v_description text;
  v_provider_description text;
begin
  v_appointment_id := public.resolve_appointment_access_token(p_access_token,'PAY');
  select * into v_appointment from public.appointments where id=v_appointment_id;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if;
  if v_appointment.status not in ('AWAITING_PAYMENT','CONFIRMED') then raise exception using errcode='P0001',message='APPOINTMENT_NOT_PAYABLE'; end if;
  if v_appointment.status='AWAITING_PAYMENT' and (v_appointment.hold_expires_at is null or v_appointment.hold_expires_at<=now()) then
    raise exception using errcode='P0001',message='PAYMENT_HOLD_EXPIRED';
  end if;

  select * into v_customer from public.customers where id=v_appointment.primary_customer_id;
  if v_customer.id is null then raise exception using errcode='P0001',message='CUSTOMER_NOT_FOUND'; end if;

  v_confirmation_percentage := v_appointment.confirmation_percentage_snapshot;
  if v_confirmation_percentage is null then raise exception using errcode='P0001',message='APPOINTMENT_CONFIRMATION_SNAPSHOT_MISSING'; end if;

  v_summary := public.get_appointment_financial_summary(v_appointment.id);
  v_settled := (v_summary->>'contract_settled')::numeric;
  v_confirmation_target := round(coalesce(v_appointment.commercial_value,0)*v_confirmation_percentage/100,2);
  v_minimum_due := round(greatest(v_confirmation_target-v_settled,0),2);
  v_description := public.appointment_commercial_description(v_appointment.id);
  v_provider_description := public.appointment_provider_commercial_description(v_appointment.id);

  return jsonb_build_object(
    'appointment_id',v_appointment.id,'public_code',v_appointment.public_code,
    'appointment_status',v_appointment.status,'financial_status',v_appointment.financial_status,
    'service_name',v_appointment.service_name_snapshot,'commercial_description',v_description,
    'provider_commercial_description',v_provider_description,
    'contracted_minutes',coalesce(v_appointment.contracted_minutes,v_appointment.base_duration_snapshot,v_appointment.duration_minutes),
    'hold_expires_at',v_appointment.hold_expires_at,
    'commercial_value',coalesce(v_appointment.commercial_value,0),'contract_settled',v_settled,
    'contract_balance',(v_summary->>'contract_balance')::numeric,
    'confirmation_percentage',v_confirmation_percentage,'confirmation_target_amount',v_confirmation_target,
    'minimum_due_contract_amount',v_minimum_due,'minimum_available',v_minimum_due>0,
    'full_available',(v_summary->>'contract_balance')::numeric>0,
    'payer',jsonb_build_object('name',v_customer.name,'email',v_customer.email,
      'tax_id',regexp_replace(coalesce(v_customer.cpf_cnpj,''),'\D','','g'))
  );
end;
$$;

revoke all on function public.format_contracted_duration(integer) from public,anon,authenticated;
revoke all on function public.build_commercial_description(text,text,integer) from public,anon,authenticated;
revoke all on function public.build_provider_commercial_description(text,text,integer) from public,anon,authenticated;
revoke all on function public.appointment_commercial_description(uuid) from public,anon,authenticated;
revoke all on function public.appointment_provider_commercial_description(uuid) from public,anon,authenticated;
grant execute on function public.appointment_commercial_description(uuid) to service_role;
grant execute on function public.appointment_provider_commercial_description(uuid) to service_role;
-- END RC MIGRATION 20260824163000_commercial_description.sql

-- BEGIN RC MIGRATION 20260824170000_rental_balance_collection.sql
create table if not exists public.appointment_balance_collections (
  id uuid primary key default gen_random_uuid(),
  appointment_id uuid not null references public.appointments(id) on delete cascade,
  sequence integer not null,
  source text not null check (source in ('AUTO_START','ADMIN_REISSUE')),
  status text not null default 'ACTIVE' check (status in ('ACTIVE','PAID','EXPIRED','REVOKED')),
  amount_snapshot numeric(12,2) not null check (amount_snapshot > 0),
  issued_at timestamptz not null default now(),
  expires_at timestamptz not null,
  created_by_admin_id uuid references public.admin_users(id),
  email_delivered_at timestamptz,
  kommo_delivered_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (appointment_id, sequence),
  check (expires_at > issued_at),
  check ((source='ADMIN_REISSUE') = (created_by_admin_id is not null))
);

create index if not exists appointment_balance_collections_active_idx
  on public.appointment_balance_collections(appointment_id,status,expires_at);

alter table public.appointment_access_tokens
  add column if not exists balance_collection_id uuid references public.appointment_balance_collections(id) on delete set null;

create index if not exists appointment_access_tokens_balance_collection_idx
  on public.appointment_access_tokens(balance_collection_id)
  where balance_collection_id is not null;

alter table public.appointment_balance_collections enable row level security;
revoke all on public.appointment_balance_collections from public,anon,authenticated;
grant select,insert,update on public.appointment_balance_collections to service_role;

create or replace function public.balance_collection_clock()
returns timestamptz
language sql
stable
set search_path=public
as $$
  select coalesce(nullif(current_setting('agenda.test_now',true),'')::timestamptz,now())
$$;

create or replace function public.expire_due_balance_collections()
returns integer
language plpgsql
volatile
security definer
set search_path=public
as $$
declare v_now timestamptz:=public.balance_collection_clock(); v_count integer:=0;
begin
  update public.appointment_balance_collections
  set status='EXPIRED',updated_at=v_now
  where status='ACTIVE' and expires_at<=v_now;
  get diagnostics v_count=row_count;

  update public.appointment_access_tokens t
  set revoked_at=coalesce(t.revoked_at,v_now)
  from public.appointment_balance_collections c
  where t.balance_collection_id=c.id and c.status='EXPIRED' and t.revoked_at is null;
  return v_count;
end;
$$;

create or replace function public.create_balance_collection(
  p_appointment_id uuid,
  p_source text,
  p_admin_id uuid default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path=public
as $$
declare
  v_now timestamptz:=public.balance_collection_clock();
  v_appointment public.appointments%rowtype;
  v_scope text;
  v_balance numeric(12,2);
  v_sequence integer;
  v_collection public.appointment_balance_collections%rowtype;
begin
  if p_source not in ('AUTO_START','ADMIN_REISSUE') then
    raise exception using errcode='22023',message='BALANCE_COLLECTION_SOURCE_INVALID';
  end if;

  select * into v_appointment from public.appointments where id=p_appointment_id for update;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if;
  select operation_scope into v_scope from public.services where id=v_appointment.service_id;
  if v_scope<>'BLACKSHEEP' then raise exception using errcode='P0001',message='BALANCE_COLLECTION_SCOPE_DENIED'; end if;
  if v_appointment.status not in ('CONFIRMED','COMPLETED') then
    raise exception using errcode='P0001',message='BALANCE_COLLECTION_APPOINTMENT_NOT_ELIGIBLE';
  end if;
  if p_source='AUTO_START' and v_appointment.start_at>v_now then
    raise exception using errcode='P0001',message='BALANCE_COLLECTION_NOT_DUE';
  end if;

  if p_source='ADMIN_REISSUE' then
    if p_admin_id is null or not public.service_admin_has_permission(p_admin_id,'FINANCE_MANAGE') then
      raise exception using errcode='42501',message='ADMIN_PERMISSION_DENIED';
    end if;
  elsif p_admin_id is not null then
    raise exception using errcode='22023',message='BALANCE_COLLECTION_ADMIN_INVALID';
  end if;

  v_balance:=round(greatest(coalesce((public.get_appointment_financial_summary(p_appointment_id)->>'contract_balance')::numeric,0),0),2);
  if v_balance<=0 then raise exception using errcode='P0001',message='BALANCE_COLLECTION_NOT_DUE'; end if;

  if p_source='AUTO_START' and exists(select 1 from public.appointment_balance_collections where appointment_id=p_appointment_id) then
    raise exception using errcode='P0001',message='BALANCE_COLLECTION_ALREADY_CREATED';
  end if;

  if p_source='ADMIN_REISSUE' then
    update public.appointment_balance_collections set status='REVOKED',updated_at=v_now
    where appointment_id=p_appointment_id and status='ACTIVE';
    update public.appointment_access_tokens set revoked_at=coalesce(revoked_at,v_now)
    where appointment_id=p_appointment_id and balance_collection_id is not null and revoked_at is null;
  end if;

  select coalesce(max(sequence),0)+1 into v_sequence
  from public.appointment_balance_collections where appointment_id=p_appointment_id;

  insert into public.appointment_balance_collections(
    appointment_id,sequence,source,status,amount_snapshot,issued_at,expires_at,created_by_admin_id
  ) values(
    p_appointment_id,v_sequence,p_source,'ACTIVE',v_balance,v_now,v_now+interval '48 hours',p_admin_id
  ) returning * into v_collection;

  insert into public.integration_jobs(job_type,entity_type,entity_id,entity_version,payload_json,idempotency_key)
  values(
    'RENTAL_BALANCE_DUE_MESSAGE','BALANCE_COLLECTION',v_collection.id,v_sequence,
    jsonb_build_object('appointment_id',p_appointment_id,'source',p_source),
    'rental-balance-due-message:'||v_collection.id::text
  ) on conflict(idempotency_key) do nothing;

  insert into public.audit_logs(entity_type,entity_id,action,before_json,after_json,origin,admin_user_id)
  values(
    'APPOINTMENT',p_appointment_id,
    case when p_source='AUTO_START' then 'BALANCE_COLLECTION_AUTO_CREATED' else 'BALANCE_COLLECTION_REISSUED' end,
    null,
    jsonb_build_object('collection_id',v_collection.id,'sequence',v_sequence,'amount',v_balance,'expires_at',v_collection.expires_at),
    case when p_source='AUTO_START' then 'SYSTEM' else 'OPERATION' end,
    p_admin_id
  );

  return jsonb_build_object(
    'collection_id',v_collection.id,'appointment_id',p_appointment_id,'sequence',v_sequence,
    'status','ACTIVE','amount',v_balance,'issued_at',v_collection.issued_at,'expires_at',v_collection.expires_at
  );
end;
$$;

create or replace function public.enqueue_due_rental_balance_collections()
returns integer
language plpgsql
volatile
security definer
set search_path=public
as $$
declare v_now timestamptz:=public.balance_collection_clock(); v_row record; v_count integer:=0;
begin
  perform public.expire_due_balance_collections();
  for v_row in
    select a.id
    from public.appointments a
    join public.services s on s.id=a.service_id
    cross join lateral (select public.get_appointment_financial_summary(a.id) as summary) fin
    where s.operation_scope='BLACKSHEEP'
      and a.status='CONFIRMED'
      and a.start_at<=v_now
      and a.start_at>v_now-interval '24 hours'
      and coalesce((fin.summary->>'contract_balance')::numeric,0)>0.005
      and not exists(select 1 from public.appointment_balance_collections c where c.appointment_id=a.id)
    order by a.start_at,a.id
    for update of a skip locked
  loop
    begin
      perform public.create_balance_collection(v_row.id,'AUTO_START',null);
      v_count:=v_count+1;
    exception when others then
      if sqlerrm not in ('BALANCE_COLLECTION_ALREADY_CREATED','BALANCE_COLLECTION_NOT_DUE') then raise; end if;
    end;
  end loop;
  return v_count;
end;
$$;

create or replace function public.service_admin_reissue_balance_collection(p_appointment_id uuid,p_admin_id uuid)
returns jsonb
language sql
volatile
security definer
set search_path=public
as $$ select public.create_balance_collection(p_appointment_id,'ADMIN_REISSUE',p_admin_id) $$;

create or replace function public.service_verify_balance_collection_email(p_collection_id uuid,p_email text)
returns jsonb
language plpgsql
volatile
security definer
set search_path=public,extensions
as $$
declare
  v_now timestamptz:=public.balance_collection_clock();
  v_collection public.appointment_balance_collections%rowtype;
  v_customer_email text;
  v_raw_token text;
  v_hash text;
  v_token_id uuid;
  v_balance numeric(12,2);
begin
  perform public.expire_due_balance_collections();
  select * into v_collection from public.appointment_balance_collections where id=p_collection_id for update;
  if not found or v_collection.status<>'ACTIVE' or v_collection.expires_at<=v_now then
    raise exception using errcode='P0001',message='BALANCE_COLLECTION_INVALID_OR_EXPIRED';
  end if;

  select lower(trim(c.email)) into v_customer_email
  from public.appointments a join public.customers c on c.id=a.primary_customer_id
  where a.id=v_collection.appointment_id;
  if v_customer_email is null or lower(trim(coalesce(p_email,'')))<>v_customer_email then
    raise exception using errcode='P0001',message='BALANCE_COLLECTION_VERIFICATION_FAILED';
  end if;

  v_balance:=round(greatest(coalesce((public.get_appointment_financial_summary(v_collection.appointment_id)->>'contract_balance')::numeric,0),0),2);
  if v_balance<=0.005 then
    update public.appointment_balance_collections set status='PAID',updated_at=v_now where id=v_collection.id;
    raise exception using errcode='P0001',message='BALANCE_COLLECTION_ALREADY_PAID';
  end if;

  v_raw_token:=encode(gen_random_bytes(32),'hex');
  v_hash:=encode(digest(v_raw_token,'sha256'),'hex');
  insert into public.appointment_access_tokens(
    appointment_id,token_hash,scope,expires_at,delivery_channel,destination_masked,balance_collection_id
  ) values(
    v_collection.appointment_id,v_hash,'PAY',v_collection.expires_at,'INTERNAL','verified-email',v_collection.id
  ) returning id into v_token_id;

  return jsonb_build_object(
    'access_token',v_raw_token,'token_id',v_token_id,'appointment_id',v_collection.appointment_id,
    'collection_id',v_collection.id,'expires_at',v_collection.expires_at,'amount',v_balance
  );
end;
$$;

create or replace view public.appointment_open_balances as
select
  a.id appointment_id,a.public_code,a.primary_customer_id customer_id,c.name customer_name,
  a.service_id,a.service_name_snapshot service_name,s.operation_scope,
  a.status appointment_status,a.financial_status,a.start_at,a.commercial_value total_value,
  coalesce((fin.summary->>'contract_settled')::numeric,0)::numeric(12,2) paid_value,
  coalesce((fin.summary->>'contract_balance')::numeric,0)::numeric(12,2) balance_value,
  bc.id active_collection_id,bc.sequence collection_sequence,bc.expires_at collection_expires_at
from public.appointments a
join public.services s on s.id=a.service_id
left join public.customers c on c.id=a.primary_customer_id
cross join lateral (select public.get_appointment_financial_summary(a.id) as summary) fin
left join lateral(
  select x.id,x.sequence,x.expires_at from public.appointment_balance_collections x
  where x.appointment_id=a.id and x.status='ACTIVE' and x.expires_at>public.balance_collection_clock()
  order by x.sequence desc limit 1
) bc on true
where a.status in ('CONFIRMED','COMPLETED')
  and coalesce((fin.summary->>'contract_balance')::numeric,0)>0.005;

revoke all on public.appointment_open_balances from public,anon,authenticated;
grant select on public.appointment_open_balances to service_role;

revoke all on function public.balance_collection_clock() from public,anon,authenticated;
revoke all on function public.expire_due_balance_collections() from public,anon,authenticated;
revoke all on function public.create_balance_collection(uuid,text,uuid) from public,anon,authenticated;
revoke all on function public.enqueue_due_rental_balance_collections() from public,anon,authenticated;
revoke all on function public.service_admin_reissue_balance_collection(uuid,uuid) from public,anon,authenticated;
revoke all on function public.service_verify_balance_collection_email(uuid,text) from public,anon,authenticated;

grant execute on function public.expire_due_balance_collections() to service_role;
grant execute on function public.enqueue_due_rental_balance_collections() to service_role;
grant execute on function public.service_admin_reissue_balance_collection(uuid,uuid) to service_role;
grant execute on function public.service_verify_balance_collection_email(uuid,text) to service_role;
-- END RC MIGRATION 20260824170000_rental_balance_collection.sql

-- BEGIN RC MIGRATION 20260824170100_balance_collection_delivery_channels.sql
create or replace function public.create_balance_collection(
  p_appointment_id uuid,
  p_source text,
  p_admin_id uuid default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path=public
as $$
declare
  v_now timestamptz:=public.balance_collection_clock();
  v_appointment public.appointments%rowtype;
  v_scope text;
  v_balance numeric(12,2);
  v_sequence integer;
  v_collection public.appointment_balance_collections%rowtype;
begin
  if p_source not in ('AUTO_START','ADMIN_REISSUE') then raise exception using errcode='22023',message='BALANCE_COLLECTION_SOURCE_INVALID'; end if;
  select * into v_appointment from public.appointments where id=p_appointment_id for update;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if;
  select operation_scope into v_scope from public.services where id=v_appointment.service_id;
  if v_scope<>'BLACKSHEEP' then raise exception using errcode='P0001',message='BALANCE_COLLECTION_SCOPE_DENIED'; end if;
  if v_appointment.status not in ('CONFIRMED','COMPLETED') then raise exception using errcode='P0001',message='BALANCE_COLLECTION_APPOINTMENT_NOT_ELIGIBLE'; end if;
  if p_source='AUTO_START' and v_appointment.start_at>v_now then raise exception using errcode='P0001',message='BALANCE_COLLECTION_NOT_DUE'; end if;

  if p_source='ADMIN_REISSUE' then
    if p_admin_id is null or not public.service_admin_has_permission(p_admin_id,'FINANCE_MANAGE') then raise exception using errcode='42501',message='ADMIN_PERMISSION_DENIED'; end if;
  elsif p_admin_id is not null then
    raise exception using errcode='22023',message='BALANCE_COLLECTION_ADMIN_INVALID';
  end if;

  v_balance:=round(greatest(coalesce((public.get_appointment_financial_summary(p_appointment_id)->>'contract_balance')::numeric,0),0),2);
  if v_balance<=0 then raise exception using errcode='P0001',message='BALANCE_COLLECTION_NOT_DUE'; end if;
  if p_source='AUTO_START' and exists(select 1 from public.appointment_balance_collections where appointment_id=p_appointment_id) then
    raise exception using errcode='P0001',message='BALANCE_COLLECTION_ALREADY_CREATED';
  end if;

  if p_source='ADMIN_REISSUE' then
    update public.appointment_balance_collections set status='REVOKED',updated_at=v_now where appointment_id=p_appointment_id and status='ACTIVE';
    update public.appointment_access_tokens set revoked_at=coalesce(revoked_at,v_now)
    where appointment_id=p_appointment_id and balance_collection_id is not null and revoked_at is null;
  end if;

  select coalesce(max(sequence),0)+1 into v_sequence from public.appointment_balance_collections where appointment_id=p_appointment_id;
  insert into public.appointment_balance_collections(appointment_id,sequence,source,status,amount_snapshot,issued_at,expires_at,created_by_admin_id)
  values(p_appointment_id,v_sequence,p_source,'ACTIVE',v_balance,v_now,v_now+interval '48 hours',p_admin_id)
  returning * into v_collection;

  insert into public.integration_jobs(job_type,entity_type,entity_id,entity_version,payload_json,idempotency_key)
  values
    ('RENTAL_BALANCE_DUE_EMAIL','BALANCE_COLLECTION',v_collection.id,v_sequence,jsonb_build_object('appointment_id',p_appointment_id,'source',p_source),'rental-balance-email:'||v_collection.id::text),
    ('RENTAL_BALANCE_DUE_KOMMO','BALANCE_COLLECTION',v_collection.id,v_sequence,jsonb_build_object('appointment_id',p_appointment_id,'source',p_source),'rental-balance-kommo:'||v_collection.id::text)
  on conflict(idempotency_key) do nothing;

  insert into public.audit_logs(entity_type,entity_id,action,before_json,after_json,origin,admin_user_id)
  values('APPOINTMENT',p_appointment_id,
    case when p_source='AUTO_START' then 'BALANCE_COLLECTION_AUTO_CREATED' else 'BALANCE_COLLECTION_REISSUED' end,
    null,jsonb_build_object('collection_id',v_collection.id,'sequence',v_sequence,'amount',v_balance,'expires_at',v_collection.expires_at),
    case when p_source='AUTO_START' then 'SYSTEM' else 'OPERATION' end,p_admin_id);

  return jsonb_build_object('collection_id',v_collection.id,'appointment_id',p_appointment_id,'sequence',v_sequence,'status','ACTIVE','amount',v_balance,'issued_at',v_collection.issued_at,'expires_at',v_collection.expires_at);
end;
$$;
-- END RC MIGRATION 20260824170100_balance_collection_delivery_channels.sql

-- BEGIN RC MIGRATION 20260824170150_prepare_balance_collection_views.sql
-- CREATE OR REPLACE VIEW cannot insert columns in the middle of an existing view.
-- The hardening migration intentionally expands the projection, so drop the V1 view
-- before recreating it with the authoritative finance columns.
drop view if exists public.appointment_open_balances;
-- END RC MIGRATION 20260824170150_prepare_balance_collection_views.sql
