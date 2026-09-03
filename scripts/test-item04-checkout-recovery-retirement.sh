#!/usr/bin/env bash
set -euo pipefail

DB_URL="${LOCAL_DB_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
MODE="${1:-}"
TEST_FILE='supabase/tests/database/015_short_hold_recovery.test.sql'

case "$MODE" in
  before|after) ;;
  *) echo 'usage: test-item04-checkout-recovery-retirement.sh before|after' >&2; exit 2 ;;
esac

test -f "$TEST_FILE"

collect_findings() {
  psql "$DB_URL" -X -A -t -q -v ON_ERROR_STOP=1 <<'SQL'
with findings(ord, finding, present) as (
  values
    (1, 'PLAINTEXT_COLUMN_PRESENT', exists (
      select 1 from information_schema.columns
      where table_schema='public' and table_name='checkout_holds' and column_name='recovery_public_token'
    )),
    (2, 'PLAINTEXT_COLUMN_NOT_NULL', exists (
      select 1 from information_schema.columns
      where table_schema='public' and table_name='checkout_holds' and column_name='recovery_public_token' and is_nullable='NO'
    )),
    (3, 'PLAINTEXT_DEFAULT_PRESENT', exists (
      select 1 from information_schema.columns
      where table_schema='public' and table_name='checkout_holds' and column_name='recovery_public_token' and column_default is not null
    )),
    (4, 'PLAINTEXT_INDEX_PRESENT', to_regclass('public.checkout_holds_recovery_public_token_uq') is not null),
    (5, 'EXPIRY_NOT_NULL', exists (
      select 1 from information_schema.columns
      where table_schema='public' and table_name='checkout_holds' and column_name='recovery_token_expires_at' and is_nullable='NO'
    )),
    (6, 'EXPIRY_DEFAULT_PRESENT', exists (
      select 1 from information_schema.columns
      where table_schema='public' and table_name='checkout_holds' and column_name='recovery_token_expires_at' and column_default is not null
    )),
    (7, 'RESUME_RPC_PLAINTEXT_LOOKUP', exists (
      select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.proname='get_checkout_hold_resume_context'
        and pg_get_function_identity_arguments(p.oid)='p_recovery_token text'
        and p.prosrc ilike '%recovery_public_token%'
    )),
    (8, 'RECOVERY_SETTER_LIVE', exists (
      select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.proname='set_checkout_hold_recovery_contact'
        and pg_get_function_identity_arguments(p.oid)='p_checkout_hold_token text, p_phone text, p_enabled boolean'
        and p.prosrc not ilike '%CHECKOUT_RECOVERY_RETIRED%'
    )),
    (9, 'RETIREMENT_CONSTRAINT_MISSING', not exists (
      select 1 from pg_constraint
      where conrelid='public.checkout_holds'::regclass
        and conname='checkout_holds_recovery_retired_check'
        and convalidated
    ))
)
select finding from findings where present order by ord;
SQL
}

run_tap() {
  local log='/tmp/item04-short-hold-recovery.tap'
  local rc test_count failure_count
  set +e
  psql "$DB_URL" -X -A -t -q -v ON_ERROR_STOP=0 -f "$TEST_FILE" >"$log" 2>&1
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    echo "psql transport failed for $TEST_FILE (rc=$rc)." >&2
    cat "$log" >&2
    exit 1
  fi
  if grep -Eq '(^|[[:space:]])(ERROR|FATAL|PANIC):' "$log"; then
    echo "Uncaught SQL error while validating $TEST_FILE." >&2
    cat "$log" >&2
    exit 1
  fi
  grep -Fxq '1..15' "$log" || { echo 'Unexpected TAP plan; expected 1..15.' >&2; cat "$log" >&2; exit 1; }
  test_count="$(grep -Ec '^(ok|not ok) [0-9]+ - ' "$log" || true)"
  failure_count="$(grep -Ec '^not ok ' "$log" || true)"
  if [[ "$test_count" -ne 15 || "$failure_count" -ne 0 ]]; then
    echo "Item 4 TAP contract failed: tests=$test_count failures=$failure_count." >&2
    cat "$log" >&2
    exit 1
  fi
}

mapfile -t actual < <(collect_findings)

if [[ "$MODE" == 'before' ]]; then
  expected=(
    'PLAINTEXT_COLUMN_PRESENT'
    'PLAINTEXT_COLUMN_NOT_NULL'
    'PLAINTEXT_DEFAULT_PRESENT'
    'PLAINTEXT_INDEX_PRESENT'
    'EXPIRY_NOT_NULL'
    'EXPIRY_DEFAULT_PRESENT'
    'RESUME_RPC_PLAINTEXT_LOOKUP'
    'RECOVERY_SETTER_LIVE'
    'RETIREMENT_CONSTRAINT_MISSING'
  )
  if [[ ${#actual[@]} -ne ${#expected[@]} ]]; then
    printf 'Item 4 before mismatch: expected %s findings, got %s.\n' "${#expected[@]}" "${#actual[@]}" >&2
    printf 'actual: %s\n' "${actual[@]}" >&2
    exit 1
  fi
  for i in "${!expected[@]}"; do
    if [[ "${actual[$i]}" != "${expected[$i]}" ]]; then
      echo "Item 4 before mismatch at position $i: expected ${expected[$i]}, got ${actual[$i]}" >&2
      exit 1
    fi
  done
  echo 'Item 4 before gate passed: exactly nine plaintext/retirement failures reproduced.'
  exit 0
fi

if [[ ${#actual[@]} -ne 0 ]]; then
  echo 'Item 4 after gate found residual recovery exposure:' >&2
  printf '  %s\n' "${actual[@]}" >&2
  exit 1
fi

psql "$DB_URL" -X -A -t -q -v ON_ERROR_STOP=1 <<'SQL' | grep -Fxq 'ITEM04_SCHEMA_OK'
select 'ITEM04_SCHEMA_OK'
where not exists (
        select 1 from information_schema.columns
        where table_schema='public' and table_name='checkout_holds' and column_name='recovery_public_token'
      )
  and exists (
        select 1 from information_schema.columns
        where table_schema='public' and table_name='checkout_holds'
          and column_name='recovery_token_expires_at'
          and is_nullable='YES' and column_default is null
      )
  and exists (
        select 1 from pg_constraint
        where conrelid='public.checkout_holds'::regclass
          and conname='checkout_holds_recovery_retired_check'
          and convalidated
      )
  and position('CHECKOUT_RECOVERY_RETIRED' in pg_get_functiondef('public.get_checkout_hold_resume_context(text)'::regprocedure)) > 0
  and position('recovery_public_token' in pg_get_functiondef('public.get_checkout_hold_resume_context(text)'::regprocedure)) = 0
  and position('CHECKOUT_RECOVERY_RETIRED' in pg_get_functiondef('public.set_checkout_hold_recovery_contact(text,text,boolean)'::regprocedure)) > 0;
SQL

run_tap

echo 'Item 4 after gate passed: plaintext capability removed and retired checkout flow remains fail-closed.'
