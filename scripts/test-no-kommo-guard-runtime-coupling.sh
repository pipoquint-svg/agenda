#!/usr/bin/env bash
set -euo pipefail

# Kommo Guard is remote-only sandbox drift tracked in #190. The authoritative
# Agenda runtime must not acquire a dependency on its tables/functions until
# ownership is explicitly resolved and a source-controlled migration exists.
roots=(supabase/migrations supabase/functions)

matches="$(grep -RIn --binary-files=without-match --exclude='*.md' 'kommo_guard_' "${roots[@]}" || true)"
if [[ -n "$matches" ]]; then
  echo 'Authoritative Agenda runtime references remote-only kommo_guard_* schema:' >&2
  printf '%s\n' "$matches" >&2
  echo 'Resolve ownership in #190 before introducing any runtime dependency.' >&2
  exit 1
fi

echo 'PASS: no authoritative migration/Edge Function depends on remote-only kommo_guard_* schema.'
