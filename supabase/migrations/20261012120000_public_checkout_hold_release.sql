-- Late checkout hold: explicit, token-scoped release of a public checkout hold.
--
-- Public journeys now create the 10-minute hold only when the customer enters
-- the personal-data step. When that customer goes back and replaces the
-- protected selection (another time, another duration), the previous hold must
-- not keep blocking the resources until it expires. This RPC lets the holder of
-- the opaque checkout token release that hold idempotently.
--
-- Contract:
-- * service_role only (called by the booking-checkout Edge Function);
-- * possession of the raw token is the only authority (hash lookup, as in every
--   other public checkout RPC);
-- * only ACTIVE, unpromoted public booking-page holds are released;
-- * admin reschedule holds and private waitlist invitation holds keep their own
--   contracts and are refused;
-- * repeated calls, unknown, expired, promoted or already released tokens are
--   no-ops that never raise, so the browser can retry safely;
-- * no appointment, payment, coupon redemption or customer record is touched.

create or replace function public.service_public_release_checkout_hold(p_checkout_hold_token text)
returns jsonb
language plpgsql
security definer
set search_path to 'public','extensions'
as $function$
declare
  v_hold public.checkout_holds%rowtype;
begin
  if p_checkout_hold_token is null or length(trim(p_checkout_hold_token)) < 32 then
    raise exception using errcode = 'P0001', message = 'CHECKOUT_HOLD_TOKEN_REQUIRED';
  end if;

  select * into v_hold
  from public.checkout_holds
  where public_token_hash = encode(digest(trim(p_checkout_hold_token), 'sha256'), 'hex')
  for update;

  if not found then
    return jsonb_build_object('released', false, 'status', 'NOT_FOUND');
  end if;

  if v_hold.status <> 'ACTIVE' or v_hold.promoted_appointment_id is not null then
    return jsonb_build_object('released', false, 'status', v_hold.status);
  end if;

  if v_hold.booking_page_id is null
     or exists (
       select 1 from public.appointment_policy_actions apa
       where apa.reschedule_checkout_hold_id = v_hold.id
     )
     or exists (
       select 1 from public.waitlist_private_slots wps
       where wps.claimed_checkout_hold_id = v_hold.id
     )
     or exists (
       select 1 from public.waitlist_private_invites wpi
       where wpi.checkout_hold_id = v_hold.id
     ) then
    raise exception using errcode = 'P0001', message = 'CHECKOUT_HOLD_RELEASE_NOT_ALLOWED';
  end if;

  update public.resource_allocations
  set status = 'RELEASED', updated_at = now()
  where checkout_hold_id = v_hold.id
    and allocation_type = 'CHECKOUT_HOLD'
    and status = 'HELD';

  update public.checkout_hour_package_reservations
  set status = 'RELEASED',
      released_at = now(),
      release_reason = 'CHECKOUT_HOLD_RELEASED',
      updated_at = now()
  where checkout_hold_id = v_hold.id
    and status = 'HELD';

  update public.checkout_holds
  set status = 'INVALIDATED', updated_at = now()
  where id = v_hold.id;

  return jsonb_build_object('released', true, 'status', 'INVALIDATED');
end;
$function$;

alter function public.service_public_release_checkout_hold(text) owner to postgres;
revoke all on function public.service_public_release_checkout_hold(text) from public, anon, authenticated;
grant execute on function public.service_public_release_checkout_hold(text) to service_role;

comment on function public.service_public_release_checkout_hold(text) is
  'Idempotent, token-scoped release of an ACTIVE public booking-page checkout hold. Service-role only; refuses reschedule and private waitlist holds.';
