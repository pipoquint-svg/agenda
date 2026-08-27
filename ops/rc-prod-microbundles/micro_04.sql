
-- BEGIN RC MIGRATION 20260824110000_blacksheep_update_active_hold_selection.sql
create or replace function public.public_update_checkout_hold_selection(
  p_checkout_hold_token text,
  p_extra_selections jsonb,
  p_people_count integer
)
returns jsonb
language plpgsql
security definer
set search_path to 'public','extensions'
as $function$
declare
  v_hold public.checkout_holds%rowtype;
  v_page_slug text;
  v_service public.services%rowtype;
  v_quote jsonb;
  v_canonical_extras jsonb;
  v_resource_ids uuid[] := '{}'::uuid[];
  v_new_pre integer;
  v_new_post integer;
  v_new_contracted integer;
  v_selection_hash text;
begin
  if p_checkout_hold_token is null or btrim(p_checkout_hold_token) = '' then
    raise exception using errcode='P0001', message='CHECKOUT_HOLD_TOKEN_REQUIRED';
  end if;

  select * into v_hold
  from public.checkout_holds
  where public_token_hash = encode(digest(p_checkout_hold_token,'sha256'),'hex')
  for update;

  if not found or v_hold.status <> 'ACTIVE' or v_hold.expires_at <= now() then
    raise exception using errcode='P0001', message='CHECKOUT_HOLD_NOT_ACTIVE';
  end if;

  select * into v_service from public.services where id=v_hold.service_id and is_active;
  if not found then
    raise exception using errcode='P0001', message='SERVICE_NOT_AVAILABLE';
  end if;
  if coalesce(v_service.operation_scope,'') <> 'BLACKSHEEP' then
    raise exception using errcode='P0001', message='HOLD_SELECTION_UPDATE_NOT_ALLOWED';
  end if;

  select bp.slug into v_page_slug
  from public.booking_pages bp
  where bp.id=v_hold.booking_page_id and bp.is_active;
  if v_page_slug is null then
    raise exception using errcode='P0001', message='CHECKOUT_ORIGIN_NOT_ACTIVE';
  end if;

  if exists (
    select 1 from public.checkout_hour_package_reservations phr
    where phr.checkout_hold_id=v_hold.id and phr.status='HELD'
  ) then
    raise exception using errcode='P0001', message='HOLD_SELECTION_LOCKED';
  end if;

  select coalesce(jsonb_agg(
    jsonb_build_object('extra_id',x.extra_id,'quantity',x.quantity) order by x.extra_id
  ),'[]'::jsonb)
  into v_canonical_extras
  from jsonb_to_recordset(coalesce(p_extra_selections,'[]'::jsonb)) x(extra_id uuid,quantity integer);

  perform public.assert_public_booking_duration(
    v_page_slug,
    v_hold.service_id,
    v_hold.service_employee_id,
    v_hold.duration_blocks,
    v_canonical_extras,
    p_people_count
  );

  v_new_contracted := public.resolve_service_contracted_minutes(v_hold.service_id,v_hold.duration_blocks);
  v_quote := public.calculate_booking_quote_for_duration(
    v_hold.service_id,
    v_hold.service_employee_id,
    v_hold.duration_blocks,
    v_canonical_extras,
    p_people_count,
    v_hold.core_start_at,
    null
  );

  v_new_pre := coalesce((v_quote->>'pre_service_minutes')::integer,0);
  v_new_post := coalesce((v_quote->>'post_service_minutes')::integer,0);

  if v_new_contracted <> v_hold.contracted_minutes
     or v_new_pre <> coalesce(v_hold.pre_service_minutes,0)
     or v_new_post <> coalesce(v_hold.post_service_minutes,0) then
    raise exception using errcode='P0001', message='HOLD_SELECTION_REQUIRES_NEW_SLOT';
  end if;

  select coalesce(array_agg(r.resource_id order by r.resource_id),'{}'::uuid[])
  into v_resource_ids
  from public.calculate_booking_resource_ranges_for_duration(
    v_hold.service_id,
    v_canonical_extras,
    v_hold.core_start_at,
    v_hold.duration_blocks
  ) r;

  if coalesce(array_length(v_resource_ids,1),0)=0 then
    raise exception using errcode='P0001', message='SERVICE_HAS_NO_REQUIRED_RESOURCES';
  end if;

  delete from public.resource_allocations
  where checkout_hold_id=v_hold.id
    and allocation_type='CHECKOUT_HOLD'
    and status='HELD';

  begin
    insert into public.resource_allocations(resource_id,checkout_hold_id,allocation_type,status,occupied_range)
    select r.resource_id,v_hold.id,'CHECKOUT_HOLD','HELD',r.occupied_range
    from public.calculate_booking_resource_ranges_for_duration(
      v_hold.service_id,
      v_canonical_extras,
      v_hold.core_start_at,
      v_hold.duration_blocks
    ) r;
  exception when exclusion_violation then
    raise exception using errcode='P0001', message='RESOURCE_NOT_AVAILABLE';
  end;

  v_selection_hash := md5(concat_ws('|',
    v_hold.service_id::text,
    v_hold.service_employee_id::text,
    coalesce(v_hold.duration_blocks::text,'FIXED'),
    v_canonical_extras::text,
    p_people_count::text,
    v_hold.requested_start_at::text,
    v_hold.core_start_at::text,
    v_quote->>'pricing_version'
  ));

  update public.checkout_holds
  set people_count=p_people_count,
      extra_selections=v_canonical_extras,
      commercial_value=(v_quote->>'commercial_value')::numeric(12,2),
      pricing_version=v_quote->>'pricing_version',
      quote_snapshot=v_quote,
      resource_ids=v_resource_ids,
      selection_hash=v_selection_hash,
      schedule_profile=v_quote->'schedule_profile',
      updated_at=now()
  where id=v_hold.id;

  return public.public_get_checkout_context(p_checkout_hold_token);
end;
$function$;

revoke all on function public.public_update_checkout_hold_selection(text,jsonb,integer) from public, anon, authenticated;
grant execute on function public.public_update_checkout_hold_selection(text,jsonb,integer) to service_role;

-- BlackSheep rentals require 24h advance notice. Visits remain separately configurable.
update public.services
set minimum_booking_notice_minutes = 1440,
    updated_at = now()
where operation_scope = 'BLACKSHEEP'
  and duration_mode = 'BLOCKS'
  and minimum_booking_notice_minutes <> 1440;
-- END RC MIGRATION 20260824110000_blacksheep_update_active_hold_selection.sql

-- BEGIN RC MIGRATION 20260824120000_autonomous_appointment_hold_expiry.sql
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
-- END RC MIGRATION 20260824120000_autonomous_appointment_hold_expiry.sql

-- BEGIN RC MIGRATION 20260824143000_booking_policy_publication_guard.sql
-- Phase 3 / finding 4: a service cannot be publicly bookable without an
-- authoritative change/cancellation policy. Existing invalid links are disabled;
-- no historical appointment policy is fabricated by this migration.

create or replace function public.assert_booking_page_service_has_change_policy()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_page_active boolean;
begin
  if not new.is_active then
    return new;
  end if;

  select bp.is_active into v_page_active
  from public.booking_pages bp
  where bp.id = new.booking_page_id;

  if coalesce(v_page_active, false)
     and not exists (
       select 1
       from public.service_change_policies cp
       where cp.service_id = new.service_id
     ) then
    raise exception using
      errcode = 'P0001',
      message = 'SERVICE_CHANGE_POLICY_REQUIRED_FOR_PUBLIC_BOOKING';
  end if;

  return new;
end;
$$;

create or replace function public.assert_booking_page_activation_has_policies()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.is_active and (tg_op = 'INSERT' or old.is_active is distinct from true) then
    if exists (
      select 1
      from public.booking_page_services bps
      left join public.service_change_policies cp on cp.service_id = bps.service_id
      where bps.booking_page_id = new.id
        and bps.is_active
        and cp.service_id is null
    ) then
      raise exception using
        errcode = 'P0001',
        message = 'BOOKING_PAGE_HAS_SERVICE_WITHOUT_CHANGE_POLICY';
    end if;
  end if;

  return new;
end;
$$;

create or replace function public.prevent_public_service_policy_delete()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if exists (
    select 1
    from public.booking_page_services bps
    join public.booking_pages bp on bp.id = bps.booking_page_id
    where bps.service_id = old.service_id
      and bps.is_active
      and bp.is_active
  ) then
    raise exception using
      errcode = 'P0001',
      message = 'PUBLIC_SERVICE_CHANGE_POLICY_CANNOT_BE_REMOVED';
  end if;

  return old;
end;
$$;

-- Repair current staging/seed state conservatively: invalid public links are
-- disabled rather than inventing commercial policy values.
update public.booking_page_services bps
set is_active = false
where bps.is_active
  and exists (
    select 1
    from public.booking_pages bp
    where bp.id = bps.booking_page_id
      and bp.is_active
  )
  and not exists (
    select 1
    from public.service_change_policies cp
    where cp.service_id = bps.service_id
  );

drop trigger if exists booking_page_services_require_change_policy on public.booking_page_services;
create trigger booking_page_services_require_change_policy
before insert or update of booking_page_id, service_id, is_active
on public.booking_page_services
for each row execute function public.assert_booking_page_service_has_change_policy();

drop trigger if exists booking_pages_require_service_policies on public.booking_pages;
create trigger booking_pages_require_service_policies
before insert or update of is_active
on public.booking_pages
for each row execute function public.assert_booking_page_activation_has_policies();

drop trigger if exists service_change_policies_protect_public_service on public.service_change_policies;
create trigger service_change_policies_protect_public_service
before delete on public.service_change_policies
for each row execute function public.prevent_public_service_policy_delete();

revoke all on function public.assert_booking_page_service_has_change_policy() from public, anon, authenticated;
revoke all on function public.assert_booking_page_activation_has_policies() from public, anon, authenticated;
revoke all on function public.prevent_public_service_policy_delete() from public, anon, authenticated;

comment on function public.assert_booking_page_service_has_change_policy() is
  'Fail-closed publication guard: active services on active booking pages require service_change_policies.';
comment on function public.prevent_public_service_policy_delete() is
  'Prevents removal of the authoritative change policy while a service remains publicly bookable.';
-- END RC MIGRATION 20260824143000_booking_policy_publication_guard.sql

-- BEGIN RC MIGRATION 20260824150000_commercial_configuration_authority.sql
-- Phase 3 findings 5 + 8: configuration must govern the engine.
-- New reservations snapshot commercial configuration once. Historical rows are
-- not assigned an unverifiable confirmation percentage by this migration.

alter table public.services
  drop constraint if exists services_confirmation_percentage_check,
  add constraint services_confirmation_percentage_check
    check (confirmation_percentage is null or confirmation_percentage > 0 and confirmation_percentage <= 100);

alter table public.operation_settings
  drop constraint if exists operation_settings_default_confirmation_percentage_check,
  add constraint operation_settings_default_confirmation_percentage_check
    check (default_confirmation_percentage > 0 and default_confirmation_percentage <= 100);

alter table public.appointment_change_settlements
  drop constraint if exists appointment_change_settlements_commitment_check,
  add constraint appointment_change_settlements_commitment_check
    check (payment_commitment_percent >= 0 and payment_commitment_percent <= 100);

alter table public.appointment_change_policy_snapshots
  drop constraint if exists appointment_change_policy_snapsh_max_customer_reschedules_check,
  add constraint appointment_change_policy_snapshots_max_customer_reschedules_check
    check (max_customer_reschedules >= 0);

alter table public.appointments
  add column confirmation_percentage_snapshot numeric(5,2),
  add constraint appointments_confirmation_percentage_snapshot_check
    check (
      confirmation_percentage_snapshot is null
      or confirmation_percentage_snapshot > 0 and confirmation_percentage_snapshot <= 100
    );

comment on column public.appointments.confirmation_percentage_snapshot is
  'Immutable checkout confirmation target captured when the reservation is created. NULL is allowed only for legacy reservations whose historical value cannot be proven.';

-- Preserve any historical value that was explicitly recorded by a payment request.
-- Do not guess for appointments with no such evidence.
with evidenced as (
  select distinct on (pt.appointment_id)
    pt.appointment_id,
    pt.requested_percentage
  from public.payment_transactions pt
  where pt.payment_purpose = 'CONTRACT'
    and pt.transaction_type = 'CHARGE'
    and pt.requested_percentage is not null
    and pt.requested_percentage < 100
  order by pt.appointment_id, pt.created_at, pt.id
)
update public.appointments a
set confirmation_percentage_snapshot = e.requested_percentage
from evidenced e
where a.id = e.appointment_id
  and a.confirmation_percentage_snapshot is null;

create or replace function public.capture_appointment_commercial_configuration()
returns trigger
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_confirmation numeric(5,2);
begin
  if new.confirmation_percentage_snapshot is null then
    select coalesce(s.confirmation_percentage, os.default_confirmation_percentage)
    into v_confirmation
    from public.services s
    cross join public.operation_settings os
    where s.id = new.service_id
      and os.id = 1;

    if v_confirmation is null then
      raise exception using errcode='P0001', message='APPOINTMENT_CONFIRMATION_CONFIGURATION_MISSING';
    end if;

    new.confirmation_percentage_snapshot := v_confirmation;
  end if;

  return new;
end;
$$;

drop trigger if exists appointments_capture_commercial_configuration on public.appointments;
create trigger appointments_capture_commercial_configuration
before insert on public.appointments
for each row execute function public.capture_appointment_commercial_configuration();

create or replace function public.prevent_appointment_confirmation_snapshot_change()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if old.confirmation_percentage_snapshot is not null
     and new.confirmation_percentage_snapshot is distinct from old.confirmation_percentage_snapshot then
    raise exception using errcode='42501', message='APPOINTMENT_CONFIRMATION_SNAPSHOT_IMMUTABLE';
  end if;
  return new;
end;
$$;

drop trigger if exists appointments_protect_confirmation_snapshot on public.appointments;
create trigger appointments_protect_confirmation_snapshot
before update of confirmation_percentage_snapshot on public.appointments
for each row execute function public.prevent_appointment_confirmation_snapshot_change();

create or replace function public.normalize_change_policy_snapshot(p_policy jsonb)
returns jsonb
language sql
immutable
set search_path = public
as $$
  select case
    when p_policy is null then null
    else p_policy || jsonb_build_object(
      'max_customer_reschedules', coalesce((p_policy->>'max_customer_reschedules')::integer, 3),
      'policy_timezone', 'America/Sao_Paulo',
      'notice_boundary_semantics', 'EXACT_LIMIT_IS_OUTSIDE_WINDOW',
      'snapshot_schema_version', case
        when nullif(p_policy->>'reschedule_first_early_percent','') is not null
         and nullif(p_policy->>'reschedule_first_late_percent','') is not null
         and nullif(p_policy->>'reschedule_repeat_percent','') is not null
         and nullif(p_policy->>'cancellation_late_percent','') is not null
        then 'CONSOLIDATED_POLICY_V2'
        else 'CHANGE_POLICY_SNAPSHOT_V1'
      end
    )
  end;
$$;

create or replace function public.capture_current_appointment_change_policy_snapshot()
returns trigger
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_policy public.service_change_policies%rowtype;
  v_effective_at timestamptz;
  v_max_reschedules integer;
  v_policy_json jsonb;
begin
  if new.status not in ('AWAITING_PAYMENT','CONFIRMED') then return new; end if;
  if exists (select 1 from public.appointment_change_policy_snapshots s where s.appointment_id=new.id) then return new; end if;

  select cp.*
  into v_policy
  from public.service_change_policies cp
  where cp.service_id=new.service_id;

  if not found then return new; end if;

  select coalesce(s.max_reschedules, 3)
  into v_max_reschedules
  from public.services s
  where s.id=new.service_id;

  if not found then return new; end if;

  v_effective_at := case when new.status='AWAITING_PAYMENT' then new.created_at else coalesce(new.confirmed_at,new.created_at) end;
  v_policy_json := public.normalize_change_policy_snapshot(
    to_jsonb(v_policy) || jsonb_build_object('max_customer_reschedules',v_max_reschedules)
  );

  insert into public.appointment_change_policy_snapshots(
    appointment_id,service_id,policy_json,effective_at,source,
    max_customer_reschedules,policy_timezone,notice_boundary_semantics
  ) values (
    new.id,new.service_id,v_policy_json,v_effective_at,'BOOKING_CAPTURE',
    v_max_reschedules,'America/Sao_Paulo','EXACT_LIMIT_IS_OUTSIDE_WINDOW'
  );

  perform public.capture_appointment_policy_terms_snapshot(new.id,new.service_id,v_effective_at);
  return new;
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
  if v_confirmation_percentage is null then
    raise exception using errcode='P0001',message='APPOINTMENT_CONFIRMATION_SNAPSHOT_MISSING';
  end if;

  v_summary := public.get_appointment_financial_summary(v_appointment.id);
  v_settled := (v_summary->>'contract_settled')::numeric;
  v_confirmation_target := round(coalesce(v_appointment.commercial_value,0)*v_confirmation_percentage/100,2);
  v_minimum_due := round(greatest(v_confirmation_target-v_settled,0),2);

  return jsonb_build_object(
    'appointment_id',v_appointment.id,'public_code',v_appointment.public_code,
    'appointment_status',v_appointment.status,'financial_status',v_appointment.financial_status,
    'service_name',v_appointment.service_name_snapshot,'hold_expires_at',v_appointment.hold_expires_at,
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

create or replace function public.service_create_payment_intent_by_token(
  p_access_token text,p_payment_kind text,p_method text,p_request_key text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_appointment_id uuid;
  v_appointment public.appointments%rowtype;
  v_percentage numeric(5,2);
  v_idempotency_key text;
begin
  if p_payment_kind not in ('MINIMUM','FULL') then raise exception using errcode='P0001',message='INVALID_PAYMENT_KIND'; end if;
  if p_method not in ('PIX','CARD') then raise exception using errcode='P0001',message='PUBLIC_PAYMENT_METHOD_NOT_ALLOWED'; end if;
  if p_request_key is null or p_request_key !~ '^[A-Za-z0-9_-]{12,100}$' then raise exception using errcode='P0001',message='PAYMENT_REQUEST_KEY_INVALID'; end if;

  v_appointment_id := public.resolve_appointment_access_token(p_access_token,'PAY');
  select * into v_appointment from public.appointments where id=v_appointment_id;

  if p_payment_kind='FULL' then v_percentage:=100;
  else
    v_percentage:=v_appointment.confirmation_percentage_snapshot;
    if v_percentage is null then raise exception using errcode='P0001',message='APPOINTMENT_CONFIRMATION_SNAPSHOT_MISSING'; end if;
  end if;

  v_idempotency_key := 'public:'||v_appointment_id::text||':'||p_request_key;
  return public.create_payment_intent(v_appointment_id,v_percentage,p_method,v_idempotency_key);
end;
$$;

create or replace function public.create_payment_intent(
  p_appointment_id uuid,p_payment_percentage numeric,p_method text,p_idempotency_key text
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
  v_balance numeric(12,2); v_settled_before numeric(12,2);
  v_confirmation_percentage numeric(5,2); v_confirmation_target numeric(12,2);
  v_contract_amount numeric(12,2); v_discount_percent numeric(5,2);
  v_discount numeric(12,2); v_cash_amount numeric(12,2); v_amounts jsonb;
  v_transaction_id uuid; v_payment_kind text;
begin
  if p_method not in ('PIX','CARD') then raise exception using errcode='P0001',message='PUBLIC_PAYMENT_METHOD_NOT_ALLOWED'; end if;
  if p_idempotency_key is null or btrim(p_idempotency_key)='' then raise exception using errcode='P0001',message='IDEMPOTENCY_KEY_REQUIRED'; end if;

  select * into v_existing from public.payment_transactions where idempotency_key=p_idempotency_key;
  if found then
    if v_existing.appointment_id<>p_appointment_id or v_existing.method<>p_method or v_existing.requested_percentage is distinct from p_payment_percentage then
      raise exception using errcode='P0001',message='IDEMPOTENCY_KEY_CONFLICT';
    end if;
    return jsonb_build_object('transaction_id',v_existing.id,'appointment_id',v_existing.appointment_id,'status',v_existing.status,
      'payment_percentage',v_existing.requested_percentage,'contract_amount_settled',v_existing.contract_amount_settled,
      'payment_discount_amount',v_existing.payment_discount_amount,'cash_amount',v_existing.cash_amount,'method',v_existing.method,'idempotent_replay',true);
  end if;

  perform public.expire_due_appointment_holds();
  select * into v_appointment from public.appointments where id=p_appointment_id for update;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if;
  if v_appointment.status not in ('AWAITING_PAYMENT','CONFIRMED') then raise exception using errcode='P0001',message='APPOINTMENT_NOT_PAYABLE'; end if;
  if v_appointment.status='AWAITING_PAYMENT' and (v_appointment.hold_expires_at is null or v_appointment.hold_expires_at<=now()) then
    raise exception using errcode='P0001',message='PAYMENT_HOLD_EXPIRED';
  end if;

  v_confirmation_percentage:=v_appointment.confirmation_percentage_snapshot;
  if v_confirmation_percentage is null then raise exception using errcode='P0001',message='APPOINTMENT_CONFIRMATION_SNAPSHOT_MISSING'; end if;
  if p_payment_percentage<>100 and p_payment_percentage<>v_confirmation_percentage then
    raise exception using errcode='P0001',message='INVALID_PAYMENT_PERCENTAGE';
  end if;

  select os.pix_discount_percent into v_discount_percent from public.operation_settings os where os.id=1;
  v_summary:=public.get_appointment_financial_summary(p_appointment_id);
  v_balance:=(v_summary->>'contract_balance')::numeric;
  v_settled_before:=(v_summary->>'contract_settled')::numeric;
  if v_balance<=0 then raise exception using errcode='P0001',message='APPOINTMENT_ALREADY_PAID'; end if;

  v_confirmation_target:=round(coalesce(v_appointment.commercial_value,0)*v_confirmation_percentage/100,2);
  if p_payment_percentage=100 then
    v_payment_kind:='FULL_BALANCE'; v_contract_amount:=v_balance;
  else
    v_payment_kind:='CONFIRMATION_MINIMUM';
    v_contract_amount:=round(greatest(v_confirmation_target-v_settled_before,0),2);
    if v_contract_amount<=0 then raise exception using errcode='P0001',message='CONFIRMATION_PAYMENT_ALREADY_SATISFIED'; end if;
    v_contract_amount:=least(v_contract_amount,v_balance);
  end if;

  v_amounts:=public.service_calculate_payment_cash_amount(v_contract_amount,p_method,v_discount_percent);
  v_discount:=(v_amounts->>'payment_discount_amount')::numeric;
  v_cash_amount:=(v_amounts->>'cash_amount')::numeric;

  insert into public.payment_transactions(
    appointment_id,transaction_type,method,provider,status,contract_amount_settled,
    payment_discount_amount,cash_amount,idempotency_key,requested_percentage
  ) values (
    p_appointment_id,'CHARGE',p_method,'MERCADO_PAGO','PENDING',v_contract_amount,
    v_discount,v_cash_amount,p_idempotency_key,p_payment_percentage
  ) returning id into v_transaction_id;

  if v_appointment.financial_status not in ('PARTIALLY_PAID','PAID','UNPAID_AUTHORIZED') then
    update public.appointments set financial_status='PENDING',updated_at=now() where id=p_appointment_id;
  end if;

  return jsonb_build_object('transaction_id',v_transaction_id,'appointment_id',p_appointment_id,'status','PENDING',
    'payment_kind',v_payment_kind,'payment_percentage',p_payment_percentage,'confirmation_percentage',v_confirmation_percentage,
    'confirmation_target_amount',v_confirmation_target,'contract_settled_before',v_settled_before,'contract_balance_before',v_balance,
    'contract_amount_settled',v_contract_amount,'payment_discount_amount',v_discount,'cash_amount',v_cash_amount,
    'method',p_method,'provider','MERCADO_PAGO','idempotent_replay',false);
end;
$$;

create or replace function public.calculate_reservation_change(
  p_appointment_id uuid,p_action_type text,p_requested_at timestamptz,p_change_origin text,p_new_contract_value numeric
)
returns jsonb
language plpgsql
stable
set search_path=public
as $$
declare
  v_appointment public.appointments%rowtype;
  v_snapshot public.appointment_change_policy_snapshots%rowtype;
  v_policy jsonb; v_schema text; v_notice integer; v_seconds numeric; v_hours numeric(12,2); v_inside boolean;
  v_count integer; v_contract numeric(12,2); v_funds numeric(12,2); v_applied numeric(12,2); v_excess_before numeric(12,2);
  v_contract_coverage numeric(12,2); v_contract_coverage_after numeric(12,2); v_commitment numeric(5,2); v_target numeric(12,2);
  v_percent numeric(5,2):=0; v_theoretical numeric(12,2):=0; v_retained numeric(12,2):=0;
  v_after numeric(12,2):=0; v_applicable numeric(12,2):=0; v_excess_after numeric(12,2):=0;
  v_difference numeric(12,2):=0; v_refund numeric(12,2):=0;
  v_legacy_type public.change_penalty_type; v_legacy_value numeric(12,2):=0;
begin
  if p_action_type not in ('RESCHEDULE','CANCEL') then raise exception using errcode='P0001',message='INVALID_CHANGE_ACTION'; end if;
  if p_requested_at is null then raise exception using errcode='P0001',message='CHANGE_REQUESTED_AT_REQUIRED'; end if;
  if p_change_origin not in ('CLIENT','OPERATION') then raise exception using errcode='P0001',message='CHANGE_ORIGIN_REQUIRED'; end if;
  if p_action_type='RESCHEDULE' and p_new_contract_value is null then raise exception using errcode='P0001',message='NEW_CONTRACT_VALUE_REQUIRED'; end if;
  if p_new_contract_value is not null and p_new_contract_value<0 then raise exception using errcode='P0001',message='NEW_CONTRACT_VALUE_INVALID'; end if;

  select * into v_appointment from public.appointments where id=p_appointment_id and deleted_at is null;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_NOT_FOUND'; end if;
  select * into v_snapshot from public.appointment_change_policy_snapshots where appointment_id=p_appointment_id;
  if not found then raise exception using errcode='P0001',message='APPOINTMENT_CHANGE_POLICY_SNAPSHOT_MISSING'; end if;

  v_policy:=v_snapshot.policy_json; v_schema:=coalesce(v_policy->>'snapshot_schema_version','CHANGE_POLICY_SNAPSHOT_V1');
  v_notice:=(v_policy->>'notice_hours')::integer;
  if v_notice is null then raise exception using errcode='P0001',message='APPOINTMENT_CHANGE_POLICY_SNAPSHOT_INVALID'; end if;

  v_seconds:=extract(epoch from (v_appointment.start_at-p_requested_at)); v_hours:=round(v_seconds/3600.0,2);
  v_inside:=v_seconds<(v_notice::numeric*3600); v_count:=public.appointment_client_reschedule_count(p_appointment_id);
  v_contract:=round(coalesce(v_appointment.commercial_value,0),2);
  v_funds:=round(public.appointment_customer_funds_amount(p_appointment_id),2);
  v_applied:=round(least(v_funds,v_contract),2); v_excess_before:=round(greatest(v_funds-v_contract,0),2);
  v_contract_coverage:=round(public.appointment_contract_coverage_amount(p_appointment_id),2);

  if v_appointment.billing_mode_snapshot='INVOICE' or v_appointment.financial_status='UNPAID_AUTHORIZED' then v_commitment:=0;
  elsif v_contract<=0 or v_contract_coverage>=v_contract then v_commitment:=100;
  else
    v_commitment:=v_appointment.confirmation_percentage_snapshot;
    if v_commitment is null then raise exception using errcode='P0001',message='APPOINTMENT_CONFIRMATION_SNAPSHOT_MISSING'; end if;
  end if;

  if p_change_origin='OPERATION' then v_percent:=0;
  elsif v_schema='CONSOLIDATED_POLICY_V2' then
    if p_action_type='RESCHEDULE' then
      if v_count>0 then v_percent:=(v_policy->>'reschedule_repeat_percent')::numeric;
      elsif v_inside then v_percent:=(v_policy->>'reschedule_first_late_percent')::numeric;
      else v_percent:=(v_policy->>'reschedule_first_early_percent')::numeric; end if;
    else v_percent:=case when v_inside then (v_policy->>'cancellation_late_percent')::numeric else 0 end; end if;
  else
    if p_action_type='RESCHEDULE' then
      if v_count>0 then v_legacy_type:=(v_policy->>'reschedule_repeat_penalty_type')::public.change_penalty_type; v_legacy_value:=(v_policy->>'reschedule_repeat_penalty_value')::numeric;
      elsif v_inside then v_legacy_type:=(v_policy->>'reschedule_late_penalty_type')::public.change_penalty_type; v_legacy_value:=(v_policy->>'reschedule_late_penalty_value')::numeric;
      else v_legacy_type:=(v_policy->>'reschedule_first_penalty_type')::public.change_penalty_type; v_legacy_value:=(v_policy->>'reschedule_first_penalty_value')::numeric; end if;
    else
      if v_inside then v_legacy_type:=(v_policy->>'cancellation_late_penalty_type')::public.change_penalty_type; v_legacy_value:=(v_policy->>'cancellation_late_penalty_value')::numeric;
      else v_legacy_type:=(v_policy->>'cancellation_early_penalty_type')::public.change_penalty_type; v_legacy_value:=(v_policy->>'cancellation_early_penalty_value')::numeric; end if;
    end if;
    if v_legacy_type='PERCENT' then v_percent:=v_legacy_value; elsif v_legacy_type='NONE' then v_percent:=0; else v_percent:=0; v_theoretical:=round(v_legacy_value,2); end if;
  end if;

  if v_theoretical=0 then v_theoretical:=round(v_contract*v_percent/100,2); end if;
  v_retained:=case when p_change_origin='OPERATION' then 0 else round(least(v_theoretical,v_applied),2) end;
  v_after:=round(greatest(v_funds-v_retained,0),2); v_contract_coverage_after:=round(greatest(v_contract_coverage-v_retained,0),2);
  if p_action_type='RESCHEDULE' then
    v_target:=round(p_new_contract_value*v_commitment/100,2); v_applicable:=round(least(v_after,p_new_contract_value),2);
    v_excess_after:=round(greatest(v_after-p_new_contract_value,0),2); v_difference:=round(greatest(v_target-v_contract_coverage_after,0),2);
  else
    v_target:=0; v_applicable:=round(greatest(v_applied-v_retained,0),2); v_excess_after:=v_excess_before; v_refund:=round(v_applicable+v_excess_before,2);
  end if;

  return jsonb_build_object(
    'appointment_id',p_appointment_id,'service_id',v_appointment.service_id,'action_type',p_action_type,'change_origin',p_change_origin,
    'requested_at',p_requested_at,'original_start_at',v_appointment.start_at,'hours_before_start',v_hours,'notice_hours',v_notice,
    'inside_notice_window',v_inside,'prior_customer_reschedules',v_count,'max_customer_reschedules',v_snapshot.max_customer_reschedules,
    'contract_value',v_contract,'new_contract_value',p_new_contract_value,'customer_funds_before',v_funds,
    'contract_applied_before',v_applied,'excess_before',v_excess_before,'contract_coverage_before',v_contract_coverage,
    'payment_commitment_percent',v_commitment,'confirmation_target_amount',v_target,
    'penalty_percent',v_percent,'theoretical_penalty',v_theoretical,'penalty_retained',v_retained,'penalty_amount',v_retained,
    'customer_funds_after_penalty',v_after,'contract_coverage_after_penalty',v_contract_coverage_after,
    'applicable_amount',v_applicable,'excess_amount',v_excess_after,'difference_due',v_difference,
    'refund_due',v_refund,'refundable_amount',v_refund,
    'customer_reschedule_limit_reached',(p_action_type='RESCHEDULE' and p_change_origin='CLIENT' and v_count>=v_snapshot.max_customer_reschedules),
    'snapshot_schema_version',v_schema
  );
end;
$$;

revoke all on function public.capture_appointment_commercial_configuration() from public,anon,authenticated,service_role;
revoke all on function public.prevent_appointment_confirmation_snapshot_change() from public,anon,authenticated;
-- END RC MIGRATION 20260824150000_commercial_configuration_authority.sql

-- BEGIN RC MIGRATION 20260824150100_fix_policy_snapshot_capture.sql
-- Keep the policy row and service-level reschedule configuration as separate
-- lookups so the typed row target remains valid in PL/pgSQL.
create or replace function public.capture_current_appointment_change_policy_snapshot()
returns trigger
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_policy public.service_change_policies%rowtype;
  v_effective_at timestamptz;
  v_max_reschedules integer;
  v_policy_json jsonb;
begin
  if new.status not in ('AWAITING_PAYMENT','CONFIRMED') then return new; end if;
  if exists (
    select 1 from public.appointment_change_policy_snapshots s
    where s.appointment_id=new.id
  ) then return new; end if;

  select * into v_policy
  from public.service_change_policies
  where service_id=new.service_id;
  if not found then return new; end if;

  select coalesce(s.max_reschedules,3)
  into v_max_reschedules
  from public.services s
  where s.id=new.service_id;

  if v_max_reschedules is null then
    raise exception using errcode='P0001',message='SERVICE_RESCHEDULE_CONFIGURATION_MISSING';
  end if;

  v_effective_at := case
    when new.status='AWAITING_PAYMENT' then new.created_at
    else coalesce(new.confirmed_at,new.created_at)
  end;

  v_policy_json := public.normalize_change_policy_snapshot(
    to_jsonb(v_policy) || jsonb_build_object('max_customer_reschedules',v_max_reschedules)
  );

  insert into public.appointment_change_policy_snapshots(
    appointment_id,service_id,policy_json,effective_at,source,
    max_customer_reschedules,policy_timezone,notice_boundary_semantics
  ) values (
    new.id,new.service_id,v_policy_json,v_effective_at,'BOOKING_CAPTURE',
    v_max_reschedules,'America/Sao_Paulo','EXACT_LIMIT_IS_OUTSIDE_WINDOW'
  );

  perform public.capture_appointment_policy_terms_snapshot(new.id,new.service_id,v_effective_at);
  return new;
end;
$$;
-- END RC MIGRATION 20260824150100_fix_policy_snapshot_capture.sql
