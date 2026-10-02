create or replace function public.create_checkout_hold_for_reschedule(
  p_appointment_id uuid,
  p_requested_start_at timestamp with time zone
)
returns jsonb
language plpgsql
set search_path to 'public', 'extensions'
as $function$
declare
  v_appointment public.appointments%rowtype;
  v_discount public.appointment_discounts%rowtype;
  v_has_discount boolean := false;
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
  v_pre_discount_value numeric(12,2) := 0;
  v_discount_amount numeric(12,2) := 0;
  v_commercial_value numeric(12,2) := 0;
  v_pricing_version text;
begin
  perform public.expire_due_checkout_holds();

  select * into v_appointment
  from public.appointments
  where id=p_appointment_id and deleted_at is null;

  if not found or v_appointment.status<>'CONFIRMED' then
    raise exception using errcode='P0001',message='APPOINTMENT_NOT_RESCHEDULABLE';
  end if;

  select *
    into v_discount
  from public.appointment_discounts
  where appointment_id=p_appointment_id;
  v_has_discount := found;

  select coalesce(
    jsonb_agg(
      jsonb_build_object('extra_id',ae.extra_id,'quantity',ae.quantity)
      order by ae.extra_id
    ),
    '[]'::jsonb
  )
  into v_extras
  from public.appointment_extras ae
  where ae.appointment_id=p_appointment_id and ae.extra_id is not null;

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
      null,
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
      null,
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

  -- A remarcação parte do preço atual do novo horário, mas preserva a
  -- condição comercial já contratada. O desconto é um snapshot da reserva,
  -- não uma nova aplicação/consumo de cupom.
  v_quote:=public.calculate_booking_quote_for_duration(
    v_appointment.service_id,
    v_appointment.service_employee_id,
    v_appointment.duration_blocks,
    v_extras,
    v_appointment.people_count,
    v_slot.core_start_at,
    null
  );

  v_pre_discount_value:=round(
    greatest(coalesce((v_quote->>'commercial_value')::numeric,0),0),
    2
  );
  v_commercial_value:=v_pre_discount_value;
  v_pricing_version:=coalesce(v_quote->>'pricing_version','');

  if v_has_discount then
    if v_discount.discount_type_snapshot='PERCENT' then
      v_discount_amount:=round(
        v_pre_discount_value * v_discount.discount_value_snapshot / 100,
        2
      );
    elsif v_discount.discount_type_snapshot='FIXED' then
      v_discount_amount:=round(
        least(v_discount.discount_value_snapshot,v_pre_discount_value),
        2
      );
    else
      raise exception using errcode='P0001',message='APPOINTMENT_DISCOUNT_SNAPSHOT_INVALID';
    end if;

    v_discount_amount:=round(
      least(greatest(v_discount_amount,0),v_pre_discount_value),
      2
    );
    v_commercial_value:=round(
      greatest(v_pre_discount_value-v_discount_amount,0),
      2
    );

    v_pricing_version:=md5(concat_ws(
      '|',
      v_pricing_version,
      'RESCHEDULE_DISCOUNT_SNAPSHOT_V1',
      coalesce(v_discount.code_snapshot,''),
      v_discount.discount_type_snapshot,
      v_discount.discount_value_snapshot::text
    ));

    v_quote:=v_quote || jsonb_build_object(
      'coupon_code',v_discount.code_snapshot,
      'coupon_discount',v_discount_amount,
      'discount_amount',v_discount_amount,
      'pre_discount_value',v_pre_discount_value,
      'commercial_value',v_commercial_value,
      'total_amount',v_commercial_value,
      'discount_source','APPOINTMENT_SNAPSHOT',
      'discount_snapshot_type',v_discount.discount_type_snapshot,
      'discount_snapshot_value',v_discount.discount_value_snapshot,
      'pricing_version',v_pricing_version
    );
  end if;

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
  where s.id=v_appointment.service_id and os.id=1;

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
    v_pricing_version
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
    primary_customer_id,
    quote_snapshot,
    applied_coupon_id,
    coupon_code_snapshot,
    coupon_discount,
    pre_discount_value
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
    v_commercial_value,
    v_pricing_version,
    v_slot.duration_minutes,
    v_resource_ids,
    v_appointment.duration_blocks,
    v_contracted_minutes,
    v_appointment.primary_customer_id,
    v_quote,
    case when v_has_discount then v_discount.coupon_id else null end,
    case when v_has_discount then v_discount.code_snapshot else null end,
    case when v_has_discount then v_discount_amount else 0 end,
    case when v_has_discount then v_pre_discount_value else null end
  )
  returning id into v_hold_id;

  -- A reserva atual já protege a parte sobreposta. O hold de remarcação segura
  -- apenas os trechos NOVOS fora da ocupação atual, evitando conflito consigo mesma.
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

      for v_segment in select unnest(v_delta_ranges)
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
    'slot_end_at',v_slot.requested_end_at,
    'core_start_at',v_slot.core_start_at,
    'core_end_at',v_slot.core_end_at,
    'pre_service_minutes',v_slot.pre_service_minutes,
    'post_service_minutes',v_slot.post_service_minutes,
    'commercial_value',v_commercial_value,
    'duration_minutes',v_slot.duration_minutes,
    'duration_blocks',v_appointment.duration_blocks,
    'contracted_minutes',v_contracted_minutes,
    'pricing_version',v_pricing_version
  );
end;
$function$;

comment on function public.create_checkout_hold_for_reschedule(uuid,timestamp with time zone) is
  'Creates reschedule holds using current slot pricing while preserving the appointment discount snapshot without consuming a coupon again.';

do $patch_reschedule_discount_snapshot$
declare
  v_oid oid;
  v_definition text;
  v_patched text;
  v_old_update text := 'commercial_value=v_settlement.new_contract_value,version=version+1,updated_at=now()';
  v_new_update text := 'commercial_value=v_settlement.new_contract_value,coupon_discount=case when v_hold.quote_snapshot->>''discount_source''=''APPOINTMENT_SNAPSHOT'' then round(coalesce(v_hold.coupon_discount,0),2) else coupon_discount end,version=version+1,updated_at=now()';
  v_old_return text := 'where id=v_appointment.id returning version into v_new_version;';
  v_new_return text := 'where id=v_appointment.id returning version into v_new_version;

  if v_hold.quote_snapshot->>''discount_source''=''APPOINTMENT_SNAPSHOT'' then
    update public.appointment_discounts
    set calculated_discount_amount=round(coalesce(v_hold.coupon_discount,0),2)
    where appointment_id=v_appointment.id;
  end if;';
begin
  select p.oid
  into v_oid
  from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public'
    and p.proname='service_admin_apply_reschedule'
    and pg_get_function_identity_arguments(p.oid)='p_policy_action_id uuid, p_admin_id uuid';

  if v_oid is null then
    raise exception 'service_admin_apply_reschedule not found';
  end if;

  v_definition:=pg_get_functiondef(v_oid);

  if position('discount_source' in v_definition)>0 then
    return;
  end if;

  v_patched:=replace(v_definition,v_old_update,v_new_update);
  if v_patched=v_definition then
    raise exception 'service_admin_apply_reschedule price snapshot patch anchor not found';
  end if;

  v_definition:=v_patched;
  v_patched:=replace(v_definition,v_old_return,v_new_return);
  if v_patched=v_definition then
    raise exception 'service_admin_apply_reschedule discount audit patch anchor not found';
  end if;

  execute v_patched;
end;
$patch_reschedule_discount_snapshot$;
