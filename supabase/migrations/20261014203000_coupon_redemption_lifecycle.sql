-- S0.5 — Coupon redemption lifecycle and discount scope.
--
-- Forward-only, expand-only. No data row is updated by this migration (no backfill):
-- new columns are nullable or use a constant default, and historical rows are
-- classified at read time from the appointment status they already carry.
--
-- 1. appointment_discounts becomes the coupon redemption ledger (reuse, no parallel table):
--      RESERVED  appointment created but not confirmed (AWAITING_PAYMENT / HELD / DRAFT)
--      REDEEMED  appointment confirmed (CONFIRMED / COMPLETED / NO_SHOW); this is the
--                definitive consumption, including confirmed invoice (UNPAID_AUTHORIZED)
--                and minimum-payment (50%) confirmations
--      RELEASED  released_at set, or appointment EXPIRED / CANCELLED
--    coupons.used_count keeps its meaning (RESERVED + REDEEMED), so max_uses still
--    blocks concurrent reservations of a single-use coupon under the coupon row lock.
-- 2. Release is idempotent: one release per appointment, whatever caller runs first.
-- 3. The per-customer limit counts only non-RELEASED redemptions; history is kept.
-- 4. coupons.discount_scope: ORDER_SUBTOTAL (default, unchanged behavior: service price
--    after day/time surcharge and people adjustments, plus extras) or SERVICE_ONLY
--    (same, excluding extras). Existing coupons and the birthday automation keep
--    ORDER_SUBTOTAL; no commercial condition changes here.
--
-- Appointment status is never written by this migration's code. No Kommo trigger fires
-- from it: the new trigger only touches appointment_discounts and coupons.

-- ---------------------------------------------------------------------------
-- Schema
-- ---------------------------------------------------------------------------

alter table public.coupons
  add column if not exists discount_scope text not null default 'ORDER_SUBTOTAL';

alter table public.coupons drop constraint if exists coupons_discount_scope_check;
alter table public.coupons add constraint coupons_discount_scope_check
  check (discount_scope in ('ORDER_SUBTOTAL','SERVICE_ONLY'));

comment on column public.coupons.discount_scope is
  'Discount base. ORDER_SUBTOTAL: service price (after surcharges/people) plus extras. SERVICE_ONLY: excludes extras.';

alter table public.appointment_discounts
  add column if not exists discount_scope_snapshot text not null default 'ORDER_SUBTOTAL',
  add column if not exists reserved_at timestamptz,
  add column if not exists redeemed_at timestamptz,
  add column if not exists released_at timestamptz,
  add column if not exists release_reason text;

alter table public.appointment_discounts drop constraint if exists appointment_discounts_scope_snapshot_check;
alter table public.appointment_discounts add constraint appointment_discounts_scope_snapshot_check
  check (discount_scope_snapshot in ('ORDER_SUBTOTAL','SERVICE_ONLY'));

alter table public.appointment_discounts drop constraint if exists appointment_discounts_release_reason_check;
alter table public.appointment_discounts add constraint appointment_discounts_release_reason_check
  check (released_at is null or nullif(btrim(release_reason), '') is not null);

comment on column public.appointment_discounts.reserved_at is
  'Set when the redemption is created. Null only for rows created before the S0.5 lifecycle.';
comment on column public.appointment_discounts.redeemed_at is
  'Set when the appointment is confirmed. Rows created before S0.5 are classified by appointment status.';
comment on column public.appointment_discounts.released_at is
  'Set exactly once when the redemption is released. Rows created before S0.5 for EXPIRED/CANCELLED appointments are classified RELEASED by appointment status.';

-- ---------------------------------------------------------------------------
-- Pure helpers
-- ---------------------------------------------------------------------------

create or replace function public.coupon_discount_amount(
  p_discount_type text,
  p_discount_value numeric,
  p_discount_scope text,
  p_subtotal numeric,
  p_extras_total numeric
)
returns numeric
language plpgsql
immutable
set search_path = public
as $$
declare
  v_base numeric;
begin
  if p_discount_scope is null or p_discount_scope = 'ORDER_SUBTOTAL' then
    v_base := coalesce(p_subtotal, 0);
  elsif p_discount_scope = 'SERVICE_ONLY' then
    v_base := round(greatest(coalesce(p_subtotal, 0) - coalesce(p_extras_total, 0), 0), 2);
  else
    raise exception using errcode = 'P0001', message = 'COUPON_DISCOUNT_SCOPE_INVALID';
  end if;

  -- Same arithmetic as the pricing cores before S0.5 for ORDER_SUBTOTAL.
  if p_discount_type = 'FIXED' then
    return least(p_discount_value, v_base);
  elsif p_discount_type = 'PERCENT' then
    return round(v_base * (p_discount_value / 100), 2);
  end if;

  raise exception using errcode = 'P0001', message = 'COUPON_DISCOUNT_TYPE_INVALID';
end;
$$;

comment on function public.coupon_discount_amount(text,numeric,text,numeric,numeric) is
  'Single coupon discount formula for checkout, legacy promotion and reschedule snapshots.';

create or replace function public.coupon_redemption_status(
  p_released_at timestamptz,
  p_redeemed_at timestamptz,
  p_appointment_status text
)
returns text
language sql
immutable
set search_path = public
as $$
  select case
    when p_released_at is not null or p_appointment_status in ('EXPIRED','CANCELLED') then 'RELEASED'
    when p_redeemed_at is not null or p_appointment_status in ('CONFIRMED','COMPLETED','NO_SHOW') then 'REDEEMED'
    else 'RESERVED'
  end;
$$;

comment on function public.coupon_redemption_status(timestamptz,timestamptz,text) is
  'Effective redemption state. Appointment status classifies rows created before the S0.5 lifecycle without a backfill.';

-- ---------------------------------------------------------------------------
-- Redemption lifecycle
-- ---------------------------------------------------------------------------

create or replace function public.trg_appointment_discount_lifecycle_defaults()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_scope text;
  v_status text;
begin
  new.reserved_at := coalesce(new.reserved_at, now());
  new.redeemed_at := null;
  new.released_at := null;
  new.release_reason := null;

  if new.coupon_id is not null then
    select c.discount_scope into v_scope from public.coupons c where c.id = new.coupon_id;
    new.discount_scope_snapshot := coalesce(v_scope, 'ORDER_SUBTOTAL');
  end if;

  select a.status into v_status from public.appointments a where a.id = new.appointment_id;
  if v_status in ('CONFIRMED','COMPLETED','NO_SHOW') then
    new.redeemed_at := new.reserved_at;
  end if;

  return new;
end;
$$;

drop trigger if exists appointment_discounts_lifecycle_defaults on public.appointment_discounts;
create trigger appointment_discounts_lifecycle_defaults
before insert on public.appointment_discounts
for each row execute function public.trg_appointment_discount_lifecycle_defaults();

create or replace function public.service_release_appointment_coupon(
  p_appointment_id uuid,
  p_reason text,
  p_status_transition boolean default false
)
returns boolean
language plpgsql
set search_path = public
as $$
declare
  v_discount public.appointment_discounts%rowtype;
  v_appointment_status text;
begin
  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception using errcode = 'P0001', message = 'COUPON_RELEASE_REASON_REQUIRED';
  end if;

  select ad.* into v_discount
  from public.appointment_discounts ad
  where ad.appointment_id = p_appointment_id
  for update;

  if not found or v_discount.released_at is not null then
    return false;
  end if;

  select a.status into v_appointment_status
  from public.appointments a
  where a.id = p_appointment_id;

  update public.appointment_discounts
  set released_at = now(),
      release_reason = p_reason
  where appointment_id = p_appointment_id
    and released_at is null;

  -- A direct call on an appointment that was already EXPIRED/CANCELLED before this
  -- lifecycle existed only records the release: the legacy path already returned
  -- the counter. Status-transition calls always return it exactly once.
  if v_discount.coupon_id is not null
     and (p_status_transition or v_appointment_status not in ('EXPIRED','CANCELLED'))
  then
    update public.coupons
    set used_count = greatest(used_count - 1, 0),
        updated_at = now()
    where id = v_discount.coupon_id
      and used_count > 0;
  end if;

  return true;
end;
$$;

comment on function public.service_release_appointment_coupon(uuid,text,boolean) is
  'Idempotent coupon release: marks the redemption RELEASED once and returns the coupon usage at most once.';

-- Existing callers (expiry, cancellation, change workflows) keep their call site.
create or replace function public.release_appointment_coupon_usage(
  p_appointment_id uuid
)
returns void
language plpgsql
volatile
set search_path = public
as $$
begin
  perform public.service_release_appointment_coupon(p_appointment_id, 'RELEASE_REQUESTED', false);
end;
$$;

create or replace function public.trg_appointment_coupon_redemption_lifecycle()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.status in ('EXPIRED','CANCELLED') then
    perform public.service_release_appointment_coupon(new.id, 'APPOINTMENT_' || new.status, true);
  elsif new.status in ('CONFIRMED','COMPLETED','NO_SHOW') then
    update public.appointment_discounts
    set redeemed_at = now()
    where appointment_id = new.id
      and redeemed_at is null
      and released_at is null;
  end if;
  return null;
end;
$$;

drop trigger if exists appointments_coupon_redemption_lifecycle on public.appointments;
create trigger appointments_coupon_redemption_lifecycle
after update of status on public.appointments
for each row
when (old.status is distinct from new.status)
execute function public.trg_appointment_coupon_redemption_lifecycle();

-- ---------------------------------------------------------------------------
-- Per-customer limit: count only non-released redemptions
-- ---------------------------------------------------------------------------

create or replace function public.enforce_coupon_customer_usage_limit()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_limit integer;
  v_customer_id uuid;
  v_used integer;
begin
  if new.coupon_id is null then return new; end if;
  select c.max_uses_per_customer into v_limit from public.coupons c where c.id = new.coupon_id for update;
  if v_limit is null then return new; end if;
  select a.primary_customer_id into v_customer_id from public.appointments a where a.id = new.appointment_id;
  if v_customer_id is null then raise exception using errcode='P0001', message='COUPON_CUSTOMER_REQUIRED'; end if;
  select count(*)::integer into v_used
  from public.appointment_discounts ad
  join public.appointments a on a.id = ad.appointment_id
  where ad.coupon_id = new.coupon_id
    and a.primary_customer_id = v_customer_id
    and public.coupon_redemption_status(ad.released_at, ad.redeemed_at, a.status) <> 'RELEASED';
  if v_used >= v_limit then raise exception using errcode='P0001', message='COUPON_CUSTOMER_USAGE_LIMIT_REACHED'; end if;
  return new;
end;
$$;

create or replace function public.enforce_checkout_coupon_customer()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_coupon public.coupons%rowtype;
  v_used integer;
begin
  if new.applied_coupon_id is null or new.primary_customer_id is null then return new; end if;
  select * into v_coupon from public.coupons where id = new.applied_coupon_id for update;
  if not found or not v_coupon.is_active or (v_coupon.valid_from is not null and now() < v_coupon.valid_from) or (v_coupon.valid_until is not null and now() > v_coupon.valid_until) then raise exception using errcode='P0001', message='INVALID_COUPON'; end if;
  if v_coupon.customer_id is not null and v_coupon.customer_id <> new.primary_customer_id then raise exception using errcode='P0001', message='COUPON_CUSTOMER_MISMATCH'; end if;
  if v_coupon.max_uses is not null and v_coupon.used_count >= v_coupon.max_uses then raise exception using errcode='P0001', message='COUPON_USAGE_LIMIT_REACHED'; end if;
  if v_coupon.max_uses_per_customer is not null then
    select count(*)::integer into v_used
    from public.appointment_discounts ad
    join public.appointments a on a.id = ad.appointment_id
    where ad.coupon_id = v_coupon.id
      and a.primary_customer_id = new.primary_customer_id
      and public.coupon_redemption_status(ad.released_at, ad.redeemed_at, a.status) <> 'RELEASED';
    if v_used >= v_coupon.max_uses_per_customer then raise exception using errcode='P0001', message='COUPON_CUSTOMER_USAGE_LIMIT_REACHED'; end if;
  end if;
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- Discount scope in both pricing cores, the legacy promotion path and reschedules.
-- Patched in place from the live definition with fail-loud anchors.
-- ---------------------------------------------------------------------------

do $patch_coupon_discount_scope$
declare
  v_patch record;
  v_definition text;
  v_patched text;
begin
  for v_patch in
    select *
    from (values
      (
        'public.calculate_booking_quote_catalog_base(uuid,uuid,jsonb,integer,timestamptz,text)',
        E'    if v_coupon.discount_type=''FIXED'' then v_coupon_discount:=least(v_coupon.discount_value,v_subtotal);\n    else v_coupon_discount:=round(v_subtotal*(v_coupon.discount_value/100),2); end if;',
        E'    v_coupon_discount:=public.coupon_discount_amount(v_coupon.discount_type,v_coupon.discount_value,v_coupon.discount_scope,v_subtotal,v_extras_total);'
      ),
      (
        'public.calculate_booking_quotes_for_duration_batch(uuid,uuid,integer,jsonb,integer,timestamptz[],text)',
        E'      if v_coupon.discount_type = ''FIXED'' then\n        v_coupon_discount := least(v_coupon.discount_value, v_subtotal);\n      else\n        v_coupon_discount := round(v_subtotal * (v_coupon.discount_value / 100), 2);\n      end if;',
        E'      v_coupon_discount := public.coupon_discount_amount(\n        v_coupon.discount_type, v_coupon.discount_value, v_coupon.discount_scope, v_subtotal, v_extras_total\n      );'
      ),
      (
        'public.promote_checkout_hold_standard(uuid,uuid,text,uuid[],jsonb,jsonb,inet,text)',
        E'      if v_coupon.discount_type = ''FIXED'' then\n        v_coupon_discount := least(v_coupon.discount_value, v_cash_due);\n      else\n        v_coupon_discount := round(v_cash_due * v_coupon.discount_value / 100, 2);\n      end if;',
        E'      v_coupon_discount := public.coupon_discount_amount(\n        v_coupon.discount_type, v_coupon.discount_value, v_coupon.discount_scope, v_cash_due, v_extras_total\n      );'
      ),
      (
        'public.calculate_reschedule_quote_for_appointment(uuid,timestamptz)',
        E'    v_discount_amount := least(round(v_discount.discount_value_snapshot, 2), v_subtotal);',
        E'    v_discount_amount := public.coupon_discount_amount(\n      ''FIXED'', round(v_discount.discount_value_snapshot, 2), v_discount.discount_scope_snapshot,\n      v_subtotal, coalesce((v_quote->>''extras_total'')::numeric, 0)\n    );'
      ),
      (
        'public.calculate_reschedule_quote_for_appointment(uuid,timestamptz)',
        E'    v_discount_amount := round(v_subtotal * (v_discount.discount_value_snapshot / 100), 2);',
        E'    v_discount_amount := public.coupon_discount_amount(\n      ''PERCENT'', v_discount.discount_value_snapshot, v_discount.discount_scope_snapshot,\n      v_subtotal, coalesce((v_quote->>''extras_total'')::numeric, 0)\n    );'
      ),
      (
        'public.create_checkout_hold_for_reschedule(uuid,timestamptz)',
        E'        v_pre_discount_value * v_discount.discount_value_snapshot / 100,',
        E'        public.coupon_discount_amount(''PERCENT'',v_discount.discount_value_snapshot,v_discount.discount_scope_snapshot,v_pre_discount_value,coalesce((v_quote->>''extras_total'')::numeric,0)),'
      ),
      (
        'public.create_checkout_hold_for_reschedule(uuid,timestamptz)',
        E'        least(v_discount.discount_value_snapshot,v_pre_discount_value),',
        E'        public.coupon_discount_amount(''FIXED'',v_discount.discount_value_snapshot,v_discount.discount_scope_snapshot,v_pre_discount_value,coalesce((v_quote->>''extras_total'')::numeric,0)),'
      )
    ) as p(signature, anchor, replacement)
  loop
    v_definition := pg_get_functiondef(v_patch.signature::regprocedure);
    if position(v_patch.anchor in v_definition) = 0 then
      raise exception 'S05_COUPON_SCOPE_ANCHOR_NOT_FOUND: %', v_patch.signature;
    end if;
    v_patched := replace(v_definition, v_patch.anchor, v_patch.replacement);
    execute v_patched;
  end loop;
end;
$patch_coupon_discount_scope$;

-- ---------------------------------------------------------------------------
-- Admin read models: released redemptions stay in history but are not uses.
-- ---------------------------------------------------------------------------

do $patch_coupon_admin_counts$
declare
  v_definition text;
  v_old_list text := E'''actual_used_count'',(select count(*) from public.appointment_discounts ad where ad.coupon_id=c.id),';
  v_new_list text := E'''actual_used_count'',(select count(*) from public.appointment_discounts ad join public.appointments a on a.id=ad.appointment_id where ad.coupon_id=c.id and public.coupon_redemption_status(ad.released_at,ad.redeemed_at,a.status)<>''RELEASED''),''reserved_count'',(select count(*) from public.appointment_discounts ad join public.appointments a on a.id=ad.appointment_id where ad.coupon_id=c.id and public.coupon_redemption_status(ad.released_at,ad.redeemed_at,a.status)=''RESERVED''),''discount_scope'',c.discount_scope,';
  v_old_page text := E'        ''actual_used_count'', (\n          select count(*)\n          from public.appointment_discounts ad\n          where ad.coupon_id = c.id\n        ),';
  v_new_page text := E'        ''actual_used_count'', (\n          select count(*)\n          from public.appointment_discounts ad\n          join public.appointments a on a.id = ad.appointment_id\n          where ad.coupon_id = c.id\n            and public.coupon_redemption_status(ad.released_at, ad.redeemed_at, a.status) <> ''RELEASED''\n        ),\n        ''reserved_count'', (\n          select count(*)\n          from public.appointment_discounts ad\n          join public.appointments a on a.id = ad.appointment_id\n          where ad.coupon_id = c.id\n            and public.coupon_redemption_status(ad.released_at, ad.redeemed_at, a.status) = ''RESERVED''\n        ),\n        ''discount_scope'', c.discount_scope,';
begin
  v_definition := pg_get_functiondef('public.admin_list_coupons()'::regprocedure);
  if position(v_old_list in v_definition) = 0 then
    raise exception 'S05_COUPON_ADMIN_ANCHOR_NOT_FOUND: admin_list_coupons';
  end if;
  execute replace(v_definition, v_old_list, v_new_list);

  v_definition := pg_get_functiondef('public.admin_list_coupons_page(integer,integer)'::regprocedure);
  if position(v_old_page in v_definition) = 0 then
    raise exception 'S05_COUPON_ADMIN_ANCHOR_NOT_FOUND: admin_list_coupons_page';
  end if;
  execute replace(v_definition, v_old_page, v_new_page);
end;
$patch_coupon_admin_counts$;

create or replace function public.admin_coupon_metrics()
returns jsonb
language sql
stable security definer
set search_path to 'public', 'pg_temp'
as $function$
with usage as (
  select c.id,c.code,count(ad.appointment_id)::integer as uses,coalesce(sum(ad.calculated_discount_amount),0)::numeric(12,2) as discount_total
  from public.coupons c
  left join (
    public.appointment_discounts ad
    join public.appointments a on a.id=ad.appointment_id
      and public.coupon_redemption_status(ad.released_at,ad.redeemed_at,a.status)<>'RELEASED'
  ) on ad.coupon_id=c.id
  group by c.id,c.code
), ranked as (select * from usage order by uses desc,code asc)
select jsonb_build_object(
  'total_uses',(select coalesce(sum(uses),0) from usage),
  'coupons_used',(select count(*) from usage where uses>0),
  'active_coupons',(select count(*) from public.coupons where is_active and (valid_from is null or valid_from<=now()) and (valid_until is null or valid_until>=now()) and (max_uses is null or used_count<max_uses)),
  'most_used',(select to_jsonb(r) from ranked r where uses>0 limit 1),
  'ranking',coalesce((select jsonb_agg(to_jsonb(r)) from (select * from ranked where uses>0 limit 20) r),'[]'::jsonb)
);
$function$;

create or replace function public.admin_coupon_usage(p_coupon_id uuid)
returns jsonb
language sql
stable security definer
set search_path to 'public', 'pg_temp'
as $function$
select coalesce(jsonb_agg(jsonb_build_object(
  'appointment_id',a.id,'public_code',a.public_code,'start_at',a.start_at,'customer_id',a.primary_customer_id,
  'customer_name',c.name,'customer_email',c.email,'discount_amount',ad.calculated_discount_amount,'final_value',a.commercial_value,
  'redemption_status',public.coupon_redemption_status(ad.released_at,ad.redeemed_at,a.status),
  'released_at',ad.released_at,'release_reason',ad.release_reason
) order by a.created_at desc),'[]'::jsonb)
from public.appointment_discounts ad join public.appointments a on a.id=ad.appointment_id left join public.customers c on c.id=a.primary_customer_id where ad.coupon_id=p_coupon_id;
$function$;

-- ---------------------------------------------------------------------------
-- Privileges: internal helpers are service-role only, like every other coupon RPC.
-- ---------------------------------------------------------------------------

revoke all on function public.coupon_discount_amount(text,numeric,text,numeric,numeric) from public, anon, authenticated;
revoke all on function public.coupon_redemption_status(timestamptz,timestamptz,text) from public, anon, authenticated;
revoke all on function public.service_release_appointment_coupon(uuid,text,boolean) from public, anon, authenticated;
-- Trigger functions are trigger-only, like the other coupon guards.
revoke all on function public.trg_appointment_discount_lifecycle_defaults() from public, anon, authenticated, service_role;
revoke all on function public.trg_appointment_coupon_redemption_lifecycle() from public, anon, authenticated, service_role;

grant execute on function public.coupon_discount_amount(text,numeric,text,numeric,numeric) to service_role;
grant execute on function public.coupon_redemption_status(timestamptz,timestamptz,text) to service_role;
grant execute on function public.service_release_appointment_coupon(uuid,text,boolean) to service_role;
