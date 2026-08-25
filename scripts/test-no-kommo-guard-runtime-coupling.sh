#!/usr/bin/env bash
set -euo pipefail

# Kommo Guard is remote-only sandbox drift tracked in #190. The authoritative
# Agenda runtime must not acquire a dependency on its tables/functions until
# ownership is explicitly resolved and a source-controlled migration exists.
#
# One historical migration is intentionally allowed: it only hardens the
# search_path of kommo_guard_adjust_due when that remote-only helper happens to
# exist in a hosted environment. It does not create, call or depend on it.
legacy_hardening='supabase/migrations/20260824185024_harden_internal_trigger_rpcs.sql'

legacy_count="$(grep -Fc "p.proname = 'kommo_guard_adjust_due'" "$legacy_hardening" || true)"
if [[ "$legacy_count" != "1" ]]; then
  echo "Expected exactly one defensive legacy hardening reference in $legacy_hardening; found $legacy_count." >&2
  exit 1
fi

migration_matches="$(grep -RIn --binary-files=without-match --exclude='*.md' --exclude="$(basename "$legacy_hardening")" 'kommo_guard_' supabase/migrations || true)"
function_matches="$(grep -RIn --binary-files=without-match --exclude='*.md' 'kommo_guard_' supabase/functions || true)"
matches="${migration_matches}${function_matches:+$'\n'${function_matches}}"

if [[ -n "$matches" ]]; then
  echo 'Authoritative Agenda runtime references remote-only kommo_guard_* schema:' >&2
  printf '%s\n' "$matches" >&2
  echo 'Resolve ownership in #190 before introducing any runtime dependency.' >&2
  exit 1
fi

echo 'PASS: no authoritative migration/Edge Function depends on remote-only kommo_guard_* schema.'
