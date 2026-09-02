#!/usr/bin/env bash
set -euo pipefail

guard='scripts/verify-local-verification-env.sh'
source_file='supabase/functions/.env.local-verification.example'
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

bash "$guard" "$source_file" >/dev/null

expect_reject() {
  local name="$1"
  local assignment="$2"
  cp "$source_file" "$tmpdir/$name.env"
  printf '\n%s\n' "$assignment" >> "$tmpdir/$name.env"
  if bash "$guard" "$tmpdir/$name.env" >/dev/null 2>&1; then
    echo "expected safety guard to reject: $name" >&2
    exit 1
  fi
}

expect_reject prod_ref 'SUPABASE_URL=https://sbexdggbwqvyhbkatucs.supabase.co'
expect_reject mp_token 'MERCADO_PAGO_PRODUCTION_ACCESS_TOKEN=APP_USR-real-looking-token'
expect_reject google_secret 'GOOGLE_CLIENT_SECRET=GOCSPX-real-looking-secret'
expect_reject real_charges 'ALLOW_REAL_CHARGES=true'

echo 'local verification safety guard: ok'
