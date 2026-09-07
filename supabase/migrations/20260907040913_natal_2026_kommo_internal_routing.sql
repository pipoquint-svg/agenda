create or replace function public.get_kommo_appointment_desired_state(p_appointment_id uuid)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_appointment public.appointments%rowtype;
  v_service public.services%rowtype;
  v_customer public.customers%rowtype;
  v_settings public.kommo_integration_settings%rowtype;
  v_stage_key text;
  v_financial jsonb;
  v_extras jsonb;
  v_is_natal_2026 boolean := false;
begin
  select * into v_appointment from public.appointments where id=p_appointment_id;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if;

  select * into v_service from public.services where id=v_appointment.service_id;
  if not found then raise exception using errcode='P0001',message='SERVICE_NOT_FOUND'; end if;

  v_is_natal_2026 := v_service.id = any(array[
    '111e9ae4-f626-4a71-a209-e20166310ee5'::uuid,
    '5268a4a1-2cfb-4c23-a89a-3cf1853fb637'::uuid,
    'ca578a83-2188-4be7-93c8-532c77801b0c'::uuid,
    '0afb550a-3cd0-46f5-9482-b1e219bf9d2e'::uuid
  ]);

  select * into v_settings from public.kommo_integration_settings where id=1;
  if v_settings.id is null
     or not coalesce(v_settings.enabled,false)
     or (v_service.operation_scope is distinct from 'BLACKSHEEP' and not v_is_natal_2026) then
    return jsonb_build_object(
      'appointment_id',v_appointment.id,
      'version',v_appointment.version,
      'eligible',false,
      'reason',case
        when v_service.operation_scope is distinct from 'BLACKSHEEP' and not v_is_natal_2026 then 'OPERATION_SCOPE_NOT_BLACKSHEEP'
        else 'KOMMO_DISABLED'
      end
    );
  end if;

  if v_appointment.primary_customer_id is not null then
    select * into v_customer from public.customers where id=v_appointment.primary_customer_id;
  end if;

  v_stage_key:=case v_appointment.status
    when 'AWAITING_PAYMENT' then 'AWAITING_PAYMENT'
    when 'CONFIRMED' then 'CONFIRMED'
    when 'COMPLETED' then 'COMPLETED'
    when 'CANCELLED' then 'CANCELLED'
    when 'NO_SHOW' then 'NO_SHOW'
    when 'EXPIRED' then 'EXPIRED'
    else 'CREATED'
  end;

  v_financial:=public.get_appointment_financial_summary(v_appointment.id);

  select coalesce(jsonb_agg(jsonb_build_object(
    'id',ae.id,
    'extra_id',ae.extra_id,
    'name',ae.name_snapshot,
    'quantity',ae.quantity,
    'unit_price',ae.unit_price_snapshot,
    'total_price',ae.total_price
  ) order by ae.created_at,ae.id),'[]'::jsonb)
  into v_extras
  from public.appointment_extras ae
  where ae.appointment_id=v_appointment.id;

  return jsonb_build_object(
    'appointment_id',v_appointment.id,
    'public_code',v_appointment.public_code,
    'version',v_appointment.version,
    'eligible',true,
    'operation_scope',v_service.operation_scope,
    'appointment_status',v_appointment.status,
    'financial_status',v_appointment.financial_status,
    'stage_key',v_stage_key,
    'service',jsonb_build_object('id',v_service.id,'name',coalesce(nullif(v_appointment.service_name_snapshot,''),v_service.name)),
    'schedule',jsonb_build_object('start_at',v_appointment.start_at,'end_at',v_appointment.end_at),
    'commercial_value',v_appointment.commercial_value,
    'financial',v_financial,
    'extras',v_extras,
    'customer',case when v_customer.id is null then null else jsonb_build_object(
      'id',v_customer.id,
      'name',v_customer.name,
      'email',v_customer.email,
      'phone',v_customer.phone
    ) end
  );
end;
$function$;

create or replace function public.enqueue_kommo_appointment_sync(p_appointment_id uuid, p_event_kind text default 'UPDATED'::text)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_appointment public.appointments%rowtype;
  v_scope text;
  v_enabled boolean;
  v_job_id uuid;
  v_event text:=upper(btrim(coalesce(p_event_kind,'UPDATED')));
  v_projection jsonb;
  v_fingerprint text;
  v_is_natal_2026 boolean := false;
begin
  if v_event not in ('CREATED','UPDATED','RESCHEDULED','STATUS_CHANGED','FINANCIAL_CHANGED','EXTRAS_CHANGED') then
    raise exception using errcode='P0001',message='KOMMO_EVENT_KIND_INVALID';
  end if;

  select * into v_appointment from public.appointments where id=p_appointment_id;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if;

  select operation_scope into v_scope from public.services where id=v_appointment.service_id;
  v_is_natal_2026 := v_appointment.service_id = any(array[
    '111e9ae4-f626-4a71-a209-e20166310ee5'::uuid,
    '5268a4a1-2cfb-4c23-a89a-3cf1853fb637'::uuid,
    'ca578a83-2188-4be7-93c8-532c77801b0c'::uuid,
    '0afb550a-3cd0-46f5-9482-b1e219bf9d2e'::uuid
  ]);

  select enabled into v_enabled from public.kommo_integration_settings where id=1;
  if not coalesce(v_enabled,false)
     or (v_scope is distinct from 'BLACKSHEEP' and not v_is_natal_2026) then
    return null;
  end if;

  v_projection:=public.get_kommo_appointment_desired_state(v_appointment.id);
  if coalesce((v_projection->>'eligible')::boolean,false) is not true then return null; end if;
  v_fingerprint:=md5(v_projection::text||':'||v_event);

  insert into public.integration_jobs(
    job_type,entity_type,entity_id,entity_version,payload_json,status,run_after,idempotency_key
  ) values(
    'KOMMO_APPOINTMENT_SYNC','APPOINTMENT',v_appointment.id,v_appointment.version,
    jsonb_build_object('event_kind',v_event,'projection_fingerprint',v_fingerprint),
    'PENDING',now(),
    'kommo-appointment:'||v_appointment.id::text||':v'||v_appointment.version::text||':'||lower(v_event)||':'||v_fingerprint
  )
  on conflict(idempotency_key) do update set updated_at=public.integration_jobs.updated_at
  returning id into v_job_id;

  return v_job_id;
end;
$function$;

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
    end if;
  elsif tg_op = 'UPDATE' then
    if new.status = 'CONFIRMED'
       and new.financial_status = 'PAID'
       and (old.status is distinct from new.status or old.financial_status is distinct from new.financial_status) then
      perform public.enqueue_kommo_appointment_sync(new.id,'STATUS_CHANGED');
    end if;
  end if;

  return new;
end;
$function$;

drop trigger if exists trg_natal_2026_kommo_sync on public.appointments;
create trigger trg_natal_2026_kommo_sync
after insert or update of status, financial_status on public.appointments
for each row execute function public.enqueue_natal_2026_kommo_sync_trigger();