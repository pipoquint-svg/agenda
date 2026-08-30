alter table public.operation_settings
  add column if not exists prebook_hold_minutes integer not null default 2880;

update public.operation_settings
set prebook_hold_minutes = 2880,
    updated_at = now()
where id = 1 and prebook_hold_minutes is distinct from 2880;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.operation_settings'::regclass
      and conname = 'operation_settings_prebook_hold_minutes_check'
  ) then
    alter table public.operation_settings
      add constraint operation_settings_prebook_hold_minutes_check
      check (prebook_hold_minutes > 0);
  end if;
end $$;

comment on column public.operation_settings.prebook_hold_minutes is
  'Prazo global da pre-reserva em minutos. Regra operacional atual: 2880 minutos (48 horas).';

create or replace function public.normalize_customer_prebook_terms_global()
returns trigger
language plpgsql
set search_path to 'public'
as $$
declare
  v_minutes integer;
begin
  select prebook_hold_minutes into v_minutes
  from public.operation_settings where id = 1;
  if v_minutes is null or v_minutes <= 0 then
    raise exception using errcode='P0001', message='PREBOOK_GLOBAL_HOLD_INVALID';
  end if;
  new.prebook_hold_minutes := v_minutes;
  new.requires_manual_confirmation := false;
  if coalesce(new.can_prebook,false) and upper(coalesce(new.billing_mode,'')) <> 'CHECKOUT' then
    raise exception using errcode='P0001', message='PREBOOK_REQUIRES_CHECKOUT';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_customer_prebook_terms_global on public.customer_commercial_terms;
create trigger trg_customer_prebook_terms_global
before insert or update on public.customer_commercial_terms
for each row execute function public.normalize_customer_prebook_terms_global();

update public.customer_commercial_terms
set prebook_hold_minutes = (select prebook_hold_minutes from public.operation_settings where id=1),
    requires_manual_confirmation = false,
    updated_at = now()
where prebook_hold_minutes is distinct from (select prebook_hold_minutes from public.operation_settings where id=1)
   or requires_manual_confirmation is distinct from false;

alter function public.promote_checkout_hold(uuid,uuid,text,uuid[],jsonb,jsonb,inet,text)
  rename to promote_checkout_hold_standard;

create function public.promote_checkout_hold(
  p_checkout_hold_id uuid,
  p_customer_id uuid,
  p_coupon_code text default null,
  p_term_version_ids uuid[] default '{}'::uuid[],
  p_participants jsonb default '[]'::jsonb,
  p_answers jsonb default '[]'::jsonb,
  p_acceptance_ip inet default null,
  p_acceptance_user_agent text default null
)
returns jsonb
language plpgsql
set search_path to 'public','extensions'
as $$
declare
  v_hold public.checkout_holds%rowtype;
  v_terms public.customer_commercial_terms%rowtype;
  v_is_prebook boolean := false;
  v_active_count integer := 0;
  v_result jsonb;
  v_appointment_id uuid;
  v_pre_reservation_id uuid;
  v_employee_id uuid;
  v_global_minutes integer;
  v_deadline timestamptz;
  v_raw_token text;
  v_token_hash text;
  v_extras_snapshot jsonb := '[]'::jsonb;
begin
  select * into v_hold
  from public.checkout_holds
  where id = p_checkout_hold_id;
  if not found then
    raise exception using errcode='P0001',message='CHECKOUT_HOLD_NOT_FOUND';
  end if;

  select * into v_terms
  from public.customer_commercial_terms
  where customer_id = p_customer_id
    and is_active = true;

  if found
     and coalesce(v_terms.can_prebook,false)
     and v_terms.billing_mode = 'CHECKOUT'
     and exists (
       select 1 from public.customer_prebook_authorized_services cas
       where cas.customer_id = p_customer_id
         and cas.service_id = v_hold.service_id
     ) then
    v_is_prebook := true;
    perform public.service_expire_pre_reservations();
    select count(*)::integer into v_active_count
    from public.pre_reservations pr
    where pr.customer_id = p_customer_id
      and pr.status = 'ACTIVE'
      and pr.expires_at > now();
    if v_active_count >= v_terms.max_active_prebooks then
      raise exception using errcode='P0001',message='MAX_ACTIVE_PREBOOKS_REACHED';
    end if;
  end if;

  v_result := public.promote_checkout_hold_standard(
    p_checkout_hold_id,
    p_customer_id,
    p_coupon_code,
    p_term_version_ids,
    p_participants,
    p_answers,
    p_acceptance_ip,
    p_acceptance_user_agent
  );

  if not v_is_prebook or coalesce(v_result->>'status','') <> 'AWAITING_PAYMENT' then
    return v_result || jsonb_build_object('pre_reservation',false);
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
    p_customer_id,v_hold.service_id,v_employee_id,v_hold.service_employee_id,v_result->>'public_code',
    v_hold.requested_start_at,v_hold.requested_end_at,v_hold.core_start_at,v_hold.core_end_at,
    v_hold.pre_service_minutes,v_hold.post_service_minutes,
    v_deadline,'ACTIVE',v_hold.people_count,v_hold.extra_selections,v_extras_snapshot,v_hold.duration_blocks,
    v_hold.contracted_minutes,v_hold.duration_minutes,v_hold.schedule_profile,v_hold.quote_snapshot,v_hold.resource_ids,
    'CHECKOUT',null,false,v_appointment_id,null
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
      'confirmation','PAYMENT_ONLY'
    ),'PUBLIC'
  );

  return v_result || jsonb_build_object(
    'pre_reservation',true,
    'pre_reservation_id',v_pre_reservation_id,
    'pre_reservation_expires_at',v_deadline,
    'hold_expires_at',v_deadline
  );
end;
$$;

create or replace function public.enforce_pre_reservation_payment_confirmation()
returns trigger
language plpgsql
set search_path to 'public'
as $$
begin
  if old.status = 'ACTIVE'
     and new.status = 'CONFIRMED'
     and coalesce(new.billing_mode_snapshot,'CHECKOUT') = 'CHECKOUT'
     and (
       new.converted_appointment_id is null
       or not exists (
         select 1 from public.appointments a
         where a.id = new.converted_appointment_id
           and a.status = 'CONFIRMED'
       )
     ) then
    raise exception using errcode='P0001',message='PRE_RESERVATION_PAYMENT_REQUIRED';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_pre_reservation_payment_confirmation on public.pre_reservations;
create trigger trg_pre_reservation_payment_confirmation
before update of status on public.pre_reservations
for each row execute function public.enforce_pre_reservation_payment_confirmation();

create or replace function public.sync_pre_reservation_from_appointment_status()
returns trigger
language plpgsql
set search_path to 'public'
as $$
declare
  v_now timestamptz := now();
begin
  if new.source_pre_reservation_id is null or new.status is not distinct from old.status then
    return new;
  end if;

  if new.status = 'CONFIRMED' then
    update public.pre_reservations
    set status='CONFIRMED',confirmed_at=coalesce(confirmed_at,new.confirmed_at,v_now),updated_at=v_now
    where id=new.source_pre_reservation_id and status='ACTIVE';
    update public.pre_reservation_access_tokens
    set revoked_at=coalesce(revoked_at,v_now)
    where pre_reservation_id=new.source_pre_reservation_id and revoked_at is null;
  elsif new.status = 'EXPIRED' then
    update public.pre_reservations
    set status='EXPIRED',released_at=coalesce(released_at,v_now),release_reason=coalesce(release_reason,'EXPIRED'),updated_at=v_now
    where id=new.source_pre_reservation_id and status='ACTIVE';
    update public.pre_reservation_access_tokens
    set revoked_at=coalesce(revoked_at,v_now)
    where pre_reservation_id=new.source_pre_reservation_id and revoked_at is null;
  elsif new.status = 'CANCELLED' then
    update public.pre_reservations
    set status='CANCELLED',cancelled_at=coalesce(cancelled_at,v_now),release_reason=coalesce(release_reason,'APPOINTMENT_CANCELLED'),updated_at=v_now
    where id=new.source_pre_reservation_id and status='ACTIVE';
    update public.pre_reservation_access_tokens
    set revoked_at=coalesce(revoked_at,v_now)
    where pre_reservation_id=new.source_pre_reservation_id and revoked_at is null;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_sync_pre_reservation_from_appointment_status on public.appointments;
create trigger trg_sync_pre_reservation_from_appointment_status
after update of status on public.appointments
for each row
when (new.source_pre_reservation_id is not null)
execute function public.sync_pre_reservation_from_appointment_status();

create or replace function public.service_expire_pre_reservations()
returns integer
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_pr public.pre_reservations%rowtype;
  v_after jsonb;
  v_count integer:=0;
  v_released_at timestamptz;
  v_appointment_expired integer:=0;
begin
  v_appointment_expired := public.expire_due_appointment_holds();
  for v_pr in
    select pr.* from public.pre_reservations pr
    where pr.status='ACTIVE' and pr.expires_at<=now()
    for update skip locked
  loop
    v_released_at:=now();
    update public.resource_allocations
    set status='EXPIRED',updated_at=v_released_at
    where pre_reservation_id=v_pr.id and status='HELD';
    update public.pre_reservation_access_tokens
    set revoked_at=coalesce(revoked_at,v_released_at)
    where pre_reservation_id=v_pr.id and revoked_at is null;
    update public.pre_reservations
    set status='EXPIRED',released_at=v_released_at,released_by_admin_id=null,
        release_reason='EXPIRED',updated_at=v_released_at
    where id=v_pr.id
    returning to_jsonb(pre_reservations.*) into v_after;
    insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,before_json,after_json,origin)
    values(null,'PRE_RESERVATION',v_pr.id,'PRE_RESERVATION_EXPIRED',to_jsonb(v_pr),v_after,'SYSTEM');
    v_count:=v_count+1;
  end loop;
  return v_count + coalesce(v_appointment_expired,0);
end;
$$;

comment on column public.customer_commercial_terms.prebook_hold_minutes is
  'LEGADO: normalizado automaticamente para operation_settings.prebook_hold_minutes; não é mais configurável por cliente.';
comment on column public.customer_commercial_terms.requires_manual_confirmation is
  'LEGADO: pré-reservas CHECKOUT são confirmadas exclusivamente por pagamento aprovado; valor normalizado para false.';