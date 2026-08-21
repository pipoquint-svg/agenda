#!/usr/bin/env bash
set -euo pipefail

DATABASE_URL="${DATABASE_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
CUSTOMER_ID="40000000-0000-0000-0000-000000000060"
EMPLOYEE_ID="40000000-0000-0000-0000-000000000010"
CATEGORY_ID="40000000-0000-0000-0000-000000000020"
SERVICE_ID="40000000-0000-0000-0000-000000000030"
SERVICE_EMPLOYEE_ID="40000000-0000-0000-0000-000000000040"
PACKAGE_ID="40000000-0000-0000-0000-000000000070"
HOLD_A="40000000-0000-0000-0000-000000000080"
HOLD_B="40000000-0000-0000-0000-000000000081"

TMP_DIR="$(mktemp -d)"

cleanup_fixture() {
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q <<SQL >/dev/null 2>&1 || true
begin;
delete from public.checkout_hour_package_reservations where hour_package_id = '$PACKAGE_ID'::uuid;
alter table public.hour_package_movements disable trigger hour_package_movements_immutable_trg;
delete from public.hour_package_movements where hour_package_id = '$PACKAGE_ID'::uuid;
alter table public.hour_package_movements enable trigger hour_package_movements_immutable_trg;
delete from public.hour_package_services where hour_package_id = '$PACKAGE_ID'::uuid;
delete from public.hour_packages where id = '$PACKAGE_ID'::uuid;
delete from public.checkout_holds where id in ('$HOLD_A'::uuid, '$HOLD_B'::uuid);
delete from public.service_employees where id = '$SERVICE_EMPLOYEE_ID'::uuid;
delete from public.services where id = '$SERVICE_ID'::uuid;
delete from public.categories where id = '$CATEGORY_ID'::uuid;
delete from public.employees where id = '$EMPLOYEE_ID'::uuid;
delete from public.customers where id = '$CUSTOMER_ID'::uuid;
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
insert into public.customers (id, name, email)
values ('$CUSTOMER_ID'::uuid, 'Package Race Customer', 'package-race@example.com');

insert into public.employees (id, name)
values ('$EMPLOYEE_ID'::uuid, 'Package Race Employee');

insert into public.categories (id, name, slug)
values ('$CATEGORY_ID'::uuid, 'Package Race', 'package-race-test');

insert into public.services (
  id, category_id, name, slug, base_duration_minutes, base_price,
  minimum_people, maximum_people, maximum_booking_horizon_days
) values (
  '$SERVICE_ID'::uuid,
  '$CATEGORY_ID'::uuid,
  'Package Race Service',
  'package-race-service',
  120,
  240.00,
  1,
  10,
  5000
);

insert into public.service_employees (id, service_id, employee_id)
values ('$SERVICE_EMPLOYEE_ID'::uuid, '$SERVICE_ID'::uuid, '$EMPLOYEE_ID'::uuid);

insert into public.hour_packages (
  id, customer_id, name, total_minutes, purchased_value,
  valid_from, valid_until, standard_start_local_time, standard_end_local_time
) values (
  '$PACKAGE_ID'::uuid,
  '$CUSTOMER_ID'::uuid,
  'Concurrency 2h Package',
  120,
  200.00,
  '2034-01-01 00:00:00-03',
  '2036-01-01 00:00:00-03',
  '09:00',
  '18:00'
);

insert into public.hour_package_services (hour_package_id, service_id)
values ('$PACKAGE_ID'::uuid, '$SERVICE_ID'::uuid);

insert into public.checkout_holds (
  id, public_token_hash, service_id, service_employee_id, selection_hash,
  people_count, requested_start_at, requested_end_at, expires_at,
  extra_selections, commercial_value, pricing_version, duration_minutes
) values
  ('$HOLD_A'::uuid, 'package-race-hold-a', '$SERVICE_ID'::uuid, '$SERVICE_EMPLOYEE_ID'::uuid, 'race-a', 1,
   '2035-01-15 10:00:00-03', '2035-01-15 12:00:00-03', now() + interval '10 minutes', '[]', 240.00, 'race', 120),
  ('$HOLD_B'::uuid, 'package-race-hold-b', '$SERVICE_ID'::uuid, '$SERVICE_EMPLOYEE_ID'::uuid, 'race-b', 1,
   '2035-01-15 13:00:00-03', '2035-01-15 15:00:00-03', now() + interval '10 minutes', '[]', 240.00, 'race', 120);
SQL

for entry in "A:$HOLD_A" "B:$HOLD_B"; do
  label="${entry%%:*}"
  hold_id="${entry#*:}"
  (
    if psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -qAtc "
      select public.reserve_hour_package_for_checkout(
        '$PACKAGE_ID'::uuid,
        '$hold_id'::uuid,
        '$CUSTOMER_ID'::uuid
      );
    " >"$TMP_DIR/$label.out" 2>"$TMP_DIR/$label.err"; then
      echo success >"$TMP_DIR/$label.status"
    else
      echo rejected >"$TMP_DIR/$label.status"
    fi
  ) &
done

wait

SUCCESS_COUNT=$(grep -l '^success$' "$TMP_DIR"/*.status | wc -l | tr -d ' ')
REJECTED_COUNT=$(grep -l '^rejected$' "$TMP_DIR"/*.status | wc -l | tr -d ' ')
HELD_COUNT=$(psql "$DATABASE_URL" -qAtc "select count(*) from public.checkout_hour_package_reservations where hour_package_id = '$PACKAGE_ID'::uuid and status = 'HELD';" | tr -d ' ')
AVAILABLE=$(psql "$DATABASE_URL" -qAtc "select available_minutes from public.hour_package_balances where hour_package_id = '$PACKAGE_ID'::uuid;" | tr -d ' ')

printf 'Package concurrency result: attempts=2 success=%s rejected=%s held=%s available_minutes=%s\n' "$SUCCESS_COUNT" "$REJECTED_COUNT" "$HELD_COUNT" "$AVAILABLE"

if [[ "$SUCCESS_COUNT" != "1" || "$REJECTED_COUNT" != "1" ]]; then
  echo "FAIL: expected exactly one package reservation to succeed and one to be rejected."
  for err in "$TMP_DIR"/*.err; do
    if [[ -s "$err" ]]; then
      echo "--- $err"
      cat "$err"
    fi
  done
  exit 1
fi

if [[ "$HELD_COUNT" != "1" || "$AVAILABLE" != "0" ]]; then
  echo "FAIL: package balance was not protected atomically."
  exit 1
fi

echo "PASS: row locking prevented double-spend of prepaid package minutes."
