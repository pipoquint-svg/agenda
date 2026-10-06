-- Coupons apply only to the contracted rental, including its day/time tariff.
-- Catalog extras, additional people and post-booking extras stay payable in full.
-- Existing finalized contracts are not repriced by this migration.

create or replace function public.calculate_rental_coupon_discount(
  p_discount_type text,
  p_discount_value numeric,
  p_rental_amount numeric
)
returns numeric
language plpgsql
immutable
security invoker
set search_path to 'pg_catalog'
as $function$
declare
  v_eligible numeric := round(greatest(coalesce(p_rental_amount, 0), 0), 2);
  v_discount numeric;
begin
  if p_discount_type = 'FIXED' then
    v_discount := coalesce(p_discount_value, 0);
  elsif p_discount_type = 'PERCENT' then
    v_discount := v_eligible * coalesce(p_discount_value, 0) / 100;
  else
    raise exception using errcode = 'P0001', message = 'INVALID_COUPON_DISCOUNT_TYPE';
  end if;

  return round(least(v_eligible, greatest(v_discount, 0)), 2);
end;
$function$;

revoke all on function public.calculate_rental_coupon_discount(text,numeric,numeric)
  from public, anon, authenticated;
grant execute on function public.calculate_rental_coupon_discount(text,numeric,numeric)
  to service_role;

comment on function public.calculate_rental_coupon_discount(text,numeric,numeric) is
  'Pure coupon arithmetic: rounds in cents and caps fixed or percentage discounts at the eligible rental amount.';

-- Keep the three existing engines and their validation/resource logic intact.
-- Production includes both formatted and historical compact definitions, hence
-- whitespace-tolerant anchors. Each required replacement fails closed on drift.
do $patch_quote_coupon_scope$
declare
  v_name text;
  v_oid oid;
  v_definition text;
  v_patched text;
  v_discount_pattern text := $pattern$if v_coupon\.discount_type[[:space:]]*=[[:space:]]*'FIXED' then[[:space:]]*v_coupon_discount[[:space:]]*:=[[:space:]]*least\(v_coupon\.discount_value,[[:space:]]*v_subtotal\);[[:space:]]*else[[:space:]]*v_coupon_discount[[:space:]]*:=[[:space:]]*round\(v_subtotal[[:space:]]*\*[[:space:]]*\(v_coupon\.discount_value[[:space:]]*/[[:space:]]*100\),[[:space:]]*2\);[[:space:]]*end if;$pattern$;
begin
  foreach v_name in array array[
    'calculate_booking_quote_base',
    'calculate_booking_quote_catalog_base',
    'calculate_booking_quotes_for_duration_batch'
  ] loop
    select p.oid into strict v_oid
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = v_name;

    v_definition := pg_get_functiondef(v_oid);
    v_patched := regexp_replace(v_definition, v_discount_pattern,
      $replacement$v_coupon_discount := public.calculate_rental_coupon_discount(
        v_coupon.discount_type,
        v_coupon.discount_value,
        greatest(least(v_after_day_time, v_after_people), 0)
      );$replacement$);
    if v_patched = v_definition then
      raise exception 'Rental coupon discount anchor missing: %', v_name;
    end if;

    v_definition := v_patched;
    v_patched := regexp_replace(v_definition,
      $pattern$'coupon_discount',[[:space:]]*v_coupon_discount$pattern$,
      $replacement$'coupon_scope', 'RENTAL_ONLY',
      'coupon_eligible_amount', round(greatest(least(v_after_day_time, v_after_people), 0), 2),
      'coupon_discount', v_coupon_discount$replacement$);
    if v_patched = v_definition then
      raise exception 'Rental coupon metadata anchor missing: %', v_name;
    end if;

    v_definition := v_patched;
    v_patched := regexp_replace(v_definition,
      $pattern$concat_ws\([[:space:]]*'\|',$pattern$,
      $replacement$concat_ws('|', 'COUPON_RENTAL_ONLY_V1',$replacement$);
    if v_patched = v_definition then
      raise exception 'Rental coupon pricing version anchor missing: %', v_name;
    end if;

    execute v_patched;
  end loop;
end;
$patch_quote_coupon_scope$;

-- Promotion must keep the already-applied coupon exactly once. Old ACTIVE
-- snapshots that discounted extras must be explicitly reapplied before submit;
-- never silently increase a customer-confirmed price during promotion.
do $patch_promotion_coupon_scope$
declare
  v_oid oid := 'public.promote_checkout_hold_standard(uuid,uuid,text,uuid[],jsonb,jsonb,inet,text)'::regprocedure;
  v_definition text;
  v_patched text;
begin
  v_definition := pg_get_functiondef(v_oid);
  v_patched := replace(v_definition,
    '  v_coupon_applied boolean := false;',
    '  v_coupon_applied boolean := false;
  v_coupon_eligible_amount numeric(12,2) := 0;');
  if v_patched = v_definition then
    raise exception 'Promotion rental coupon declaration anchor missing';
  end if;

  v_definition := v_patched;
  v_patched := replace(v_definition,
    '  v_extras_total := coalesce((v_quote->>''extras_total'')::numeric, 0);',
    '  v_extras_total := coalesce((v_quote->>''extras_total'')::numeric, 0);
  v_coupon_eligible_amount := round(greatest(least(
    v_base_price + v_day_time_adjustment,
    v_base_price + v_day_time_adjustment + v_people_adjustment
  ), 0), 2);');
  if v_patched = v_definition then
    raise exception 'Promotion rental coupon amount anchor missing';
  end if;

  v_definition := v_patched;
  v_patched := replace(v_definition,
    '      v_coupon_discount := round(coalesce(v_hold.coupon_discount, 0), 2);',
    '      if coalesce(v_hold.coupon_discount, 0) > v_coupon_eligible_amount
        or (
          coalesce(v_quote->>''coupon_scope'', '''') <> ''RENTAL_ONLY''
          and round(coalesce(v_hold.coupon_discount, 0), 2) is distinct from
            public.calculate_rental_coupon_discount(
              v_coupon.discount_type, v_coupon.discount_value, v_coupon_eligible_amount
            )
        )
      then
        raise exception using errcode = ''P0001'', message = ''CHECKOUT_COUPON_REAPPLY_REQUIRED'';
      end if;

      v_coupon_discount := round(coalesce(v_hold.coupon_discount, 0), 2);');
  if v_patched = v_definition then
    raise exception 'Promotion persisted rental coupon anchor missing';
  end if;

  v_definition := v_patched;
  v_patched := replace(v_definition,
    $old$      if v_coupon.discount_type = 'FIXED' then
        v_coupon_discount := least(v_coupon.discount_value, v_cash_due);
      else
        v_coupon_discount := round(v_cash_due * v_coupon.discount_value / 100, 2);
      end if;$old$,
    $new$      v_coupon_discount := public.calculate_rental_coupon_discount(
        v_coupon.discount_type, v_coupon.discount_value, v_coupon_eligible_amount
      );$new$);
  if v_patched = v_definition then
    raise exception 'Promotion direct rental coupon anchor missing';
  end if;

  v_definition := v_patched;
  v_patched := replace(v_definition,
    $old$      'coupon_applied', v_coupon_applied
    ),$old$,
    $new$      'coupon_applied', v_coupon_applied,
      'coupon_scope', 'RENTAL_ONLY',
      'coupon_eligible_amount', v_coupon_eligible_amount
    ),$new$);
  if v_patched = v_definition then
    raise exception 'Promotion rental coupon audit anchor missing';
  end if;

  execute v_patched;
end;
$patch_promotion_coupon_scope$;

-- Preserve the coupon scope agreed when the original appointment was created.
-- New contracts retain rental-only pricing through every reschedule; an existing
-- legacy contract is not repriced retroactively by a change of date.
create or replace function public.appointment_original_coupon_scope(p_appointment_id uuid)
returns text
language plpgsql
stable
set search_path = public
as $function$
declare
  v_scope text;
begin
  -- The original creation audit is append-only and outlives checkout holds.
  select nullif(coalesce(
    al.after_json->>'coupon_scope',
    al.after_json#>>'{quote_snapshot,coupon_scope}'
  ), '')
  into v_scope
  from public.audit_logs al
  where al.entity_type = 'APPOINTMENT'
    and al.entity_id = p_appointment_id
    and al.action = 'CHECKOUT_HOLD_PROMOTED'
  order by al.created_at, al.id
  limit 1;

  if v_scope is null then
    select nullif(ch.quote_snapshot->>'coupon_scope', '')
    into v_scope
    from public.checkout_holds ch
    where ch.promoted_appointment_id = p_appointment_id
      and ch.quote_snapshot is not null
    order by ch.created_at, ch.id
    limit 1;
  end if;

  if v_scope is null then
    select nullif(pr.quote_snapshot->>'coupon_scope', '')
    into v_scope
    from public.pre_reservations pr
    where pr.converted_appointment_id = p_appointment_id
      and pr.quote_snapshot is not null
    order by pr.created_at, pr.id
    limit 1;
  end if;

  if v_scope is null then
    return 'LEGACY_TOTAL';
  end if;
  if v_scope not in ('RENTAL_ONLY', 'LEGACY_TOTAL') then
    raise exception using errcode='P0001', message='APPOINTMENT_COUPON_SCOPE_INVALID';
  end if;
  return v_scope;
end;
$function$;

revoke all on function public.appointment_original_coupon_scope(uuid)
  from public, anon, authenticated;
grant execute on function public.appointment_original_coupon_scope(uuid)
  to service_role;

create or replace function public.calculate_reschedule_quote_for_appointment(
  p_appointment_id uuid,
  p_requested_start_at timestamptz
)
returns jsonb
language plpgsql
stable
set search_path = public, extensions
as $function$
declare
  v_appointment public.appointments%rowtype;
  v_extras jsonb;
  v_quote jsonb;
  v_discount public.appointment_discounts%rowtype;
  v_scope text;
  v_subtotal numeric(12,2);
  v_eligible_amount numeric(12,2);
  v_discount_amount numeric(12,2);
  v_total numeric(12,2);
  v_pricing_version text;
begin
  select * into v_appointment
  from public.appointments
  where id = p_appointment_id and deleted_at is null;
  if not found then
    raise exception using errcode='P0001', message='APPOINTMENT_NOT_FOUND';
  end if;

  select coalesce(jsonb_agg(
    jsonb_build_object('extra_id', ae.extra_id, 'quantity', ae.quantity)
    order by ae.extra_id
  ), '[]'::jsonb)
  into v_extras
  from public.appointment_extras ae
  where ae.appointment_id = p_appointment_id and ae.extra_id is not null;

  v_quote := public.calculate_booking_quote_for_duration(
    v_appointment.service_id,
    v_appointment.service_employee_id,
    v_appointment.duration_blocks,
    v_extras,
    v_appointment.people_count,
    p_requested_start_at,
    null
  );

  select * into v_discount
  from public.appointment_discounts
  where appointment_id = p_appointment_id;
  if not found then
    return v_quote;
  end if;
  if v_discount.discount_type_snapshot not in ('FIXED', 'PERCENT') then
    raise exception using errcode='P0001', message='APPOINTMENT_DISCOUNT_SNAPSHOT_INVALID';
  end if;

  v_scope := public.appointment_original_coupon_scope(p_appointment_id);
  v_subtotal := round(greatest(coalesce((v_quote->>'commercial_value')::numeric, 0), 0), 2);
  if v_scope = 'RENTAL_ONLY' then
    if v_quote->>'coupon_eligible_amount' is null then
      raise exception using errcode='P0001', message='RENTAL_COUPON_QUOTE_METADATA_MISSING';
    end if;
    v_eligible_amount := round(least(v_subtotal,
      greatest((v_quote->>'coupon_eligible_amount')::numeric, 0)), 2);
  else
    v_eligible_amount := v_subtotal;
  end if;

  -- A reschedule continues the same contract: use its original discount type,
  -- nominal value and scope, even when the coupon is now inactive or expired.
  -- No current coupon lookup or new coupon redemption belongs in this path.
  v_discount_amount := public.calculate_rental_coupon_discount(
    v_discount.discount_type_snapshot,
    v_discount.discount_value_snapshot,
    v_eligible_amount
  );
  v_total := round(greatest(v_subtotal - v_discount_amount, 0), 2);
  v_pricing_version := md5(concat_ws('|',
    coalesce(v_quote->>'pricing_version', ''),
    'RESCHEDULE_DISCOUNT_SCOPE_V2',
    v_scope,
    coalesce(v_discount.code_snapshot, ''),
    v_discount.discount_type_snapshot,
    v_discount.discount_value_snapshot::text
  ));

  return v_quote || jsonb_build_object(
    'coupon_code_snapshot', v_discount.code_snapshot,
    'coupon_scope', v_scope,
    'coupon_eligible_amount', v_eligible_amount,
    'coupon_discount', v_discount_amount,
    'discount_amount', v_discount_amount,
    'commercial_value', v_total,
    'total_amount', v_total,
    'pricing_version', v_pricing_version
  );
end;
$function$;

-- The client hold path previously repeated the discount math independently.
-- Delegate only its pricing block to the scope-aware function above, keeping
-- all slot, resource, timing, ACL and appointment-snapshot behavior in place.
do $patch_reschedule_coupon_scope$
declare
  v_definition text;
  v_pricing_start integer;
  v_pricing_end integer;
  v_start_anchor text := '  -- A remarcação parte do preço atual do novo horário, mas preserva a';
  v_end_anchor text := '  select coalesce(array_agg(r.resource_id order by r.resource_id)';
  v_new_pricing text := $pricing$
  v_quote := public.calculate_reschedule_quote_for_appointment(
    p_appointment_id, v_slot.core_start_at
  );
  v_discount_amount := round(coalesce((v_quote->>'coupon_discount')::numeric, 0), 2);
  v_commercial_value := round(coalesce((v_quote->>'commercial_value')::numeric, 0), 2);
  v_pre_discount_value := round(v_commercial_value + v_discount_amount, 2);
  v_pricing_version := coalesce(v_quote->>'pricing_version', '');

  if v_has_discount then
    v_quote := v_quote || jsonb_build_object(
      'coupon_code', v_discount.code_snapshot,
      'pre_discount_value', v_pre_discount_value,
      'discount_source', 'APPOINTMENT_SNAPSHOT',
      'discount_snapshot_type', v_discount.discount_type_snapshot,
      'discount_snapshot_value', v_discount.discount_value_snapshot
    );
  end if;

$pricing$;
begin
  v_definition := pg_get_functiondef(
    'public.create_checkout_hold_for_reschedule(uuid,timestamptz)'::regprocedure
  );
  v_pricing_start := strpos(v_definition, v_start_anchor);
  v_pricing_end := strpos(v_definition, v_end_anchor);
  if v_pricing_start = 0 or v_pricing_end <= v_pricing_start then
    raise exception 'create_checkout_hold_for_reschedule coupon pricing anchors not found';
  end if;
  execute substr(v_definition, 1, v_pricing_start - 1)
    || v_new_pricing || substr(v_definition, v_pricing_end);
end;
$patch_reschedule_coupon_scope$;
