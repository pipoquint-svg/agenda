#!/usr/bin/env bash
set -euo pipefail

DB_URL="${1:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
LOG_FILE="${2:-/tmp/item02a-private-waitlist-overlay.log}"

set +e
psql "$DB_URL" \
  -v ON_ERROR_STOP=1 \
  -f tests/acl-parity/item02a_acl_parity.sql \
  > "$LOG_FILE" 2>&1
rc=$?
set -e
cat "$LOG_FILE"

# The authoritative Item 2A file still describes deployed production. This
# feature intentionally extends that schema, so the old production comparison
# must fail — but only by the exact, reviewed private-waitlist delta below.
if [[ "$rc" -eq 0 ]]; then
  echo 'Private waitlist overlay unexpectedly matches the old production ACL baseline.' >&2
  exit 1
fi
grep -Fq 'ACL_PARITY_IDENTITY_DIFF_PRESENT' "$LOG_FILE"

for expected in \
  $'IDENTITY_SUMMARY\tfunction\t440\t051eff0670edc6ecf07d783a23f430be026cc9e596e0d6afd05a5a9479cd488a' \
  $'IDENTITY_SUMMARY\tsequence\t3\t175a4c7ab0f0c8b1f173a13ae52e1bb1fedc145cebd4a4b6d944a6c9f29a2ba0' \
  $'IDENTITY_SUMMARY\ttable\t111\t6596dbe2a07e4f9cbb6aa64a014cb932258adc85ff02d6702d531e0a03643b3c' \
  $'IDENTITY_SUMMARY\tview\t8\tbcb8b6692e6b40eaf95ef20d1c9e115ad622c27c4fc0f78d0e3b4907c5b1b6c2' \
  $'ACL_SUMMARY\tfunction\t440\t846\t5008c6ecd3a4c67859395addeff58a67e0817e3136e3329fb3aa384d9e1f4448' \
  $'ACL_SUMMARY\tsequence\t3\t15\tae67d7f57fc8786c476d71d39252720bc9a2bdc650696ff198556de85cc64294' \
  $'ACL_SUMMARY\ttable\t111\t1698\t17a1ac8d87a4dc4334b63418e3b18e06c7697713da5e0cb5b76bceaf49db7271' \
  $'ACL_SUMMARY\tview\t8\t128\tf09dedfa6c33eb98d6840f295c537ce4be013f4f6949c094d7b28ebc14e164be'
do
  grep -Fxq "$expected" "$LOG_FILE"
done

# Only function/table identity and summary counts may differ from deployed
# production. Sequence/view drift would indicate an unrelated change.
test "$(grep -c '^IDENTITY_DIFF' "$LOG_FILE" || true)" -eq 4
for expected in \
  $'IDENTITY_DIFF\tACTUAL\tfunction\t440\t051eff0670edc6ecf07d783a23f430be026cc9e596e0d6afd05a5a9479cd488a' \
  $'IDENTITY_DIFF\tPRODUCTION\tfunction\t421\t7373e550eabdc3854b1feb70fcf2a84fcf3ec33183c0acec95b606eaa64af706' \
  $'IDENTITY_DIFF\tACTUAL\ttable\t111\t6596dbe2a07e4f9cbb6aa64a014cb932258adc85ff02d6702d531e0a03643b3c' \
  $'IDENTITY_DIFF\tPRODUCTION\ttable\t107\t11c6e40d0e805d0718ee7def831e0b43b608d38b33880e8c03a6b2928f08b535'
do
  grep -Fxq "$expected" "$LOG_FILE"
done

test "$(grep -c '^ACL_SUMMARY_DIFF' "$LOG_FILE" || true)" -eq 4
for expected in \
  $'ACL_SUMMARY_DIFF\tACTUAL\tfunction\t440\t846\t5008c6ecd3a4c67859395addeff58a67e0817e3136e3329fb3aa384d9e1f4448' \
  $'ACL_SUMMARY_DIFF\tPRODUCTION\tfunction\t421\t812\t28b8c4bf36d11fb225556a2a8cc3d0689734c518e5ac6b0adcc68c7330d4a6ed' \
  $'ACL_SUMMARY_DIFF\tACTUAL\ttable\t111\t1698\t17a1ac8d87a4dc4334b63418e3b18e06c7697713da5e0cb5b76bceaf49db7271' \
  $'ACL_SUMMARY_DIFF\tPRODUCTION\ttable\t107\t1634\t29e28820938fa434b31793f0a66609b62829fc65a27d188f45ae3d59dbef5cdc'
do
  grep -Fxq "$expected" "$LOG_FILE"
done

# The only row-level ACL delta is that the four new trigger helpers are
# intentionally NOT executable by service_role. No ACTUAL_ONLY grant is allowed.
test "$(grep -c '^ACL_ROW_DIFF' "$LOG_FILE" || true)" -eq 4
if grep -q $'^ACL_ROW_DIFF\tACTUAL_ONLY\t' "$LOG_FILE"; then
  echo 'Unexpected additional ACL grant in private waitlist overlay.' >&2
  exit 1
fi
for expected in \
  $'ACL_ROW_DIFF\tEXPECTED_ONLY\tfunction\tpublic.trg_restore_waitlist_private_slot_allocation()\tpostgres\tservice_role\tpostgres\tEXECUTE\tf' \
  $'ACL_ROW_DIFF\tEXPECTED_ONLY\tfunction\tpublic.trg_sync_waitlist_private_appointment_status()\tpostgres\tservice_role\tpostgres\tEXECUTE\tf' \
  $'ACL_ROW_DIFF\tEXPECTED_ONLY\tfunction\tpublic.trg_sync_waitlist_private_checkout_promotion()\tpostgres\tservice_role\tpostgres\tEXECUTE\tf' \
  $'ACL_ROW_DIFF\tEXPECTED_ONLY\tfunction\tpublic.trg_validate_waitlist_private_slot_service()\tpostgres\tservice_role\tpostgres\tEXECUTE\tf'
do
  grep -Fxq "$expected" "$LOG_FILE"
done

echo 'ITEM02A_PRIVATE_WAITLIST_OVERLAY_OK' | tee -a "$LOG_FILE"
