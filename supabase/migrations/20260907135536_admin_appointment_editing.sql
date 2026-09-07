create or replace function public.service_admin_get_appointment_edit_options(
  p_appointment_id uuid,
  p_admin_id uuid
) returns jsonb
language plpgsql
security definer
set search_path to 'public','pg_temp'
as $function$
declare
  v_appointment public.appointments%rowtype;
  v_extras jsonb;
begin
  if not public.service_admin_has_permission(p_admin_id,'AGENDA_MANAGE') then
    raise exception 'ADMIN_PERMISSION_DENIED';
  end if;

  select * into v_appointment
  from public.appointments
  where id=p_appointment_id;

  if not found then raise exception 'APPOINTMENT_NOT_FOUND'; end if;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id',e.id,
      'name',e.name,
      'description',e.description,
      'price',e.price,
      'duration_delta_minutes',e.duration_delta_minutes,
      'max_quantity',se.max_quantity,
      'existing_quantity',coalesce((
        select sum(ae.quantity)::integer
        from public.appointment_extras ae
        where ae.appointment_id=v_appointment.id and ae.extra_id=e.id
      ),0),
      'can_add_without_reschedule',
        coalesce(e.duration_delta_minutes,0)=0
        and coalesce(se.default_schedule_minutes,0)=0
        and not exists (
          select 1 from public.service_extra_schedule_rules sr
          where sr.service_id=se.service_id
            and sr.extra_id=se.extra_id
            and sr.is_active
            and coalesce(sr.schedule_minutes,0)<>0
        )
    ) order by se.sort_order,e.name
  ),'[]'::jsonb)
  into v_extras
  from public.service_extras se
  join public.extras e on e.id=se.extra_id
  where se.service_id=v_appointment.service_id
    and e.is_active;

  return jsonb_build_object(
    'appointment_id',v_appointment.id,
    'status',v_appointment.status,
    'financial_status',v_appointment.financial_status,
    'can_confirm_unpaid',v_appointment.status in ('EXPIRED','AWAITING_PAYMENT'),
    'extras',v_extras
  );
end;
$function$;

create or replace function public.service_admin_confirm_appointment_unpaid(
  p_appointment_id uuid,
  p_reason text,
  p_admin_id uuid
) returns jsonb
language plpgsql
security definer
set search_path to 'public','pg_temp'
as $function$
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

create or replace function public.service_admin_add_appointment_extra(
  p_appointment_id uuid,
  p_extra_id uuid,
  p_quantity integer,
  p_admin_id uuid
) returns jsonb
language plpgsql
security definer
set search_path to 'public','pg_temp'
as $function$
declare
  v_appointment public.appointments%rowtype;
  v_extra public.extras%rowtype;
  v_link public.service_extras%rowtype;
  v_existing_quantity integer:=0;
  v_total_price numeric(12,2);
  v_total_duration integer;
  v_row public.appointment_extras%rowtype;
  v_financial_status public.financial_status;
  v_new_extras_total numeric(12,2);
  v_new_commercial_value numeric(12,2);
begin
  if not public.service_admin_has_permission(p_admin_id,'AGENDA_MANAGE') then
    raise exception 'ADMIN_PERMISSION_DENIED';
  end if;
  if p_quantity is null or p_quantity<1 or p_quantity>99 then
    raise exception 'APPOINTMENT_EXTRA_QUANTITY_INVALID';
  end if;

  select * into v_appointment
  from public.appointments
  where id=p_appointment_id
  for update;
  if not found then raise exception 'APPOINTMENT_NOT_FOUND'; end if;

  if v_appointment.status not in ('CONFIRMED','AWAITING_PAYMENT') then
    raise exception 'APPOINTMENT_EXTRA_STATUS_NOT_ALLOWED';
  end if;

  if exists (select 1 from public.appointment_package_usage apu where apu.appointment_id=v_appointment.id) then
    raise exception 'APPOINTMENT_EXTRA_PACKAGE_REQUIRES_DECISION';
  end if;

  select se.* into v_link
  from public.service_extras se
  where se.service_id=v_appointment.service_id and se.extra_id=p_extra_id;
  if not found then raise exception 'APPOINTMENT_EXTRA_NOT_AVAILABLE'; end if;

  select * into v_extra
  from public.extras
  where id=p_extra_id and is_active
  for share;
  if not found then raise exception 'APPOINTMENT_EXTRA_NOT_AVAILABLE'; end if;

  select coalesce(sum(quantity),0)::integer into v_existing_quantity
  from public.appointment_extras
  where appointment_id=v_appointment.id and extra_id=v_extra.id;

  if v_existing_quantity+p_quantity>v_link.max_quantity then
    raise exception 'APPOINTMENT_EXTRA_MAX_QUANTITY_EXCEEDED';
  end if;

  if coalesce(v_extra.duration_delta_minutes,0)<>0
     or coalesce(v_link.default_schedule_minutes,0)<>0
     or exists (
       select 1 from public.service_extra_schedule_rules sr
       where sr.service_id=v_link.service_id
         and sr.extra_id=v_link.extra_id
         and sr.is_active
         and coalesce(sr.schedule_minutes,0)<>0
     ) then
    raise exception 'APPOINTMENT_EXTRA_DURATION_CHANGE_REQUIRES_RESCHEDULE';
  end if;

  v_total_price:=round(v_extra.price*p_quantity,2);
  v_total_duration:=v_extra.duration_delta_minutes*p_quantity;

  insert into public.appointment_extras(
    appointment_id,extra_id,name_snapshot,unit_price_snapshot,duration_delta_snapshot,
    quantity,total_price,total_duration_delta
  ) values (
    v_appointment.id,v_extra.id,v_extra.name,v_extra.price,v_extra.duration_delta_minutes,
    p_quantity,v_total_price,v_total_duration
  ) returning * into v_row;

  update public.appointments
  set extras_total=round(coalesce(extras_total,0)+v_total_price,2),
      commercial_value=round(coalesce(commercial_value,0)+v_total_price,2),
      version=version+1,
      updated_at=now()
  where id=v_appointment.id
  returning extras_total,commercial_value into v_new_extras_total,v_new_commercial_value;

  v_financial_status:=public.refresh_appointment_financial_status(v_appointment.id);

  insert into public.audit_logs(
    admin_user_id,entity_type,entity_id,action,before_json,after_json,origin
  ) values (
    p_admin_id,'APPOINTMENT',v_appointment.id,'APPOINTMENT_EXTRA_ADDED',
    jsonb_build_object('extras_total',v_appointment.extras_total,'commercial_value',v_appointment.commercial_value),
    jsonb_build_object(
      'extra_id',v_extra.id,'extra_name',v_extra.name,'quantity',p_quantity,'added_value',v_total_price,
      'extras_total',v_new_extras_total,'commercial_value',v_new_commercial_value,'financial_status',v_financial_status
    ),
    'ADMIN_UI'
  );

  return jsonb_build_object(
    'appointment_id',v_appointment.id,
    'extra',to_jsonb(v_row),
    'extras_total',v_new_extras_total,
    'commercial_value',v_new_commercial_value,
    'financial_status',v_financial_status
  );
end;
$function$;

revoke all on function public.service_admin_get_appointment_edit_options(uuid,uuid) from public,anon,authenticated;
revoke all on function public.service_admin_confirm_appointment_unpaid(uuid,text,uuid) from public,anon,authenticated;
revoke all on function public.service_admin_add_appointment_extra(uuid,uuid,integer,uuid) from public,anon,authenticated;
grant execute on function public.service_admin_get_appointment_edit_options(uuid,uuid) to service_role;
grant execute on function public.service_admin_confirm_appointment_unpaid(uuid,text,uuid) to service_role;
grant execute on function public.service_admin_add_appointment_extra(uuid,uuid,integer,uuid) to service_role;
