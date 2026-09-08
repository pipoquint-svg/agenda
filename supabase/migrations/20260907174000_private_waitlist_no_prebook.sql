-- Private waitlist opportunities are intentionally first-come and use the
-- short checkout hold only. A customer who normally has the 48h pre-reservation
-- benefit must not extend a scarce private invitation into a long prebook.

create or replace function public.service_public_get_checkout_prebook_option(
  p_checkout_hold_token text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions'
as $function$
declare
  v_hold public.checkout_holds%rowtype;
  v_terms public.customer_commercial_terms%rowtype;
  v_global_minutes integer := 2880;
  v_active_count integer := 0;
  v_authorized boolean := false;
  v_eligible boolean := false;
begin
  select * into v_hold from public.checkout_holds
  where public_token_hash = encode(digest(p_checkout_hold_token,'sha256'),'hex') for update;
  if not found or v_hold.status <> 'ACTIVE' or v_hold.expires_at <= now() then
    raise exception using errcode='P0001',message='CHECKOUT_HOLD_NOT_ACTIVE';
  end if;
  if v_hold.primary_customer_id is null then
    raise exception using errcode='P0001',message='CHECKOUT_CUSTOMER_REQUIRED';
  end if;

  if coalesce(v_hold.attribution_json->>'source','') = 'WAITLIST_PRIVATE_INVITE' then
    return jsonb_build_object(
      'eligible', false,
      'available', false,
      'active_count', 0,
      'max_active_prebooks', 0,
      'hold_minutes', 0,
      'reason', 'PREBOOK_NOT_AVAILABLE'
    );
  end if;

  select prebook_hold_minutes into v_global_minutes from public.operation_settings where id=1;
  if coalesce(v_global_minutes,0) <= 0 then
    raise exception using errcode='P0001',message='PREBOOK_GLOBAL_HOLD_INVALID';
  end if;

  select * into v_terms from public.customer_commercial_terms
  where customer_id = v_hold.primary_customer_id and is_active = true;
  if found then
    select exists(select 1 from public.customer_prebook_authorized_services cas
      where cas.customer_id = v_hold.primary_customer_id and cas.service_id = v_hold.service_id) into v_authorized;
    v_eligible := coalesce(v_terms.can_prebook,false) and v_terms.billing_mode = 'CHECKOUT' and v_authorized;
  end if;

  if v_eligible then
    perform public.service_expire_pre_reservations();
    select count(*)::integer into v_active_count from public.pre_reservations pr
    where pr.customer_id = v_hold.primary_customer_id and pr.status = 'ACTIVE' and pr.expires_at > now();
  end if;

  return jsonb_build_object(
    'eligible', v_eligible,
    'available', v_eligible and v_active_count < coalesce(v_terms.max_active_prebooks,0),
    'active_count', v_active_count,
    'max_active_prebooks', case when v_eligible then v_terms.max_active_prebooks else 0 end,
    'hold_minutes', v_global_minutes,
    'reason', case
      when not found then 'PREBOOK_NOT_ENABLED'
      when not coalesce(v_terms.can_prebook,false) then 'PREBOOK_NOT_ENABLED'
      when v_terms.billing_mode <> 'CHECKOUT' then 'PREBOOK_NOT_AVAILABLE'
      when not v_authorized then 'SERVICE_NOT_AUTHORIZED_FOR_PREBOOK'
      when v_active_count >= coalesce(v_terms.max_active_prebooks,0) then 'MAX_ACTIVE_PREBOOKS_REACHED'
      else null end
  );
end;
$function$;
