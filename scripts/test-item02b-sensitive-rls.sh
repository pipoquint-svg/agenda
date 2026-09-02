#!/usr/bin/env bash
set -euo pipefail

DB_URL="${LOCAL_DB_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
MODE="${1:-after}"
TEST_FILE='supabase/tests/database/141_sensitive_rls_deny_by_default.test.sql'
PLAN=37
LOG="/tmp/item02b-sensitive-rls-${MODE}.tap"

case "$MODE" in
  before|after) ;;
  *) echo "Usage: $0 before|after" >&2; exit 2 ;;
esac

test -f "$TEST_FILE"

set +e
psql "$DB_URL" -X -A -t -q -v ON_ERROR_STOP=0 -f "$TEST_FILE" >"$LOG" 2>&1
rc=$?
set -e

if [[ $rc -ne 0 ]]; then
  echo "psql transport failed for Item 2B test (rc=$rc)." >&2
  cat "$LOG" >&2
  exit 1
fi
if grep -Eq '(^|[[:space:]])(ERROR|FATAL|PANIC):' "$LOG"; then
  echo 'Uncaught SQL error in Item 2B RLS test.' >&2
  cat "$LOG" >&2
  exit 1
fi
if ! grep -Fxq "1..$PLAN" "$LOG"; then
  echo "Unexpected or missing TAP plan; expected 1..$PLAN." >&2
  cat "$LOG" >&2
  exit 1
fi

test_count="$(grep -Ec '^(ok|not ok) [0-9]+ - ' "$LOG" || true)"
if [[ "$test_count" -ne "$PLAN" ]]; then
  echo "Incomplete Item 2B TAP stream: expected $PLAN tests, found $test_count." >&2
  cat "$LOG" >&2
  exit 1
fi

mapfile -t actual < <(grep '^not ok ' "$LOG" | sed -E 's/^not ok [0-9]+ - //; s/[[:space:]]+#.*$//')

if [[ "$MODE" == 'before' ]]; then
  expected=(
    'RLS enabled on public.customers'
    'RLS enabled on public.appointments'
    'RLS enabled on public.payment_transactions'
    'RLS enabled on public.payment_provider_events'
    'RLS enabled on public.checkout_holds'
    'RLS enabled on public.appointment_access_tokens'
    'RLS enabled on public.pre_reservation_access_tokens'
    'RLS enabled on public.google_connections'
    'RLS enabled on public.audit_logs'
    'RLS enabled on public.google_calendar_events'
  )

  if [[ ${#actual[@]} -ne ${#expected[@]} ]]; then
    echo "Item 2B before-state failure count changed: expected ${#expected[@]}, found ${#actual[@]}." >&2
    cat "$LOG" >&2
    exit 1
  fi
  for i in "${!expected[@]}"; do
    if [[ "${actual[$i]}" != "${expected[$i]}" ]]; then
      echo "Unexpected Item 2B before-state failure at position $i." >&2
      echo "expected: ${expected[$i]}" >&2
      echo "actual:   ${actual[$i]}" >&2
      cat "$LOG" >&2
      exit 1
    fi
  done
  echo 'Item 2B before-state proven: exactly the 10 intended tables fail RLS; customer_balance_movements is already green.'
else
  if [[ ${#actual[@]} -ne 0 ]]; then
    echo "Item 2B after-state is not fully green: ${#actual[@]} failure(s)." >&2
    cat "$LOG" >&2
    exit 1
  fi
  echo 'Item 2B after-state proven: all 11 sensitive tables are deny-by-default RLS with no direct policies.'
fi
