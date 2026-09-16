-- Checkout coupons are already priced and persisted on checkout_holds before submit.
-- promote_checkout_hold_standard still contains the legacy path that recalculates the
-- same coupon from quote_snapshot->commercial_value, applying it a second time.
--
-- Preserve the legacy direct-coupon path for callers without a persisted hold coupon,
-- but treat the checkout hold snapshot as authoritative when applied_coupon_id exists.

do $patch_coupon_snapshot_single_application$
declare
  v_oid oid;
  v_definition text;
  v_patched text;
  v_legacy_anchor text := '    if p_coupon_code is not null and btrim(p_coupon_code) <> '''' then';
  v_replacement text := '    if v_hold.applied_coupon_id is not null then
      select c.* into v_coupon
      from public.coupons c
      where c.id = v_hold.applied_coupon_id
      for update;

      if not found
        or not v_coupon.is_active
        or (v_coupon.valid_from is not null and now() < v_coupon.valid_from)
        or (v_coupon.valid_until is not null and now() > v_coupon.valid_until)
      then
        raise exception using errcode = ''P0001'', message = ''INVALID_COUPON'';
      end if;

      if p_coupon_code is not null
        and btrim(p_coupon_code) <> ''''
        and lower(btrim(p_coupon_code)) <> lower(coalesce(v_hold.coupon_code_snapshot, v_coupon.code))
      then
        raise exception using errcode = ''P0001'', message = ''CHECKOUT_COUPON_SNAPSHOT_MISMATCH'';
      end if;

      if v_coupon.max_uses is not null and v_coupon.used_count >= v_coupon.max_uses then
        raise exception using errcode = ''P0001'', message = ''COUPON_USAGE_LIMIT_REACHED'';
      end if;

      if v_coupon.source = ''CANCELLATION_CREDIT''
        and v_coupon.customer_id <> p_customer_id
      then
        raise exception using errcode = ''P0001'', message = ''COUPON_CUSTOMER_MISMATCH'';
      end if;

      if exists (select 1 from public.coupon_services cs where cs.coupon_id = v_coupon.id)
        and not exists (
          select 1
          from public.coupon_services cs
          where cs.coupon_id = v_coupon.id
            and cs.service_id = v_hold.service_id
        )
      then
        raise exception using errcode = ''P0001'', message = ''INVALID_COUPON'';
      end if;

      if v_hold.pre_discount_value is not null
        and abs(v_hold.pre_discount_value - (v_hold.commercial_value + v_hold.coupon_discount)) > 0.01
      then
        raise exception using errcode = ''P0001'', message = ''CHECKOUT_COUPON_SNAPSHOT_INVALID'';
      end if;

      v_coupon_discount := round(coalesce(v_hold.coupon_discount, 0), 2);
      v_cash_due := round(coalesce(v_hold.commercial_value, v_contract_value_before_package), 2);
      v_coupon_applied := true;
    elsif p_coupon_code is not null and btrim(p_coupon_code) <> '''' then';
begin
  select p.oid
    into v_oid
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname = 'promote_checkout_hold_standard'
    and pg_get_function_identity_arguments(p.oid) = 'p_checkout_hold_id uuid, p_customer_id uuid, p_coupon_code text, p_term_version_ids uuid[], p_participants jsonb, p_answers jsonb, p_acceptance_ip inet, p_acceptance_user_agent text';

  if v_oid is null then
    raise exception 'promote_checkout_hold_standard not found';
  end if;

  v_definition := pg_get_functiondef(v_oid);

  if position('if v_hold.applied_coupon_id is not null then' in v_definition) > 0 then
    return;
  end if;

  v_patched := replace(v_definition, v_legacy_anchor, v_replacement);

  if v_patched = v_definition then
    raise exception 'promote_checkout_hold_standard coupon patch anchor not found';
  end if;

  execute v_patched;
end;
$patch_coupon_snapshot_single_application$;

comment on function public.promote_checkout_hold_standard(uuid,uuid,text,uuid[],jsonb,jsonb,inet,text) is
  'Promotes a checkout hold. Persisted checkout coupon snapshots are authoritative and are applied exactly once.';
