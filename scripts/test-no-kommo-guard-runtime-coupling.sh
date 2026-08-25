#!/usr/bin/env bash
set -euo pipefail

# Kommo Guard started as remote-only sandbox drift tracked in #190. The
# authoritative Agenda runtime must not acquire an operational dependency on
# its tables/functions. Two source-controlled migrations are intentionally
# allowed:
# 1) historical defensive search_path hardening when the helper happens to exist;
# 2) the audited cleanup migration that removes the isolated drift without CASCADE.
legacy_hardening='supabase/migrations/20260824185024_harden_internal_trigger_rpcs.sql'
cleanup_migration='supabase/migrations/20260825154800_remove_kommo_guard_drift.sql'

legacy_count="$(grep -Fc "p.proname = 'kommo_guard_adjust_due'" "$legacy_hardening" || true)"
if [[ "$legacy_count" != "1" ]]; then
  echo "Expected exactly one defensive legacy hardening reference in $legacy_hardening; found $legacy_count." >&2
  exit 1
fi

if [[ ! -f "$cleanup_migration" ]]; then
  echo "Expected audited Kommo Guard cleanup migration: $cleanup_migration" >&2
  exit 1
fi

# The cleanup exception is deliberately narrow: it must be removal-only,
# explicit, non-CASCADE, and retain fail-closed drift assertions.
grep -Fq 'KOMMO_GUARD_CLEANUP_INVENTORY_MISMATCH' "$cleanup_migration"
grep -Fq 'KOMMO_GUARD_CLEANUP_DATA_DRIFT_DETECTED' "$cleanup_migration"
grep -Fq 'KOMMO_GUARD_CLEANUP_EXTERNAL_FK_DEPENDENCY' "$cleanup_migration"
grep -Fq 'DROP FUNCTION IF EXISTS public.kommo_guard_adjust_due(timestamptz);' "$cleanup_migration"

# Ignore comments when checking executable SQL. Mentioning CASCADE in the safety
# contract must not itself trip the gate.
executable_cleanup="$(grep -Ev '^[[:space:]]*--' "$cleanup_migration" || true)"
if grep -Eiq '(^|[[:space:]])CASCADE([[:space:];]|$)' <<<"$executable_cleanup"; then
  echo 'Kommo Guard cleanup migration must not use CASCADE.' >&2
  exit 1
fi
if grep -Eiq '(^|[[:space:]])CREATE[[:space:]]+(TABLE|FUNCTION|TRIGGER|POLICY|VIEW)[[:space:]]' <<<"$executable_cleanup"; then
  echo 'Kommo Guard cleanup migration must not recreate runtime objects.' >&2
  exit 1
fi

migration_matches="$(grep -RIn --binary-files=without-match --exclude='*.md' \
  --exclude="$(basename "$legacy_hardening")" \
  --exclude="$(basename "$cleanup_migration")" \
  'kommo_guard_' supabase/migrations || true)"
function_matches="$(grep -RIn --binary-files=without-match --exclude='*.md' 'kommo_guard_' supabase/functions || true)"
matches="${migration_matches}${function_matches:+$'\n'${function_matches}}"

if [[ -n "$matches" ]]; then
  echo 'Authoritative Agenda runtime references isolated kommo_guard_* schema outside approved hardening/cleanup migrations:' >&2
  printf '%s\n' "$matches" >&2
  exit 1
fi

echo 'PASS: no Agenda runtime coupling to kommo_guard_*; only audited hardening/cleanup migrations are present.'
