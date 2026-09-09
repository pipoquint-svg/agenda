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

# The authoritative Item 2A file still describes the older deployed production
# snapshot. Private waitlist slots, multi-slot rounds and the later manual-booking
# production RPCs intentionally extend that schema, so the old comparison must
# fail — but only by the exact reviewed delta captured below.
if [[ "$rc" -eq 0 ]]; then
  echo 'Current production overlay unexpectedly matches the old production ACL baseline.' >&2
  exit 1
fi
grep -Fq 'ACL_PARITY_IDENTITY_DIFF_PRESENT' "$LOG_FILE"

for expected in \
  $'IDENTITY_SUMMARY\tfunction\t447\t5aecebea14de141d6dc1ec9b3cf3bacd7057c19d727939b1fbd71fcef6eb1b59' \
  $'IDENTITY_SUMMARY\tsequence\t3\t175a4c7ab0f0c8b1f173a13ae52e1bb1fedc145cebd4a4b6d944a6c9f29a2ba0' \
  $'IDENTITY_SUMMARY\ttable\t114\t47098d3fc3c871939b099a30b9f65bcd3f98a90df3fee6d5909533bcb57d74af' \
  $'IDENTITY_SUMMARY\tview\t8\tbcb8b6692e6b40eaf95ef20d1c9e115ad622c27c4fc0f78d0e3b4907c5b1b6c2' \
  $'ACL_SUMMARY\tfunction\t447\t861\t4b272081732896fae5ba7c2a0fceb75d38041dcda056affca433ebb9cf621607' \
  $'ACL_SUMMARY\tsequence\t3\t15\tae67d7f57fc8786c476d71d39252720bc9a2bdc650696ff198556de85cc64294' \
  $'ACL_SUMMARY\ttable\t114\t1722\tb64d5f3bde02bba203fad64617aed0da3f1b9bb43b4c3c2d5c5c9cb1e7c9648d' \
  $'ACL_SUMMARY\tview\t8\t128\tf09dedfa6c33eb98d6840f295c537ce4be013f4f6949c094d7b28ebc14e164be'
do
  grep -Fxq "$expected" "$LOG_FILE"
done

# Only function/table identity and summary counts may differ from the historical
# production snapshot. Sequence/view drift would indicate an unrelated change.
test "$(grep -c '^IDENTITY_DIFF' "$LOG_FILE" || true)" -eq 4
for expected in \
  $'IDENTITY_DIFF\tACTUAL\tfunction\t447\t5aecebea14de141d6dc1ec9b3cf3bacd7057c19d727939b1fbd71fcef6eb1b59' \
  $'IDENTITY_DIFF\tPRODUCTION\tfunction\t421\t7373e550eabdc3854b1feb70fcf2a84fcf3ec33183c0acec95b606eaa64af706' \
  $'IDENTITY_DIFF\tACTUAL\ttable\t114\t47098d3fc3c871939b099a30b9f65bcd3f98a90df3fee6d5909533bcb57d74af' \
  $'IDENTITY_DIFF\tPRODUCTION\ttable\t107\t11c6e40d0e805d0718ee7def831e0b43b608d38b33880e8c03a6b2928f08b535'
do
  grep -Fxq "$expected" "$LOG_FILE"
done

test "$(grep -c '^ACL_SUMMARY_DIFF' "$LOG_FILE" || true)" -eq 4
for expected in \
  $'ACL_SUMMARY_DIFF\tACTUAL\tfunction\t447\t861\t4b272081732896fae5ba7c2a0fceb75d38041dcda056affca433ebb9cf621607' \
  $'ACL_SUMMARY_DIFF\tPRODUCTION\tfunction\t421\t812\t28b8c4bf36d11fb225556a2a8cc3d0689734c518e5ac6b0adcc68c7330d4a6ed' \
  $'ACL_SUMMARY_DIFF\tACTUAL\ttable\t114\t1722\tb64d5f3bde02bba203fad64617aed0da3f1b9bb43b4c3c2d5c5c9cb1e7c9648d' \
  $'ACL_SUMMARY_DIFF\tPRODUCTION\ttable\t107\t1634\t29e28820938fa434b31793f0a66609b62829fc65a27d188f45ae3d59dbef5cdc'
do
  grep -Fxq "$expected" "$LOG_FILE"
done

# Reviewed row-level delta:
# - the four private-slot trigger helpers remain trigger-only (no service_role
#   direct EXECUTE);
# - the three round tables are server-only storage and intentionally expose no
#   direct relation privilege to service_role at all;
# - the one ACTUAL_ONLY grant is the production admin-only manual confirmation
#   RPC. It is authenticated but performs auth.uid(), admin resolution,
#   AGENDA_MANAGE permission and ADMIN-origin checks before mutation.
test "$(grep -c '^ACL_ROW_DIFF' "$LOG_FILE" || true)" -eq 29
test "$(grep -c $'^ACL_ROW_DIFF\tACTUAL_ONLY\t' "$LOG_FILE" || true)" -eq 1
grep -Fxq $'ACL_ROW_DIFF\tACTUAL_ONLY\tfunction\tpublic.service_admin_confirm_manual_appointment_unpaid(p_appointment_id uuid, p_reason text)\tpostgres\tauthenticated\tpostgres\tEXECUTE\tf' "$LOG_FILE"

for expected in \
  $'ACL_ROW_DIFF\tEXPECTED_ONLY\tfunction\tpublic.trg_restore_waitlist_private_slot_allocation()\tpostgres\tservice_role\tpostgres\tEXECUTE\tf' \
  $'ACL_ROW_DIFF\tEXPECTED_ONLY\tfunction\tpublic.trg_sync_waitlist_private_appointment_status()\tpostgres\tservice_role\tpostgres\tEXECUTE\tf' \
  $'ACL_ROW_DIFF\tEXPECTED_ONLY\tfunction\tpublic.trg_sync_waitlist_private_checkout_promotion()\tpostgres\tservice_role\tpostgres\tEXECUTE\tf' \
  $'ACL_ROW_DIFF\tEXPECTED_ONLY\tfunction\tpublic.trg_validate_waitlist_private_slot_service()\tpostgres\tservice_role\tpostgres\tEXECUTE\tf' \
  $'ACL_ROW_DIFF\tEXPECTED_ONLY\ttable\tpublic.waitlist_private_round_invites\tpostgres\tservice_role\tpostgres\tDELETE\tf' \
  $'ACL_ROW_DIFF\tEXPECTED_ONLY\ttable\tpublic.waitlist_private_round_invites\tpostgres\tservice_role\tpostgres\tINSERT\tf' \
  $'ACL_ROW_DIFF\tEXPECTED_ONLY\ttable\tpublic.waitlist_private_round_invites\tpostgres\tservice_role\tpostgres\tMAINTAIN\tf' \
  $'ACL_ROW_DIFF\tEXPECTED_ONLY\ttable\tpublic.waitlist_private_round_invites\tpostgres\tservice_role\tpostgres\tREFERENCES\tf' \
  $'ACL_ROW_DIFF\tEXPECTED_ONLY\ttable\tpublic.waitlist_private_round_invites\tpostgres\tservice_role\tpostgres\tSELECT\tf' \
  $'ACL_ROW_DIFF\tEXPECTED_ONLY\ttable\tpublic.waitlist_private_round_invites\tpostgres\tservice_role\tpostgres\tTRIGGER\tf' \
  $'ACL_ROW_DIFF\tEXPECTED_ONLY\ttable\tpublic.waitlist_private_round_invites\tpostgres\tservice_role\tpostgres\tTRUNCATE\tf' \
  $'ACL_ROW_DIFF\tEXPECTED_ONLY\ttable\tpublic.waitlist_private_round_invites\tpostgres\tservice_role\tpostgres\tUPDATE\tf' \
  $'ACL_ROW_DIFF\tEXPECTED_ONLY\ttable\tpublic.waitlist_private_round_slots\tpostgres\tservice_role\tpostgres\tDELETE\tf' \
  $'ACL_ROW_DIFF\tEXPECTED_ONLY\ttable\tpublic.waitlist_private_round_slots\tpostgres\tservice_role\tpostgres\tINSERT\tf' \
  $'ACL_ROW_DIFF\tEXPECTED_ONLY\ttable\tpublic.waitlist_private_round_slots\tpostgres\tservice_role\tpostgres\tMAINTAIN\tf' \
  $'ACL_ROW_DIFF\tEXPECTED_ONLY\ttable\tpublic.waitlist_private_round_slots\tpostgres\tservice_role\tpostgres\tREFERENCES\tf' \
  $'ACL_ROW_DIFF\tEXPECTED_ONLY\ttable\tpublic.waitlist_private_round_slots\tpostgres\tservice_role\tpostgres\tSELECT\tf' \
  $'ACL_ROW_DIFF\tEXPECTED_ONLY\ttable\tpublic.waitlist_private_round_slots\tpostgres\tservice_role\tpostgres\tTRIGGER\tf' \
  $'ACL_ROW_DIFF\tEXPECTED_ONLY\ttable\tpublic.waitlist_private_round_slots\tpostgres\tservice_role\tpostgres\tTRUNCATE\tf' \
  $'ACL_ROW_DIFF\tEXPECTED_ONLY\ttable\tpublic.waitlist_private_round_slots\tpostgres\tservice_role\tpostgres\tUPDATE\tf' \
  $'ACL_ROW_DIFF\tEXPECTED_ONLY\ttable\tpublic.waitlist_private_rounds\tpostgres\tservice_role\tpostgres\tDELETE\tf' \
  $'ACL_ROW_DIFF\tEXPECTED_ONLY\ttable\tpublic.waitlist_private_rounds\tpostgres\tservice_role\tpostgres\tINSERT\tf' \
  $'ACL_ROW_DIFF\tEXPECTED_ONLY\ttable\tpublic.waitlist_private_rounds\tpostgres\tservice_role\tpostgres\tMAINTAIN\tf' \
  $'ACL_ROW_DIFF\tEXPECTED_ONLY\ttable\tpublic.waitlist_private_rounds\tpostgres\tservice_role\tpostgres\tREFERENCES\tf' \
  $'ACL_ROW_DIFF\tEXPECTED_ONLY\ttable\tpublic.waitlist_private_rounds\tpostgres\tservice_role\tpostgres\tSELECT\tf' \
  $'ACL_ROW_DIFF\tEXPECTED_ONLY\ttable\tpublic.waitlist_private_rounds\tpostgres\tservice_role\tpostgres\tTRIGGER\tf' \
  $'ACL_ROW_DIFF\tEXPECTED_ONLY\ttable\tpublic.waitlist_private_rounds\tpostgres\tservice_role\tpostgres\tTRUNCATE\tf' \
  $'ACL_ROW_DIFF\tEXPECTED_ONLY\ttable\tpublic.waitlist_private_rounds\tpostgres\tservice_role\tpostgres\tUPDATE\tf'
do
  grep -Fxq "$expected" "$LOG_FILE"
done

echo 'ITEM02A_PRIVATE_WAITLIST_OVERLAY_OK' | tee -a "$LOG_FILE"
