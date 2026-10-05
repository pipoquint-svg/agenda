#!/usr/bin/env bash
set -euo pipefail

BASELINE="${1:-tests/rls-parity/production_rls_baseline.txt}"
ACTUAL="${2:-/tmp/local-rls-baseline.txt}"
EXPECTED="$(mktemp)"
trap 'rm -f "$EXPECTED"' EXIT

cat "$BASELINE" > "$EXPECTED"
cat >> "$EXPECTED" <<'EOF'
TABLE|waitlist_private_round_invites|true|false
TABLE|waitlist_private_round_slots|true|false
TABLE|waitlist_private_rounds|true|false
TABLE|appointment_post_booking_extras|true|false
TABLE|tenant_capabilities|true|false
TABLE|tenant_members|true|false
TABLE|tenant_settings|true|false
TABLE|tenants|true|false
EOF
sort -o "$EXPECTED" "$EXPECTED"

if ! diff -u "$EXPECTED" "$ACTUAL"; then
  echo "Unexpected RLS delta beyond reviewed private-waitlist-round, tenant-foundation and post-booking-extra tables." >&2
  exit 1
fi

echo "PRIVATE_WAITLIST_ROUND_RLS_OVERLAY_OK"
