-- BlackSheep Rewards S5: campaign coupons expire by confirmation time, while
-- every pre-existing coupon keeps the established rental-start interpretation.

alter table public.coupons
  add column validity_basis text not null default 'RENTAL_START'
  check (validity_basis in ('BOOKING_CONFIRMATION', 'RENTAL_START'));

comment on column public.coupons.validity_basis is
  'Coupon validity clock. Legacy coupons use RENTAL_START; Rewards campaign issuances snapshot BOOKING_CONFIRMATION.';

create or replace function public.coupon_is_valid_for_booking(
  p_coupon public.coupons,
  p_rental_start_at timestamptz,
  p_evaluated_at timestamptz default now()
)
returns boolean
language sql
stable
set search_path = public
as $function$
  select p_coupon.is_active
    and (
      p_coupon.valid_from is null
      or case p_coupon.validity_basis
           when 'BOOKING_CONFIRMATION' then p_evaluated_at
           else coalesce(p_rental_start_at, p_evaluated_at)
         end >= p_coupon.valid_from
    )
    and (
      p_coupon.valid_until is null
      or case p_coupon.validity_basis
           when 'BOOKING_CONFIRMATION' then p_evaluated_at
           else coalesce(p_rental_start_at, p_evaluated_at)
         end <= p_coupon.valid_until
    );
$function$;

revoke all on function public.coupon_is_valid_for_booking(public.coupons,timestamptz,timestamptz)
  from public, anon, authenticated;
grant execute on function public.coupon_is_valid_for_booking(public.coupons,timestamptz,timestamptz)
  to service_role;

comment on function public.coupon_is_valid_for_booking(public.coupons,timestamptz,timestamptz) is
  'Internal validity boundary. BOOKING_CONFIRMATION evaluates at checkout/confirmation; legacy RENTAL_START evaluates against the booked rental.';

-- Keep the S4 issuance action as the only writer of a Rewards coupon's
-- confirmation-based basis. The version is immutable after publication.
do $patch_rewards_issuance_validity_basis$
declare
  v_definition text;
  v_columns text := E'    used_count, discount_scope\n  ) values (';
  v_values text := E'    v_version.max_uses, v_version.max_uses_per_customer, 0, v_version.discount_scope\n  ) returning id into v_coupon_id;';
begin
  v_definition := pg_get_functiondef(
    'public.service_issue_marketing_campaign_coupon(uuid,uuid,text)'::regprocedure
  );

  if position(v_columns in v_definition) = 0 or position(v_values in v_definition) = 0 then
    raise exception 'REWARDS_S5_ISSUANCE_VALIDITY_ANCHOR_NOT_FOUND';
  end if;

  v_definition := replace(
    v_definition,
    v_columns,
    E'    used_count, discount_scope, validity_basis\n  ) values ('
  );
  v_definition := replace(
    v_definition,
    v_values,
    E'    v_version.max_uses, v_version.max_uses_per_customer, 0, v_version.discount_scope, v_version.validity_basis\n  ) returning id into v_coupon_id;'
  );
  execute v_definition;
end;
$patch_rewards_issuance_validity_basis$;

-- Both pricing cores and all coupon-bearing checkout paths delegate to the
-- same boundary. Fail loudly if a future source definition drifts.
do $patch_coupon_booking_validity$
declare
  v_patch record;
  v_definition text;
  v_patched text;
begin
  for v_patch in
    select *
    from (values
      (
        'public.calculate_booking_quote_catalog_base(uuid,uuid,jsonb,integer,timestamp with time zone,text)',
        E'      and (c.valid_from is null or coalesce(p_requested_start_at,now())>=c.valid_from)\n      and (c.valid_until is null or coalesce(p_requested_start_at,now())<=c.valid_until)',
        E'      and public.coupon_is_valid_for_booking(c, p_requested_start_at)'
      ),
      (
        'public.calculate_booking_quotes_for_duration_batch(uuid,uuid,integer,jsonb,integer,timestamp with time zone[],text)',
        E'      if (v_coupon.valid_from is not null and coalesce(v_start, now()) < v_coupon.valid_from)\n         or (v_coupon.valid_until is not null and coalesce(v_start, now()) > v_coupon.valid_until)\n      then',
        E'      if not public.coupon_is_valid_for_booking(v_coupon, v_start) then'
      )
    ) as p(signature, anchor, replacement)
  loop
    v_definition := pg_get_functiondef(v_patch.signature::regprocedure);
    if position(v_patch.anchor in v_definition) = 0 then
      raise exception 'REWARDS_S5_BOOKING_VALIDITY_ANCHOR_NOT_FOUND: %', v_patch.signature;
    end if;
    v_patched := replace(v_definition, v_patch.anchor, v_patch.replacement);
    execute v_patched;
  end loop;

end;
$patch_coupon_booking_validity$;

-- A persisted hold can be paid after the Rewards window closes. Do not turn it
-- into a confirmed appointment in that case; legacy coupons are intentionally
-- excluded and retain their historical rental-start contract.
create or replace function public.trg_appointment_enforce_campaign_coupon_confirmation_validity()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_coupon public.coupons%rowtype;
begin
  if new.status <> 'CONFIRMED' or old.status = 'CONFIRMED' then
    return new;
  end if;

  select c.*
    into v_coupon
  from public.appointment_discounts d
  join public.coupons c on c.id = d.coupon_id
  join public.marketing_campaign_issuances i on i.coupon_id = c.id
  where d.appointment_id = new.id
  for key share of c;

  if found and not public.coupon_is_valid_for_booking(v_coupon, new.start_at) then
    raise exception using
      errcode = 'P0001',
      message = 'MARKETING_CAMPAIGN_COUPON_EXPIRED_AT_CONFIRMATION';
  end if;

  return new;
end;
$function$;

drop trigger if exists appointments_campaign_coupon_confirmation_validity on public.appointments;
create trigger appointments_campaign_coupon_confirmation_validity
before update of status on public.appointments
for each row
when (old.status is distinct from new.status)
execute function public.trg_appointment_enforce_campaign_coupon_confirmation_validity();

revoke all on function public.trg_appointment_enforce_campaign_coupon_confirmation_validity()
  from public, anon, authenticated, service_role;
