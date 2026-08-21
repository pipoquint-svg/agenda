#!/usr/bin/env bash
set -euo pipefail

DATABASE_URL="${DATABASE_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
PACKAGE_ID="20000000-0000-0000-0000-000000000701"
CUSTOMER_ID="20000000-0000-0000-0000-000000000601"
CATEGORY_ID="20000000-0000-0000-0000-000000000301"
SERVICE_ID="20000000-0000-0000-0000-000000000401"
SERVICE_EMPLOYEE_ID="20000000-0000-0000-0000-000000000501"
HOLD1_ID="20000000-0000-0000-0000-000000000801"
HOLD2_ID="20000000-0000-0000-0000-000000000802"

TMP_DIR="$(mktemp -d)"

cleanup() {
  psql "$DATABASE_URL" -qAtc "
    delete from public.time_package_usages where package_id = '$PACKAGE_ID'::uuid;
    delete from public.checkout_holds where id in ('$HOLD1_ID'::uuid, '$HOLD2_ID'::uuid);
    delete from public.time_package_services where package_id = '$PACKAGE_ID'::uuid;
    delete from public.customer_time_packages where id = '$PACKAGE_ID'::uuid;
    delete from public.availability_rules where service_employee_id = '$SERVICE_EMPLOYEE_ID'::uuid;
    delete from public.service_employees where id = '$SERVICE_EMPLOYEE_ID'::uuid;
    delete from public.services where id = '$SERVICE_ID'::uuid;
    delete from public.categories where id = '$CATEGORY_ID'::uuid;
    delete from public.customers where id = '$CUSTOMER_ID'::uuid;
  " >/dev/null 2>&1 || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q <<SQL
insert into public.categories (id, name, slug)
values ('$CATEGORY_ID', 'Package Race', 'package-race');

insert into public.services (
  id, category_id, name, slug, base_duration_minutes, base_price, minimum_people, maximum_people
) values (
  '$SERVICE_ID', '$CATEGORY_ID', 'Package Race Service', 'package-race-service', 60, 100, 1, 10
);

insert into public.service_employees (id, service_id, employee_id)
values ('$SERVICE_EMPLOYEE_ID', '$SERVICE_ID', '00000000-0000-0000-0000-000000000201');

insert into public.availability_rules (
  service_employee_id, weekday, start_local_time, end_local_time, slot_interval_minutes, availability_class
) values (
  '$SERVICE_EMPLOYEE_ID', 6, '09:00', '18:00', 30, 'REGULAR'
);

insert into public.customers (id, name, email, phone)
values ('$CUSTOMER_ID', 'Package Race Customer', 'package-race@example.com', '+5548000000000');

insert into public.customer_time_packages (
  id, customer_id, name, total_minutes, purchase_amount, valid_from, expires_at
) values (
  '$PACKAGE_ID', '$CUSTOMER_ID', '2 hour race package', 120, 200,
  '2000-01-01 00:00:00+00', '2100-01-01 00:00:00+00'
);

insert into public.time_package_services (package_id, service_id)
values ('$PACKAGE_ID', '$SERVICE_ID');

insert into public.checkout_holds (
  id, public_token_hash, service_id, service_employee_id, selection_hash,
  customer_id, extra_selections, people_count,
  requested_start_at, requested_end_at, expires_at
) values
  (
    '$HOLD1_ID', 'package-race-hold-1', '$SERVICE_ID', '$SERVICE_EMPLOYEE_ID', 'race-1',
    '$CUSTOMER_ID', '[]'::jsonb, 1,
    '2035-01-13 10:00:00-03', '2035-01-13 12:00:00-03', now() + interval '10 minutes'
  ),
  (
    '$HOLD2_ID', 'package-race-hold-2', '$SERVICE_ID', '$SERVICE_EMPLOYEE_ID', 'race-2',
    '$CUSTOMER_ID', '[]'::jsonb, 1,
    '2035-01-13 14:00:00-03', '2035-01-13 16:00:00-03', now() + interval '10 minutes'
  );
SQL

for hold in "$HOLD1_ID" "$HOLD2_ID"; do
  (
    if psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -qAtc "
      select (public.reserve_time_package_minutes('$PACKAGE_ID'::uuid, '$hold'::uuid)).id;
    " >"$TMP_DIR/$hold.out" 2>"$TMP_DIR/$hold.err"; then
      echo success >"$TMP_DIR/$hold.status"
    else
      echo rejected >"$TMP_DIR/$hold.status"
    fi
  ) &
done

wait

SUCCESS_COUNT=$(grep -l '^success$' "$TMP_DIR"/*.status | wc -l | tr -d ' ')
REJECTED_COUNT=$(grep -l '^rejected$' "$TMP_DIR"/*.status | wc -l | tr -d ' ')
HELD_USAGE_COUNT=$(psql "$DATABASE_URL" -qAtc "select count(*) from public.time_package_usages where package_id = '$PACKAGE_ID'::uuid and status = 'HELD';" | tr -d ' ')
AVAILABLE_MINUTES=$(psql "$DATABASE_URL" -qAtc "select available_minutes from public.customer_time_package_balances where package_id = '$PACKAGE_ID'::uuid;" | tr -d ' ')

printf 'Package concurrency result: attempts=2 success=%s rejected=%s held_usages=%s available_minutes=%s\n' \
  "$SUCCESS_COUNT" "$REJECTED_COUNT" "$HELD_USAGE_COUNT" "$AVAILABLE_MINUTES"

if [[ "$SUCCESS_COUNT" != "1" ]]; then
  echo "FAIL: expected exactly one package reservation to succeed."
  for err in "$TMP_DIR"/*.err; do
    if [[ -s "$err" ]]; then
      echo "--- $err"
      cat "$err"
    fi
  done
  exit 1
fi

if [[ "$REJECTED_COUNT" != "1" ]]; then
  echo "FAIL: expected exactly one package reservation to be rejected."
  exit 1
fi

if [[ "$HELD_USAGE_COUNT" != "1" ]]; then
  echo "FAIL: expected exactly one held package usage; got $HELD_USAGE_COUNT."
  exit 1
fi

if [[ "$AVAILABLE_MINUTES" != "0" ]]; then
  echo "FAIL: expected zero available minutes after the winning reservation; got $AVAILABLE_MINUTES."
  exit 1
fi

echo "PASS: package row lock prevented double spending of prepaid time."
