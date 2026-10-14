#!/usr/bin/env bash
set -euo pipefail

# S0.5 — concurrent promotions must never redeem a coupon beyond its limits.
# Phase 1: N customers race for a single-use coupon (max_uses = 1).
# Phase 2: one customer races N reservations against max_uses_per_customer = 1.

DATABASE_URL="${DATABASE_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
ATTEMPTS="${ATTEMPTS:-8}"
PREFIX="96910000-0000-0000"
RESOURCE_ID="$PREFIX-0000-000000000001"
EMPLOYEE_ID="$PREFIX-0000-000000000002"
CATEGORY_ID="$PREFIX-0000-000000000003"
SERVICE_ID="$PREFIX-0000-000000000010"
SERVICE_EMPLOYEE_ID="$PREFIX-0000-000000000020"
GLOBAL_COUPON_ID="$PREFIX-0000-000000000060"
CUSTOMER_COUPON_ID="$PREFIX-0000-000000000061"

TMP_DIR="$(mktemp -d)"

cleanup_fixture() {
  psql "$DATABASE_URL" -v ON_ERROR_STOP=0 -q <<SQL >/dev/null 2>&1 || true
begin;
set local session_replication_role = replica;
delete from public.appointment_discounts where coupon_id in ('$GLOBAL_COUPON_ID'::uuid, '$CUSTOMER_COUPON_ID'::uuid);
delete from public.resource_allocations where resource_id = '$RESOURCE_ID'::uuid;
delete from public.checkout_holds where service_id = '$SERVICE_ID'::uuid;
delete from public.appointments where service_id = '$SERVICE_ID'::uuid;
delete from public.coupons where id in ('$GLOBAL_COUPON_ID'::uuid, '$CUSTOMER_COUPON_ID'::uuid);
delete from public.service_resources where service_id = '$SERVICE_ID'::uuid;
delete from public.service_employees where id = '$SERVICE_EMPLOYEE_ID'::uuid;
delete from public.service_change_policies where service_id = '$SERVICE_ID'::uuid;
delete from public.services where id = '$SERVICE_ID'::uuid;
delete from public.categories where id = '$CATEGORY_ID'::uuid;
delete from public.employees where id = '$EMPLOYEE_ID'::uuid;
delete from public.resources where id = '$RESOURCE_ID'::uuid;
delete from public.customers where id::text like '$PREFIX-0000-0000000005%';
commit;
SQL
}

cleanup() {
  cleanup_fixture
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

cleanup_fixture

psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q <<SQL
insert into public.resources (id, name, resource_type) values ('$RESOURCE_ID'::uuid, 'Coupon Race Studio', 'PHYSICAL');
insert into public.employees (id, name) values ('$EMPLOYEE_ID'::uuid, 'Coupon Race Employee');
insert into public.categories (id, name, slug) values ('$CATEGORY_ID'::uuid, 'Coupon Race', 'coupon-race-test');

-- Created inactive so the explicit policy exists before the active-service invariant runs.
insert into public.services (
  id, category_id, name, slug, base_duration_minutes, base_price,
  minimum_people, maximum_people, maximum_booking_horizon_days, requires_terms, is_active
) values (
  '$SERVICE_ID'::uuid, '$CATEGORY_ID'::uuid, 'Coupon Race Service', 'coupon-race-service',
  60, 100.00, 1, 10, 5000, false, false
);
insert into public.service_change_policies (
  service_id, notice_hours, reschedule_first_early_percent,
  reschedule_first_late_percent, reschedule_repeat_percent, cancellation_late_percent
) values ('$SERVICE_ID'::uuid, 0, 0, 0, 0, 0);
update public.services set is_active = true where id = '$SERVICE_ID'::uuid;

insert into public.service_employees (id, service_id, employee_id)
values ('$SERVICE_EMPLOYEE_ID'::uuid, '$SERVICE_ID'::uuid, '$EMPLOYEE_ID'::uuid);
insert into public.service_resources (service_id, resource_id) values ('$SERVICE_ID'::uuid, '$RESOURCE_ID'::uuid);

insert into public.coupons (id, code, discount_type, discount_value, valid_until, max_uses, max_uses_per_customer)
values
  ('$GLOBAL_COUPON_ID'::uuid, 'RACEONCE', 'PERCENT', 10, '2036-01-01 00:00:00-03', 1, null),
  ('$CUSTOMER_COUPON_ID'::uuid, 'RACEPERCUST', 'PERCENT', 10, '2036-01-01 00:00:00-03', 100, 1);

insert into public.customers (id, name, email)
select ('$PREFIX-0000-0000000005' || lpad(n::text, 2, '0'))::uuid, 'Coupon Race Customer ' || n, 'coupon-race-' || n || '@example.com'
from generate_series(0, 2 * $ATTEMPTS) n;

-- One active hold per attempt, coupon already applied through the real checkout RPC.
do \$\$
declare
  v_start timestamptz;
  v_hold uuid;
  v_code text;
begin
  for n in 1..(2 * $ATTEMPTS) loop
    v_start := timestamptz '2035-03-05 00:00:00-03' + make_interval(hours => n);
    v_hold := ('$PREFIX-0001-' || lpad(n::text, 12, '0'))::uuid;
    v_code := case when n <= $ATTEMPTS then 'RACEONCE' else 'RACEPERCUST' end;
    insert into public.checkout_holds (
      id, public_token_hash, service_id, service_employee_id, selection_hash, people_count,
      requested_start_at, requested_end_at, core_start_at, core_end_at, expires_at,
      extra_selections, commercial_value, pricing_version, duration_minutes, resource_ids
    ) values (
      v_hold, encode(extensions.digest('coupon-race-token-' || n, 'sha256'), 'hex'),
      '$SERVICE_ID'::uuid, '$SERVICE_EMPLOYEE_ID'::uuid, 'coupon-race-' || n, 1,
      v_start, v_start + interval '1 hour', v_start, v_start + interval '1 hour', now() + interval '10 minutes',
      '[]'::jsonb, 0, 'coupon-race', 60, array['$RESOURCE_ID'::uuid]
    );
    insert into public.resource_allocations (resource_id, checkout_hold_id, allocation_type, status, occupied_range)
    values ('$RESOURCE_ID'::uuid, v_hold, 'CHECKOUT_HOLD', 'HELD', tstzrange(v_start, v_start + interval '1 hour', '[)'));
    perform public.apply_checkout_coupon('coupon-race-token-' || n, v_code);
  end loop;
end
\$\$;
SQL

race() {
  local phase="$1" first="$2" last="$3" same_customer="$4"
  for n in $(seq "$first" "$last"); do
    local customer
    if [[ "$same_customer" == "yes" ]]; then
      customer="$PREFIX-0000-000000000500"
    else
      customer="$PREFIX-0000-0000000005$(printf '%02d' "$n")"
    fi
    (
      if psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -qAtc "
        select public.promote_checkout_hold(
          '$PREFIX-0001-$(printf '%012d' "$n")'::uuid,
          '$customer'::uuid
        );
      " >"$TMP_DIR/$phase-$n.out" 2>"$TMP_DIR/$phase-$n.err"; then
        echo success >"$TMP_DIR/$phase-$n.status"
      else
        echo rejected >"$TMP_DIR/$phase-$n.status"
      fi
    ) &
  done
  wait
}

assert_phase() {
  local phase="$1" coupon_id="$2" expected_error="$3"
  local success rejected wrong_errors active used
  success=$(grep -l '^success$' "$TMP_DIR/$phase"-*.status | wc -l | tr -d ' ')
  rejected=$(grep -l '^rejected$' "$TMP_DIR/$phase"-*.status | wc -l | tr -d ' ')
  wrong_errors=$(for err in "$TMP_DIR/$phase"-*.err; do
      if [[ -s "$err" ]] && ! grep -q "$expected_error" "$err"; then echo "$err"; fi
    done | wc -l | tr -d ' ')
  active=$(psql "$DATABASE_URL" -qAtc "
    select count(*) from public.appointment_discounts ad
    join public.appointments a on a.id = ad.appointment_id
    where ad.coupon_id = '$coupon_id'::uuid
      and public.coupon_redemption_status(ad.released_at, ad.redeemed_at, a.status) <> 'RELEASED';" | tr -d ' ')
  used=$(psql "$DATABASE_URL" -qAtc "select used_count from public.coupons where id = '$coupon_id'::uuid;" | tr -d ' ')

  printf 'Coupon concurrency %s: attempts=%s success=%s rejected=%s active_redemptions=%s used_count=%s\n' \
    "$phase" "$ATTEMPTS" "$success" "$rejected" "$active" "$used"

  if [[ "$success" != "1" || "$rejected" != "$((ATTEMPTS - 1))" || "$wrong_errors" != "0" || "$active" != "1" ]]; then
    echo "FAIL: expected exactly one redemption and $((ATTEMPTS - 1)) rejections with $expected_error."
    for err in "$TMP_DIR/$phase"-*.err; do
      if [[ -s "$err" ]]; then echo "--- $err"; cat "$err"; fi
    done
    exit 1
  fi
  if [[ "$phase" == "global" && "$used" != "1" ]]; then
    echo "FAIL: single-use coupon counter must be exactly 1."
    exit 1
  fi
}

race global 1 "$ATTEMPTS" no
assert_phase global "$GLOBAL_COUPON_ID" COUPON_USAGE_LIMIT_REACHED

race customer "$((ATTEMPTS + 1))" "$((2 * ATTEMPTS))" yes
assert_phase customer "$CUSTOMER_COUPON_ID" COUPON_CUSTOMER_USAGE_LIMIT_REACHED

echo "PASS: coupon row locking prevented concurrent over-redemption (global and per-customer)."
