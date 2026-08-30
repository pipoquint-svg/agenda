#!/usr/bin/env bash
set -euo pipefail

DATABASE_URL="${DATABASE_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
START_AT="2031-01-07 08:00:00-03"
TMP_DIR="$(mktemp -d)"

CAT="94500000-0000-0000-0000-000000000001"
STUDIO="94500000-0000-0000-0000-000000000002"
PERSON="94500000-0000-0000-0000-000000000003"
EMPLOYEE="94500000-0000-0000-0000-000000000004"
SERVICE="94500000-0000-0000-0000-000000000005"
SERVICE_EMPLOYEE="94500000-0000-0000-0000-000000000006"
CUSTOMER_A="94500000-0000-0000-0000-000000000007"
CUSTOMER_B="94500000-0000-0000-0000-000000000008"
AUTH="14500000-0000-4000-8000-000000000001"
ADMIN="24500000-0000-4000-8000-000000000001"

cleanup() {
  psql "$DATABASE_URL" -v ON_ERROR_STOP=0 -qAt <<SQL >/dev/null 2>&1 || true
DELETE FROM public.resource_allocations WHERE pre_reservation_id IN (SELECT id FROM public.pre_reservations WHERE customer_id IN ('$CUSTOMER_A'::uuid,'$CUSTOMER_B'::uuid));
DELETE FROM public.pre_reservation_access_tokens WHERE pre_reservation_id IN (SELECT id FROM public.pre_reservations WHERE customer_id IN ('$CUSTOMER_A'::uuid,'$CUSTOMER_B'::uuid));
DELETE FROM public.pre_reservations WHERE customer_id IN ('$CUSTOMER_A'::uuid,'$CUSTOMER_B'::uuid);
DELETE FROM public.customer_prebook_authorized_services WHERE customer_id IN ('$CUSTOMER_A'::uuid,'$CUSTOMER_B'::uuid);
DELETE FROM public.customer_commercial_terms WHERE customer_id IN ('$CUSTOMER_A'::uuid,'$CUSTOMER_B'::uuid);
DELETE FROM public.customers WHERE id IN ('$CUSTOMER_A'::uuid,'$CUSTOMER_B'::uuid);
DELETE FROM public.resource_availability_rules WHERE resource_id='$STUDIO'::uuid;
DELETE FROM public.availability_rules WHERE service_employee_id='$SERVICE_EMPLOYEE'::uuid;
DELETE FROM public.service_resources WHERE service_id='$SERVICE'::uuid;
DELETE FROM public.service_employees WHERE id='$SERVICE_EMPLOYEE'::uuid;
UPDATE public.services SET is_active=false WHERE id='$SERVICE'::uuid;
DELETE FROM public.service_change_policies WHERE service_id='$SERVICE'::uuid;
DELETE FROM public.services WHERE id='$SERVICE'::uuid;
DELETE FROM public.employees WHERE id='$EMPLOYEE'::uuid;
DELETE FROM public.resources WHERE id IN ('$STUDIO'::uuid,'$PERSON'::uuid);
DELETE FROM public.categories WHERE id='$CAT'::uuid;
DELETE FROM public.admin_users WHERE id='$ADMIN'::uuid;
DELETE FROM auth.users WHERE id='$AUTH'::uuid;
SQL
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT
cleanup || true
mkdir -p "$TMP_DIR"

psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -qAt <<SQL
INSERT INTO auth.users(id,instance_id,aud,role,email,encrypted_password,created_at,updated_at)
VALUES ('$AUTH'::uuid,'00000000-0000-0000-0000-000000000000','authenticated','authenticated','prebook-race@example.test','',now(),now());
INSERT INTO public.admin_users(id,auth_user_id,display_name,role)
VALUES ('$ADMIN'::uuid,'$AUTH'::uuid,'Prebook Race Owner','OWNER');
INSERT INTO public.categories(id,name,slug) VALUES ('$CAT'::uuid,'Prebook Race','prebook-race');
INSERT INTO public.resources(id,name,resource_type) VALUES
  ('$STUDIO'::uuid,'PREBOOK RACE STUDIO','PHYSICAL'),
  ('$PERSON'::uuid,'PREBOOK RACE PERSON','PERSON');
INSERT INTO public.employees(id,name,resource_id) VALUES ('$EMPLOYEE'::uuid,'Prebook Race Employee','$PERSON'::uuid);
INSERT INTO public.services(
  id,category_id,name,slug,base_duration_minutes,base_price,buffer_before_minutes,buffer_after_minutes,
  minimum_people,maximum_people,maximum_booking_horizon_days,duration_mode,booking_block_minutes,
  minimum_booking_blocks,maximum_booking_blocks,price_per_block,is_active
) VALUES (
  '$SERVICE'::uuid,'$CAT'::uuid,'Prebook Race Rental','prebook-race-rental',30,100,0,30,
  1,10,5000,'BLOCKS',30,2,12,100,false
);
INSERT INTO public.service_change_policies(
  service_id,notice_hours,reschedule_first_early_percent,reschedule_first_late_percent,
  reschedule_repeat_percent,cancellation_late_percent
) VALUES ('$SERVICE'::uuid,48,0,0,0,0);
UPDATE public.services SET is_active=true WHERE id='$SERVICE'::uuid;
INSERT INTO public.service_employees(id,service_id,employee_id)
VALUES ('$SERVICE_EMPLOYEE'::uuid,'$SERVICE'::uuid,'$EMPLOYEE'::uuid);
INSERT INTO public.service_resources(service_id,resource_id,is_required)
VALUES ('$SERVICE'::uuid,'$STUDIO'::uuid,true);
-- 2031-01-07 is Tuesday (PostgreSQL DOW=2).
INSERT INTO public.availability_rules(service_employee_id,weekday,start_local_time,end_local_time)
VALUES ('$SERVICE_EMPLOYEE'::uuid,2,'08:00','18:00');
INSERT INTO public.resource_availability_rules(resource_id,weekday,start_local_time,end_local_time)
VALUES ('$STUDIO'::uuid,2,'08:00','18:30');
INSERT INTO public.customers(id,customer_type,name) VALUES
  ('$CUSTOMER_A'::uuid,'BUSINESS','Prebook Race A'),
  ('$CUSTOMER_B'::uuid,'BUSINESS','Prebook Race B');
INSERT INTO public.customer_commercial_terms(
  customer_id,can_prebook,prebook_hold_minutes,max_active_prebooks,requires_manual_confirmation,billing_mode,invoice_due_days,is_active
) VALUES
  ('$CUSTOMER_A'::uuid,true,720,10,true,'CHECKOUT',null,true),
  ('$CUSTOMER_B'::uuid,true,720,10,true,'CHECKOUT',null,true);
INSERT INTO public.customer_prebook_authorized_services(customer_id,service_id) VALUES
  ('$CUSTOMER_A'::uuid,'$SERVICE'::uuid),
  ('$CUSTOMER_B'::uuid,'$SERVICE'::uuid);

-- The trigger must normalize the stale per-customer inputs to the global contract.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.customer_commercial_terms
    WHERE customer_id IN ('$CUSTOMER_A'::uuid,'$CUSTOMER_B'::uuid)
      AND (prebook_hold_minutes <> 2880 OR requires_manual_confirmation OR billing_mode <> 'CHECKOUT')
  ) THEN
    RAISE EXCEPTION 'PREBOOK_GLOBAL_CONTRACT_NOT_NORMALIZED';
  END IF;
END
$$;
SQL

run_attempt() {
  local customer="$1"
  local idx="$2"
  if psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -qAtc "
    select public.service_admin_create_pre_reservation(
      '$customer'::uuid,
      '$SERVICE'::uuid,
      '$SERVICE_EMPLOYEE'::uuid,
      '$START_AT'::timestamptz,
      '$ADMIN'::uuid,
      4,
      '[]'::jsonb,
      1,
      'concurrency attempt $idx'
    );
  " >"$TMP_DIR/$idx.out" 2>"$TMP_DIR/$idx.err"; then
    echo success >"$TMP_DIR/$idx.status"
  else
    echo rejected >"$TMP_DIR/$idx.status"
  fi
}

run_attempt "$CUSTOMER_A" 1 &
PID_A=$!
run_attempt "$CUSTOMER_B" 2 &
PID_B=$!
wait "$PID_A" || true
wait "$PID_B" || true

SUCCESS_COUNT=$(grep -l '^success$' "$TMP_DIR"/*.status | wc -l | tr -d ' ')
REJECTED_COUNT=$(grep -l '^rejected$' "$TMP_DIR"/*.status | wc -l | tr -d ' ')
ACTIVE_COUNT=$(psql "$DATABASE_URL" -qAtc "select count(*) from public.pre_reservations where customer_id in ('$CUSTOMER_A'::uuid,'$CUSTOMER_B'::uuid) and status='ACTIVE';" | tr -d ' ')
ALLOCATION_COUNT=$(psql "$DATABASE_URL" -qAtc "select count(*) from public.resource_allocations where resource_id='$STUDIO'::uuid and allocation_type='PRE_RESERVATION' and status='HELD' and occupied_range && tstzrange('$START_AT'::timestamptz, '$START_AT'::timestamptz + interval '2 hours 30 minutes', '[)');" | tr -d ' ')

printf 'Pre-reservation concurrency result: success=%s rejected=%s active=%s allocations=%s\n' "$SUCCESS_COUNT" "$REJECTED_COUNT" "$ACTIVE_COUNT" "$ALLOCATION_COUNT"

if [[ "$SUCCESS_COUNT" != "1" || "$REJECTED_COUNT" != "1" ]]; then
  echo "FAIL: expected one successful and one rejected competing pre-reservation."
  for err in "$TMP_DIR"/*.err; do
    if [[ -s "$err" ]]; then
      echo "--- $err"
      cat "$err"
    fi
  done
  exit 1
fi

if [[ "$ACTIVE_COUNT" != "1" || "$ALLOCATION_COUNT" != "1" ]]; then
  echo "FAIL: expected exactly one active authoritative pre-reservation/allocation."
  exit 1
fi

echo "PASS: two independent customers racing for the same resource cannot create a double pre-reservation."
