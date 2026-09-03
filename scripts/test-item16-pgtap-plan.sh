#!/usr/bin/env bash
set -euo pipefail

target='supabase/tests/20260902090500_external_physical_block_post_buffer_test.sql'
harnesses=(
  'scripts/test-database-core-gates.sh'
  'scripts/test-item02a-database-gates.sh'
)

test -f "$target"
for harness in "${harnesses[@]}"; do
  test -f "$harness"
done

grep -Eq '^[[:space:]]*select[[:space:]]+plan\([[:space:]]*4[[:space:]]*\);' "$target"

assertions=$(grep -Ec '^[[:space:]]*select[[:space:]]+(is|ok|isnt|cmp_ok)\(' "$target" || true)
if [[ "$assertions" -ne 4 ]]; then
  echo "Item 16 requires exactly 4 explicit pgTAP assertions; found $assertions" >&2
  exit 1
fi

if grep -Eq 'do[[:space:]]+\$test\$|raise[[:space:]]+exception' "$target"; then
  echo 'Item 16 target still contains legacy DO/RAISE checks instead of pgTAP assertions.' >&2
  exit 1
fi

for harness in "${harnesses[@]}"; do
  if grep -Eq 'legacy_non_tap|quarantine_dir|mv[[:space:]].*external_physical_block_post_buffer_test|psql.*external_physical_block_post_buffer_test' "$harness"; then
    echo "$harness still special-cases/quarantines the Item 16 test." >&2
    exit 1
  fi
  grep -Eq 'supabase[[:space:]]+test[[:space:]]+db' "$harness"
done

echo 'ITEM16_PGTAP_PLAN_OK'
