-- Scheduling policy clarified from operational rules.
-- 1) Offered start-time cadence defaults to 30 minutes.
-- 2) Buffers belong to the service, never to an individual rental block.
-- 3) Fixed-duration services (e.g. Sabrina) keep per-service before/after buffers.
-- 4) Block-duration services (e.g. studio rental) use 30-minute contracted blocks
--    and receive the service buffer exactly once around the whole contracted period.

alter table public.operation_settings
  add column if not exists default_slot_interval_minutes integer not null default 30
  check (default_slot_interval_minutes > 0 and default_slot_interval_minutes <= 1440);

alter table public.availability_rules
  alter column slot_interval_minutes set default 30;

update public.operation_settings
set default_slot_interval_minutes = 30,
    updated_at = now()
where id = 1;

alter table public.services
  add column duration_mode text not null default 'FIXED'
    check (duration_mode in ('FIXED','BLOCKS')),
  add column booking_block_minutes integer,
  add column minimum_booking_blocks integer,
  add column maximum_booking_blocks integer,
  add column price_per_block numeric(12,2);

alter table public.services
  add constraint services_duration_policy_check
  check (
    (
      duration_mode = 'FIXED'
      and booking_block_minutes is null
      and minimum_booking_blocks is null
      and maximum_booking_blocks is null
      and price_per_block is null
    )
    or
    (
      duration_mode = 'BLOCKS'
      and booking_block_minutes = 30
      and minimum_booking_blocks is not null
      and maximum_booking_blocks is not null
      and minimum_booking_blocks >= 1
      and maximum_booking_blocks >= minimum_booking_blocks
      and price_per_block is not null
      and price_per_block >= 0
    )
  );

alter table public.checkout_holds
  add column duration_blocks integer,
  add column contracted_minutes integer;

alter table public.appointments
  add column duration_blocks integer,
  add column contracted_minutes integer;

update public.checkout_holds
set contracted_minutes = greatest(
  1,
  round(extract(epoch from (core_end_at - core_start_at)) / 60)::integer
)
where contracted_minutes is null
  and core_start_at is not null
  and core_end_at is not null;

update public.appointments
set contracted_minutes = greatest(
  1,
  round(extract(epoch from (core_end_at - core_start_at)) / 60)::integer
)
where contracted_minutes is null
  and core_start_at is not null
  and core_end_at is not null;

alter table public.checkout_holds
  add constraint checkout_holds_duration_blocks_check
    check (duration_blocks is null or duration_blocks >= 1),
  add constraint checkout_holds_contracted_minutes_check
    check (contracted_minutes is null or contracted_minutes > 0);

alter table public.appointments
  add constraint appointments_duration_blocks_check
    check (duration_blocks is null or duration_blocks >= 1),
  add constraint appointments_contracted_minutes_check
    check (contracted_minutes is null or contracted_minutes > 0);

comment on column public.operation_settings.default_slot_interval_minutes is
  'Default cadence between offered start times. V1 default is 30 minutes.';
comment on column public.services.duration_mode is
  'FIXED uses base_duration_minutes. BLOCKS lets the customer contract multiple 30-minute blocks.';
comment on column public.services.booking_block_minutes is
  'Contracted unit size for BLOCKS services. V1 rental block is exactly 30 minutes.';
comment on column public.services.buffer_before_minutes is
  'Service-level buffer applied once before the complete contracted service period.';
comment on column public.services.buffer_after_minutes is
  'Service-level buffer applied once after the complete contracted service period; never multiplied by block count.';
comment on column public.checkout_holds.contracted_minutes is
  'Customer-contracted core duration, excluding PREPEND/APPEND extras and service buffers.';
comment on column public.appointments.contracted_minutes is
  'Snapshot of customer-contracted core duration, excluding service buffers.';

create or replace function public.get_default_slot_interval_minutes()
returns integer
language sql
stable
set search_path = public
as $$
select coalesce(
  (select os.default_slot_interval_minutes from public.operation_settings os where os.id = 1),
  30
);
$$;

create or replace function public.resolve_service_contracted_minutes(
  p_service_id uuid,
  p_duration_blocks integer default null
)
returns integer
language plpgsql
stable
set search_path = public
as $$
declare
  v_service public.services%rowtype;
begin
  select * into v_service
  from public.services
  where id = p_service_id;

  if not found then
    raise exception using errcode = 'P0001', message = 'SERVICE_NOT_FOUND';
  end if;

  if v_service.duration_mode = 'FIXED' then
    if p_duration_blocks is not null then
      raise exception using errcode = 'P0001', message = 'DURATION_BLOCKS_NOT_ALLOWED';
    end if;
    return v_service.base_duration_minutes;
  end if;

  if p_duration_blocks is null
     or p_duration_blocks < v_service.minimum_booking_blocks
     or p_duration_blocks > v_service.maximum_booking_blocks then
    raise exception using errcode = 'P0001', message = 'INVALID_DURATION_BLOCKS';
  end if;

  return v_service.booking_block_minutes * p_duration_blocks;
end;
$$;

create or replace function public.service_resource_envelope(
  p_service_id uuid,
  p_core_start_at timestamptz,
  p_duration_blocks integer default null
)
returns tstzrange
language plpgsql
stable
set search_path = public
as $$
declare
  v_service public.services%rowtype;
  v_contracted_minutes integer;
begin
  select * into v_service
  from public.services
  where id = p_service_id;

  if not found then
    raise exception using errcode = 'P0001', message = 'SERVICE_NOT_FOUND';
  end if;

  v_contracted_minutes := public.resolve_service_contracted_minutes(
    p_service_id,
    p_duration_blocks
  );

  -- Critical invariant: buffers are applied once to the WHOLE service envelope.
  -- They are deliberately outside the block multiplication.
  return tstzrange(
    p_core_start_at - make_interval(mins => v_service.buffer_before_minutes),
    p_core_start_at
      + make_interval(mins => v_contracted_minutes)
      + make_interval(mins => v_service.buffer_after_minutes),
    '[)'
  );
end;
$$;

create or replace function public.set_service_duration_policy(
  p_service_id uuid,
  p_duration_mode text,
  p_buffer_before_minutes integer,
  p_buffer_after_minutes integer,
  p_booking_block_minutes integer default null,
  p_minimum_booking_blocks integer default null,
  p_maximum_booking_blocks integer default null,
  p_price_per_block numeric default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_mode text := upper(btrim(coalesce(p_duration_mode, '')));
  v_service public.services%rowtype;
begin
  if v_mode not in ('FIXED','BLOCKS') then
    raise exception using errcode = 'P0001', message = 'INVALID_DURATION_MODE';
  end if;

  if p_buffer_before_minutes is null or p_buffer_before_minutes < 0
     or p_buffer_after_minutes is null or p_buffer_after_minutes < 0 then
    raise exception using errcode = 'P0001', message = 'INVALID_SERVICE_BUFFER';
  end if;

  if v_mode = 'BLOCKS' then
    if p_booking_block_minutes is distinct from 30 then
      raise exception using errcode = 'P0001', message = 'RENTAL_BLOCK_MUST_BE_30_MINUTES';
    end if;
    if p_minimum_booking_blocks is null
       or p_maximum_booking_blocks is null
       or p_minimum_booking_blocks < 1
       or p_maximum_booking_blocks < p_minimum_booking_blocks
       or p_price_per_block is null
       or p_price_per_block < 0 then
      raise exception using errcode = 'P0001', message = 'INVALID_BLOCK_DURATION_POLICY';
    end if;
  end if;

  update public.services
  set duration_mode = v_mode,
      buffer_before_minutes = p_buffer_before_minutes,
      buffer_after_minutes = p_buffer_after_minutes,
      booking_block_minutes = case when v_mode = 'BLOCKS' then 30 else null end,
      minimum_booking_blocks = case when v_mode = 'BLOCKS' then p_minimum_booking_blocks else null end,
      maximum_booking_blocks = case when v_mode = 'BLOCKS' then p_maximum_booking_blocks else null end,
      price_per_block = case when v_mode = 'BLOCKS' then p_price_per_block::numeric(12,2) else null end,
      updated_at = now()
  where id = p_service_id
  returning * into v_service;

  if not found then
    raise exception using errcode = 'P0001', message = 'SERVICE_NOT_FOUND';
  end if;

  insert into public.audit_logs(entity_type, entity_id, action, after_json, origin)
  values (
    'SERVICE',
    p_service_id,
    'DURATION_POLICY_CHANGED',
    jsonb_build_object(
      'duration_mode', v_mode,
      'buffer_before_minutes', p_buffer_before_minutes,
      'buffer_after_minutes', p_buffer_after_minutes,
      'booking_block_minutes', case when v_mode = 'BLOCKS' then 30 else null end,
      'minimum_booking_blocks', case when v_mode = 'BLOCKS' then p_minimum_booking_blocks else null end,
      'maximum_booking_blocks', case when v_mode = 'BLOCKS' then p_maximum_booking_blocks else null end,
      'price_per_block', case when v_mode = 'BLOCKS' then p_price_per_block else null end
    ),
    'ADMIN'
  );

  return jsonb_build_object(
    'service_id', v_service.id,
    'duration_mode', v_service.duration_mode,
    'buffer_before_minutes', v_service.buffer_before_minutes,
    'buffer_after_minutes', v_service.buffer_after_minutes,
    'booking_block_minutes', v_service.booking_block_minutes,
    'minimum_booking_blocks', v_service.minimum_booking_blocks,
    'maximum_booking_blocks', v_service.maximum_booking_blocks,
    'price_per_block', v_service.price_per_block
  );
end;
$$;

revoke all on function public.get_default_slot_interval_minutes() from public, anon, authenticated;
grant execute on function public.get_default_slot_interval_minutes() to service_role;
revoke all on function public.resolve_service_contracted_minutes(uuid,integer) from public, anon, authenticated;
grant execute on function public.resolve_service_contracted_minutes(uuid,integer) to service_role;
revoke all on function public.service_resource_envelope(uuid,timestamptz,integer) from public, anon, authenticated;
grant execute on function public.service_resource_envelope(uuid,timestamptz,integer) to service_role;
revoke all on function public.set_service_duration_policy(uuid,text,integer,integer,integer,integer,integer,numeric)
  from public, anon, authenticated;
grant execute on function public.set_service_duration_policy(uuid,text,integer,integer,integer,integer,integer,numeric)
  to service_role;
