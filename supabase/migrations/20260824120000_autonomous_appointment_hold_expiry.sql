-- Finding 15: abandoned AWAITING_PAYMENT appointments must not keep resources occupied.
-- The custom GUC is test-only clock injection; production falls back to transaction time.

create or replace function public.expire_due_appointment_holds()
returns integer
language plpgsql
volatile
set search_path = public
as $$
declare
  v_appointment record;
  v_count integer := 0;
  v_now timestamptz := coalesce(
    nullif(current_setting('agenda.test_now', true), '')::timestamptz,
    now()
  );
begin
  for v_appointment in
    select a.id
    from public.appointments a
    where a.status = 'AWAITING_PAYMENT'
      and a.hold_expires_at is not null
      and a.hold_expires_at <= v_now
    for update skip locked
  loop
    perform public.release_appointment_coupon_usage(v_appointment.id);

    update public.appointments
    set status = 'EXPIRED',
        financial_status = case
          when financial_status in ('NOT_STARTED','PENDING','REJECTED') then 'EXPIRED'
          else financial_status
        end,
        updated_at = v_now
    where id = v_appointment.id;

    update public.resource_allocations
    set status = 'EXPIRED',
        updated_at = v_now
    where appointment_id = v_appointment.id
      and status in ('HELD','AWAITING_PAYMENT');

    update public.checkout_hour_package_reservations phr
    set status = 'RELEASED',
        released_at = v_now,
        release_reason = 'APPOINTMENT_PAYMENT_HOLD_EXPIRED',
        updated_at = v_now
    from public.checkout_holds ch
    where ch.promoted_appointment_id = v_appointment.id
      and phr.checkout_hold_id = ch.id
      and phr.status = 'HELD';

    insert into public.audit_logs (
      entity_type, entity_id, action, after_json, origin
    ) values (
      'APPOINTMENT', v_appointment.id, 'PAYMENT_HOLD_EXPIRED',
      jsonb_build_object('status', 'EXPIRED'), 'SYSTEM'
    );

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

create or replace function public.list_available_slots_for_duration(
  p_service_id uuid,
  p_service_employee_id uuid,
  p_duration_blocks integer default null,
  p_extra_selections jsonb default '[]'::jsonb,
  p_people_count integer default 1,
  p_local_date date default current_date,
  p_coupon_code text default null
)
returns table (
  slot_start_at timestamptz,
  slot_end_at timestamptz,
  core_start_at timestamptz,
  core_end_at timestamptz,
  pre_service_minutes integer,
  post_service_minutes integer,
  duration_minutes integer,
  commercial_value numeric(12,2)
)
language plpgsql
stable
set search_path = public, extensions
as $$
declare
  v_service public.services%rowtype;
  v_timezone text;
  v_slot_interval integer := 30;
  v_dow smallint;
  v_candidate_local timestamp without time zone;
  v_anchor_start timestamptz;
  v_core_end timestamptz;
  v_appointment_start timestamptz;
  v_appointment_end timestamptz;
  v_contracted_minutes integer;
  v_quote jsonb;
  v_pre integer;
  v_post integer;
  v_resource record;
  v_resource_local_date date;
  v_resource_dow smallint;
  v_resource_ok boolean;
  v_service_window_ok boolean;
  v_now timestamptz := coalesce(
    nullif(current_setting('agenda.test_now', true), '')::timestamptz,
    now()
  );
begin
  select * into v_service from public.services where id = p_service_id and is_active;
  if not found then
    raise exception using errcode = 'P0001', message = 'SERVICE_NOT_AVAILABLE';
  end if;

  if not exists (
    select 1 from public.service_employees se
    where se.id = p_service_employee_id and se.service_id = p_service_id and se.is_active
  ) then
    raise exception using errcode = 'P0001', message = 'EMPLOYEE_NOT_AVAILABLE_FOR_SERVICE';
  end if;

  v_contracted_minutes := public.resolve_service_contracted_minutes(p_service_id, p_duration_blocks);
  select timezone into v_timezone from public.operation_settings where id = 1;
  v_dow := extract(dow from p_local_date)::smallint;

  select coalesce(min(ar.slot_interval_minutes), public.get_default_slot_interval_minutes())
  into v_slot_interval
  from public.availability_rules ar
  where ar.service_employee_id = p_service_employee_id
    and ar.weekday = v_dow
    and ar.is_active;

  for v_candidate_local in
    select gs from generate_series(
      p_local_date::timestamp,
      (p_local_date + 1)::timestamp - interval '1 minute',
      make_interval(mins => v_slot_interval)
    ) gs
  loop
    v_anchor_start := v_candidate_local at time zone v_timezone;
    v_core_end := v_anchor_start + make_interval(mins => v_contracted_minutes);

    v_quote := public.calculate_booking_quote_for_duration(
      p_service_id, p_service_employee_id, p_duration_blocks,
      p_extra_selections, p_people_count, v_anchor_start, p_coupon_code
    );
    v_pre := coalesce((v_quote->>'pre_service_minutes')::integer, 0);
    v_post := coalesce((v_quote->>'post_service_minutes')::integer, 0);
    v_appointment_start := v_anchor_start - make_interval(mins => v_pre);
    v_appointment_end := v_core_end + make_interval(mins => v_post);

    if v_appointment_start < v_now + make_interval(mins => v_service.minimum_booking_notice_minutes) then continue; end if;
    if v_anchor_start > v_now + make_interval(days => v_service.maximum_booking_horizon_days) then continue; end if;

    select (
      exists (
        select 1 from public.availability_rules ar
        where ar.service_employee_id = p_service_employee_id
          and ar.weekday = v_dow and ar.is_active
          and tstzrange(
            (p_local_date + ar.start_local_time) at time zone v_timezone,
            (p_local_date + ar.end_local_time) at time zone v_timezone,
            '[)'
          ) @> tstzrange(v_anchor_start, v_core_end, '[)')
      )
      or exists (
        select 1 from public.availability_exceptions ae
        where ae.service_employee_id = p_service_employee_id
          and ae.exception_type = 'OPEN'
          and tstzrange(ae.start_at, ae.end_at, '[)') @> tstzrange(v_anchor_start, v_core_end, '[)')
      )
    ) into v_service_window_ok;
    if not v_service_window_ok then continue; end if;

    if exists (
      select 1 from public.availability_exceptions ae
      where ae.service_employee_id = p_service_employee_id
        and ae.exception_type = 'BLOCK'
        and tstzrange(ae.start_at, ae.end_at, '[)') && tstzrange(v_anchor_start, v_core_end, '[)')
    ) then continue; end if;

    v_resource_ok := true;
    for v_resource in
      select * from public.calculate_booking_resource_ranges_for_duration(
        p_service_id, p_extra_selections, v_anchor_start, p_duration_blocks
      )
    loop
      v_resource_local_date := (lower(v_resource.occupied_range) at time zone v_timezone)::date;
      v_resource_dow := extract(dow from v_resource_local_date)::smallint;

      if exists (
        select 1 from public.resource_availability_rules rar
        where rar.resource_id = v_resource.resource_id
          and rar.weekday = v_resource_dow and rar.is_active
      ) then
        if not (
          exists (
            select 1 from public.resource_availability_rules rar
            where rar.resource_id = v_resource.resource_id
              and rar.weekday = v_resource_dow and rar.is_active
              and tstzrange(
                (v_resource_local_date + rar.start_local_time) at time zone v_timezone,
                (v_resource_local_date + rar.end_local_time) at time zone v_timezone,
                '[)'
              ) @> v_resource.occupied_range
          )
          or exists (
            select 1 from public.availability_exceptions ae
            where ae.resource_id = v_resource.resource_id
              and ae.exception_type = 'OPEN'
              and tstzrange(ae.start_at, ae.end_at, '[)') @> v_resource.occupied_range
          )
        ) then
          v_resource_ok := false; exit;
        end if;
      end if;

      if exists (
        select 1 from public.availability_exceptions ae
        where ae.resource_id = v_resource.resource_id
          and ae.exception_type = 'BLOCK'
          and tstzrange(ae.start_at, ae.end_at, '[)') && v_resource.occupied_range
      ) then v_resource_ok := false; exit; end if;

      if exists (
        select 1 from public.resource_allocations ra
        where ra.resource_id = v_resource.resource_id
          and ra.status in ('HELD','AWAITING_PAYMENT','CONFIRMED','BLOCKED','EXTERNAL_ACTIVE')
          and ra.occupied_range && v_resource.occupied_range
          and not (
            ra.status = 'AWAITING_PAYMENT'
            and ra.appointment_id is not null
            and exists (
              select 1
              from public.appointments a
              where a.id = ra.appointment_id
                and a.status = 'AWAITING_PAYMENT'
                and a.hold_expires_at is not null
                and a.hold_expires_at <= v_now
            )
          )
      ) then v_resource_ok := false; exit; end if;
    end loop;

    if not v_resource_ok then continue; end if;

    slot_start_at := v_appointment_start;
    slot_end_at := v_appointment_end;
    core_start_at := v_anchor_start;
    core_end_at := v_core_end;
    pre_service_minutes := v_pre;
    post_service_minutes := v_post;
    duration_minutes := v_contracted_minutes + v_pre + v_post;
    commercial_value := (v_quote->>'commercial_value')::numeric(12,2);
    return next;
  end loop;
end;
$$;

comment on function public.list_available_slots_for_duration(uuid,uuid,integer,jsonb,integer,date,text) is
  'Lists duration slots. Expired AWAITING_PAYMENT appointment allocations are ignored at read time; periodic maintenance performs authoritative expiry cleanup.';
