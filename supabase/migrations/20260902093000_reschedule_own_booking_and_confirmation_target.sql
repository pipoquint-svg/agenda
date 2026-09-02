-- Remarcação segura: permite reutilizar a própria ocupação, segura somente o delta
-- novo e exige pagamento apenas quando a cobertura fica abaixo da meta de confirmação.

CREATE OR REPLACE FUNCTION public.list_available_slots_for_duration_reschedule_base(
  p_service_id uuid,
  p_service_employee_id uuid,
  p_duration_blocks integer DEFAULT NULL::integer,
  p_extra_selections jsonb DEFAULT '[]'::jsonb,
  p_people_count integer DEFAULT 1,
  p_local_date date DEFAULT CURRENT_DATE,
  p_coupon_code text DEFAULT NULL::text,
  p_ignore_appointment_id uuid DEFAULT NULL::uuid
)
RETURNS TABLE(
  slot_start_at timestamp with time zone,
  slot_end_at timestamp with time zone,
  core_start_at timestamp with time zone,
  core_end_at timestamp with time zone,
  pre_service_minutes integer,
  post_service_minutes integer,
  duration_minutes integer,
  commercial_value numeric
)
LANGUAGE plpgsql
STABLE
SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_service public.services%rowtype;
  v_timezone text;
  v_slot_interval integer := 30;
  v_dow smallint;
  v_anchor_start timestamptz;
  v_core_end timestamptz;
  v_appointment_start timestamptz;
  v_appointment_end timestamptz;
  v_contracted_minutes integer;
  v_profile jsonb;
  v_candidates jsonb := '[]'::jsonb;
  v_pre integer;
  v_post integer;
  v_resource record;
  v_resource_local_date date;
  v_resource_dow smallint;
  v_resource_ok boolean;
  v_service_window_ok boolean;
  v_now timestamptz := coalesce(nullif(current_setting('agenda.test_now', true), '')::timestamptz, now());
begin
  select * into v_service from public.services where id=p_service_id and is_active;
  if not found then raise exception using errcode='P0001',message='SERVICE_NOT_AVAILABLE'; end if;

  if not exists(
    select 1 from public.service_employees se
    where se.id=p_service_employee_id and se.service_id=p_service_id and se.is_active
  ) then raise exception using errcode='P0001',message='EMPLOYEE_NOT_AVAILABLE_FOR_SERVICE'; end if;

  v_contracted_minutes:=public.resolve_service_contracted_minutes(p_service_id,p_duration_blocks);
  select timezone into v_timezone from public.operation_settings where id=1;
  v_dow:=extract(dow from p_local_date)::smallint;
  v_slot_interval:=coalesce(v_service.slot_interval_minutes,30);

  for v_anchor_start in
    with weekly_candidates as (
      select gs at time zone v_timezone as candidate_start
      from public.availability_rules ar
      cross join lateral generate_series(
        p_local_date+ar.start_local_time,
        (p_local_date+ar.end_local_time)-interval '1 microsecond',
        make_interval(mins=>v_slot_interval)
      ) gs
      where ar.service_employee_id=p_service_employee_id and ar.weekday=v_dow and ar.is_active
    ), open_candidates as (
      select gs as candidate_start
      from (
        select ae.* from public.availability_exceptions ae
        where ae.service_employee_id=p_service_employee_id
          and ae.exception_type='OPEN'
          and tstzrange(ae.start_at,ae.end_at,'[)') && tstzrange(
            p_local_date::timestamp at time zone v_timezone,
            (p_local_date+1)::timestamp at time zone v_timezone,
            '[)'
          )
      ) ae
      cross join lateral generate_series(
        ae.start_at,ae.end_at-interval '1 microsecond',make_interval(mins=>v_slot_interval)
      ) gs
      where (gs at time zone v_timezone)::date=p_local_date
    )
    select candidate_start from weekly_candidates
    union
    select candidate_start from open_candidates
    order by 1
  loop
    v_core_end:=v_anchor_start+make_interval(mins=>v_contracted_minutes);
    v_profile:=public.resolve_extra_schedule_profile(p_service_id,p_extra_selections,v_anchor_start);
    v_pre:=coalesce((v_profile->>'pre_service_minutes')::integer,0);
    v_post:=coalesce((v_profile->>'post_service_minutes')::integer,0);
    v_appointment_start:=v_anchor_start-make_interval(mins=>v_pre);
    v_appointment_end:=v_core_end+make_interval(mins=>v_post);

    if v_appointment_start < v_now+make_interval(mins=>v_service.minimum_booking_notice_minutes) then continue; end if;
    if v_anchor_start > v_now+make_interval(days=>v_service.maximum_booking_horizon_days) then continue; end if;

    select (
      exists(
        select 1 from public.availability_rules ar
        where ar.service_employee_id=p_service_employee_id and ar.weekday=v_dow and ar.is_active
          and tstzrange((p_local_date+ar.start_local_time) at time zone v_timezone,(p_local_date+ar.end_local_time) at time zone v_timezone,'[)') @> tstzrange(v_anchor_start,v_core_end,'[)')
      ) or exists(
        select 1 from public.availability_exceptions ae
        where ae.service_employee_id=p_service_employee_id and ae.exception_type='OPEN'
          and tstzrange(ae.start_at,ae.end_at,'[)') @> tstzrange(v_anchor_start,v_core_end,'[)')
      )
    ) into v_service_window_ok;
    if not v_service_window_ok then continue; end if;

    if exists(
      select 1 from public.availability_exceptions ae
      where ae.service_employee_id=p_service_employee_id and ae.exception_type='BLOCK'
        and tstzrange(ae.start_at,ae.end_at,'[)') && tstzrange(v_anchor_start,v_core_end,'[)')
    ) then continue; end if;

    v_resource_ok:=true;
    for v_resource in
      select * from public.calculate_booking_resource_ranges_for_duration(
        p_service_id,p_extra_selections,v_anchor_start,p_duration_blocks
      )
    loop
      v_resource_local_date:=(lower(v_resource.occupied_range) at time zone v_timezone)::date;
      v_resource_dow:=extract(dow from v_resource_local_date)::smallint;

      if not (
        exists(
          select 1 from public.resource_availability_rules rar
          where rar.resource_id=v_resource.resource_id and rar.weekday=v_resource_dow and rar.is_active
            and tstzrange((v_resource_local_date+rar.start_local_time) at time zone v_timezone,(v_resource_local_date+rar.end_local_time) at time zone v_timezone,'[)') @> v_resource.occupied_range
        ) or exists(
          select 1 from public.availability_exceptions ae
          where ae.resource_id=v_resource.resource_id and ae.exception_type='OPEN'
            and tstzrange(ae.start_at,ae.end_at,'[)') @> v_resource.occupied_range
        )
      ) then v_resource_ok:=false; exit; end if;

      if exists(
        select 1 from public.availability_exceptions ae
        where ae.resource_id=v_resource.resource_id and ae.exception_type='BLOCK'
          and tstzrange(ae.start_at,ae.end_at,'[)') && v_resource.occupied_range
      ) then v_resource_ok:=false; exit; end if;

      if exists(
        select 1 from public.resource_allocations ra
        where ra.resource_id=v_resource.resource_id
          and ra.status in ('HELD','AWAITING_PAYMENT','CONFIRMED','BLOCKED','EXTERNAL_ACTIVE')
          and ra.occupied_range && v_resource.occupied_range
          and (p_ignore_appointment_id is null or ra.appointment_id is distinct from p_ignore_appointment_id)
          and (
            ra.status<>'HELD' or ra.allocation_type<>'CHECKOUT_HOLD'
            or exists(
              select 1 from public.checkout_holds ch
              where ch.id=ra.checkout_hold_id and ch.status='ACTIVE' and ch.expires_at>v_now
            )
          )
          and not (
            ra.status='AWAITING_PAYMENT' and ra.appointment_id is not null
            and exists(
              select 1 from public.appointments a
              where a.id=ra.appointment_id and a.status='AWAITING_PAYMENT'
                and a.hold_expires_at is not null and a.hold_expires_at<=v_now
            )
          )
      ) then v_resource_ok:=false; exit; end if;
    end loop;

    if not v_resource_ok then continue; end if;

    v_candidates:=v_candidates||jsonb_build_array(jsonb_build_object(
      'slot_start_at',v_appointment_start,
      'slot_end_at',v_appointment_end,
      'core_start_at',v_anchor_start,
      'core_end_at',v_core_end,
      'pre_service_minutes',v_pre,
      'post_service_minutes',v_post,
      'duration_minutes',v_contracted_minutes+v_pre+v_post
    ));
  end loop;

  if jsonb_array_length(v_candidates)=0 then return; end if;

  return query
  with candidates as (
    select ord::bigint ord,
      (item->>'slot_start_at')::timestamptz slot_start_at,
      (item->>'slot_end_at')::timestamptz slot_end_at,
      (item->>'core_start_at')::timestamptz core_start_at,
      (item->>'core_end_at')::timestamptz core_end_at,
      (item->>'pre_service_minutes')::integer pre_service_minutes,
      (item->>'post_service_minutes')::integer post_service_minutes,
      (item->>'duration_minutes')::integer duration_minutes
    from jsonb_array_elements(v_candidates) with ordinality x(item,ord)
  ), quotes as (
    select b.requested_start_at,b.quote
    from public.calculate_booking_quotes_for_duration_listing_batch(
      p_service_id,p_service_employee_id,p_duration_blocks,p_extra_selections,p_people_count,
      (select array_agg(c.core_start_at order by c.ord) from candidates c),p_coupon_code
    ) b
  )
  select c.slot_start_at,c.slot_end_at,c.core_start_at,c.core_end_at,
    c.pre_service_minutes,c.post_service_minutes,c.duration_minutes,
    (q.quote->>'commercial_value')::numeric(12,2)
  from candidates c join quotes q on q.requested_start_at=c.core_start_at
  order by c.ord;
end;
$function$;

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
begin
  perform public.expire_due_checkout_holds();
  select * into v_appointment from public.appointments where id=p_appointment_id and deleted_at is null;
  if not found or v_appointment.status<>'CONFIRMED' then raise exception using errcode='P0001',message='APPOINTMENT_NOT_RESCHEDULABLE'; end if;

  select coalesce(jsonb_agg(jsonb_build_object('extra_id',ae.extra_id,'quantity',ae.quantity) order by ae.extra_id),'[]'::jsonb)
  into v_extras from public.appointment_extras ae where ae.appointment_id=p_appointment_id and ae.extra_id is not null;

  v_contracted_minutes:=public.resolve_service_contracted_minutes(v_appointment.service_id,v_appointment.duration_blocks);
  select timezone into v_timezone from public.operation_settings where id=1;
  v_requested_local_date:=(p_requested_start_at at time zone v_timezone)::date;

  select s.* into v_slot
  from (
    select * from public.list_available_slots_for_duration_reschedule_base(
      v_appointment.service_id,v_appointment.service_employee_id,v_appointment.duration_blocks,
      v_extras,v_appointment.people_count,v_requested_local_date,null,p_appointment_id
    )
    union all
    select * from public.list_available_slots_for_duration_reschedule_base(
      v_appointment.service_id,v_appointment.service_employee_id,v_appointment.duration_blocks,
      v_extras,v_appointment.people_count,v_requested_local_date+1,null,p_appointment_id
    )
  ) s
  where s.slot_start_at=p_requested_start_at
    and s.core_start_at is distinct from v_appointment.core_start_at
    and not exists(
      select 1 from public.calculate_booking_resource_ranges_for_duration(
        v_appointment.service_id,v_extras,s.core_start_at,v_appointment.duration_blocks
      ) rr where not public.google_resource_sync_is_ready(rr.resource_id,600)
    )
  order by s.core_start_at limit 1;
  if not found then raise exception using errcode='P0001',message='SLOT_NO_LONGER_AVAILABLE'; end if;

  v_quote:=public.calculate_booking_quote_for_duration(
    v_appointment.service_id,v_appointment.service_employee_id,v_appointment.duration_blocks,
    v_extras,v_appointment.people_count,v_slot.core_start_at,null
  );

  select coalesce(array_agg(r.resource_id order by r.resource_id),'{}'::uuid[])
  into v_resource_ids
  from public.calculate_booking_resource_ranges_for_duration(
    v_appointment.service_id,v_extras,v_slot.core_start_at,v_appointment.duration_blocks
  ) r;
  if coalesce(array_length(v_resource_ids,1),0)=0 then raise exception using errcode='P0001',message='SERVICE_HAS_NO_REQUIRED_RESOURCES'; end if;

  select coalesce(s.checkout_hold_minutes,os.checkout_hold_minutes)
  into v_hold_minutes from public.services s cross join public.operation_settings os
  where s.id=v_appointment.service_id and os.id=1;
  v_expires_at:=coalesce(nullif(current_setting('agenda.test_now',true),'')::timestamptz,now())+make_interval(mins=>v_hold_minutes);
  v_raw_token:=encode(gen_random_bytes(32),'hex');
  v_token_hash:=encode(digest(v_raw_token,'sha256'),'hex');
  v_selection_hash:=md5(concat_ws('|','RESCHEDULE',p_appointment_id::text,v_appointment.service_id::text,v_appointment.service_employee_id::text,coalesce(v_appointment.duration_blocks::text,'FIXED'),v_extras::text,v_appointment.people_count::text,v_slot.slot_start_at::text,v_slot.core_start_at::text,v_quote->>'pricing_version'));

  insert into public.checkout_holds(
    public_token_hash,service_id,service_employee_id,selection_hash,people_count,
    requested_start_at,requested_end_at,core_start_at,core_end_at,pre_service_minutes,post_service_minutes,
    schedule_profile,status,expires_at,extra_selections,commercial_value,pricing_version,duration_minutes,
    resource_ids,duration_blocks,contracted_minutes,primary_customer_id
  ) values(
    v_token_hash,v_appointment.service_id,v_appointment.service_employee_id,v_selection_hash,v_appointment.people_count,
    v_slot.slot_start_at,v_slot.slot_end_at,v_slot.core_start_at,v_slot.core_end_at,v_slot.pre_service_minutes,v_slot.post_service_minutes,
    v_quote->'schedule_profile','ACTIVE',v_expires_at,v_extras,(v_quote->>'commercial_value')::numeric(12,2),v_quote->>'pricing_version',v_slot.duration_minutes,
    v_resource_ids,v_appointment.duration_blocks,v_contracted_minutes,v_appointment.primary_customer_id
  ) returning id into v_hold_id;

  -- A reserva atual já protege a parte sobreposta. O hold de remarcação segura
  -- apenas os trechos NOVOS fora da ocupação atual, evitando conflito consigo mesma.
  begin
    for v_range in
      select * from public.calculate_booking_resource_ranges_for_duration(
        v_appointment.service_id,v_extras,v_slot.core_start_at,v_appointment.duration_blocks
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
        insert into public.resource_allocations(resource_id,checkout_hold_id,allocation_type,status,occupied_range)
        values(v_range.resource_id,v_hold_id,'CHECKOUT_HOLD','HELD',v_segment);
      end loop;
    end loop;
  exception when exclusion_violation then
    update public.checkout_holds set status='INVALIDATED',updated_at=now() where id=v_hold_id;
    raise exception using errcode='P0001',message='SLOT_NO_LONGER_AVAILABLE';
  end;

  return jsonb_build_object(
    'checkout_hold_token',v_raw_token,'checkout_hold_id',v_hold_id,'status','ACTIVE','expires_at',v_expires_at,
    'slot_start_at',v_slot.slot_start_at,'slot_end_at',v_slot.slot_end_at,'core_start_at',v_slot.core_start_at,'core_end_at',v_slot.core_end_at,
    'pre_service_minutes',v_slot.pre_service_minutes,'post_service_minutes',v_slot.post_service_minutes,
    'commercial_value',(v_quote->>'commercial_value')::numeric(12,2),'duration_minutes',v_slot.duration_minutes,
    'duration_blocks',v_appointment.duration_blocks,'contracted_minutes',v_contracted_minutes,'pricing_version',v_quote->>'pricing_version'
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.service_admin_list_reschedule_slots(p_appointment_id uuid, p_local_date date)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
declare
  v_appointment public.appointments%rowtype;
  v_usage public.appointment_package_usage%rowtype;
  v_package public.hour_packages%rowtype;
  v_extras jsonb;
  v_timezone text;
  v_available bigint;
  v_old_charged bigint;
  v_local_start timestamp without time zone;
  v_local_end timestamp without time zone;
  v_required bigint;
  v_surcharge bigint;
  v_delta bigint;
  v_special boolean;
  v_result jsonb:='[]'::jsonb;
  r record;
begin
  if p_local_date is null then raise exception using errcode='P0001',message='RESCHEDULE_DATE_REQUIRED'; end if;
  select * into v_appointment from public.appointments where id=p_appointment_id and deleted_at is null;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if;
  if v_appointment.status<>'CONFIRMED' then raise exception using errcode='P0001',message='APPOINTMENT_NOT_RESCHEDULABLE'; end if;

  select coalesce(jsonb_agg(jsonb_build_object('extra_id',ae.extra_id,'quantity',ae.quantity) order by ae.extra_id),'[]'::jsonb)
  into v_extras from public.appointment_extras ae where ae.appointment_id=p_appointment_id and ae.extra_id is not null;

  select * into v_usage from public.appointment_package_usage where appointment_id=p_appointment_id and reversal_movement_id is null;
  if found then
    select * into v_package from public.hour_packages where id=v_usage.hour_package_id;
    select available_seconds into v_available from public.hour_package_balances where hour_package_id=v_package.id;
    v_old_charged:=v_usage.charged_seconds;
    select timezone into v_timezone from public.operation_settings where id=1;
  end if;

  for r in
    select s.*
    from public.list_available_slots_for_duration_reschedule_base(
      v_appointment.service_id,v_appointment.service_employee_id,v_appointment.duration_blocks,
      v_extras,v_appointment.people_count,p_local_date,null,p_appointment_id
    ) s
    where s.core_start_at is distinct from v_appointment.core_start_at
      and not exists(
        select 1 from public.calculate_booking_resource_ranges_for_duration(
          v_appointment.service_id,v_extras,s.core_start_at,v_appointment.duration_blocks
        ) rr where not public.google_resource_sync_is_ready(rr.resource_id,600)
      )
  loop
    if v_usage.id is not null then
      if v_package.status<>'ACTIVE' or r.slot_start_at<v_package.valid_from or r.slot_start_at>=v_package.valid_until
        or not exists(select 1 from public.hour_package_services where hour_package_id=v_package.id and service_id=v_appointment.service_id)
      then continue; end if;
      v_local_start:=r.slot_start_at at time zone v_timezone;
      v_local_end:=r.slot_end_at at time zone v_timezone;
      v_special:=extract(dow from v_local_start)::integer in(0,6)
        or v_local_start::date<>v_local_end::date
        or v_local_start::time<v_package.standard_start_local_time
        or v_local_end::time>v_package.standard_end_local_time;
      v_required:=r.duration_minutes::bigint*60;
      v_surcharge:=case when v_special then round(v_required::numeric*v_package.special_surcharge_percent/100)::bigint else 0 end;
      v_delta:=(v_required+v_surcharge)-v_old_charged;
      if v_delta>0 and coalesce(v_available,0)<v_delta then continue; end if;
    end if;

    v_result:=v_result||jsonb_build_array(jsonb_build_object(
      'slot_start_at',r.slot_start_at,'slot_end_at',r.slot_end_at,
      'core_start_at',r.core_start_at,'core_end_at',r.core_end_at,
      'pre_service_minutes',r.pre_service_minutes,'post_service_minutes',r.post_service_minutes,
      'duration_minutes',r.duration_minutes,
      'package_delta_seconds',case when v_usage.id is null then 0 else v_delta end
    ));
  end loop;
  return v_result;
end;
$function$;

CREATE OR REPLACE FUNCTION public.service_admin_create_reschedule_hold(
  p_appointment_id uuid,
  p_requested_start_at timestamp with time zone,
  p_requested_at timestamp with time zone,
  p_change_origin text,
  p_admin_id uuid DEFAULT NULL::uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
declare
  v_appointment public.appointments%rowtype;
  v_preview jsonb;
  v_hold jsonb;
  v_package_quote jsonb;
  v_hold_row public.checkout_holds%rowtype;
  v_hold_id uuid;
  v_action_id uuid;
  v_action_status text;
  v_previous record;
  v_settlement_id uuid;
  v_new_contract_value numeric(12,2);
  v_package_cash_due numeric(12,2);
begin
  if p_requested_start_at is null or p_requested_at is null then raise exception using errcode='P0001',message='RESCHEDULE_TIME_REQUIRED'; end if;
  if p_change_origin not in ('CLIENT','OPERATION') then raise exception using errcode='P0001',message='CHANGE_ORIGIN_REQUIRED'; end if;

  select * into v_appointment from public.appointments where id=p_appointment_id and deleted_at is null for update;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if;
  if v_appointment.status<>'CONFIRMED' then raise exception using errcode='P0001',message='APPOINTMENT_NOT_RESCHEDULABLE'; end if;
  perform public.enforce_appointment_reschedule_limit(p_appointment_id,p_change_origin);

  for v_previous in
    select id,reschedule_checkout_hold_id from public.appointment_policy_actions
    where appointment_id=p_appointment_id and action_type='RESCHEDULE' and status in ('PREVIEW','AWAITING_DIFFERENCE_PAYMENT') for update
  loop
    if v_previous.reschedule_checkout_hold_id is not null then
      update public.resource_allocations set status='RELEASED',updated_at=now()
      where checkout_hold_id=v_previous.reschedule_checkout_hold_id and allocation_type='CHECKOUT_HOLD' and status='HELD';
      update public.checkout_holds set status='INVALIDATED',updated_at=now()
      where id=v_previous.reschedule_checkout_hold_id and status='ACTIVE';
    end if;
    update public.appointment_policy_actions set status='VOIDED',updated_at=now() where id=v_previous.id;
  end loop;

  v_hold:=public.create_checkout_hold_for_reschedule(p_appointment_id,p_requested_start_at);
  v_hold_id:=(v_hold->>'checkout_hold_id')::uuid;
  select * into v_hold_row from public.checkout_holds where id=v_hold_id;

  v_package_quote:=public.service_quote_reschedule_package_hold(p_appointment_id,v_hold_id);
  if coalesce((v_package_quote->>'uses_package')::boolean,false) then
    select apu.cash_due into v_package_cash_due from public.appointment_package_usage apu
    where apu.appointment_id=p_appointment_id and apu.reversal_movement_id is null;
    if v_package_cash_due is null then raise exception using errcode='P0001',message='RESCHEDULE_PACKAGE_USAGE_MISSING'; end if;
    v_new_contract_value:=round(v_package_cash_due,2);
  else
    v_new_contract_value:=round(v_hold_row.commercial_value,2);
  end if;

  v_preview:=public.calculate_reservation_change(p_appointment_id,'RESCHEDULE',p_requested_at,p_change_origin,v_new_contract_value);
  if coalesce((v_preview->>'customer_reschedule_limit_reached')::boolean,false) then raise exception using errcode='P0001',message='CLIENT_RESCHEDULE_LIMIT_REACHED'; end if;
  v_action_status:=case when coalesce((v_preview->>'difference_due')::numeric,0)>0 then 'AWAITING_DIFFERENCE_PAYMENT' else 'PREVIEW' end;

  insert into public.appointment_policy_actions(
    appointment_id,action_type,status,requested_at,original_start_at,requested_new_start_at,hours_before_start,notice_hours_snapshot,
    is_inside_notice_window,prior_customer_reschedules,contract_value_snapshot,net_paid_snapshot,penalty_type,penalty_value,penalty_amount,
    refundable_amount,reschedule_checkout_hold_id,created_by_admin_id,change_origin,policy_schema_version,contract_applied_before,excess_before,
    applicable_amount,excess_amount,difference_due,refund_due
  ) values(
    p_appointment_id,'RESCHEDULE',v_action_status,p_requested_at,v_appointment.start_at,v_hold_row.requested_start_at,
    (v_preview->>'hours_before_start')::numeric,(v_preview->>'notice_hours')::integer,(v_preview->>'inside_notice_window')::boolean,
    (v_preview->>'prior_customer_reschedules')::integer,(v_preview->>'contract_value')::numeric,(v_preview->>'customer_funds_before')::numeric,
    'PERCENT'::public.change_penalty_type,(v_preview->>'penalty_percent')::numeric,(v_preview->>'penalty_retained')::numeric,0,v_hold_id,p_admin_id,
    p_change_origin,v_preview->>'snapshot_schema_version',(v_preview->>'contract_applied_before')::numeric,(v_preview->>'excess_before')::numeric,
    (v_preview->>'applicable_amount')::numeric,(v_preview->>'excess_amount')::numeric,(v_preview->>'difference_due')::numeric,0
  ) returning id into v_action_id;

  v_settlement_id:=public.record_appointment_change_settlement(v_action_id,v_preview);
  insert into public.audit_logs(admin_user_id,entity_type,entity_id,action,after_json,origin)
  values(p_admin_id,'APPOINTMENT',p_appointment_id,'RESCHEDULE_PREVIEW_CREATED',jsonb_build_object(
    'policy_action_id',v_action_id,'settlement_id',v_settlement_id,'change_origin',p_change_origin,
    'penalty_retained',v_preview->'penalty_retained','applicable_amount',v_preview->'applicable_amount',
    'new_contract_value',v_new_contract_value,'difference_due',v_preview->'difference_due','excess_amount',v_preview->'excess_amount',
    'package_reconciliation',v_package_quote
  ),case when p_change_origin='CLIENT' then 'CLIENT' else 'ADMIN' end);

  return jsonb_build_object(
    'policy_action_id',v_action_id,'settlement_id',v_settlement_id,'policy_action_status',v_action_status,'appointment_id',p_appointment_id,
    'change_origin',p_change_origin,'original_start_at',v_appointment.start_at,
    'new_slot',jsonb_build_object('checkout_hold_id',v_hold_id,'expires_at',v_hold_row.expires_at,'slot_start_at',v_hold_row.requested_start_at,
      'slot_end_at',v_hold_row.requested_end_at,'core_start_at',v_hold_row.core_start_at,'core_end_at',v_hold_row.core_end_at),
    'contract_value',v_preview->'contract_value','new_contract_value',v_new_contract_value,'payment_commitment_percent',v_preview->'payment_commitment_percent',
    'confirmation_target_amount',v_preview->'confirmation_target_amount','penalty_percent',v_preview->'penalty_percent','penalty_retained',v_preview->'penalty_retained',
    'applicable_amount',v_preview->'applicable_amount','difference_due',v_preview->'difference_due','excess_amount',v_preview->'excess_amount',
    'prior_customer_reschedules',v_preview->'prior_customer_reschedules','max_customer_reschedules',v_preview->'max_customer_reschedules',
    'package_reconciliation',v_package_quote
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.service_client_reschedule_requirements(p_token_id uuid, p_policy_action_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
declare
  v_token public.appointment_access_tokens%rowtype;
  v_action public.appointment_policy_actions%rowtype;
  v_settlement public.appointment_change_settlements%rowtype;
  v_appointment public.appointments%rowtype;
  v_hold public.checkout_holds%rowtype;
  v_current_coverage numeric(12,2);
  v_coverage_after_penalty numeric(12,2);
  v_outstanding numeric(12,2);
  v_financial boolean;
begin
  select * into v_token from public.appointment_access_tokens where id=p_token_id;
  if not found or v_token.scope<>'RESCHEDULE' or v_token.revoked_at is not null or v_token.consumed_at is not null or v_token.expires_at is null or v_token.expires_at<=clock_timestamp() then
    raise exception using errcode='P0001',message='APPOINTMENT_TOKEN_INVALID';
  end if;

  select * into v_appointment from public.appointments where id=v_token.appointment_id and deleted_at is null;
  if not found or v_appointment.status<>'CONFIRMED' or v_appointment.start_at<=clock_timestamp() or v_token.expires_at<>v_appointment.start_at then
    raise exception using errcode='P0001',message='APPOINTMENT_TOKEN_INVALID';
  end if;

  select * into v_action from public.appointment_policy_actions where id=p_policy_action_id;
  if not found or v_action.appointment_id<>v_appointment.id or v_action.action_type<>'RESCHEDULE' or v_action.change_origin<>'CLIENT' or v_action.status not in ('PREVIEW','AWAITING_DIFFERENCE_PAYMENT') then
    raise exception using errcode='P0001',message='CLIENT_RESCHEDULE_ACTION_INVALID';
  end if;

  select * into v_settlement from public.appointment_change_settlements where policy_action_id=v_action.id;
  if not found then raise exception using errcode='P0001',message='CHANGE_SETTLEMENT_NOT_FOUND'; end if;

  select * into v_hold from public.checkout_holds where id=v_action.reschedule_checkout_hold_id;
  if not found or v_hold.status<>'ACTIVE' or v_hold.expires_at<=clock_timestamp() then
    raise exception using errcode='P0001',message='RESCHEDULE_HOLD_EXPIRED';
  end if;

  -- Regra autoritativa: uma remarcação só exige pagamento adicional quando a
  -- cobertura atual, após eventual multa, fica abaixo da META DE CONFIRMAÇÃO
  -- do novo contrato. Não se exige quitação integral quando a reserva original
  -- foi confirmada legitimamente com sinal/percentual.
  v_current_coverage:=round(public.appointment_contract_coverage_amount(v_appointment.id),2);
  v_coverage_after_penalty:=round(greatest(v_current_coverage-coalesce(v_settlement.penalty_retained,0),0),2);
  v_outstanding:=round(greatest(coalesce(v_settlement.confirmation_target_amount,0)-v_coverage_after_penalty,0),2);
  v_financial:=coalesce(v_settlement.penalty_retained,0)>0.005
    or abs(coalesce(v_settlement.new_contract_value,0)-coalesce(v_settlement.contract_value,0))>0.005
    or coalesce(v_settlement.difference_due,0)>0.005;

  return jsonb_build_object(
    'appointment_id',v_appointment.id,
    'policy_action_id',v_action.id,
    'hold_expires_at',v_hold.expires_at,
    'new_start_at',v_hold.requested_start_at,
    'new_end_at',v_hold.requested_end_at,
    'contract_value',v_settlement.contract_value,
    'new_contract_value',v_settlement.new_contract_value,
    'penalty_amount',v_settlement.penalty_retained,
    'confirmation_target_amount',v_settlement.confirmation_target_amount,
    'current_contract_coverage',v_current_coverage,
    'coverage_after_penalty',v_coverage_after_penalty,
    'outstanding_difference',v_outstanding,
    'requires_payment',v_outstanding>0.005,
    'requires_email_verification',v_financial
  );
end;
$function$;
