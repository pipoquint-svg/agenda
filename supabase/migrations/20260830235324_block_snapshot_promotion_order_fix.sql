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
    -- promote_checkout_hold_standard cria a linha da reserva antes de
    -- sync_promoted_appointment_schedule copiar duration_blocks do hold.
    -- Nesse primeiro INSERT, preserva os snapshots que vieram do quote do hold;
    -- a atualizacao seguinte de duration_blocks dispara este mesmo motor novamente.
    if new.duration_blocks is null then
      new.surcharge_amount_snapshot := coalesce(new.surcharge_amount_snapshot, 0);
      return new;
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