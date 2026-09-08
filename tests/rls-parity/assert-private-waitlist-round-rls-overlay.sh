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
EOF
sort -o "$EXPECTED" "$EXPECTED"

if ! diff -u "$EXPECTED" "$ACTUAL"; then
  echo "Unexpected RLS delta beyond the reviewed private-waitlist-round tables." >&2
  exit 1
fi

echo "PRIVATE_WAITLIST_ROUND_RLS_OVERLAY_OK"
