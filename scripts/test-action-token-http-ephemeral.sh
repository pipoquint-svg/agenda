#!/usr/bin/env bash
set -euo pipefail

DB_URL="${DB_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
FUNCTION_URL="${FUNCTION_URL:-http://127.0.0.1:54321/functions/v1/appointment-action-access}"
WORK_DIR="$(mktemp -d)"
SERVE_LOG="$WORK_DIR/functions.log"
SERVE_PID=""

cleanup() {
  if [[ -n "$SERVE_PID" ]]; then
    kill "$SERVE_PID" >/dev/null 2>&1 || true
    wait "$SERVE_PID" >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# This fixture exists only inside the local Supabase instance created by CI. Any
# ACCESS/network evidence produced below disappears when the runner is torn down.
psql "$DB_URL" -v ON_ERROR_STOP=1 <<'SQL' >/dev/null
insert into public.categories(id,name,slug)
values ('95800000-0000-0000-0000-000000000001','HTTP Action Token','http-action-token-test');
insert into public.employees(id,name)
values ('95800000-0000-0000-0000-000000000002','HTTP Action Token Employee');
insert into public.services(id,category_id,name,slug,base_duration_minutes,base_price,minimum_people,maximum_people,maximum_booking_horizon_days,confirmation_percentage)
values ('95800000-0000-0000-0000-000000000010','95800000-0000-0000-0000-000000000001','HTTP Action Token Service','http-action-token-service',60,1000,1,2,5000,50);
insert into public.service_employees(id,service_id,employee_id)
values ('95800000-0000-0000-0000-000000000011','95800000-0000-0000-0000-000000000010','95800000-0000-0000-0000-000000000002');
insert into public.service_change_policies(service_id,notice_hours,reschedule_first_early_percent,reschedule_first_late_percent,reschedule_repeat_percent,cancellation_late_percent)
values ('95800000-0000-0000-0000-000000000010',48,0,20,30,30);
insert into public.customers(id,name,email,phone)
values ('95800000-0000-0000-0000-000000000020','HTTP Action Token Customer','http.action.token@example.com','48999995555');
insert into public.appointments(id,public_code,service_id,service_employee_id,service_name_snapshot,primary_customer_id,status,financial_status,start_at,end_at,duration_minutes,people_count,commercial_value,confirmed_at)
values ('95800000-0000-0000-0000-000000000030','HTTP-ACTION-TOKEN-1','95800000-0000-0000-0000-000000000010','95800000-0000-0000-0000-000000000011','HTTP Action Token Service','95800000-0000-0000-0000-000000000020','CONFIRMED','PARTIALLY_PAID','2035-03-10 10:00:00-03','2035-03-10 11:00:00-03',60,1,1000,now());
SQL

issue_token() {
  local scope="$1"
  psql "$DB_URL" -Atqc "select public.service_issue_appointment_action_token('95800000-0000-0000-0000-000000000030','$scope','INTERNAL','qa-http','qa-http-issue')::text"
}

valid_json="$(issue_token CANCEL)"
wrong_scope_json="$(issue_token RESCHEDULE)"
expired_json="$(issue_token CANCEL)"
consumed_json="$(issue_token CANCEL)"

valid_token="$(jq -r '.access_token' <<<"$valid_json")"
wrong_scope_token="$(jq -r '.access_token' <<<"$wrong_scope_json")"
expired_token="$(jq -r '.access_token' <<<"$expired_json")"
consumed_token="$(jq -r '.access_token' <<<"$consumed_json")"
expired_id="$(jq -r '.token_id' <<<"$expired_json")"
consumed_id="$(jq -r '.token_id' <<<"$consumed_json")"

psql "$DB_URL" -v ON_ERROR_STOP=1 -c "update public.appointment_access_tokens set expires_at = now() - interval '1 minute' where id = '$expired_id'::uuid" >/dev/null
psql "$DB_URL" -v ON_ERROR_STOP=1 -c "update public.appointment_access_tokens set consumed_at = now(), consumed_action = 'CANCEL_CONFIRMED' where id = '$consumed_id'::uuid" >/dev/null

# Serve only the target Edge Function against the disposable local database.
supabase functions serve appointment-action-access --no-verify-jwt >"$SERVE_LOG" 2>&1 &
SERVE_PID=$!

ready=false
for _ in $(seq 1 60); do
  status="$(curl --silent --output /dev/null --write-out '%{http_code}' --request OPTIONS "$FUNCTION_URL" || true)"
  if [[ "$status" == "200" || "$status" == "204" ]]; then
    ready=true
    break
  fi
  if ! kill -0 "$SERVE_PID" >/dev/null 2>&1; then
    echo 'Edge Function serve process exited before readiness.' >&2
    cat "$SERVE_LOG" >&2
    exit 1
  fi
  sleep 1
done
if [[ "$ready" != "true" ]]; then
  echo 'Edge Function route did not become ready within 60 seconds.' >&2
  cat "$SERVE_LOG" >&2
  exit 1
fi

request() {
  local token="$1"
  local output="$2"
  curl --silent --show-error \
    --output "$output" \
    --write-out '%{http_code} %{time_total}' \
    --request POST \
    --header 'content-type: application/json' \
    --header 'user-agent: Agenda-QA-Ephemeral/1.0' \
    --header 'x-forwarded-for: 203.0.113.100' \
    --header 'x-request-id: qa-action-token-http' \
    --header "x-appointment-token: $token" \
    --data '{"operation":"RESOLVE","scope":"CANCEL"}' \
    "$FUNCTION_URL"
}

# After `supabase db reset`, Kong can answer OPTIONS before the Edge runtime has
# re-established its upstream connection. Require one functional application-level
# response before measuring the gate. Retry only startup/transport 5xx; any other
# unexpected status fails immediately so this does not hide product regressions.
warmup_token="ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
functional_ready=false
for _ in $(seq 1 30); do
  warmup_meta="$(request "$warmup_token" "$WORK_DIR/warmup.json" || true)"
  warmup_status="${warmup_meta%% *}"
  if [[ "$warmup_status" == "400" ]]; then
    functional_ready=true
    break
  fi
  if [[ "$warmup_status" != "502" && "$warmup_status" != "503" && "$warmup_status" != "000" && -n "$warmup_status" ]]; then
    echo "Edge Function warm-up returned unexpected HTTP $warmup_status" >&2
    cat "$WORK_DIR/warmup.json" >&2 2>/dev/null || true
    cat "$SERVE_LOG" >&2
    exit 1
  fi
  if ! kill -0 "$SERVE_PID" >/dev/null 2>&1; then
    echo 'Edge Function serve process exited during functional warm-up.' >&2
    cat "$SERVE_LOG" >&2
    exit 1
  fi
  sleep 1
done
if [[ "$functional_ready" != "true" ]]; then
  echo 'Edge Function did not become functionally ready within 30 seconds.' >&2
  cat "$WORK_DIR/warmup.json" >&2 2>/dev/null || true
  cat "$SERVE_LOG" >&2
  exit 1
fi

valid_meta="$(request "$valid_token" "$WORK_DIR/valid.json" || true)"
valid_status="${valid_meta%% *}"
if [[ "$valid_status" != "200" ]]; then
  echo "Valid token resolve failed: HTTP ${valid_status:-transport-error}" >&2
  cat "$WORK_DIR/valid.json" >&2 2>/dev/null || true
  cat "$SERVE_LOG" >&2
  exit 1
fi
jq -e '.data.valid == true and .data.scope == "CANCEL" and .data.warning == "link pessoal, válido por tempo limitado, não encaminhe"' "$WORK_DIR/valid.json" >/dev/null

invalid_token="ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
declare -A TOKENS=(
  [missing]="$invalid_token"
  [wrong_scope]="$wrong_scope_token"
  [expired]="$expired_token"
  [consumed]="$consumed_token"
)

printf '%s\n' '{"error":{"code":"LINK_INVALID_OR_EXPIRED"}}' > "$WORK_DIR/expected-error.json"

for case_name in missing wrong_scope expired consumed; do
  : > "$WORK_DIR/$case_name.times"
  for attempt in 1 2 3; do
    meta="$(request "${TOKENS[$case_name]}" "$WORK_DIR/$case_name.$attempt.json" || true)"
    status="${meta%% *}"
    elapsed="${meta##* }"
    if [[ "$status" != "400" ]]; then
      echo "Invalid-token case $case_name failed: HTTP ${status:-transport-error}" >&2
      cat "$WORK_DIR/$case_name.$attempt.json" >&2 2>/dev/null || true
      cat "$SERVE_LOG" >&2
      exit 1
    fi
    [[ "$(jq -c . "$WORK_DIR/$case_name.$attempt.json")" == "$(jq -c . "$WORK_DIR/expected-error.json")" ]] || {
      echo "Anti-enumeration envelope differs for $case_name" >&2
      cat "$WORK_DIR/$case_name.$attempt.json" >&2
      exit 1
    }
    printf '%s\n' "$elapsed" >> "$WORK_DIR/$case_name.times"
  done
done

python3 - "$WORK_DIR" <<'PY'
import pathlib, statistics, sys
root = pathlib.Path(sys.argv[1])
medians = {}
for name in ("missing", "wrong_scope", "expired", "consumed"):
    values = [float(v) for v in (root / f"{name}.times").read_text().split()]
    medians[name] = statistics.median(values)
    # The Edge helper intentionally enforces a 120 ms minimum; allow timer/network jitter.
    if medians[name] < 0.10:
        raise SystemExit(f"anti-enumeration minimum delay failed for {name}: {medians[name]:.3f}s")
spread = max(medians.values()) - min(medians.values())
if spread > 0.15:
    raise SystemExit(f"anti-enumeration timing spread too high: {medians}, spread={spread:.3f}s")
print("Action-token HTTP anti-enumeration medians:", ", ".join(f"{k}={v:.3f}s" for k, v in medians.items()))
PY

# Prove the valid request captured network evidence only in this disposable database.
psql "$DB_URL" -v ON_ERROR_STOP=1 -Atqc "
select case when exists (
  select 1
  from public.appointment_token_events e
  join public.appointment_token_network_evidence n on n.token_event_id = e.id
  where e.appointment_access_token_id = '$(jq -r '.token_id' <<<"$valid_json")'::uuid
    and e.event_type = 'ACCESS'
    and n.ip_address = '203.0.113.100'::inet
    and n.user_agent = 'Agenda-QA-Ephemeral/1.0'
    and n.retain_until >= n.occurred_at + interval '5 years' - interval '1 minute'
) then 'PASS' else 'FAIL' end" | grep -qx PASS

echo 'Action-token HTTP ephemeral gate PASS: valid resolve, generic invalid-link envelope, timing floor, scope isolation, consumed/expired handling, and network evidence.'
