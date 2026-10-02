CREATE OR REPLACE FUNCTION public.create_checkout_hold_for_reschedule(
  p_appointment_id uuid,
  p_requested_start_at timestamp with time zone
)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_appointment public.appointments%rowtype;
  v_timezone text;
  v_requested_local_date date;
  v_slot record;
  v_quote jsonb;
  v_resource_ids uuid[]:='{}'::uuid[];
  v_hold_id uuid;
  v_raw_token text;
  v_token_hash text;
  v_selection_hash text;
  v_extras jsonb;
  v_expires_at timestamptz;
  v_hold_minutes integer;
  v_contracted_minutes integer;
  v_range record;
  v_own_ranges tstzmultirange;
  v_delta_ranges tstzmultirange;
  v_segment tstzrange;
  v_coupon_code text;
begin
  perform public.expire_due_checkout_holds();

  select * into v_appointment
  from public.appointments
  where id=p_appointment_id
    and deleted_at is null;

  if not found or v_appointment.status<>'CONFIRMED' then
    raise exception using errcode='P0001',message='APPOINTMENT_NOT_RESCHEDULABLE';
  end if;

  -- Remarcação preserva a condição comercial já contratada.
  -- O cupom não é uma nova utilização; apenas reaplicamos o snapshot/código
  -- original para recalcular o mesmo contrato no novo horário.
  select ad.code_snapshot
  into v_coupon_code
  from public.appointment_discounts ad
  where ad.appointment_id=p_appointment_id
    and nullif(btrim(ad.code_snapshot),'') is not null
  order by ad.created_at desc
  limit 1;

  select coalesce(
    jsonb_agg(
      jsonb_build_object('extra_id',ae.extra_id,'quantity',ae.quantity)
      order by ae.extra_id
    ),
    '[]'::jsonb
  )
  into v_extras
  from public.appointment_extras ae
  where ae.appointment_id=p_appointment_id
    and ae.extra_id is not null;

  v_contracted_minutes:=public.resolve_service_contracted_minutes(
    v_appointment.service_id,
    v_appointment.duration_blocks
  );

  select timezone into v_timezone
  from public.operation_settings
  where id=1;

  v_requested_local_date:=(p_requested_start_at at time zone v_timezone)::date;

  select s.* into v_slot
  from (
    select *
    from public.list_available_slots_for_duration_reschedule_base(
      v_appointment.service_id,
      v_appointment.service_employee_id,
      v_appointment.duration_blocks,
      v_extras,
      v_appointment.people_count,
      v_requested_local_date,
      v_coupon_code,
      p_appointment_id
    )
    union all
    select *
    from public.list_available_slots_for_duration_reschedule_base(
      v_appointment.service_id,
      v_appointment.service_employee_id,
      v_appointment.duration_blocks,
      v_extras,
      v_appointment.people_count,
      v_requested_local_date+1,
      v_coupon_code,
      p_appointment_id
    )
  ) s
  where s.slot_start_at=p_requested_start_at
    and s.core_start_at is distinct from v_appointment.core_start_at
    and not exists(
      select 1
      from public.calculate_booking_resource_ranges_for_duration(
        v_appointment.service_id,
        v_extras,
        s.core_start_at,
        v_appointment.duration_blocks
      ) rr
      where not public.google_resource_sync_is_ready(rr.resource_id,600)
    )
  order by s.core_start_at
  limit 1;

  if not found then
    raise exception using errcode='P0001',message='SLOT_NO_LONGER_AVAILABLE';
  end if;

  v_quote:=public.calculate_booking_quote_for_duration(
    v_appointment.service_id,
    v_appointment.service_employee_id,
    v_appointment.duration_blocks,
    v_extras,
    v_appointment.people_count,
    v_slot.core_start_at,
    v_coupon_code
  );

  select coalesce(array_agg(r.resource_id order by r.resource_id),'{}'::uuid[])
  into v_resource_ids
  from public.calculate_booking_resource_ranges_for_duration(
    v_appointment.service_id,
    v_extras,
    v_slot.core_start_at,
    v_appointment.duration_blocks
  ) r;

  if coalesce(array_length(v_resource_ids,1),0)=0 then
    raise exception using errcode='P0001',message='SERVICE_HAS_NO_REQUIRED_RESOURCES';
  end if;

  select coalesce(s.checkout_hold_minutes,os.checkout_hold_minutes)
  into v_hold_minutes
  from public.services s
  cross join public.operation_settings os
  where s.id=v_appointment.service_id
    and os.id=1;

  v_expires_at:=coalesce(
    nullif(current_setting('agenda.test_now',true),'')::timestamptz,
    now()
  )+make_interval(mins=>v_hold_minutes);

  v_raw_token:=encode(gen_random_bytes(32),'hex');
  v_token_hash:=encode(digest(v_raw_token,'sha256'),'hex');
  v_selection_hash:=md5(concat_ws(
    '|',
    'RESCHEDULE',
    p_appointment_id::text,
    v_appointment.service_id::text,
    v_appointment.service_employee_id::text,
    coalesce(v_appointment.duration_blocks::text,'FIXED'),
    v_extras::text,
    v_appointment.people_count::text,
    v_slot.slot_start_at::text,
    v_slot.core_start_at::text,
    v_quote->>'pricing_version'
  ));

  insert into public.checkout_holds(
    public_token_hash,
    service_id,
    service_employee_id,
    selection_hash,
    people_count,
    requested_start_at,
    requested_end_at,
    core_start_at,
    core_end_at,
    pre_service_minutes,
    post_service_minutes,
    schedule_profile,
    status,
    expires_at,
    extra_selections,
    commercial_value,
    pricing_version,
    duration_minutes,
    resource_ids,
    duration_blocks,
    contracted_minutes,
    primary_customer_id
  ) values(
    v_token_hash,
    v_appointment.service_id,
    v_appointment.service_employee_id,
    v_selection_hash,
    v_appointment.people_count,
    v_slot.slot_start_at,
    v_slot.slot_end_at,
    v_slot.core_start_at,
    v_slot.core_end_at,
    v_slot.pre_service_minutes,
    v_slot.post_service_minutes,
    v_quote->'schedule_profile',
    'ACTIVE',
    v_expires_at,
    v_extras,
    (v_quote->>'commercial_value')::numeric(12,2),
    v_quote->>'pricing_version',
    v_slot.duration_minutes,
    v_resource_ids,
    v_appointment.duration_blocks,
    v_contracted_minutes,
    v_appointment.primary_customer_id
  )
  returning id into v_hold_id;

  begin
    for v_range in
      select *
      from public.calculate_booking_resource_ranges_for_duration(
        v_appointment.service_id,
        v_extras,
        v_slot.core_start_at,
        v_appointment.duration_blocks
      )
    loop
      select coalesce(range_agg(ra.occupied_range),'{}'::tstzmultirange)
      into v_own_ranges
      from public.resource_allocations ra
      where ra.appointment_id=p_appointment_id
        and ra.resource_id=v_range.resource_id
        and ra.allocation_type='APPOINTMENT'
        and ra.status in ('HELD','AWAITING_PAYMENT','CONFIRMED','BLOCKED');

      v_delta_ranges:=tstzmultirange(v_range.occupied_range)-v_own_ranges;

      for v_segment in
        select unnest(v_delta_ranges)
      loop
        insert into public.resource_allocations(
          resource_id,
          checkout_hold_id,
          allocation_type,
          status,
          occupied_range
        )
        values(
          v_range.resource_id,
          v_hold_id,
          'CHECKOUT_HOLD',
          'HELD',
          v_segment
        );
      end loop;
    end loop;
  exception
    when exclusion_violation then
      update public.checkout_holds
      set status='INVALIDATED',updated_at=now()
      where id=v_hold_id;
      raise exception using errcode='P0001',message='SLOT_NO_LONGER_AVAILABLE';
  end;

  return jsonb_build_object(
    'checkout_hold_token',v_raw_token,
    'checkout_hold_id',v_hold_id,
    'status','ACTIVE',
    'expires_at',v_expires_at,
    'slot_start_at',v_slot.slot_start_at,
    'slot_end_at',v_slot.slot_end_at,
    'core_start_at',v_slot.core_start_at,
    'core_end_at',v_slot.core_end_at,
    'pre_service_minutes',v_slot.pre_service_minutes,
    'post_service_minutes',v_slot.post_service_minutes,
    'commercial_value',(v_quote->>'commercial_value')::numeric(12,2),
    'duration_minutes',v_slot.duration_minutes,
    'duration_blocks',v_appointment.duration_blocks,
    'contracted_minutes',v_contracted_minutes,
    'pricing_version',v_quote->>'pricing_version'
  );
end;
$function$;
