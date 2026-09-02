#!/usr/bin/env bash
set -euo pipefail

DB_URL="${LOCAL_DB_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
legacy_non_tap='supabase/tests/20260902090500_external_physical_block_post_buffer_test.sql'

test -f "$legacy_non_tap"

# This inherited file is SQL regression, not TAP. Execute its DO/RAISE checks
# directly, then remove it only while the official pgTAP runner executes.
psql "$DB_URL" -X -v ON_ERROR_STOP=1 -q -f "$legacy_non_tap"

quarantine_dir="$(mktemp -d /tmp/database-core-tests.XXXXXX)"
restore() {
  local parked="$quarantine_dir/$(basename "$legacy_non_tap")"
  [[ ! -f "$parked" ]] || mv "$parked" "$legacy_non_tap"
  rmdir "$quarantine_dir" 2>/dev/null || true
}
trap restore EXIT

mv "$legacy_non_tap" "$quarantine_dir/$(basename "$legacy_non_tap")"
supabase test db
restore
trap - EXIT

echo 'Database Core gate passed: non-TAP SQL regression green and complete pgTAP suite green with zero expected-failure quarantine.'
