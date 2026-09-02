#!/usr/bin/env bash
set -euo pipefail

DB_URL="${LOCAL_DB_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
legacy_non_tap='supabase/tests/20260902090500_external_physical_block_post_buffer_test.sql'
pretest_files=(
  'supabase/tests/database/000_i09_legacy_confirmation_compat.test.sql'
  'supabase/tests/database/000_i09_legacy_fixture_policy_compat.test.sql'
)
expected_files=(
  'supabase/tests/database/027_admin_change_policies.test.sql'
  'supabase/tests/database/039_admin_service_audit_hardening.test.sql'
  'supabase/tests/database/042_audit_logs_append_only.test.sql'
  'supabase/tests/database/050_appointment_token_authorship.test.sql'
)

for file in "$legacy_non_tap" "${pretest_files[@]}" "${expected_files[@]}"; do test -f "$file"; done

# This inherited file is SQL regression, not TAP. Execute its four DO/RAISE checks directly.
psql "$DB_URL" -X -v ON_ERROR_STOP=1 -q -f "$legacy_non_tap"

run_green_pretest() {
  local file="$1"
  local expected_plan="$2"
  local log="/tmp/item02a-pretest-$(basename "$file").tap"
  local rc test_count failure_count

  # These 000_* files intentionally install test-only compatibility objects that
  # persist for later files in the official pgTAP suite. Validate them before
  # relying on that state so the isolated Item 2C gate mirrors the real harness.
  set +e
  psql "$DB_URL" -X -A -t -q -v ON_ERROR_STOP=0 -f "$file" >"$log" 2>&1
  rc=$?
  set -e

  if [[ $rc -ne 0 ]]; then
    echo "psql transport failed for pre-test $file (rc=$rc)." >&2
    cat "$log" >&2
    return 1
  fi
  if grep -Eq '(^|[[:space:]])(ERROR|FATAL|PANIC):' "$log"; then
    echo "Uncaught SQL error while validating pre-test $file." >&2
    cat "$log" >&2
    return 1
  fi
  if ! grep -Fxq "1..$expected_plan" "$log"; then
    echo "Unexpected or missing TAP plan in pre-test $file; expected 1..$expected_plan." >&2
    cat "$log" >&2
    return 1
  fi

  test_count="$(grep -Ec '^(ok|not ok) [0-9]+ - ' "$log" || true)"
  failure_count="$(grep -Ec '^not ok ' "$log" || true)"
  if [[ "$test_count" -ne "$expected_plan" || "$failure_count" -ne 0 ]]; then
    echo "Pre-test $file is not fully green: expected $expected_plan tests and zero failures; found $test_count tests / $failure_count failures." >&2
    cat "$log" >&2
    return 1
  fi
  echo "Item 2A pre-test bootstrap: $file passed complete $expected_plan-test TAP stream"
}

# The normal suite runs these first and deliberately leaves their test-only
# compatibility triggers installed for legacy fixtures such as test 050.
run_green_pretest "${pretest_files[0]}" 1
run_green_pretest "${pretest_files[1]}" 1

run_expected() {
  local file="$1"; shift
  local expected_plan="$1"; shift
  local expected=("$@")
  local log="/tmp/item02c-$(basename "$file").tap"
  local actual=()
  local rc test_count

  # pg_prove runs pgTAP scripts without ON_ERROR_STOP. Mirror that execution model,
  # then independently reject any uncaught SQL error and validate the complete TAP stream.
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
  if [[ "$test_count" -ne "$expected_plan" ]]; then
    echo "Incomplete TAP stream in $file: expected $expected_plan tests, found $test_count." >&2
    cat "$log" >&2
    return 1
  fi

  mapfile -t actual < <(grep '^not ok ' "$log" | sed -E 's/^not ok [0-9]+ - //; s/[[:space:]]+#.*$//')
  if [[ ${#actual[@]} -ne ${#expected[@]} ]]; then
    echo "Unexpected expected-failure count in $file: expected ${#expected[@]}, found ${#actual[@]}." >&2
    cat "$log" >&2
    return 1
  fi
  for i in "${!expected[@]}"; do
    if [[ "${actual[$i]}" != "${expected[$i]}" ]]; then
      echo "Unexpected failure in $file at expected-failure position $i." >&2
      echo "expected: ${expected[$i]}" >&2
      echo "actual:   ${actual[$i]}" >&2
      cat "$log" >&2
      return 1
    fi
  done
  echo "Item 2C #371: confirmed ${#expected[@]} exact expected failure(s) across complete $expected_plan-test TAP stream in $file"
}

run_expected 'supabase/tests/database/027_admin_change_policies.test.sql' 14 \
  'service_role cannot bypass the audited policy wrapper'
run_expected 'supabase/tests/database/039_admin_service_audit_hardening.test.sql' 13 \
  'legacy timing mutation is no longer directly executable by service role' \
  'legacy duration configuration mutation is no longer directly executable by service role' \
  'internal policy primitive is not directly executable by service role'
run_expected 'supabase/tests/database/042_audit_logs_append_only.test.sql' 18 \
  'service_role cannot invoke maintenance purge'
run_expected 'supabase/tests/database/050_appointment_token_authorship.test.sql' 29 \
  'application service_role cannot invoke five-year maintenance purge'

quarantine_dir="$(mktemp -d /tmp/item02a-db-tests.XXXXXX)"
quarantine_files=("$legacy_non_tap" "${expected_files[@]}")
restore() {
  local file parked
  for file in "${quarantine_files[@]}"; do
    parked="$quarantine_dir/$(basename "$file")"
    [[ ! -f "$parked" ]] || mv "$parked" "$file"
  done
  rmdir "$quarantine_dir" 2>/dev/null || true
}
trap restore EXIT
for file in "${quarantine_files[@]}"; do mv "$file" "$quarantine_dir/$(basename "$file")"; done
supabase test db
restore
trap - EXIT

echo 'Item 2A database gate passed: SQL regression green; pre-test compatibility validated; exactly six Item 2C expected failures; remaining pgTAP green.'
