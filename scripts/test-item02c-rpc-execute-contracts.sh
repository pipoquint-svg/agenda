#!/usr/bin/env bash
set -euo pipefail

DB_URL="${LOCAL_DB_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
MODE="${1:-}"
overlay='tests/acl-parity/item02c_acl_overlay.sql'
pretest_files=(
  'supabase/tests/database/000_i09_legacy_confirmation_compat.test.sql'
  'supabase/tests/database/000_i09_legacy_fixture_policy_compat.test.sql'
)
target_files=(
  'supabase/tests/database/027_admin_change_policies.test.sql'
  'supabase/tests/database/039_admin_service_audit_hardening.test.sql'
  'supabase/tests/database/042_audit_logs_append_only.test.sql'
  'supabase/tests/database/050_appointment_token_authorship.test.sql'
)

case "$MODE" in
  before|after) ;;
  *) echo 'usage: test-item02c-rpc-execute-contracts.sh before|after' >&2; exit 2 ;;
esac

for file in "$overlay" "${pretest_files[@]}" "${target_files[@]}"; do
  test -f "$file"
done

run_tap() {
  local file="$1"; shift
  local expected_plan="$1"; shift
  local expected=("$@")
  local log="/tmp/item02c-$(basename "$file").tap"
  local rc test_count failure_count
  local actual=()

  set +e
  psql "$DB_URL" -X -A -t -q -v ON_ERROR_STOP=0 -f "$file" >"$log" 2>&1
  rc=$?
  set -e

  if [[ $rc -ne 0 ]]; then
    echo "psql transport failed for $file (rc=$rc)." >&2
    cat "$log" >&2
    return 1
  fi
  if grep -Eq '(^|[[:space:]])(ERROR|FATAL|PANIC):' "$log"; then
    echo "Uncaught SQL error while validating $file." >&2
    cat "$log" >&2
    return 1
  fi
  if ! grep -Fxq "1..$expected_plan" "$log"; then
    echo "Unexpected or missing TAP plan in $file; expected 1..$expected_plan." >&2
    cat "$log" >&2
    return 1
  fi

  test_count="$(grep -Ec '^(ok|not ok) [0-9]+ - ' "$log" || true)"
  failure_count="$(grep -Ec '^not ok ' "$log" || true)"
  if [[ "$test_count" -ne "$expected_plan" ]]; then
    echo "Incomplete TAP stream in $file: expected $expected_plan tests, found $test_count." >&2
    cat "$log" >&2
    return 1
  fi

  mapfile -t actual < <(grep '^not ok ' "$log" | sed -E 's/^not ok [0-9]+ - //; s/[[:space:]]+#.*$//')
  if [[ ${#actual[@]} -ne ${#expected[@]} ]]; then
    echo "Unexpected failure count in $file: expected ${#expected[@]}, found $failure_count." >&2
    cat "$log" >&2
    return 1
  fi
  for i in "${!expected[@]}"; do
    if [[ "${actual[$i]}" != "${expected[$i]}" ]]; then
      echo "Unexpected failure in $file at position $i." >&2
      echo "expected: ${expected[$i]}" >&2
      echo "actual:   ${actual[$i]}" >&2
      cat "$log" >&2
      return 1
    fi
  done
}

if [[ "$MODE" == 'before' ]]; then
  # Measure the clean rebuilt schema before test-only compatibility functions
  # are installed. The overlay must fail only because the primitives are still
  # executable before the Item 2C migration.
  set +e
  psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f "$overlay" > /tmp/item02c-overlay-before.log 2>&1
  overlay_rc=$?
  set -e
  cat /tmp/item02c-overlay-before.log
  if [[ $overlay_rc -eq 0 ]]; then
    echo 'Item 2C ACL overlay unexpectedly passed before the migration.' >&2
    exit 1
  fi
  grep -Fq 'ITEM02C_PRIMITIVE_STILL_EXECUTABLE:' /tmp/item02c-overlay-before.log

  # These tests install explicit test-only compatibility objects required by
  # the target pgTAP fixtures. Run them only after the ACL inventory proof so
  # their helper functions cannot contaminate production-relevant counts.
  run_tap "${pretest_files[0]}" 1
  run_tap "${pretest_files[1]}" 1

  run_tap 'supabase/tests/database/027_admin_change_policies.test.sql' 14 \
    'service_role cannot bypass the audited policy wrapper'
  run_tap 'supabase/tests/database/039_admin_service_audit_hardening.test.sql' 13 \
    'legacy timing mutation is no longer directly executable by service role' \
    'legacy duration configuration mutation is no longer directly executable by service role' \
    'internal policy primitive is not directly executable by service role'
  run_tap 'supabase/tests/database/042_audit_logs_append_only.test.sql' 18 \
    'service_role cannot invoke maintenance purge'
  run_tap 'supabase/tests/database/050_appointment_token_authorship.test.sql' 29 \
    'application service_role cannot invoke five-year maintenance purge'

  echo 'Item 2C before gate passed: exactly six #371 failures and primitive EXECUTE exposure reproduced.'
  exit 0
fi

# On the post-migration state, prove the clean schema ACL contract before any
# test-only compatibility helper functions are created.
psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f "$overlay" | tee /tmp/item02c-overlay-after.log
grep -Fxq 'ITEM02C_ACL_OVERLAY_OK' /tmp/item02c-overlay-after.log

run_tap "${pretest_files[0]}" 1
run_tap "${pretest_files[1]}" 1
run_tap 'supabase/tests/database/027_admin_change_policies.test.sql' 14
run_tap 'supabase/tests/database/039_admin_service_audit_hardening.test.sql' 13
run_tap 'supabase/tests/database/042_audit_logs_append_only.test.sql' 18
run_tap 'supabase/tests/database/050_appointment_token_authorship.test.sql' 29

echo 'Item 2C after gate passed: ACL overlay exact and all #371 assertions green.'
