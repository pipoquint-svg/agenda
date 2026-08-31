alter table public.appointments
  add column if not exists surcharge_amount_snapshot numeric(12,2) not null default 0;

comment on column public.appointments.surcharge_amount_snapshot is
  'Snapshot do ajuste DAY_TIME proporcional para servicos BLOCKS. FIXED permanece no motor legado e grava zero aqui.';

create or replace function public.populate_checkout_hold_quote_snapshot()
returns trigger
language plpgsql
set search_path to 'public'
as $function$
declare
  v_duration_mode text;
begin
  if new.quote_snapshot is null then
    select s.duration_mode
      into v_duration_mode
    from public.services s
    where s.id = new.service_id;

    if not found then
      raise exception using errcode = 'P0001', message = 'SERVICE_NOT_AVAILABLE';
    end if;

    if v_duration_mode = 'BLOCKS' then
      if new.duration_blocks is null then
        raise exception using errcode = 'P0001', message = 'DURATION_BLOCKS_REQUIRED_FOR_BLOCK_PRICING';
      end if;

      new.quote_snapshot := public.calculate_booking_quote_for_duration(
        new.service_id,
        new.service_employee_id,
        new.duration_blocks,
        coalesce(new.extra_selections, '[]'::jsonb),
        new.people_count,
        coalesce(new.core_start_at, new.requested_start_at),
        null
      );
    else
      new.quote_snapshot := public.calculate_booking_quote(
        new.service_id,
        new.service_employee_id,
        coalesce(new.extra_selections, '[]'::jsonb),
        new.people_count,
        coalesce(new.core_start_at, new.requested_start_at),
        null
      );
    end if;
  end if;

  return new;
end;
$function$;

create or replace function public.populate_appointment_block_pricing_snapshots()
returns trigger
language plpgsql
set search_path to 'public'
as $function$
declare
  v_duration_mode text;
  v_quote jsonb;
  v_quote_start timestamptz;
begin
  select s.duration_mode
    into v_duration_mode
  from public.services s
  where s.id = new.service_id;

  if v_duration_mode = 'BLOCKS' then
    if new.duration_blocks is null then
      raise exception using errcode = 'P0001', message = 'DURATION_BLOCKS_REQUIRED_FOR_BLOCK_PRICING';
    end if;

    v_quote_start := coalesce(new.core_start_at, new.start_at);
    if v_quote_start is null then
      raise exception using errcode = 'P0001', message = 'BLOCK_PRICING_START_REQUIRED';
    end if;

    v_quote := public.calculate_booking_quote_for_duration(
      new.service_id,
      new.service_employee_id,
      new.duration_blocks,
      '[]'::jsonb,
      coalesce(new.people_count, 1),
      v_quote_start,
      null
    );

    new.base_price_snapshot := coalesce((v_quote->>'base_price')::numeric, new.base_price_snapshot, 0);
    new.surcharge_amount_snapshot := coalesce((v_quote->>'surcharge_amount')::numeric, 0);
    new.variable_price_adjustment :=
      coalesce((v_quote->>'day_time_adjustment')::numeric, 0)
      + coalesce((v_quote->>'people_adjustment')::numeric, 0);
  else
    new.surcharge_amount_snapshot := 0;
  end if;

  return new;
end;
$function$;

drop trigger if exists appointments_block_pricing_snapshot_insert_trg on public.appointments;
create trigger appointments_block_pricing_snapshot_insert_trg
before insert on public.appointments
for each row execute function public.populate_appointment_block_pricing_snapshots();

drop trigger if exists appointments_block_pricing_snapshot_reschedule_trg on public.appointments;
create trigger appointments_block_pricing_snapshot_reschedule_trg
before update of service_id, service_employee_id, start_at, core_start_at, duration_blocks, people_count
on public.appointments
for each row execute function public.populate_appointment_block_pricing_snapshots();

do $patch_admin_detail$
declare
  v_oid oid;
  v_definition text;
  v_patched text;
begin
  select p.oid
    into v_oid
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname = 'service_admin_get_appointment_base'
    and pg_get_function_identity_arguments(p.oid) = 'p_appointment_id uuid';

  if v_oid is null then
    raise exception 'service_admin_get_appointment_base not found';
  end if;

  v_definition := pg_get_functiondef(v_oid);

  if position('''surcharge_amount'',v_a.surcharge_amount_snapshot' in v_definition) = 0 then
    v_patched := replace(
      v_definition,
      '''base_price'',v_a.base_price_snapshot,''variable_price_adjustment''',
      '''base_price'',v_a.base_price_snapshot,''surcharge_amount'',v_a.surcharge_amount_snapshot,''variable_price_adjustment'''
    );

    if v_patched = v_definition then
      raise exception 'service_admin_get_appointment_base patch anchor not found';
    end if;

    execute v_patched;
  end if;
end;
$patch_admin_detail$;